#!/usr/bin/env bash
# Render tests for the mto-extension-vault-enterprise charts.
#
# There is no controller in this repo to catch a mistake downstream: these
# checks are the quality gate. Rules every check follows:
#   - A check that can pass on its own failure is worse than no check. Render on
#     its own line, check the status, then assert on the output — never inside
#     $(...), which discards the exit status.
#   - Every guard is paired with a positive control, so a guard that rejects
#     everything cannot pass.
#   - Report line 1 of a failure: infrastructure errors print first.
#
#   1. golden       — component=all is object-set identical to the committed golden.
#   2. disjoint     — no object is emitted by both slices (two TIs would fight over it via SSA).
#   3. union        — core ∪ eso emits exactly the all set.
#   4. exclusivity  — external-secrets.io objects appear only in the eso slice.
#   5. empty        — the eso slice with no opt-ins renders zero objects.
#   6. badvalue     — an unknown component fails the render with the helper's message.
#   7. emission     — the parent emits one TI per enabled slice per tenant, none for a
#                     tenant without a labelled namespace or named like the shared
#                     namespace, and a roster of exactly the rendered tenants.
#   8. namebudget   — a sliced render fails when the TI name would exceed 63 chars;
#                     component=all is exempt.
#   9. templateset  — the bootstrap installs a child Template for exactly the enabled
#                     slices, and every templateRef the parent emits resolves.
#  10. rbacgate     — `create` on ESO kinds exists only while ESO is enabled; the reap
#                     verbs exist regardless (gating them wedges TI teardown).
#  11. rbaccover    — every redhatcop.redhat.io kind any render emits is in the
#                     ClusterRole (list only) and the configNamespace Role (all verbs).
#  12. toggles      — near-miss toggle values fail, via the schema with templates
#                     stripped AND via the helpers with the schema removed.
#  13. subread      — a kv-subscribe-ns grant is read-only on the producer's prefix,
#                     on the metadata path too.
#  14. guards       — every misconfigured ServiceAccount/Deployment gets an error
#                     ConfigMap and nothing else; the correct ones in another
#                     namespace still render; hostile values never reach a spec.
#  15. targetns     — every tenant CR except the Namespace carries
#                     authentication.targetNamespace = the tenant (or shared); the
#                     Namespace carries none. Without it the object lands in the
#                     login namespace — root — and tenants collide.
#  16. nsagree      — the Vault namespace the workload side uses (VAULT_NAMESPACE,
#                     SecretStore) equals <vco.namespace>/<target> for the VCO side.
#  17. mountagree   — the auth mount path agrees across AuthEngineMount,
#                     KubernetesAuthEngineConfig, every role, the SecretStores and
#                     VAULT_K8S_MOUNT.
#  18. tokenseconds — token durations are integers on every role; a duration string
#                     fails the render with the schema removed, and the schema
#                     rejects it too.
#  19. tokentype    — every role pins tokenType; batch + period fails.
#  20. nullfields   — no rendered field is YAML null when the tenant has no workloads.
#  21. ssoredirect  — empty sso.allowedRedirectUris fails at render, naming the value.
#  22. ssorootlist  — every SSO tier policy can LIST the kv mount root.
#  23. parentplumb  — install-wide knobs reach the child valuesTemplate and survive
#                     the tenant chart; an unset token block is omitted, not empty.
#  24. versionpin   — the bootstrap's tenantChart.version equals the tenant chart
#                     version.
#  25. outputnames  — output and field names are unique within every Template.
#                     t-op-v2 rejects a field name repeated across outputs and
#                     then resolves none of them (OutputsResolved=False).
#
# The parent gotemplate is rendered through helm's tpl — an approximation of
# t-op-v2's text/template+Sprig engine that is exact for the constructs it uses.
#
# Regenerating the golden after an INTENTIONAL chart change:
#   helm template mto-extension-vault-enterprise charts/mto-extension-vault-enterprise \
#     -n vault-config -f hack/render-fixtures/values-full.yaml \
#     | yq ea -P '[.] | sort_by(.apiVersion + "|" + .kind + "|" + (.metadata.namespace // "") + "|" + .metadata.name) | .[] | sort_keys(..) | splitDoc' \
#     > hack/render-fixtures/golden-all.yaml
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$REPO_ROOT/charts/mto-extension-vault-enterprise"
BOOTSTRAP="$REPO_ROOT/charts/mto-extension-vault-enterprise-bootstrap"
FIXTURES="$REPO_ROOT/hack/render-fixtures"
HELM="${HELM:-$(command -v "$REPO_ROOT/bin/helm" || command -v helm)}"
YQ="${YQ:-$(command -v "$REPO_ROOT/bin/yq" || command -v yq)}"
RELEASE=mto-extension-vault-enterprise
NS=vault-config
SLICES="core eso"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fail=0
check() { # check <name> <ok:0|1> [detail]
  if [ "$2" -eq 0 ]; then
    echo "PASS  $1"
  else
    echo "FAIL  $1${3:+ — $3}"
    fail=1
  fi
}
first() { head -1 "$1" | cut -c1-160; }
# yqs <var> <expr> <file>: run yq to completion into <var>. A yq error stops the
# run: it must never read as an empty result, which is the pass condition of
# every "must not contain" check. Never pipe a producer into `grep -q` here —
# under pipefail grep's early exit SIGPIPEs the producer, and the pipeline
# status then says nothing about the match.
yqs() {
  local __o
  __o="$("$YQ" e -N "$2" "$3" 2>"$WORK/yq.err")" \
    || { echo "FAIL  infra — yq failed on $3: $(first "$WORK/yq.err")"; exit 1; }
  printf -v "$1" '%s' "$__o"
}

render() { # render <component> <valuesfile> [extra helm args...] -> manifest on stdout
  local c="$1" v="$2"; shift 2
  "$HELM" template "$RELEASE" "$CHART" -n "$NS" -f "$v" --set "component=$c" "$@"
}

# Sort docs by identity and normalise key order so comparisons are stable.
normalize() {
  "$YQ" ea -P '[.] | sort_by(.apiVersion + "|" + .kind + "|" + (.metadata.namespace // "") + "|" + .metadata.name) | .[] | sort_keys(..) | splitDoc'
}
identities() { # identities <normalized-file>
  "$YQ" ea '[.apiVersion + "|" + .kind + "|" + (.metadata.namespace // "") + "|" + .metadata.name] | .[]' "$1" | sort
}

