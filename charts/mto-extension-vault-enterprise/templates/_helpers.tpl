{{/*
Returns "true" when the given component should render in this pass, "" when
it should not. Every template block belongs to exactly one component (core,
eso); component=all renders both. Fails the render on an unrecognized
.Values.component so a typo surfaces loudly instead of silently emitting
nothing.
Usage:  {{ if include "vault.componentEnabled" (dict "component" "eso" "ctx" $) }}
*/}}
{{- define "vault.componentEnabled" -}}
{{- $valid := list "all" "core" "eso" -}}
{{- if not (has .ctx.Values.component $valid) -}}
{{- fail (printf "unknown component %q — must be one of: %s" .ctx.Values.component (join ", " $valid)) -}}
{{- end -}}
{{- /* Helm ignores unknown values, so a values file still setting a removed
       feature would believe it is on. Checked here because every template
       calls this first; the file named in the error is incidental. */ -}}
{{- if hasKey .ctx.Values "networkPolicy" -}}
{{- fail "networkPolicy was removed: a default-deny egress policy for tenant workloads is not this chart's to own (use MTO's network policies). Delete networkPolicy from your values" -}}
{{- end -}}
{{- if hasKey ((.ctx.Values.sso | default dict).oidc | default dict) "perTenantClient" -}}
{{- fail "sso.oidc.perTenantClient was removed: every tenant uses the one shared IdP client sso.oidc.clientId. Delete sso.oidc.perTenantClient from your values" -}}
{{- end -}}
{{- if hasKey (.ctx.Values.sso | default dict) "audience" -}}
{{- fail "sso.audience was removed: every SSO role accepts sso.oidc.clientId as the audience, because an ID token's aud is the client ID it was issued to. Delete sso.audience from your values (set sso.oidc.clientId to your IdP client instead)" -}}
{{- end -}}
{{- /* A sliced render only happens under the bootstrap's per-tenant
       TemplateInstance convention (mto-extension-vault-enterprise-<tenant>[.eso]), and
       template-operator-v2 stamps that TI name as a label value on every
       rendered resource — Kubernetes caps label values at 63 chars. Fail with a
       clear message instead of letting every object bounce off server-side
       dry-run with an opaque invalid-label error. component=all (standalone,
       no TI) is exempt. */ -}}
{{- if ne .ctx.Values.component "all" -}}
{{- $suffix := index (dict "core" "" "eso" ".eso") .ctx.Values.component -}}
{{- $tiName := printf "mto-extension-vault-enterprise-%s%s" (.ctx.Values.tenant | default "") $suffix -}}
{{- if gt (len $tiName) 63 -}}
{{- fail (printf "tenant name %q (%d chars) makes TemplateInstance name %q %d chars; it is stamped as a label value on every rendered resource and label values cap at 63 — shorten the tenant name (budget: ≤32 core, ≤28 .eso). Checked in every template, so the file named above is incidental." .ctx.Values.tenant (len .ctx.Values.tenant) $tiName (len $tiName)) -}}
{{- end -}}
{{- end -}}
{{- if or (eq .ctx.Values.component "all") (eq .ctx.Values.component .component) -}}true{{- end -}}
{{- end -}}

{{/*
Returns "true" when a toggle is on, "" when it is off. A boolean, or the string
"true"/"false"; absent or null is off. Anything else fails. Never test a toggle
with a bare `if .Values.x.enabled`: the string "false" is non-empty, so it is
TRUE to Go templates, and the schema accepts it (it has to — t-op-v2 and
--set-string send strings).
Usage: {{ if include "vault.on" (dict "name" "sso.enabled" "value" .Values.sso.enabled) }}
*/}}
{{- define "vault.on" -}}
{{- $v := .value -}}
{{- if kindIs "invalid" $v -}}
{{- else -}}
{{- $s := toString $v -}}
{{- if not (has $s (list "true" "false")) -}}
{{- fail (printf "%s must be true or false — got %q" .name $s) -}}
{{- end -}}
{{- if eq $s "true" -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Fails the render if a generated resource name exceeds the 253-char Kubernetes
metadata.name limit, naming the offender. Returns the name unchanged.
*/}}
{{- define "vault.assertName" -}}
{{- if gt (len .) 253 -}}
{{- fail (printf "generated resource name %q is %d chars, over the 253-char Kubernetes name limit — shorten the tenant, namespace, service-account, or peer name" . (len .)) -}}
{{- end -}}
{{- . -}}
{{- end -}}

