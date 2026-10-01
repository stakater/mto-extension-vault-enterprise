#!/usr/bin/env bash
#
# The docs images gate: every Markdown reference to
# docs/screenshots/captured/<name>.png resolves to a file, and every captured
# image is referenced. A missing image renders as a broken image in the docs;
# an image no page uses is a flow step nobody needs, or a reference that was
# removed. The images come from the e2e suite's ui step (make screenshots).
#
# Usage: hack/screenshots-check.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

CAPTURED=docs/screenshots/captured
pattern='[^( ]*docs/screenshots/captured/[A-Za-z0-9._-]+\.png'
fail=0
used=" "

mds="$(git ls-files --cached --others --exclude-standard -- '*.md')"
while IFS= read -r md; do
  [ -n "$md" ] || continue
  # grep: 0 = matches, 1 = none, anything else is an error and fails the gate.
  rc=0
  refs="$(grep -o -E "$pattern" "$md")" || rc=$?
  if [ "$rc" -gt 1 ]; then
    echo "FAIL  cannot read $md" >&2
    exit 1
  fi
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    if [ -f "$(dirname "$md")/$ref" ]; then
      used="$used$(basename "$ref") "
    else
      echo "FAIL  $md references $ref, which does not exist"
      fail=1
    fi
  done <<<"$refs"
done <<<"$mds"

for png in "$CAPTURED"/*.png; do
  [ -e "$png" ] || continue
  name="$(basename "$png")"
  case "$used" in
    *" $name "*) ;;
    *) echo "FAIL  $png is not referenced by any Markdown file"; fail=1 ;;
  esac
done

if [ "$fail" = 0 ]; then
  echo "PASS  screenshots — every docs image reference resolves, and every captured image is used"
fi
exit "$fail"