for c in all $SLICES; do
  render "$c" "$FIXTURES/values-full.yaml" > "$WORK/$c.raw" 2>"$WORK/$c.err" \
    || { echo "FAIL  setup — values-full component=$c did not render: $(first "$WORK/$c.err")"; exit 1; }
  normalize < "$WORK/$c.raw" > "$WORK/$c.yaml"
  identities "$WORK/$c.yaml" > "$WORK/$c.ids"
done
[ -s "$WORK/all.ids" ] || { echo "FAIL  setup — values-full rendered zero objects"; exit 1; }

# 1. golden
normalize < "$FIXTURES/golden-all.yaml" > "$WORK/golden.yaml"
diff -u "$WORK/golden.yaml" "$WORK/all.yaml" > "$WORK/golden.diff" \
  && check golden 0 \
  || check golden 1 "component=all drifted from golden-all.yaml (see header for regeneration); first lines: $(head -6 "$WORK/golden.diff" | tail -3 | tr '\n' ' ')"

# 2. disjoint
overlap="$(comm -12 "$WORK/core.ids" "$WORK/eso.ids")"
[ -z "$overlap" ] && check disjoint 0 || check disjoint 1 "emitted by both slices: $overlap"

# 3. union
sort "$WORK/core.ids" "$WORK/eso.ids" > "$WORK/union.ids"
diff "$WORK/union.ids" "$WORK/all.ids" > /dev/null \
  && check union 0 \
  || check union 1 "core ∪ eso ≠ all: $(diff "$WORK/union.ids" "$WORK/all.ids" | head -4 | tr '\n' ' ')"

# 4. exclusivity
ex_ok=0; ex_detail=""
eso_in_eso="$(grep -c '^apiVersion: external-secrets\.io/' "$WORK/eso.yaml" || true)"
eso_in_core="$(grep -c '^apiVersion: external-secrets\.io/' "$WORK/core.yaml" || true)"
[ "$eso_in_eso" -gt 0 ] || { ex_ok=1; ex_detail="$ex_detail external-secrets.io missing from eso;"; }
[ "$eso_in_core" -eq 0 ] || { ex_ok=1; ex_detail="$ex_detail external-secrets.io leaked into core ($eso_in_core);"; }
check exclusivity "$ex_ok" "$ex_detail"

# 5. empty
if render eso "$FIXTURES/values-no-optins.yaml" > "$WORK/empty.yaml" 2>"$WORK/empty.err"; then
  emptycount="$(normalize < "$WORK/empty.yaml" | grep -c '^kind:' || true)"
  [ "$emptycount" -eq 0 ] && check empty 0 || check empty 1 "expected 0 objects, got $emptycount"
else
  check empty 1 "render itself failed: $(first "$WORK/empty.err")"
fi

# 6. badvalue
if render bogus "$FIXTURES/values-full.yaml" > /dev/null 2> "$WORK/bogus.err"; then
  check badvalue 1 "component=bogus rendered instead of failing"
else
  grep -q 'unknown component' "$WORK/bogus.err" \
    && check badvalue 0 \
    || check badvalue 1 "failed without the componentEnabled message: $(first "$WORK/bogus.err")"
fi

# 7. emission — the parent gotemplate through a shim chart
mkdir -p "$WORK/shim/templates" "$WORK/shim/files"
cp "$BOOTSTRAP/files/parent-gotemplate.tpl" "$WORK/shim/files/"
printf 'apiVersion: v2\nname: shim\nversion: 0.0.1\n' > "$WORK/shim/Chart.yaml"
printf '{{ tpl ($.Files.Get "files/parent-gotemplate.tpl") (dict "parameters" .Values.parameters) }}\n' > "$WORK/shim/templates/render.yaml"
cat > "$WORK/shim/values.yaml" <<'EOF'
parameters:
  env: dev
  configNamespace: vault-config
  childTemplateName: mto-extension-vault-enterprise
  tenantLabelKey: stakater.com/tenant
  sharedTenantName: shared
  ssoEnabled: "false"
  ssoIssuerUrl: ""
  eso: enabled
  externalSecretRefreshInterval: "1h"
  vcoAuthPath: kubernetes
  vcoRole: vco-admin
  vcoServiceAccount: vco-admin
  vcoNamespace: ""
  k8sAuthPath: kubernetes
  k8sAuthName: workloads
  kubernetesHost: https://kubernetes.default.svc:443
  tokenReviewerServiceAccount: ""
  tenants:
    - metadata: { name: team-a }
    - metadata: { name: team-b }
    # no labelled namespace -> skipped
    - metadata: { name: empty-tenant }
    # named like the shared namespace -> skipped, even with a namespace
    - metadata: { name: shared }
  # The gate counts namespaces carrying tenantLabelKey. The unlabelled and
  # foreign-labelled entries prove the filter is not counting the whole list.
  tenantNamespaces:
    - metadata: { name: team-a-dev, labels: { stakater.com/tenant: team-a } }
    - metadata: { name: team-b-dev, labels: { stakater.com/tenant: team-b } }
    - metadata: { name: shared-dev, labels: { stakater.com/tenant: shared } }
    - metadata: { name: no-label-ns }
    - metadata: { name: someone-elses-ns, labels: { stakater.com/tenant: other-tenant } }
