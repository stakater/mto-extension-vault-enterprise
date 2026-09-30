{{- $cfgNs := .parameters.configNamespace }}
{{- $childTemplate := .parameters.childTemplateName }}
{{- $tenantLabel := .parameters.tenantLabelKey }}
{{- $shared := .parameters.sharedTenantName }}
{{- $eso := .parameters.eso }}
{{- $k8sPath := .parameters.k8sAuthPath }}
{{- $k8sName := .parameters.k8sAuthName }}
{{- $reviewer := .parameters.tokenReviewerServiceAccount }}
{{- /* The spec.authentication block every CR here carries. The tenant chart
       renders the same block from the same values. */ -}}
{{- $auth := printf "path: %s\n    role: %s\n    serviceAccount:\n      name: %s" .parameters.vcoAuthPath .parameters.vcoRole .parameters.vcoServiceAccount }}
{{- if .parameters.vcoNamespace }}
{{- $auth = printf "%s\n    namespace: %s" $auth (.parameters.vcoNamespace | quote) }}
{{- end }}
{{- /* Namespaces per tenant, counted from the <tenantLabel> label: the ONLY
       fact MTO and this chart both agree on. MTO puts that label on a
       namespace whether it is listed in the Tenant spec or adopted by label,
       and it is exactly what the child TI's namespaceSelector resolves. */ -}}
{{- $nsCount := dict }}
{{- range $ns := (default list .parameters.tenantNamespaces) }}
{{- $owner := dig "metadata" "labels" $tenantLabel "" $ns }}
{{- if $owner }}
{{- $_ := set $nsCount $owner (add1 (int (get $nsCount $owner))) }}
{{- end }}
{{- end }}
{{- /* Tenants this parent renders for. Skipped, and listed in the
       skipped-tenants ConfigMap with the reason, so a skip is visible:
         - a name that is not a DNS label: the Tenant CRD does not restrict
           names, and a dot or an uppercase letter breaks the Vault namespace,
           the label value and the dot-joined object names;
         - a name longer than 63 characters: it is the tenant label value on
           the Namespace and kv mount CRs below and in the child TI's
           namespaceSelector, and a label value caps at 63. Rendered, it would
           fail the apply of this whole render, for every tenant;
         - a name equal to the shared namespace: its Namespace CR would be the
           shared one, and two renders would fight over it through SSA. */ -}}
{{- $tenants := list }}
{{- $skipped := dict }}
{{- range $t := (default list .parameters.tenants) }}
{{- $n := toString $t.metadata.name }}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $n) }}
{{- $_ := set $skipped $n "the name is not a DNS label (lowercase letters, digits and hyphens, no dots): nothing is rendered for this tenant" }}
{{- else if gt (len $n) 63 }}
{{- $_ := set $skipped $n (printf "the name is %d characters: it is a label value, and label values cap at 63: nothing is rendered for this tenant" (len $n)) }}
{{- else if eq $n $shared }}
{{- $_ := set $skipped $n (printf "the name is the shared Vault namespace %q: nothing is rendered for this tenant" $shared) }}
{{- else }}
{{- $tenants = append $tenants $n }}
{{- end }}
{{- end }}
{{- /* Comma-separated roster of tenant names a share can usefully target: those
       with a labelled namespace, because only they get a workload render. It
       self-heals when a tenant gets its first labelled namespace. */ -}}
{{- $withNs := list }}
{{- range $n := $tenants }}
{{- if gt (int (get $nsCount $n)) 0 }}{{ $withNs = append $withNs $n }}{{ end }}
{{- end }}
{{- $knownTenants := join "," $withNs }}
{{- if $skipped }}
---
apiVersion: v1
kind: ConfigMap
metadata: { name: mto-extension-vault-enterprise-skipped-tenants, namespace: {{ $cfgNs }} }
data:
  {{- range $n, $reason := $skipped }}
  {{ $n | quote }}: {{ $reason | quote }}
  {{- end }}
{{- end }}
{{- /* The shared namespace: where cross-tenant shares land. */}}
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: Namespace
metadata: { name: {{ $shared | quote }}, namespace: {{ $cfgNs }} }
spec:
  authentication:
    {{ $auth }}
  name: {{ $shared | quote }}
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: SecretEngineMount
metadata: { name: {{ printf "%s-kv" $shared | quote }}, namespace: {{ $cfgNs }} }
spec:
  authentication:
    {{ $auth }}
    targetNamespace: {{ $shared | quote }}
  name: kv
  type: kv
  options:
    version: "2"
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: AuthEngineMount
metadata: { name: {{ printf "%s-kubernetes" $shared | quote }}, namespace: {{ $cfgNs }} }
spec:
  authentication:
    {{ $auth }}
    targetNamespace: {{ $shared | quote }}
  path: {{ $k8sPath }}
  name: {{ $k8sName }}
  type: kubernetes
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: KubernetesAuthEngineConfig
metadata: { name: {{ printf "%s-kubernetes-config" $shared | quote }}, namespace: {{ $cfgNs }} }
spec:
  authentication:
    {{ $auth }}
    targetNamespace: {{ $shared | quote }}
  path: {{ $k8sPath }}
  name: {{ $k8sName }}
  kubernetesHost: {{ .parameters.kubernetesHost }}
{{- if $reviewer }}
  tokenReviewerServiceAccount:
    name: {{ $reviewer }}
{{- end }}
{{- range $name := $tenants }}
{{- /* Every tenant's Vault namespace and kv mount, rendered HERE rather than
       in the tenant chart, so they live as long as the Tenant CR. The child
       TIs below exist only while the tenant has a labelled namespace; had the
       namespace and the mount been in them, deleting the tenant's last
       namespace would have deleted its Vault namespace and every secret in it. */}}
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: Namespace
metadata: { name: {{ $name | quote }}, namespace: {{ $cfgNs }}, labels: { {{ $tenantLabel }}: {{ $name | quote }} } }
spec:
  authentication:
    {{ $auth }}
  name: {{ $name | quote }}