{{/*
Per-SA own-tenant role/policy name: kv.<tenant>.<saNs>.<sa>.

Joined with dots because none of the parts can contain one: the tenant is
checked by vault.labels, a namespace is a DNS label, and saFacts rejects a
dotted ServiceAccount name. With hyphens, namespace t-web + ServiceAccount api-x
and namespace t-web-api + ServiceAccount x gave the same name, and two tenants
whose names are prefixes of each other could collide in configNamespace.

The `kv.` prefix keeps the name families apart: kv.* has 4 parts, sso.* 3 and
share.* 6, so no name of one family can equal a name of another. Without it,
tenant "sso" with namespace "acme" and ServiceAccount "admin" rendered Policy
sso.acme.admin, the name of tenant acme's SSO admin Policy.

The role annotation is deliberately not part of it: a role change would become
a rename.
*/}}
{{- define "vault.roleName" -}}
{{- include "vault.assertName" (printf "kv.%s.%s.%s" .tenant .saNs .saName) -}}
{{- end -}}

{{/* Cross-tenant share-out role/policy name: share.<tenant>.<saNs>.<sa>.out.<peer>. */}}
{{- define "vault.shareOutName" -}}
{{- include "vault.assertName" (printf "share.%s.%s.%s.out.%s" .tenant .saNs .saName .peer) -}}
{{- end -}}

{{/* Cross-tenant share-in role/policy name: share.<tenant>.<saNs>.<sa>.in.<peer>. */}}
{{- define "vault.shareInName" -}}
{{- include "vault.assertName" (printf "share.%s.%s.%s.in.%s" .tenant .saNs .saName .peer) -}}
{{- end -}}

{{/*
Returns "true" when a cross-tenant share to .peer should be rendered: .peer is
non-empty AND either .knownCsv is empty (no roster supplied, filtering off) or
.peer is in it. Skipping an unknown peer avoids a dangling Policy/Role for a
tenant that does not exist; the share self-heals when that tenant appears.
*/}}
{{- define "vault.peerEmittable" -}}
{{- $peer := .peer -}}
{{- $csv := toString (.knownCsv | default "") -}}
{{- if not $peer -}}
{{- else if not (trim $csv) -}}
true
{{- else -}}
{{- $known := list -}}
{{- range $t := splitList "," $csv -}}{{- $known = append $known (trim $t) -}}{{- end -}}
{{- if has $peer $known -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Renders the IdP-side group name for a (tenant, role) pair.
Resolution: tenantRoleMapping[<role>].pattern → tenantGroupTemplate → fail.
*/}}
{{- define "vault.ssoGroup" -}}
{{- $roleEntry := index .mapping .role -}}
{{- $pattern := "" -}}
{{- if and $roleEntry $roleEntry.pattern -}}
{{- $pattern = $roleEntry.pattern -}}
{{- else if .defaultTemplate -}}
{{- $pattern = .defaultTemplate -}}
{{- else -}}
{{- fail (printf "sso: role %q has no pattern and no sso.tenantGroupTemplate default is set" .role) -}}
{{- end -}}
{{- $s := $pattern -}}
{{- $s = replace "{tenant}" .tenant $s -}}
{{- $s = replace "{role}" .role $s -}}
{{- $s -}}
{{- end -}}

{{/* SSO Vault role/policy name for a (tenant, role) pair: sso.<tenant>.<role>. */}}
{{- define "vault.ssoRoleName" -}}
{{- printf "sso.%s.%s" .tenant .role -}}
{{- end -}}