EOF
emit() { # emit <eso> [extra --set args] -> rendered parent output
  local eso="$1"; shift
  "$HELM" template shim "$WORK/shim" --set "parameters.eso=$eso" "$@"
}
em_ok=0; em_detail=""
for em in "enabled:mto-extension-vault-enterprise-team-a->mto-extension-vault-enterprise mto-extension-vault-enterprise-team-a.eso->mto-extension-vault-enterprise-eso mto-extension-vault-enterprise-team-b->mto-extension-vault-enterprise mto-extension-vault-enterprise-team-b.eso->mto-extension-vault-enterprise-eso" \
          "disabled:mto-extension-vault-enterprise-team-a->mto-extension-vault-enterprise mto-extension-vault-enterprise-team-b->mto-extension-vault-enterprise"; do
  eso="${em%%:*}"; want="$(printf '%s\n' ${em#*:} | sort | tr '\n' ' ')"
  emit "$eso" > "$WORK/emit-$eso.yaml" 2>"$WORK/emit.err" \
    || { em_ok=1; em_detail="$em_detail [eso=$eso: parent render failed: $(first "$WORK/emit.err")]"; continue; }
  got="$("$YQ" e -N 'select(.kind == "TemplateInstance") | .metadata.name + "->" + .spec.templateRef.name' "$WORK/emit-$eso.yaml" | sort | tr '\n' ' ')"
  [ "$got" = "$want" ] || { em_ok=1; em_detail="$em_detail [eso=$eso: want $want got $got]"; }
done
roster="$("$YQ" e -N 'select(.kind == "TemplateInstance") | .spec.parameters[] | select(.name == "knownTenants") | .value' "$WORK/emit-enabled.yaml" | sort -u)"
[ "$roster" = "team-a,team-b" ] || { em_ok=1; em_detail="$em_detail [knownTenants roster: want team-a,team-b got '$roster']"; }
shared_kinds="$("$YQ" e -N 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .kind + "/" + .metadata.name' "$WORK/emit-enabled.yaml" | sort | tr '\n' ' ')"
[ "$shared_kinds" = "AuthEngineMount/shared-kubernetes KubernetesAuthEngineConfig/shared-kubernetes-config Namespace/shared SecretEngineMount/shared-kv " ] \
  || { em_ok=1; em_detail="$em_detail [shared scaffolding: got $shared_kinds]"; }
check emission "$em_ok" "$em_detail"

# 8. namebudget — "mto-extension-vault-enterprise-" is 31 chars: core ≤32, .eso ≤28.
nb_ok=0; nb_detail=""
t32="$(printf 'a%.0s' $(seq 1 32))"; t33="${t32}a"; t28="$(printf 'a%.0s' $(seq 1 28))"; t29="${t28}a"
nb_case() { # nb_case <component> <tenant> <expect: ok|fail>
  if render "$1" "$FIXTURES/values-no-optins.yaml" --set "tenant=$2" > /dev/null 2>"$WORK/nb.err"; then
    [ "$3" = ok ] || { nb_ok=1; nb_detail="$nb_detail [$1 tenant len ${#2} rendered, expected fail]"; }
  else
    if [ "$3" = fail ]; then
      grep -q 'label values cap at 63' "$WORK/nb.err" || { nb_ok=1; nb_detail="$nb_detail [$1 len ${#2} failed without the budget message: $(first "$WORK/nb.err")]"; }
    else
      nb_ok=1; nb_detail="$nb_detail [$1 tenant len ${#2} failed, expected ok: $(first "$WORK/nb.err")]"
    fi
  fi
}
nb_case core "$t32" ok; nb_case core "$t33" fail
nb_case eso "$t28" ok;  nb_case eso "$t29" fail
nb_case all "$t33" ok
check namebudget "$nb_ok" "$nb_detail"

# 9. templateset
ts_ok=0; ts_detail=""
for ts in "enabled:mto-extension-vault-enterprise mto-extension-vault-enterprise-eso mto-extension-vault-enterprise-parent" "disabled:mto-extension-vault-enterprise mto-extension-vault-enterprise-parent"; do
  eso="${ts%%:*}"; want="$(printf '%s\n' ${ts#*:} | sort | tr '\n' ' ')"
  "$HELM" template b "$BOOTSTRAP" -n "$NS" --set "parent.eso=$eso" > "$WORK/boot-$eso.yaml" 2>"$WORK/boot.err" \
    || { ts_ok=1; ts_detail="$ts_detail [eso=$eso: bootstrap render failed: $(first "$WORK/boot.err")]"; continue; }
  got="$("$YQ" e -N 'select(.kind == "Template") | .metadata.name' "$WORK/boot-$eso.yaml" | sort | tr '\n' ' ')"
  [ "$got" = "$want" ] || { ts_ok=1; ts_detail="$ts_detail [eso=$eso: want $want got $got]"; }
  # every templateRef the parent can emit for this toggle resolves to a Template
  for ref in $("$YQ" e -N 'select(.kind == "TemplateInstance") | .spec.templateRef.name' "$WORK/emit-$eso.yaml" | sort -u); do
    grep -qx "$ref" <(printf '%s\n' $got) || { ts_ok=1; ts_detail="$ts_detail [eso=$eso: parent emits templateRef $ref with no Template]"; }
  done
done
check templateset "$ts_ok" "$ts_detail"

# 10. rbacgate
rbac_atoms() { # <bootstrap manifest> -> "group/resource verb" atoms of the manager ClusterRole
  "$YQ" e -N 'select(.kind == "ClusterRole" and .metadata.name == "mto-extension-vault-enterprise-manager") | .rules[] | . as $r | $r.apiGroups[] as $g | $r.resources[] as $res | $r.verbs[] | $g + "/" + $res + " " + .' "$1" | sort -u
}
rg_ok=0; rg_detail=""
rbac_atoms "$WORK/boot-enabled.yaml" > "$WORK/rbac-on"
rbac_atoms "$WORK/boot-disabled.yaml" > "$WORK/rbac-off"
[ -s "$WORK/rbac-on" ] || { rg_ok=1; rg_detail="$rg_detail [no ClusterRole atoms extracted — the check proves nothing]"; }
for kind in secretstores externalsecrets; do
  grep -qx "external-secrets.io/$kind create" "$WORK/rbac-on"  || { rg_ok=1; rg_detail="$rg_detail [$kind create missing with ESO on]"; }
  grep -qx "external-secrets.io/$kind create" "$WORK/rbac-off" && { rg_ok=1; rg_detail="$rg_detail [$kind create present with ESO off]"; }
  for v in get list watch update patch delete; do
    grep -qx "external-secrets.io/$kind $v" "$WORK/rbac-off" || { rg_ok=1; rg_detail="$rg_detail [$kind $v missing with ESO off — TI teardown would wedge]"; }
  done
done
check rbacgate "$rg_ok" "$rg_detail"

