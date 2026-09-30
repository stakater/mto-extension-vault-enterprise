#!/usr/bin/env bash
# Validate every rendered VCO CR against vault-config-operator's CRDs, through
# the apiserver's own admission pipeline (hack/crd-validate).
#
# Coverage is per render path: the tenant chart at component=all and at each
# slice, for every fixture, plus the parent gotemplate's shared scaffolding.
# Each render path must check exactly the number of CRs it emits today, so a
# render that silently drops objects fails here (a bare -min 1 accepted a render
# that fell to one object). The eso slice emits none by design. When a fixture
# or template changes the count on purpose, update the table below.
#
# Usage: hack/crd-validate.sh <crd-dir>
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRDS="${1:?usage: hack/crd-validate.sh <crd-dir>}"
HELM="${HELM:-helm}"
YQ="${YQ:-yq}"
CHART="$REPO_ROOT/charts/mto-extension-vault-enterprise"
BOOTSTRAP="$REPO_ROOT/charts/mto-extension-vault-enterprise-bootstrap"
FIXTURES="$REPO_ROOT/hack/render-fixtures"

[ -d "$CRDS" ] || { echo "error: CRD directory $CRDS does not exist" >&2; exit 1; }
ls "$CRDS"/*.yaml > /dev/null 2>&1 || { echo "error: no CRD files in $CRDS" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0

validate() { # validate <label> <manifest> <expected-count>
  local args=(-min "$3")
  [ "$3" = 0 ] && args=(-allow-empty)
  printf '%-26s ' "$1"
  if ! (cd "$REPO_ROOT" && go run ./hack/crd-validate "${args[@]}" "$CRDS" "$2"); then
    fail=1
  fi
}

expected() { # expected <fixture> <component> -> VCO CR count that render emits
  [ "$2" = eso ] && { echo 0; return; }
  case "$1" in
    full) echo 25 ;; guards) echo 12 ;; no-optins) echo 2 ;; no-workloads) echo 12 ;;
    *) echo "no expected count for fixture $1" >&2; exit 1 ;;
  esac
}

for fx in full guards no-optins no-workloads; do
  for c in all core eso; do
    # Render on its own line: a failed render must not become an empty input.
    if ! "$HELM" template mto-extension-vault-enterprise "$CHART" -n vault-config \
        -f "$FIXTURES/values-$fx.yaml" --set "component=$c" > "$WORK/r.yaml" 2>"$WORK/r.err"; then
      echo "FAIL $fx/$c: render failed: $(head -1 "$WORK/r.err" | cut -c1-200)"; fail=1; continue
    fi
    validate "$fx/$c" "$WORK/r.yaml" "$(expected "$fx" "$c")"
  done
done

# The parent gotemplate, rendered through helm's tpl with the parameters the
# bootstrap chart stamps, so its shared scaffolding is validated too.
"$HELM" template b "$BOOTSTRAP" -n vault-config > "$WORK/boot.yaml"
mkdir -p "$WORK/shim/templates" "$WORK/shim/files"
cp "$BOOTSTRAP/files/parent-gotemplate.tpl" "$WORK/shim/files/"
printf 'apiVersion: v2\nname: shim\nversion: 0.0.1\n' > "$WORK/shim/Chart.yaml"
printf '{{ tpl ($.Files.Get "files/parent-gotemplate.tpl") (dict "parameters" .Values.parameters) }}\n' > "$WORK/shim/templates/render.yaml"
# The parent Template's own parameter defaults, as a values file, plus Tenants.
"$YQ" e -N 'select(.kind == "Template" and .metadata.name == "mto-extension-vault-enterprise-parent")
         | {"parameters": (.spec.parameters | map(select(has("value"))) | map({"key": .name, "value": .value}) | from_entries)}' \
  "$WORK/boot.yaml" > "$WORK/shim/values.yaml"
"$YQ" e -i '.parameters.tenants = [{"metadata": {"name": "team-a"}}] | .parameters.tenantNamespaces = [{"metadata": {"name": "team-a-dev", "labels": {"stakater.com/tenant": "team-a"}}}]' "$WORK/shim/values.yaml"
for tr in "" vault-token-reviewer; do
  if ! "$HELM" template shim "$WORK/shim" --set-string "parameters.tokenReviewerServiceAccount=$tr" --set-string parameters.vcoNamespace=org > "$WORK/parent.yaml" 2>"$WORK/p.err"; then
    echo "FAIL parent: render failed: $(head -1 "$WORK/p.err" | cut -c1-200)"; fail=1; continue
  fi
  validate "parent${tr:+ (reviewer)}" "$WORK/parent.yaml" 6
done

# Self-test: a misspelt metadata key, which pruning cannot see, is refused. The
# same Policy without the typo must validate, so the refusal is about the typo.
"$YQ" ea '[select(.kind == "Policy")] | .[0]' "$FIXTURES/golden-all.yaml" > "$WORK/meta-ok.yaml"
"$YQ" e '.metadata.annotaions = {"x": "y"}' "$WORK/meta-ok.yaml" > "$WORK/meta-typo.yaml"
validate "self-test (clean Policy)" "$WORK/meta-ok.yaml" 1
printf '%-26s ' "self-test (metadata typo)"
if (cd "$REPO_ROOT" && go run ./hack/crd-validate -min 1 "$CRDS" "$WORK/meta-typo.yaml") > "$WORK/self.out" 2>&1; then
  echo "FAIL a misspelt metadata key validated"; fail=1
elif grep -q 'unknown field "annotaions"' "$WORK/self.out"; then
  echo "OK refused: unknown field \"annotaions\""
else
  echo "FAIL refused for another reason: $(head -3 "$WORK/self.out" | tr '\n' ' ')"; fail=1
fi

exit "$fail"