{{/*
Common labels stamped on every chart-emitted resource. The tenant label is the
same key the parent's namespaceSelector uses.
*/}}
{{- define "vault.labels" -}}
{{- $t := toString (required ".Values.tenant must be set by the parent" .Values.tenant) -}}
{{- /* A DNS label: it names the Vault namespace, is a label value, and is a
       part of dot-joined names that must stay unambiguous. The Tenant CRD
       itself does not restrict names. */ -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $t) -}}
{{- fail (printf "tenant name %q is not a DNS label (lowercase letters, digits and hyphens, no dots)" $t) -}}
{{- end -}}
{{- if gt (len $t) 63 -}}
{{- fail (printf "tenant name %q is %d chars; it is stamped as the %q label value on every resource and a Kubernetes label value must be <=63 chars" $t (len $t) .Values.tenantLabelKey) -}}
{{- end -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: helm-via-template-operator-v2
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{ .Values.tenantLabelKey }}: {{ $t | quote }}
{{- end -}}

{{/*
The spec.authentication block of every VCO CR. VCO logs in to vco.namespace
(empty = root) and, when .target is set, manages the object in
<vco.namespace>/<target> — targetNamespace is relative to the login namespace.
Usage:
  spec:
    {{- include "vault.vcoAuth" (dict "ctx" $ "target" $tenant) | nindent 2 }}
*/}}
{{- define "vault.vcoAuth" -}}
{{- $v := .ctx.Values.vco -}}
authentication:
  path: {{ required "vco.authPath must be set" $v.authPath }}
  role: {{ required "vco.role must be set" $v.role }}
  serviceAccount:
    name: {{ required "vco.serviceAccount must be set" $v.serviceAccount }}
  {{- with $v.namespace }}
  namespace: {{ . | quote }}
  {{- end }}
  {{- with .target }}
  targetNamespace: {{ . | quote }}
  {{- end }}
{{- end -}}

{{/*
Full Vault namespace path of a tenant (or the shared) namespace, as a client
sees it: <vco.namespace>/<name>. This is what VAULT_NAMESPACE and the ESO
SecretStore carry. VCO's targetNamespace is relative, so both sides agree.
Usage: {{ include "vault.nsPath" (dict "ctx" $ "name" $tenant) }}
*/}}
{{- define "vault.nsPath" -}}
{{- $parent := trimAll "/" (.ctx.Values.vco.namespace | default "") -}}
{{- $name := trimAll "/" .name -}}
{{- if $parent -}}{{- printf "%s/%s" $parent $name -}}{{- else -}}{{- $name -}}{{- end -}}
{{- end -}}

{{/* The workload kubernetes auth mount, as Vault sees it: <path>/<name>. */}}
{{- define "vault.k8sAuthMount" -}}
{{- printf "%s/%s" (trimAll "/" .Values.kubernetesAuth.path) (trimAll "/" .Values.kubernetesAuth.name) -}}
{{- end -}}

{{/* The SSO OIDC auth mount, as Vault sees it: <path>/<name>. */}}
{{- define "vault.ssoMount" -}}
{{- printf "%s/%s" (trimAll "/" .Values.sso.mount.path) (trimAll "/" .Values.sso.mount.name) -}}
{{- end -}}

{{/*
A workload token duration, in the integer seconds VCO's KubernetesAuthEngineRole
takes. A duration string ("1h") would render fine and then fail server-side
validation of the whole TemplateInstance apply, so it is rejected here with the
fix in the message. Returns "" for 0, meaning "omit, use Vault's default".
Usage: {{ include "vault.tokenSeconds" (dict "name" "token.ttl" "value" $.Values.token.ttl) }}
*/}}
{{- define "vault.tokenSeconds" -}}
{{- $v := .value -}}
{{- /* sprig `get` returns "" for a missing key, so "" means unset. */ -}}
{{- if or (kindIs "invalid" $v) (and (kindIs "string" $v) (eq $v "")) -}}
{{- else if kindIs "string" $v -}}
{{- fail (printf "%s must be an integer number of seconds — got the string %q. vault-config-operator's KubernetesAuthEngineRole takes seconds (3600, not \"1h\")." .name $v) -}}
{{- else -}}
{{- $n := int64 $v -}}
{{- if ne (float64 $n) (float64 $v) -}}
{{- fail (printf "%s must be a whole number of seconds — got %v" .name $v) -}}
{{- end -}}
{{- if lt $n 0 -}}
{{- fail (printf "%s must not be negative — got %d" .name $n) -}}
{{- end -}}
{{- if gt $n 0 -}}{{- $n -}}{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Token type stamped on every KubernetesAuthEngineRole.

  service  Vault persists the token: it can be renewed and REVOKED, and it is
           enumerable through its accessor.
  batch    never written to storage; far cheaper per login, but it cannot be
           renewed, revoked or listed — its TTL is the only way to retire it.

token.period is rejected with batch: Vault accepts period on a batch token and
ignores it, so a grant that reads as periodic would not be.
*/}}
{{- define "vault.tokenType" -}}
{{- $token := .Values.token | default dict -}}
{{- $t := "service" -}}
{{- if hasKey $token "type" -}}
{{- $t = get $token "type" | toString -}}
{{- end -}}
{{- if not (has $t (list "service" "batch")) -}}
{{- fail (printf "token.type must be \"service\" or \"batch\" — got %q. Vault also accepts default/default-service/default-batch, which resolve against the auth mount's tune and so make the token semantics depend on state this chart does not own; they are rejected here." $t) -}}
{{- end -}}
{{- if and (eq $t "batch") (include "vault.tokenSeconds" (dict "name" "token.period" "value" (get $token "period"))) -}}
{{- fail (printf "token.type=batch with token.period=%v: a batch token cannot be renewed, and Vault silently ignores period on one. Set token.period to 0 or use token.type=service." (get $token "period")) -}}
{{- end -}}
{{- $t -}}
{{- end -}}

