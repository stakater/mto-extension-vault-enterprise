{{- $env := .parameters.env }}
{{- $cfgNs := .parameters.configNamespace }}
{{- $childTemplate := .parameters.childTemplateName }}
{{- $tenantLabel := .parameters.tenantLabelKey }}
{{- $shared := .parameters.sharedTenantName }}
{{- $ssoEnabled := .parameters.ssoEnabled }}
{{- $ssoIssuerUrl := .parameters.ssoIssuerUrl }}
{{- $eso := .parameters.eso }}
{{- $esoRefresh := .parameters.externalSecretRefreshInterval }}
{{- $k8sPath := .parameters.k8sAuthPath }}
{{- $k8sName := .parameters.k8sAuthName }}
{{- $reviewer := .parameters.tokenReviewerServiceAccount }}
{{- /* The spec.authentication block every shared-scaffolding CR carries. The
       tenant chart renders the same block from the same values. */ -}}
{{- $auth := printf "path: %s\n    role: %s\n    serviceAccount:\n      name: %s" .parameters.vcoAuthPath .parameters.vcoRole .parameters.vcoServiceAccount }}
{{- if .parameters.vcoNamespace }}
{{- $auth = printf "%s\n    namespace: %s" $auth .parameters.vcoNamespace }}
{{- end }}
{{- /* Namespaces per tenant, counted from the <tenantLabel> label. This is the
       ONLY fact MTO and this chart both agree on: MTO puts that label on a
       namespace whether it is listed in the Tenant spec or adopted by label,
       and it is exactly what the child TI's namespaceSelector resolves. */ -}}
{{- $nsCount := dict }}
{{- range $ns := (default list .parameters.tenantNamespaces) }}
{{- $owner := dig "metadata" "labels" $tenantLabel "" $ns }}
{{- if $owner }}
{{- $_ := set $nsCount $owner (add1 (int (get $nsCount $owner))) }}
{{- end }}
{{- end }}
{{- /* Tenants this parent renders for: at least one labelled namespace, and not
       named like the shared namespace. A Tenant called <sharedTenantName> would
       render a Namespace CR with the same name as the shared one in the same
       Kubernetes namespace, and the two TemplateInstances would fight over it
       through server-side apply. */ -}}
{{- $tenantNames := list }}
{{- range $t := (default list .parameters.tenants) }}
{{- $n := $t.metadata.name }}
{{- if and (gt (int (get $nsCount $n)) 0) (ne $n $shared) }}
{{- $tenantNames = append $tenantNames $n }}
{{- end }}
{{- end }}
{{- $knownTenants := join "," $tenantNames }}
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: Namespace
metadata: { name: {{ $shared }}, namespace: {{ $cfgNs }} }
spec:
  authentication:
    {{ $auth }}
  name: {{ $shared }}
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: SecretEngineMount
metadata: { name: {{ $shared }}-kv, namespace: {{ $cfgNs }} }
spec:
  authentication:
    {{ $auth }}
    targetNamespace: {{ $shared }}
  name: kv
  type: kv
  options:
    version: "2"
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: AuthEngineMount
metadata: { name: {{ $shared }}-kubernetes, namespace: {{ $cfgNs }} }
spec:
  authentication:
    {{ $auth }}
    targetNamespace: {{ $shared }}
  path: {{ $k8sPath }}
  name: {{ $k8sName }}
  type: kubernetes
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: KubernetesAuthEngineConfig
metadata: { name: {{ $shared }}-kubernetes-config, namespace: {{ $cfgNs }} }
spec:
  authentication:
    {{ $auth }}
    targetNamespace: {{ $shared }}
  path: {{ $k8sPath }}
  name: {{ $k8sName }}
  kubernetesHost: {{ .parameters.kubernetesHost }}
{{- if $reviewer }}
  tokenReviewerServiceAccount:
    name: {{ $reviewer }}
{{- end }}
{{- range $name := $tenantNames }}
{{- /* A tenant with no labelled namespace was skipped above: its child TI would
       fail parameter validation (NamespaceSelectorMatchedZero). It self-heals —
       the parent re-renders once the tenant gets its first labelled namespace.
       One TI per enabled component; the optional suffix uses a dot because
       tenant names are RFC 1123 labels (no dots), so the core TI of tenant
       "<x>-eso" cannot collide with the eso TI of tenant "<x>". */ -}}
{{- $slices := list (dict "suffix" "" "tmpl" "") }}
{{- if eq $eso "enabled" }}{{- $slices = append $slices (dict "suffix" ".eso" "tmpl" "-eso") }}{{- end }}
{{- range $slice := $slices }}
---
apiVersion: templates.v2.stakater.com/v2alpha1
kind: TemplateInstance
metadata:
  name: mto-extension-vault-enterprise-{{ $name }}{{ $slice.suffix }}
  namespace: {{ $cfgNs }}
spec:
  templateRef:
    name: {{ $childTemplate }}{{ $slice.tmpl }}
    namespace: {{ $cfgNs }}
  parameters:
    - name: tenant
      value: {{ $name }}
    - name: env
      value: {{ $env }}
    - name: ssoEnabled
      value: {{ $ssoEnabled | quote }}
{{- if $ssoIssuerUrl }}
    - name: ssoIssuerUrl
      value: {{ $ssoIssuerUrl | quote }}
{{- end }}
    - name: eso
      value: {{ $eso }}
    - name: externalSecretRefreshInterval
      value: {{ $esoRefresh | quote }}
    - name: sharedTenantName
      value: {{ $shared }}
    - name: knownTenants
      value: {{ $knownTenants | quote }}
    - name: serviceAccounts
      valueFrom:
        objectFieldRef:
          apiVersion: v1
          kind: ServiceAccount
          jsonPath: .items
          namespaceSelector:
            matchLabels:
              {{ $tenantLabel }}: {{ $name }}
    - name: deployments
      valueFrom:
        objectFieldRef:
          apiVersion: apps/v1
          kind: Deployment
          jsonPath: .items
          namespaceSelector:
            matchLabels:
              {{ $tenantLabel }}: {{ $name }}
{{- end }}
{{- end }}
