{{/*
Integration toggles, validated and normalised in one place.

Every toggle is consumed as a STRING comparison (`eq … "true"` /
`eq … "enabled"`), because it travels through a t-op-v2 Template parameter,
which is typed string. That makes a typo silent: `yes`, `on`, `True` and `1`
all fail the comparison, so the integration renders nothing and says nothing.

These helpers `fail` on anything that is not a canonical value. For every value
they accept, the canonical form equals what `.Values.<toggle> | quote` would
have produced — the point is the guard, not the conversion. They are what
survive `--skip-schema-validation` and SDK render paths that do not apply
values.schema.json, and they give files/parent-gotemplate.tpl (rendered by
t-op-v2, where this chart's validation cannot reach) the guarantee that its
parameters are only ever "true"/"false" or "enabled"/"disabled".

Never compare .Values.<toggle> directly — go through the named helper.
*/}}
{{- define "mto-extension-vault-enterprise-bootstrap.boolValue" -}}
{{- $raw := .value -}}
{{- $s := "" -}}
{{- if kindIs "invalid" $raw -}}
{{- $s = "false" -}}
{{- else -}}
{{- $s = toString $raw -}}
{{- end -}}
{{- if not (has $s (list "true" "false")) -}}
{{- fail (printf "%s must be a boolean true or false — got %q. Quoted \"true\"/\"false\" also work; anything else (yes, on, 1, True, TRUE) is silently NOT enabled, so it is rejected here instead." .name $s) -}}
{{- end -}}
{{- $s -}}
{{- end -}}

{{- define "mto-extension-vault-enterprise-bootstrap.esoMode" -}}
{{- $raw := .Values.parent.eso -}}
{{- $s := "" -}}
{{- if kindIs "invalid" $raw -}}
{{- $s = "disabled" -}}
{{- else -}}
{{- $s = toString $raw -}}
{{- end -}}
{{- if not (has $s (list "enabled" "disabled")) -}}
{{- fail (printf "parent.eso must be \"enabled\" or \"disabled\" — got %q. It is a string, not a boolean: true/false/yes/on are silently NOT enabled, so they are rejected here instead." $s) -}}
{{- end -}}
{{- $s -}}
{{- end -}}

{{/* parent.sso is nullable, and a chained deref through it nil-pointers the
     whole render. `parent` itself is required by values.schema.json. */}}
{{- define "mto-extension-vault-enterprise-bootstrap.parentSso" -}}
{{- toYaml ((.Values.parent | default dict).sso | default dict) -}}
{{- end -}}

{{- define "mto-extension-vault-enterprise-bootstrap.ssoEnabled" -}}
{{- $sso := include "mto-extension-vault-enterprise-bootstrap.parentSso" . | fromYaml -}}
{{- include "mto-extension-vault-enterprise-bootstrap.boolValue" (dict "name" "parent.sso.enabled" "value" $sso.enabled) -}}
{{- end -}}

{{/*
Drift-protection block (t-op-v2 Template spec.sync) from .Values.sync. An absent
or null mode falls back to the chart default; an explicit empty string fails, so
a wrapper passing an unset variable cannot silently ship without drift
protection. Emits nothing for "off".
*/}}
{{- define "mto-extension-vault-enterprise-bootstrap.templateSync" -}}
{{- $sync := .Values.sync | default dict -}}
{{- $mode := "revert" -}}
{{- if hasKey $sync "mode" -}}
{{- $mode = $sync.mode | toString -}}
{{- end -}}
{{- if not (has $mode (list "off" "revert" "strict")) -}}
{{- fail (printf "sync.mode must be one of off, revert, strict — got %q (unquoted on/yes/true parse as YAML booleans; quote the value)" $mode) -}}
{{- end -}}
{{- if ne $mode "off" -}}
sync:
  mode: {{ $mode }}
{{- with $sync.ignoreFields }}
  ignoreFields:
    {{- toYaml . | nindent 4 }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
The redhatcop.redhat.io kinds the tenant chart and the parent render. One list,
so the RBAC ClusterRole, the RBAC Role and the Template outputs cannot drift.
Each entry: resource (plural, for RBAC) and kind (for outputs).
*/}}
{{- define "mto-extension-vault-enterprise-bootstrap.vcoKinds" -}}
- { resource: namespaces,                  kind: Namespace,                  output: namespaces }
- { resource: secretenginemounts,          kind: SecretEngineMount,          output: engines }
- { resource: authenginemounts,            kind: AuthEngineMount,            output: authMounts }
- { resource: kubernetesauthengineconfigs, kind: KubernetesAuthEngineConfig, output: k8sAuthConfigs }
- { resource: kubernetesauthengineroles,   kind: KubernetesAuthEngineRole,   output: k8sAuthRoles }
- { resource: policies,                    kind: Policy,                     output: policies }
- { resource: jwtoidcauthengineconfigs,    kind: JWTOIDCAuthEngineConfig,    output: oidcConfigs }
- { resource: jwtoidcauthengineroles,      kind: JWTOIDCAuthEngineRole,      output: oidcRoles }
{{- end -}}