{{/*
The token fields of a KubernetesAuthEngineRole spec, shared by the own-tenant
and share roles so they cannot drift.
*/}}
{{- define "vault.roleTokenFields" -}}
tokenType: {{ include "vault.tokenType" . }}
{{- with include "vault.tokenSeconds" (dict "name" "token.ttl" "value" .Values.token.ttl) }}
tokenTTL: {{ . }}
{{- end }}
{{- with include "vault.tokenSeconds" (dict "name" "token.maxTTL" "value" .Values.token.maxTTL) }}
tokenMaxTTL: {{ . }}
{{- end }}
{{- with include "vault.tokenSeconds" (dict "name" "token.period" "value" .Values.token.period) }}
tokenPeriod: {{ . }}
{{- end }}
{{- end -}}

{{/*
The complete set of `vault.stakater.com/` keys this chart reads on a
ServiceAccount, so an unrecognised one is reported rather than ignored. A new
annotation must be added here too, or it is rejected as unknown — loud, and the
safe direction to fail.
*/}}
{{- define "vault.saAnnotationKeys" -}}
{{- $keys := list
      "kv" "role" "app"
      "kv-subscribe-ns" "kv-export-tenant" "kv-import-tenant" -}}
{{- toYaml $keys -}}
{{- end -}}

{{/*
Resolves and validates every `vault.stakater.com/` annotation on one
ServiceAccount, returning a YAML dict the caller parses with `fromYaml`. One
helper, so validation and the values used to render cannot drift apart.

Returns: name, ns, app, role, kvOn, caps, and `errors`. A non-empty `errors`
means the caller renders the error ConfigMap and nothing else for this
ServiceAccount.

Reported per ServiceAccount rather than failed: one TemplateInstance renders
every namespace a tenant owns, so `fail` would produce zero objects for the
tenant and freeze unrelated namespaces.
*/}}
{{- define "vault.saFacts" -}}
{{- /* Both maps are required. Defaulting them would leave the app-collision and
       foreign-namespace checks inert for a caller that forgot to thread them. */ -}}
{{- if not (hasKey . "appClaims") -}}
{{- fail "vault.saFacts requires an appClaims argument (see vault.appClaims); omitting it would silently disable the app-collision check" -}}
{{- end -}}
{{- if not (hasKey . "tenantNamespaces") -}}
{{- fail "vault.saFacts requires a tenantNamespaces argument (see vault.tenantNamespaces); omitting it would silently disable the foreign-namespace check" -}}
{{- end -}}
{{- $sa := .sa -}}
{{- $v := .ctx.Values -}}
{{- $p := "vault.stakater.com/" -}}
{{- $known := include "vault.saAnnotationKeys" . | fromYamlArray -}}
{{- $name := dig "metadata" "name" "" $sa -}}
{{- $ns := dig "metadata" "namespace" "" $sa -}}
{{- $ann := dig "metadata" "annotations" (dict) $sa -}}
{{- $errs := list -}}

{{- /* Unknown key, checked first: a misspelled key means nothing read below
       reflects what the user meant. transit and pki are named separately: they
       exist in the OpenBao extension and are a likely thing to try here. */ -}}
{{- $hasVault := false -}}
{{- range $k, $_ := $ann -}}
{{- if hasPrefix $p $k -}}
{{- $hasVault = true -}}
{{- $short := trimPrefix $p $k -}}
{{- if or (hasPrefix "transit" $short) (hasPrefix "pki" $short) -}}
{{- $errs = append $errs (printf "annotation %q is not supported: this extension configures KV only — transit and PKI are not available yet" $k) -}}
{{- else if not (has $short $known) -}}
{{- $errs = append $errs (printf "unknown annotation %q — this chart reads none of that name, so it has no effect. Valid keys: %s" $k (join ", " (sortAlpha $known))) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- /* Rendered ConfigMap and SecretStore names embed this name and reserve
       dot-separated suffixes (.error, .deploy-error, .share-<peer>-vault). */ -}}
{{- if and $hasVault (not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name)) -}}
{{- $errs = append $errs (printf "ServiceAccount name %q cannot be used with Vault: rendered ConfigMap and SecretStore names embed it and reserve dot-separated suffixes (.error, .share-<peer>-vault), so it must match ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ (lowercase letters, digits and hyphens — no dots). Rename the ServiceAccount" $name) -}}
{{- end -}}

