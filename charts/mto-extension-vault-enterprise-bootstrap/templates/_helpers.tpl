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
