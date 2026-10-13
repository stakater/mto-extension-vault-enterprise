#!/usr/bin/env bash
# Fail when a chart changed against <base> but its Chart.yaml version did not.
#
# The release job skips a version that is already published (it never
# overwrites one), so a chart change merged without a bump would never be
# released — silently. This check runs on the PR, where the bump can still be
# added. A chart that does not exist on <base> yet passes.
#
# Usage: hack/version-bump-check.sh <base-ref> <chart-dir>...
set -euo pipefail

base="${1:?usage: version-bump-check.sh <base-ref> <chart-dir>...}"; shift
git rev-parse --verify --quiet "$base^{commit}" > /dev/null \
  || { echo "base ref $base not found — fetch it first (actions/checkout needs fetch-depth: 0)" >&2; exit 1; }

fail=0
for dir in "$@"; do
  if git diff --quiet "$base...HEAD" -- "$dir"; then
    echo "$dir: unchanged"
    continue
  fi
  if ! base_chart="$(git show "$base:$dir/Chart.yaml" 2>/dev/null)"; then
    echo "$dir: new chart"
    continue
  fi
  old="$(awk '/^version:/{print $2; exit}' <<<"$base_chart")"
  new="$(awk '/^version:/{print $2; exit}' "$dir/Chart.yaml")"
  if [ "$old" = "$new" ]; then
    echo "$dir: changed but still at version $new — bump Chart.yaml, or it will never be released" >&2
    fail=1
  else
    echo "$dir: $old -> $new"
  fi
done
exit "$fail"