{{- /* A misspelled boolean would leave KV off with no message. */ -}}
{{- $kvRaw := lower (trim (toString (dig "metadata" "annotations" (printf "%skv" $p) "" $sa))) -}}
{{- if and $kvRaw (not (has $kvRaw (list "true" "false"))) -}}
{{- $errs = append $errs (printf "%skv must be \"true\" or \"false\", got %q" $p $kvRaw) -}}
{{- end -}}
{{- $kvOn := eq $kvRaw "true" -}}

{{- $role := trim (toString (dig "metadata" "annotations" (printf "%srole" $p) "" $sa)) -}}
{{- $app := trim (toString (dig "metadata" "annotations" (printf "%sapp" $p) "" $sa)) -}}
{{- if not $app -}}{{- $app = $name -}}{{- end -}}

{{- /* Every pod that omits serviceAccountName runs as `default`, so granting it
       hands one identity and one prefix to all of them. */ -}}
{{- if and (eq $name "default") $kvOn -}}
{{- $errs = append $errs (printf "the `default` ServiceAccount cannot be granted Vault access: every pod that omits serviceAccountName runs as `default`, so they would all share one identity and the prefix kv/data/%s/%s/default/. Give each workload its own ServiceAccount and annotate that instead" $v.env $ns) -}}
{{- end -}}

{{- /* An engine without a role grants nothing, and a role without an engine
       grants nothing. */ -}}
{{- if and $role (not $kvOn) -}}
{{- $errs = append $errs (printf "%srole is set to %q but %skv is not \"true\", so nothing is granted" $p $role $p) -}}
{{- end -}}
{{- if and $kvOn (not $role) -}}
{{- $errs = append $errs (printf "%skv is \"true\" but %srole is not set, so no capabilities can be granted. Set a role: %s" $p $p (join ", " (keys $v.roleCaps | sortAlpha))) -}}
{{- end -}}
{{- if and (dig "metadata" "annotations" (printf "%sapp" $p) "" $sa) (not $kvOn) -}}
{{- $errs = append $errs (printf "%sapp is set but %skv is not \"true\", so no app identity is registered — it only names the prefix a KV grant would use" $p $p) -}}
{{- end -}}

{{- /* An unknown role makes the capability lookup nil, which would skip the
       ServiceAccount with no signal. */ -}}
{{- if and $role (not (hasKey $v.roleCaps $role)) -}}
{{- $errs = append $errs (printf "%srole %q is not a known role. Valid roles: %s" $p $role (join ", " (keys $v.roleCaps | sortAlpha))) -}}
{{- end -}}
{{- $caps := "" -}}
{{- if hasKey $v.roleCaps $role -}}
{{- $caps = index $v.roleCaps $role -}}
{{- end -}}
{{- if and $kvOn $role (hasKey $v.roleCaps $role) (or (not $caps) (eq $caps "[]")) -}}
{{- $errs = append $errs (printf "%skv is enabled but role %q grants no KV capabilities" $p $role) -}}
{{- end -}}

{{- /* The app name becomes a path segment inside an HCL policy body.
       Unvalidated it is not a name but a policy the tenant writes: a value with
       a quote and a brace closes our `path "..."` block and opens another, and
       `+` is Vault's single-segment wildcard. Underscore-prefixed names are
       reserved for chart-owned prefixes such as `_shared`. */ -}}
{{- if $kvOn -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $app) -}}
{{- $errs = append $errs (printf "%sapp %q is not a valid app name — it must match ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ (lowercase letters, digits and hyphens; no leading or trailing hyphen). It is used as a path segment in the Vault policy" $p $app) -}}
{{- else if gt (len $app) 63 -}}
{{- $errs = append $errs (printf "%sapp %q is %d characters; keep it to 63 or fewer" $p $app (len $app)) -}}
{{- end -}}
{{- end -}}