{{/*
t-op-v2 status outputs for the VCO kinds, one output per kind.

VCO's status cannot say whether an object is healthy NOW. It sets two condition
types side by side — ReconcileSuccessful (always status True) and
ReconcileFailed (always status False) — and both lastTransitionTime values
freeze after their first write, because a condition's transition time only
moves when its status changes and these never do. So:
  <output>Succeeded  "True" once the object has been written to Vault at least
                     once; "[]" means never — the one unambiguous failure.
  <output>LastError  the message of the most recent failed reconcile, EVER. It
                     stays after the object recovers.
Field names carry the output name because t-op-v2 rejects a field name that
repeats across outputs, and then resolves none of them. Both are filter paths,
never scalars: a filter matching nothing resolves to "[]", a scalar matching
nothing fails the whole field.
Usage: {{ include "mto-extension-vault-enterprise-bootstrap.vcoOutputs" (dict "ns" $ns "kinds" $kinds) }}
*/}}
{{- define "mto-extension-vault-enterprise-bootstrap.vcoOutputs" -}}
{{- range $k := .kinds }}
- name: {{ $k.output }}
  fromAll:
    apiVersion: redhatcop.redhat.io/v1alpha1
    kind: {{ $k.kind }}
    namespace: {{ $.ns }}
  keyTemplate: "{.metadata.name}"
  fields:
    - { name: {{ $k.output }}Succeeded, jsonPath: "{.status.conditions[?(@.type=='ReconcileSuccessful')].status}" }
    - { name: {{ $k.output }}LastError, jsonPath: "{.status.conditions[?(@.type=='ReconcileFailed')].message}" }
{{- end }}
{{- end -}}