---
apiVersion: redhatcop.redhat.io/v1alpha1
kind: SecretEngineMount
metadata: { name: {{ printf "%s-kv" $name | quote }}, namespace: {{ $cfgNs }}, labels: { {{ $tenantLabel }}: {{ $name | quote }} } }
spec:
  authentication:
    {{ $auth }}
    targetNamespace: {{ $name | quote }}
  name: kv
  type: kv
  options:
    version: "2"
{{- /* The workload render, only for a tenant with a labelled namespace: its
       child TI resolves serviceAccounts/deployments through a namespaceSelector
       on the tenant label, and with zero matching namespaces t-op-v2 fails it
       (NamespaceSelectorMatchedZero). It self-heals when the first namespace is
       labelled. One TI per enabled component; the optional suffix uses a dot
       because tenant names are DNS labels (checked above), so the core TI of
       tenant "<x>-eso" cannot collide with the eso TI of tenant "<x>". */ -}}
{{- if gt (int (get $nsCount $name)) 0 }}
{{- $slices := list (dict "suffix" "" "tmpl" "") }}
{{- if eq $eso "enabled" }}{{- $slices = append $slices (dict "suffix" ".eso" "tmpl" "-eso") }}{{- end }}
{{- range $slice := $slices }}
---
apiVersion: templates.v2.stakater.com/v2alpha1
kind: TemplateInstance
metadata:
  name: {{ printf "mto-extension-vault-enterprise-%s%s" $name $slice.suffix | quote }}
  namespace: {{ $cfgNs }}
spec:
  templateRef:
    name: {{ $childTemplate }}{{ $slice.tmpl }}
    namespace: {{ $cfgNs }}
  parameters:
    - name: tenant
      value: {{ $name | quote }}
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
              {{ $tenantLabel }}: {{ $name | quote }}
    - name: deployments
      valueFrom:
        objectFieldRef:
          apiVersion: apps/v1
          kind: Deployment
          jsonPath: .items
          namespaceSelector:
            matchLabels:
              {{ $tenantLabel }}: {{ $name | quote }}
{{- end }}
{{- end }}
{{- end }}