{{- /* Two ServiceAccounts resolving to one app share a prefix. Compared on
       RESOLVED names, so an SA that declared no `app` still defends its own
       name against another claiming it. */ -}}
{{- $claim := index .appClaims (printf "%s/%s" $ns $app) -}}
{{- if and $kvOn $claim (gt (len $claim) 1) -}}
{{- $errs = append $errs (printf "app %q in namespace %s is claimed by more than one ServiceAccount (%s). Each app owns its own secret prefix, so the name must be unique within the namespace — change %sapp on all but one" $app $ns (join ", " $claim) $p) -}}
{{- end -}}

{{- /* A sharing annotation with KV off grants nothing. */ -}}
{{- range $k := list "kv-subscribe-ns" "kv-export-tenant" "kv-import-tenant" -}}
{{- if and (dig "metadata" "annotations" (printf "%s%s" $p $k) "" $sa) (not $kvOn) -}}
{{- $errs = append $errs (printf "%s%s is set but %skv is not \"true\", so it grants nothing" $p $k $p) -}}
{{- end -}}
{{- end -}}

{{- /* A namespace outside the tenant grants read on a prefix nothing writes to. */ -}}
{{- range $subNs := splitList "," (dig "metadata" "annotations" (printf "%skv-subscribe-ns" $p) "" $sa) -}}
{{- $subNs = trim $subNs -}}
{{- if and $subNs (not (hasKey $.tenantNamespaces $subNs)) -}}
{{- $errs = append $errs (printf "%skv-subscribe-ns references namespace %q, which is not a namespace of tenant %q (tenant owns: %s)" $p $subNs $v.tenant (join ", " (keys $.tenantNamespaces | sortAlpha))) -}}
{{- end -}}
{{- end -}}

{{- $out := dict
      "name" $name "ns" $ns "app" $app "role" $role
      "kvOn" $kvOn "caps" $caps
      "errors" $errs -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Builds the (namespace, resolved app) claim map: "<ns>/<app>" -> sorted
ServiceAccount names resolving to it. Only ServiceAccounts with KV on claim an
app. Sorted so the message is stable whatever order the parent lists them in.
*/}}
{{- define "vault.appClaims" -}}
{{- $p := "vault.stakater.com/" -}}
{{- $claims := dict -}}
{{- range $sa := (ternary .Values.serviceAccounts (list) (kindIs "slice" .Values.serviceAccounts)) -}}
{{- $name := dig "metadata" "name" "" $sa -}}
{{- $ns := dig "metadata" "namespace" "" $sa -}}
{{- $on := eq (lower (trim (toString (dig "metadata" "annotations" (printf "%skv" $p) "" $sa)))) "true" -}}
{{- if and $on $name $ns -}}
{{- $app := trim (toString (dig "metadata" "annotations" (printf "%sapp" $p) "" $sa)) -}}
{{- if not $app -}}{{- $app = $name -}}{{- end -}}
{{- $k := printf "%s/%s" $ns $app -}}
{{- $_ := set $claims $k (append (index $claims $k | default (list)) $name | sortAlpha) -}}
{{- end -}}
{{- end -}}
{{- toYaml $claims -}}
{{- end -}}

{{/*
Reports a misconfiguration next to the object that carries it. No
`vault-config-<sa>` is rendered for a ServiceAccount with errors, so the pod
fails to start on the missing `configMapRef` and this object, beside it in the
same namespace, says why.
*/}}
{{- define "vault.errorConfigMap" -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .name }}
  namespace: {{ .ns }}
  labels:
    {{- .labels | nindent 4 }}
data:
  ERROR: |
    Vault access has NOT been configured for {{ .subject }}.
    {{- range $i, $e := .errors }}
    {{ add1 $i }}. {{ $e }}
    {{- end }}
{{- end -}}

{{/*
Set of every Kubernetes namespace this tenant owns, from the ServiceAccount and
Deployment lists the child TI resolves through its namespaceSelector.
*/}}
{{- define "vault.tenantNamespaces" -}}
{{- $ns := dict -}}
{{- range $sa := (ternary .Values.serviceAccounts (list) (kindIs "slice" .Values.serviceAccounts)) -}}
{{- $n := dig "metadata" "namespace" "" $sa -}}
{{- if $n }}{{- $_ := set $ns $n true -}}{{- end -}}
{{- end -}}
{{- range $d := (ternary .Values.deployments (list) (kindIs "slice" .Values.deployments)) -}}
{{- $n := dig "metadata" "namespace" "" $d -}}
{{- if $n }}{{- $_ := set $ns $n true -}}{{- end -}}
{{- end -}}
{{- toYaml $ns -}}
{{- end -}}