# 11. rbaccover — every redhatcop kind any render emits, lower-cased plural
rc_ok=0; rc_detail=""
{ "$YQ" e -N 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .kind' "$WORK/all.raw"
  "$YQ" e -N 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .kind' "$WORK/emit-enabled.yaml"; } | sort -u > "$WORK/rendered-kinds"
[ -s "$WORK/rendered-kinds" ] || { rc_ok=1; rc_detail="$rc_detail [no redhatcop kinds rendered — the check proves nothing]"; }
cr_list="$("$YQ" e -N 'select(.kind == "ClusterRole" and .metadata.name == "mto-extension-vault-enterprise-manager") | .rules[] | select(.apiGroups[] == "redhatcop.redhat.io") | .verbs | join(",")' "$WORK/boot-enabled.yaml")"
[ "$cr_list" = "list" ] || { rc_ok=1; rc_detail="$rc_detail [ClusterRole redhatcop verbs must be exactly list, got '$cr_list']"; }
role_verbs="$("$YQ" e -N 'select(.kind == "Role" and .metadata.name == "mto-extension-vault-enterprise-manager") | .rules[] | select(.apiGroups[] == "redhatcop.redhat.io") | .verbs | join(",")' "$WORK/boot-enabled.yaml")"
[ "$role_verbs" = "get,list,watch,create,update,patch,delete" ] || { rc_ok=1; rc_detail="$rc_detail [Role redhatcop verbs: '$role_verbs']"; }
while read -r kind; do
  plural="$(echo "$kind" | tr 'A-Z' 'a-z')"; case "$plural" in *y) plural="${plural%y}ies";; *) plural="${plural}s";; esac
  for which in ClusterRole Role; do
    yqs res "select(.kind == \"$which\" and .metadata.name == \"mto-extension-vault-enterprise-manager\") | .rules[] | select(.apiGroups[] == \"redhatcop.redhat.io\") | .resources[]" "$WORK/boot-enabled.yaml"
    grep -qx "$plural" <<<"$res" \
      || { rc_ok=1; rc_detail="$rc_detail [$kind ($plural) rendered but not in the $which]"; }
  done
done < "$WORK/rendered-kinds"
check rbaccover "$rc_ok" "$rc_detail"

# 12. toggles — schema with templates stripped, helpers with the schema removed
tg_ok=0; tg_detail=""
mkdir -p "$WORK/noschema" "$WORK/notpl"
cp -R "$BOOTSTRAP" "$WORK/noschema/boot"; rm "$WORK/noschema/boot/values.schema.json"
cp -R "$BOOTSTRAP" "$WORK/notpl/boot"; rm -rf "$WORK/notpl/boot/templates"; mkdir "$WORK/notpl/boot/templates"
cp -R "$CHART" "$WORK/noschema/tenant"; rm "$WORK/noschema/tenant/values.schema.json"
cp -R "$CHART" "$WORK/notpl/tenant"; rm -rf "$WORK/notpl/tenant/templates"; mkdir "$WORK/notpl/tenant/templates"
tg_case() { # tg_case <chart-dir-name> <values-arg> <label>
  for variant in noschema notpl; do
    if "$HELM" template x "$WORK/$variant/$1" -n "$NS" $2 > /dev/null 2>"$WORK/tg.err"; then
      tg_ok=1; tg_detail="$tg_detail [$3 accepted with $variant]"
    fi
  done
}
tg_case boot "--set parent.eso=true" "parent.eso=true"
tg_case boot "--set parent.sso.enabled=yes" "parent.sso.enabled=yes"
tg_case boot "--set-string sync.mode=on" "sync.mode=on"
tg_case tenant "--set-string sso.enabled=on --set tenant=t" "sso.enabled=on"
# Positive controls: canonical values render in both variants.
for variant in noschema notpl; do
  "$HELM" template x "$WORK/$variant/boot" -n "$NS" --set parent.eso=disabled --set-string parent.sso.enabled=true > /dev/null 2>"$WORK/tg.err" \
    || { tg_ok=1; tg_detail="$tg_detail [canonical bootstrap values rejected with $variant: $(first "$WORK/tg.err")]"; }
done
check toggles "$tg_ok" "$tg_detail"

# 13. subread — app-a (editor) subscribes to team-a-tools; app-d (audit-read) to team-a-dev
sr_ok=0; sr_detail=""
pol() { "$YQ" e -N "select(.kind == \"Policy\" and .metadata.name == \"$1\") | .spec.policy" "$WORK/all.raw"; }
pol team-a-team-a-dev-app-a > "$WORK/pol-a"
grep -q 'path "kv/metadata/dev/_shared/from-team-a-tools/\*" { capabilities = \["read", "list"\] }' "$WORK/pol-a" \
  || { sr_ok=1; sr_detail="$sr_detail [editor subscriber metadata grant is not read/list]"; }
grep -qE 'path "kv/data/dev/_shared/from-team-a-tools/\*" +{ capabilities = \["read", "list"\] }' "$WORK/pol-a" \
  || { sr_ok=1; sr_detail="$sr_detail [editor subscriber data grant is not read/list]"; }
grep 'from-team-a-tools' "$WORK/pol-a" > "$WORK/pol-a-sub" \
  || { sr_ok=1; sr_detail="$sr_detail [no from-team-a-tools grant at all]"; }
grep -qE '"(create|update|patch|delete)"' "$WORK/pol-a-sub" \
  && { sr_ok=1; sr_detail="$sr_detail [a write capability on the producer's prefix]"; }
pol team-a-team-a-tools-app-d > "$WORK/pol-d"
grep -q 'path "kv/metadata/dev/_shared/from-team-a-dev/\*" { capabilities = \["list"\] }' "$WORK/pol-d" \
  || { sr_ok=1; sr_detail="$sr_detail [audit-read subscriber metadata grant is not list-only]"; }
grep -q 'kv/data/dev/_shared/from-team-a-dev/' "$WORK/pol-d" \
  && { sr_ok=1; sr_detail="$sr_detail [audit-read subscriber was granted data reads]"; }
check subread "$sr_ok" "$sr_detail"

# 14. guards
gd_ok=0; gd_detail=""
render all "$FIXTURES/values-guards.yaml" > "$WORK/guards.yaml" 2>"$WORK/guards.err" \
  || { gd_ok=1; gd_detail="$gd_detail [guards fixture did not render: $(first "$WORK/guards.err")]"; }
