#!/usr/bin/env bash
# Package and push one chart to the OCI registry, unless its version is already
# published.
#
# helm push has no existence check and no --force, and GHCR allows tag
# overwrite, so pushing a published version would silently replace what tenants
# pull. A published version is therefore SKIPPED, not pushed and not failed:
# a push to main that changes no chart (or only the other chart) must not fail
# the release. That a changed chart bumps its version is checked on the PR
# (hack/version-bump-check.sh), where a mistake can still be fixed.
#
# Fails closed: only an explicit "not found" from the registry means the version
# is free. helm show chart also fails on a DNS error or an expired token, and
# treating those as free would push over tenants on a network blip. Run after
# helm registry login — unauthenticated, GHCR answers 403 for absent and
# published tags alike.
#
# Usage: hack/release-chart.sh <chart-dir> <registry-without-oci://>
set -euo pipefail

chart_dir="${1:?usage: release-chart.sh <chart-dir> <registry>}"
registry="${2:?usage: release-chart.sh <chart-dir> <registry>}"
HELM="${HELM:-helm}"

name="$(awk '/^name:/{print $2; exit}' "$chart_dir/Chart.yaml")"
version="$(awk '/^version:/{print $2; exit}' "$chart_dir/Chart.yaml")"
[ -n "$name" ] && [ -n "$version" ] || { echo "cannot read name/version from $chart_dir/Chart.yaml" >&2; exit 1; }

# rc is set before the substitution so set -e cannot end the script on the
# expected failure: `out=$(cmd); rc=$?` never reaches `rc=$?` under -e.
rc=0
out="$("$HELM" show chart "oci://$registry/$name" --version "$version" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ]; then
  echo "$name $version is already published — skipping"
  exit 0
fi
if ! grep -qiE 'not found|manifest unknown|name unknown' <<<"$out"; then
  echo "cannot determine whether $name $version is published — refusing to push:" >&2
  head -3 <<<"$out" >&2
  exit 1
fi

mkdir -p dist
"$HELM" package "$chart_dir" -d dist
"$HELM" push "dist/$name-$version.tgz" "oci://$registry"
echo "$name $version published"