{{/*
The install-wide part of every child TemplateInstance's values, as YAML: the
tenant chart values that are the same for every tenant. Only tenant,
knownTenants, serviceAccounts and deployments differ per tenant; the child
valuesTemplate adds those as t-op-v2 placeholders.

.Values.tenantValues is merged in as given, so any tenant chart value can be set
install-wide (vaultCABundle, networkPolicy, monitoring, sso.oidc.*, sso.tiers,
tierCaps, …). A key this chart already owns fails the render instead of being
silently overridden, naming the bootstrap value to set instead.

t-op-v2 renders the valuesTemplate as a Go template, so a value containing "{{"
would be executed there; that fails here too.
*/}}
{{- define "mto-extension-vault-enterprise-bootstrap.installWideValues" -}}
{{- $tv := deepCopy (.Values.tenantValues | default dict) -}}
{{- $owned := dict
      "component" "set per slice by this chart"
      "tenant" "set per tenant by the parent"
      "knownTenants" "set per tenant by the parent"
      "serviceAccounts" "set per tenant by the parent"
      "deployments" "set per tenant by the parent"
      "env" "parent.env"
      "vaultServer" "parent.vaultServer"
      "eso" "parent.eso"
      "externalSecretRefreshInterval" "parent.externalSecretRefreshInterval"
      "configNamespace" "configNamespace"
      "vco" "vco"
      "kubernetesAuth" "kubernetesAuth"
      "tenantLabelKey" "parent.tenantLabelKey"
      "sharedTenant" "parent.sharedTenantName"
      "token" "parent.token" -}}
{{- range $k, $use := $owned -}}
{{- if hasKey $tv $k -}}
{{- fail (printf "tenantValues.%s is set by this chart — use %s instead" $k $use) -}}
{{- end -}}
{{- end -}}
{{- if hasKey $tv "networkPolicy" -}}
{{- fail "tenantValues.networkPolicy: the tenant chart's NetworkPolicy feature was removed — tenant egress policy belongs to MTO. Delete it" -}}
{{- end -}}
{{- $parentSso := include "mto-extension-vault-enterprise-bootstrap.parentSso" . | fromYaml -}}
{{- /* Checked here, once, rather than left to the tenant chart: there it fails
       every tenant's core render while this install reports success. */ -}}
{{- if and (eq (include "mto-extension-vault-enterprise-bootstrap.ssoEnabled" .) "true") (not $parentSso.issuerUrl) -}}
{{- fail "parent.sso.enabled=true requires parent.sso.issuerUrl — without it every tenant's render fails" -}}
{{- end -}}
{{- $sso := $tv.sso | default dict -}}
{{- range $k, $use := dict "enabled" "parent.sso.enabled" "allowedRedirectUris" "parent.sso.allowedRedirectUris" -}}
{{- if hasKey $sso $k -}}
{{- fail (printf "tenantValues.sso.%s is set by this chart — use %s instead" $k $use) -}}
{{- end -}}
{{- end -}}
{{- if hasKey $sso "audience" -}}
{{- fail "tenantValues.sso.audience was removed — every SSO role accepts tenantValues.sso.oidc.clientId as the audience, because an ID token's aud is the client ID. Delete it (set sso.oidc.clientId to your IdP client instead)" -}}
{{- end -}}
{{- $oidc := $sso.oidc | default dict -}}
{{- if hasKey $oidc "perTenantClient" -}}
{{- fail "tenantValues.sso.oidc.perTenantClient: the per-tenant client option was removed — every tenant uses the one shared IdP client sso.oidc.clientId. Delete it" -}}
{{- end -}}
{{- if hasKey $oidc "issuerUrl" -}}
{{- fail "tenantValues.sso.oidc.issuerUrl is set by this chart — use parent.sso.issuerUrl instead" -}}
{{- end -}}
{{- $_ := set $oidc "issuerUrl" ($parentSso.issuerUrl | default "") -}}
{{- $_ := set $sso "oidc" $oidc -}}
{{- $_ := set $sso "enabled" (eq (include "mto-extension-vault-enterprise-bootstrap.ssoEnabled" .) "true") -}}
{{- with $parentSso.allowedRedirectUris }}{{ $_ := set $sso "allowedRedirectUris" . }}{{ end -}}
{{- $_ := set $tv "sso" $sso -}}
{{- $_ := set $tv "env" .Values.parent.env -}}
{{- $_ := set $tv "vaultServer" .Values.parent.vaultServer -}}
{{- $_ := set $tv "eso" (include "mto-extension-vault-enterprise-bootstrap.esoMode" .) -}}
{{- $_ := set $tv "externalSecretRefreshInterval" .Values.parent.externalSecretRefreshInterval -}}
{{- $_ := set $tv "configNamespace" .Values.configNamespace -}}
{{- $_ := set $tv "vco" .Values.vco -}}
{{- $_ := set $tv "kubernetesAuth" .Values.kubernetesAuth -}}
{{- $_ := set $tv "tenantLabelKey" .Values.parent.tenantLabelKey -}}
{{- $_ := set $tv "sharedTenant" (dict "name" .Values.parent.sharedTenantName) -}}
{{- /* Built key-by-key and set only when one is given: an empty token map would
       wipe the tenant chart's own defaults. period is not plumbed on purpose. */ -}}
{{- $ptok := dict -}}
{{- $src := ((.Values.parent | default dict).token | default dict) -}}
{{- range $k := (list "type" "ttl" "maxTTL") -}}
{{- $v := get $src $k -}}
{{- if $v }}{{- $_ := set $ptok $k $v }}{{- end -}}
{{- end -}}
{{- with $ptok }}{{ $_ := set $tv "token" . }}{{ end -}}
{{- $out := toYaml $tv -}}
{{- if contains "{{" $out -}}
{{- fail "a tenant value contains \"{{\": t-op-v2 renders the child valuesTemplate as a Go template and would execute it. Remove it from tenantValues (or the value it came from)" -}}
{{- end -}}
{{- $out -}}
{{- end -}}

{{/*
"true" when an optional tenant-chart feature is switched on install-wide in
tenantValues. Used to gate the RBAC `create` that feature needs.
Usage: {{ include "mto-extension-vault-enterprise-bootstrap.tenantFeature" (dict "ctx" . "feature" "networkPolicy") }}
*/}}
{{- define "mto-extension-vault-enterprise-bootstrap.tenantFeature" -}}
{{- $f := get (.ctx.Values.tenantValues | default dict) .feature | default dict -}}
{{- $v := ternary (get $f "enabled") nil (hasKey $f "enabled") -}}
{{- include "mto-extension-vault-enterprise-bootstrap.boolValue" (dict "name" (printf "tenantValues.%s.enabled" .feature) "value" $v) -}}
{{- end -}}