for pair in \
  "g-tier-only:kv is not" "g-no-tier:tier is not set" "g-bad-tier:is not a known tier" \
  "g-transit:is not supported" "g-injection:is not a valid app name" "g-wildcard:is not a valid app name" \
  "g-reserved:is not a valid app name" "g-claimed:claimed by more than one" "g-claimer:claimed by more than one" \
  "g-orphan-share:so it grants nothing" "default:cannot be granted Vault access" "g-foreign-ns:is not a namespace of tenant" \
  "g-unknown-key:unknown annotation" "g-bad-bool:must be" "g-app-only:no app identity is registered" \
  "g.dotted:cannot be used with Vault"; do
  sa="${pair%%:*}"; msg="${pair#*:}"
  yqs err "select(.kind == \"ConfigMap\" and .metadata.name == \"vault-config-$sa.error\") | .data.ERROR" "$WORK/guards.yaml"
  grep -q -- "$msg" <<<"$err" \
    || { gd_ok=1; gd_detail="$gd_detail [$sa: no error ConfigMap saying '$msg']"; }
  yqs hit "select(.kind == \"Policy\" and (.metadata.name | test(\"-$sa\$\"))) | .metadata.name" "$WORK/guards.yaml"
  [ -n "$hit" ] \
    && { gd_ok=1; gd_detail="$gd_detail [$sa: a Policy rendered despite the error]"; }
done
# Positive controls in the other namespace.
for sa in good-sa sub-ok hostile-sa; do
  yqs hit "select(.kind == \"Policy\" and .metadata.name == \"team-a-team-a-prod-$sa\") | .metadata.name" "$WORK/guards.yaml"
  [ -n "$hit" ] \
    || { gd_ok=1; gd_detail="$gd_detail [$sa: correct SA rendered no Policy — one namespace's error froze another]"; }
done
# Deployment-level cases.
es_count() { "$YQ" e -N "select(.kind == \"ExternalSecret\" and .metadata.name == \"$1\") | .metadata.name" "$WORK/guards.yaml" | grep -c . || true; }
[ "$(es_count good-sa-db)" = 1 ] || { gd_ok=1; gd_detail="$gd_detail [identical asks were not deduped to ONE ExternalSecret]"; }
[ "$(es_count good-sa-cfg)" = 0 ] || { gd_ok=1; gd_detail="$gd_detail [clashing asks rendered an ExternalSecret]"; }
[ "$(es_count sub-ok-y)" = 1 ] || { gd_ok=1; gd_detail="$gd_detail [a granted subscription rendered no ExternalSecret]"; }
[ "$(es_count good-sa-z)" = 1 ] || { gd_ok=1; gd_detail="$gd_detail [an own-namespace subscription rendered no ExternalSecret]"; }
[ "$(es_count sub-missing-x)" = 0 ] || { gd_ok=1; gd_detail="$gd_detail [an ungranted subscription rendered an ExternalSecret]"; }
for pair in "d-clash-a:ask for different secrets" "d-no-sa:requires spec.template.spec.serviceAccountName" \
  "d-misplaced:is read on the ServiceAccount" "d-sub-nogrant:does not list it in" "d-imp-bad:not in the tenant roster" \
  "d-unknown:unknown annotation" "d-evil-key:field selector" "d-evil-leaf:is not a valid secret reference" "d-evil-name:names the Kubernetes Secret"; do
  d="${pair%%:*}"; msg="${pair#*:}"
  yqs err "select(.kind == \"ConfigMap\" and .metadata.name == \"vault-config-$d.deploy-error\") | .data.ERROR" "$WORK/guards.yaml"
  grep -q -- "$msg" <<<"$err" \
    || { gd_ok=1; gd_detail="$gd_detail [$d: no deploy-error ConfigMap saying '$msg']"; }
done
# Hostile values never reach a rendered spec, and the error ConfigMap cannot be forged.
yqs strs 'select(.kind != "ConfigMap") | .. | select(tag == "!!str")' "$WORK/guards.yaml"
[ -n "$strs" ] || { gd_ok=1; gd_detail="$gd_detail [no strings extracted — the hostile-value check proves nothing]"; }
grep -qE 'capabilities = \["sudo"\]|\.\./|forged' <<<"$strs" \
  && { gd_ok=1; gd_detail="$gd_detail [a hostile value reached a non-ConfigMap object]"; }
yqs forged 'select(.kind == "ConfigMap") | has("spec")' "$WORK/guards.yaml"
grep -qx true <<<"$forged" \
  && { gd_ok=1; gd_detail="$gd_detail [an error ConfigMap carries a forged top-level field]"; }
check guards "$gd_ok" "$gd_detail"

# 15. targetns
tn_ok=0; tn_detail=""
"$YQ" e -N 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .kind + "/" + .metadata.name + " " + (.spec.authentication.targetNamespace // "<none>")' "$WORK/all.raw" > "$WORK/targets"
[ -s "$WORK/targets" ] || { tn_ok=1; tn_detail="$tn_detail [no VCO CRs rendered]"; }
while read -r obj target; do
  case "$obj" in
    Namespace/*) [ "$target" = "<none>" ] || { tn_ok=1; tn_detail="$tn_detail [$obj carries targetNamespace $target]"; } ;;
    */share-*)   [ "$target" = shared ]   || { tn_ok=1; tn_detail="$tn_detail [$obj targets $target, want shared]"; } ;;
    *)           [ "$target" = team-a ]   || { tn_ok=1; tn_detail="$tn_detail [$obj targets $target, want team-a]"; } ;;
  esac
done < "$WORK/targets"
"$YQ" e -N 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .kind + "/" + .metadata.name + " " + (.spec.authentication.targetNamespace // "<none>")' "$WORK/emit-enabled.yaml" > "$WORK/ptargets"
while read -r obj target; do
  case "$obj" in
    Namespace/*) [ "$target" = "<none>" ] || { tn_ok=1; tn_detail="$tn_detail [parent $obj carries targetNamespace $target]"; } ;;
    *)           [ "$target" = shared ]   || { tn_ok=1; tn_detail="$tn_detail [parent $obj targets $target, want shared]"; } ;;
  esac
done < "$WORK/ptargets"
# Every CR logs in the same way, in the tenant chart and in the parent.
auths="$({ "$YQ" e -N -o=json -I=0 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .spec.authentication | del(.targetNamespace)' "$WORK/all.raw"; } | sort -u | wc -l | tr -d ' ')"
[ "$auths" = 1 ] || { tn_ok=1; tn_detail="$tn_detail [$auths distinct login blocks in the tenant render, want 1]"; }
check targetns "$tn_ok" "$tn_detail"

# 16. nsagree — values-full sets vco.namespace=org
na_ok=0; na_detail=""
bad_cm="$("$YQ" e -N 'select(.kind == "ConfigMap" and (.metadata.name | test("^vault-config-")) and (.data | has("VAULT_NAMESPACE"))) | select(.data.VAULT_NAMESPACE != "org/team-a") | .metadata.name' "$WORK/all.raw")"
[ -z "$bad_cm" ] || { na_ok=1; na_detail="$na_detail [VAULT_NAMESPACE wrong in: $bad_cm]"; }
cms="$("$YQ" e -N 'select(.kind == "ConfigMap" and (.data | has("VAULT_NAMESPACE"))) | .metadata.name' "$WORK/all.raw" | grep -c . || true)"
[ "$cms" -gt 0 ] || { na_ok=1; na_detail="$na_detail [no ConfigMap carries VAULT_NAMESPACE]"; }
"$YQ" e -N 'select(.kind == "SecretStore") | .metadata.name + " " + .spec.provider.vault.namespace' "$WORK/all.raw" > "$WORK/stores"
[ -s "$WORK/stores" ] || { na_ok=1; na_detail="$na_detail [no SecretStores rendered]"; }
while read -r store ns; do
  case "$store" in
    *.share-*) [ "$ns" = org/shared ] || { na_ok=1; na_detail="$na_detail [$store namespace $ns, want org/shared]"; } ;;
    *)         [ "$ns" = org/team-a ] || { na_ok=1; na_detail="$na_detail [$store namespace $ns, want org/team-a]"; } ;;
  esac
done < "$WORK/stores"
yqs loginns 'select(.apiVersion == "redhatcop.redhat.io/v1alpha1") | .spec.authentication.namespace' "$WORK/all.raw"
[ "$(sort -u <<<"$loginns")" = org ] \
  || { na_ok=1; na_detail="$na_detail [VCO login namespace is not org]"; }
check nsagree "$na_ok" "$na_detail"

# 17. mountagree
ma_ok=0; ma_detail=""
m_auth="$("$YQ" e -N 'select(.kind == "AuthEngineMount" and .spec.type == "kubernetes") | .spec.path + "/" + .spec.name' "$WORK/all.raw")"
m_cfg="$("$YQ" e -N 'select(.kind == "KubernetesAuthEngineConfig") | .spec.path + "/" + .spec.name' "$WORK/all.raw")"
m_roles="$("$YQ" e -N 'select(.kind == "KubernetesAuthEngineRole") | .spec.path' "$WORK/all.raw" | sort -u)"
m_stores="$("$YQ" e -N 'select(.kind == "SecretStore") | .spec.provider.vault.auth.kubernetes.mountPath' "$WORK/all.raw" | sort -u)"
m_cms="$("$YQ" e -N 'select(.kind == "ConfigMap" and (.data | has("VAULT_K8S_MOUNT"))) | .data.VAULT_K8S_MOUNT' "$WORK/all.raw" | sort -u)"
for pair in "AuthEngineMount:$m_auth" "KubernetesAuthEngineConfig:$m_cfg" "roles:$m_roles" "SecretStores:$m_stores" "VAULT_K8S_MOUNT:$m_cms"; do
  [ "${pair#*:}" = kubernetes/workloads ] || { ma_ok=1; ma_detail="$ma_detail [${pair%%:*}: '$(echo "${pair#*:}" | tr '\n' ' ')']"; }
done
m_sso="$("$YQ" e -N 'select(.kind == "AuthEngineMount" and .spec.type == "oidc") | .spec.path + "/" + .spec.name' "$WORK/all.raw")"
m_ssocfg="$("$YQ" e -N 'select(.kind == "JWTOIDCAuthEngineConfig") | .spec.path' "$WORK/all.raw")"
m_ssoroles="$("$YQ" e -N 'select(.kind == "JWTOIDCAuthEngineRole") | .spec.path' "$WORK/all.raw" | sort -u)"
for pair in "oidc AuthEngineMount:$m_sso" "JWTOIDCAuthEngineConfig:$m_ssocfg" "oidc roles:$m_ssoroles"; do
  [ "${pair#*:}" = oidc/sso ] || { ma_ok=1; ma_detail="$ma_detail [${pair%%:*}: '$(echo "${pair#*:}" | tr '\n' ' ')']"; }
done
check mountagree "$ma_ok" "$ma_detail"

# 18. tokenseconds
tsx_ok=0; tsx_detail=""
nonint="$("$YQ" e -N 'select(.kind == "KubernetesAuthEngineRole") | .spec | to_entries | .[] | select(.key | test("^token(TTL|MaxTTL|Period)$")) | select(.value | tag != "!!int") | .key' "$WORK/all.raw")"
[ -z "$nonint" ] || { tsx_ok=1; tsx_detail="$tsx_detail [non-integer token fields: $nonint]"; }
ints="$("$YQ" e -N 'select(.kind == "KubernetesAuthEngineRole") | .spec.tokenTTL' "$WORK/all.raw" | sort -u)"
[ "$ints" = 3600 ] || { tsx_ok=1; tsx_detail="$tsx_detail [tokenTTL not plumbed as 3600: '$ints']"; }
if "$HELM" template x "$WORK/noschema/tenant" -n "$NS" -f "$FIXTURES/values-full.yaml" --set-string token.ttl=1h > /dev/null 2>"$WORK/tsx.err"; then
  tsx_ok=1; tsx_detail="$tsx_detail [token.ttl=1h rendered with the schema removed]"
else
  grep -q 'must be an integer number of seconds' "$WORK/tsx.err" || { tsx_ok=1; tsx_detail="$tsx_detail [token.ttl=1h failed without the helper message: $(first "$WORK/tsx.err")]"; }
fi
if "$HELM" template x "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" --set-string token.ttl=1h > /dev/null 2>"$WORK/tsx.err"; then
  tsx_ok=1; tsx_detail="$tsx_detail [the schema accepted token.ttl=1h]"
fi
check tokenseconds "$tsx_ok" "$tsx_detail"

# 19. tokentype
tt_ok=0; tt_detail=""
roles="$("$YQ" e -N 'select(.kind == "KubernetesAuthEngineRole") | .metadata.name' "$WORK/all.raw" | grep -c . || true)"
typed="$("$YQ" e -N 'select(.kind == "KubernetesAuthEngineRole") | .spec.tokenType' "$WORK/all.raw" | grep -cx service || true)"
[ "$roles" -gt 0 ] || { tt_ok=1; tt_detail="$tt_detail [no roles rendered]"; }
[ "$typed" = "$roles" ] || { tt_ok=1; tt_detail="$tt_detail [$typed of $roles roles pin tokenType service]"; }
if "$HELM" template x "$WORK/noschema/tenant" -n "$NS" -f "$FIXTURES/values-full.yaml" --set token.type=batch > /dev/null 2>"$WORK/tt.err"; then
  tt_ok=1; tt_detail="$tt_detail [batch + period rendered]"
else
  grep -q 'a batch token cannot be renewed' "$WORK/tt.err" || { tt_ok=1; tt_detail="$tt_detail [batch + period failed elsewhere: $(first "$WORK/tt.err")]"; }
fi
"$HELM" template x "$CHART" -n "$NS" -f "$FIXTURES/values-full.yaml" --set token.type=batch --set token.period=0 > /dev/null 2>"$WORK/tt.err" \
  || { tt_ok=1; tt_detail="$tt_detail [batch without period rejected: $(first "$WORK/tt.err")]"; }
check tokentype "$tt_ok" "$tt_detail"

# 20. nullfields — with a self-check, because a detector that cannot report is
# indistinguishable from a clean render.
nullfield_paths() { # <manifest> -> "Kind/name path" per null leaf
  "$YQ" e -N 'select(. != null) | . as $d | (.. | select(tag == "!!null") | ($d.kind + "/" + $d.metadata.name + " " + (path | join("."))))' "$1"
}
nf_detail=""
printf 'kind: Probe\nmetadata:\n  name: clean\nspec:\n  domains:\n    - a\n' > "$WORK/nf-clean.yaml"
printf 'kind: Probe\nmetadata:\n  name: dirty\nspec:\n  domains:\n' > "$WORK/nf-dirty.yaml"
[ -z "$(nullfield_paths "$WORK/nf-clean.yaml")" ] || nf_detail="$nf_detail [self-check: false positive on a clean probe]"
[ "$(nullfield_paths "$WORK/nf-dirty.yaml")" = "Probe/dirty spec.domains" ] || nf_detail="$nf_detail [self-check: the detector cannot see a known null]"
for c in all core eso; do
  render "$c" "$FIXTURES/values-no-workloads.yaml" > "$WORK/nw-$c.yaml" 2>"$WORK/nw.err" \
    || { nf_detail="$nf_detail [no-workloads $c: render failed: $(first "$WORK/nw.err")]"; continue; }
  nf_out="$(nullfield_paths "$WORK/nw-$c.yaml")" || { nf_detail="$nf_detail [$c: yq failed]"; continue; }
  [ -z "$nf_out" ] || nf_detail="$nf_detail [$c: $(printf '%s' "$nf_out" | sort -u | tr '\n' ' ')]"
done
"$HELM" template b "$BOOTSTRAP" -n "$NS" > "$WORK/nw-boot.yaml" 2>"$WORK/nw.err" \
  || nf_detail="$nf_detail [bootstrap render failed: $(first "$WORK/nw.err")]"
nf_out="$(nullfield_paths "$WORK/nw-boot.yaml")"; [ -z "$nf_out" ] || nf_detail="$nf_detail [bootstrap: $nf_out]"
[ -z "$nf_detail" ] && check nullfields 0 || check nullfields 1 "rendered null field(s) — admission rejects these and fails the whole TI:$nf_detail"

# 21. ssoredirect — both empty forms from a VALUES FILE: `--set x=[]` gives helm
# the string "[]", which would never reach the guard.
so_ok=0; so_detail=""
printf 'sso:\n  allowedRedirectUris: []\n'   > "$WORK/ssor-empty.yaml"
printf 'sso:\n  allowedRedirectUris: null\n' > "$WORK/ssor-null.yaml"
for form in empty null; do
  if render core "$FIXTURES/values-full.yaml" -f "$WORK/ssor-$form.yaml" > "$WORK/ssor.out" 2>&1; then
    so_ok=1; so_detail="$so_detail [allowedRedirectUris=$form rendered]"; continue
  fi
  grep -q 'requires at least one entry in sso.allowedRedirectUris' "$WORK/ssor.out" \
    || { so_ok=1; so_detail="$so_detail [$form failed elsewhere: $(first "$WORK/ssor.out")]"; }
done
# The VALUE, not the key: the key renders above its range even when it is empty.
uris="$("$YQ" e -N 'select(.kind == "JWTOIDCAuthEngineRole") | .spec.allowedRedirectURIs[]' "$WORK/all.raw" | sort -u)"
[ "$uris" = "http://localhost:8250/oidc/callback" ] || { so_ok=1; so_detail="$so_detail [populated list rendered '$uris']"; }
check ssoredirect "$so_ok" "$so_detail"

# 22. ssorootlist
sl_ok=0; sl_detail=""
n_sso=0
for p in $("$YQ" e -N 'select(.kind == "Policy" and (.metadata.name | test("^sso-"))) | .metadata.name' "$WORK/all.raw"); do
  n_sso=$((n_sso + 1))
  yqs body "select(.kind == \"Policy\" and .metadata.name == \"$p\") | .spec.policy" "$WORK/all.raw"
  grep -q 'path "kv/metadata" { capabilities = \["list"\] }' <<<"$body" || { sl_ok=1; sl_detail="$sl_detail [$p cannot list the kv root]"; }
done
[ "$n_sso" -eq 4 ] || { sl_ok=1; sl_detail="$sl_detail [expected 4 SSO tier policies, found $n_sso]"; }
check ssorootlist "$sl_ok" "$sl_detail"

# 23. parentplumb — parsed as YAML, never grepped
pp_ok=0; pp_detail=""
cat > "$WORK/pp.yaml" <<'YAML'
vco:
  namespace: org
  role: my-role
kubernetesAuth:
  name: apps
parent:
  token:
    type: batch
    ttl: 900
  sso:
    allowedRedirectUris:
      - "https://console.example.com/oidc/callback"
YAML
"$HELM" template b "$BOOTSTRAP" -n "$NS" -f "$WORK/pp.yaml" > "$WORK/pp.out" 2>&1 \
  || { pp_ok=1; pp_detail="$pp_detail [bootstrap render failed: $(first "$WORK/pp.out")]"; }
"$YQ" e -N 'select(.kind == "Template" and .metadata.name == "mto-extension-vault-enterprise") | .spec.helm.valuesTemplate' "$WORK/pp.out" > "$WORK/pp-values.yaml" 2>/dev/null \
  || { pp_ok=1; pp_detail="$pp_detail [could not extract the core valuesTemplate]"; }
pp_get() { "$YQ" e -N "$1" "$WORK/pp-values.yaml" 2>/dev/null; }
[ "$(pp_get '.vco.namespace')" = org ] || { pp_ok=1; pp_detail="$pp_detail [vco.namespace not plumbed]"; }
[ "$(pp_get '.vco.role')" = my-role ] || { pp_ok=1; pp_detail="$pp_detail [vco.role not plumbed]"; }
[ "$(pp_get '.kubernetesAuth.name')" = apps ] || { pp_ok=1; pp_detail="$pp_detail [kubernetesAuth.name not plumbed]"; }
[ "$(pp_get '.token.type')" = batch ] || { pp_ok=1; pp_detail="$pp_detail [token.type not plumbed]"; }
[ "$(pp_get '.token.ttl | tag')" = '!!int' ] || { pp_ok=1; pp_detail="$pp_detail [token.ttl lost its integer type: $(pp_get '.token.ttl | tag')]"; }
[ "$(pp_get '.sso.allowedRedirectUris[0]')" = 'https://console.example.com/oidc/callback' ] || { pp_ok=1; pp_detail="$pp_detail [allowedRedirectUris not plumbed]"; }
# The plumbed values must survive the tenant chart, not only parse here.
"$YQ" e -N '{"vco": .vco, "kubernetesAuth": .kubernetesAuth, "token": .token, "sso": {"allowedRedirectUris": .sso.allowedRedirectUris}}' "$WORK/pp-values.yaml" > "$WORK/pp-tenant-values.yaml"
if render core "$FIXTURES/values-full.yaml" -f "$WORK/pp-tenant-values.yaml" --set token.period=0 > "$WORK/pp-tenant.out" 2>&1; then
  yqs ppaths 'select(.kind == "KubernetesAuthEngineRole") | .spec.path' "$WORK/pp-tenant.out"
  [ "$(sort -u <<<"$ppaths")" = kubernetes/apps ] \
    || { pp_ok=1; pp_detail="$pp_detail [plumbed mount name did not reach the roles: '$(sort -u <<<"$ppaths" | tr '\n' ' ')']"; }
else
  pp_ok=1; pp_detail="$pp_detail [tenant chart rejected the plumbed values: $(first "$WORK/pp-tenant.out")]"
fi
# Counterweight: an unset token block is omitted, not emitted empty.
"$YQ" e -N 'select(.kind == "Template" and .metadata.name == "mto-extension-vault-enterprise") | .spec.helm.valuesTemplate' "$WORK/boot-enabled.yaml" > "$WORK/pp-def.yaml"
yqs hastok 'has("token")' "$WORK/pp-def.yaml"
[ "$hastok" = false ] || { pp_ok=1; pp_detail="$pp_detail [an unset parent.token emitted a token key]"; }
printf 'parent:\n  sso: null\n  token: null\n' > "$WORK/pp-null.yaml"
"$HELM" template b "$BOOTSTRAP" -n "$NS" -f "$WORK/pp-null.yaml" > "$WORK/pp-null.out" 2>&1 \
  || { pp_ok=1; pp_detail="$pp_detail [a nulled parent.sso/token failed the render: $(first "$WORK/pp-null.out")]"; }
check parentplumb "$pp_ok" "$pp_detail"

# 24. versionpin
tv="$("$YQ" e '.version' "$CHART/Chart.yaml")"
bv="$("$YQ" e '.tenantChart.version' "$BOOTSTRAP/values.yaml")"
[ "$tv" = "$bv" ] && check versionpin 0 || check versionpin 1 "tenant chart is $tv, bootstrap pins $bv"

# 25. outputnames — on both ESO settings, so every Template variant is covered.
on_ok=0; on_detail=""
for eso in enabled disabled; do
  yqs tmpls 'select(.kind == "Template") | .metadata.name' "$WORK/boot-$eso.yaml"
  [ -n "$tmpls" ] || { on_ok=1; on_detail="$on_detail [eso=$eso: no Templates]"; }
  for t in $tmpls; do
    yqs onames "select(.kind == \"Template\" and .metadata.name == \"$t\") | .spec.outputs[].name" "$WORK/boot-$eso.yaml"
    yqs fnames "select(.kind == \"Template\" and .metadata.name == \"$t\") | .spec.outputs[].fields[].name" "$WORK/boot-$eso.yaml"
    [ -n "$fnames" ] || { on_ok=1; on_detail="$on_detail [$t: no output fields]"; }
    dup="$(sort <<<"$onames" | uniq -d)"; [ -z "$dup" ] || { on_ok=1; on_detail="$on_detail [$t: duplicate output names: $dup]"; }
    dup="$(sort <<<"$fnames" | uniq -d | tr '\n' ' ')"; [ -z "$dup" ] || { on_ok=1; on_detail="$on_detail [$t: duplicate field names: $dup]"; }
  done
done
check outputnames "$on_ok" "$on_detail"

exit "$fail"
