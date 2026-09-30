#!/usr/bin/env bash
#
# Package the tenant chart from THIS checkout and serve it from the in-cluster
# chart repository (hack/lab/chart-repo.yaml), so template-operator-v2 renders the
# working tree rather than whatever is published at ghcr.io.
#
# Idempotent: re-run after every chart edit. The ConfigMap is replaced rather than
# patched, and the nginx Deployment is restarted so the new files are mounted
# immediately instead of on the kubelet's next ConfigMap sync.
set -euo pipefail

KUBECTL=${KUBECTL:-kubectl}
HELM=${HELM:-helm}
CONTEXT=${E2E_CONTEXT:?E2E_CONTEXT must be set}
REPO_NS=${E2E_CHART_REPO_NS:-chart-repo}
CHART_DIR=${CHART_DIR:?CHART_DIR must be set (the tenant chart directory)}

kc() { "${KUBECTL}" --context "${CONTEXT}" "$@"; }

name=$(awk '/^name:/{print $2; exit}' "${CHART_DIR}/Chart.yaml")
version=$(awk '/^version:/{print $2; exit}' "${CHART_DIR}/Chart.yaml")
[ -n "${name}" ] && [ -n "${version}" ] || { echo "could not read name/version from ${CHART_DIR}/Chart.yaml" >&2; exit 1; }

pkg=$(mktemp -d)
trap 'rm -rf "${pkg}"' EXIT

"${HELM}" package "${CHART_DIR}" -d "${pkg}" >/dev/null
tgz="${pkg}/${name}-${version}.tgz"
[ -f "${tgz}" ] || { echo "helm package did not produce ${tgz}" >&2; exit 1; }
# No --url: the index then carries the tarball as a RELATIVE url, which helm
# resolves against whatever repository URL the Template names. The Service DNS
# name does not have to be repeated here.
(cd "${pkg}" && "${HELM}" repo index . >/dev/null)

echo ">> publishing ${name} ${version} to ${REPO_NS}/chart-files"
kc -n "${REPO_NS}" delete configmap chart-files --ignore-not-found >/dev/null
# --from-file on a .tgz lands in binaryData automatically.
kc -n "${REPO_NS}" create configmap chart-files \
  --from-file="${pkg}/index.yaml" \
  --from-file="$(basename "${tgz}")=${tgz}" >/dev/null
kc -n "${REPO_NS}" rollout restart deploy/chart-repo >/dev/null
kc -n "${REPO_NS}" rollout status deploy/chart-repo --timeout=120s >/dev/null

# The restarted pod is what must be probed; the old one lingers a moment in
# Terminating and still answers with the OLD files. Wait until one pod is left.
pod=""
for _ in $(seq 1 30); do
  pods=$(kc -n "${REPO_NS}" get pod -l app=chart-repo -o jsonpath='{.items[*].metadata.name}')
  if [ "$(printf '%s\n' ${pods} | wc -l | tr -d ' ')" = "1" ]; then pod=${pods}; break; fi
  sleep 2
done
[ -n "${pod}" ] || { echo "chart-repo did not settle to a single pod" >&2; kc -n "${REPO_NS}" get pod -l app=chart-repo >&2; exit 1; }

# Prove the repo serves THIS version — the index AND the tarball. From inside the
# pod (busybox wget): the Service is not reachable from the host. 127.0.0.1, not
# localhost: in this image localhost resolves to ::1 and nginx listens on IPv4 only. A stale index
# would make every child TemplateInstance render an older chart and every
# assertion in the suite would then be about the wrong code.
served=$(kc -n "${REPO_NS}" exec "${pod}" -- wget -qO- http://127.0.0.1:8080/index.yaml)
# A here-string, not printf | grep -q: under pipefail grep's early exit can
# fail printf on a large index and read a served version as missing.
if ! grep -q "version: ${version}$" <<<"${served}"; then
  echo "chart-repo's index.yaml does not list ${name} ${version}:" >&2
  printf '%s\n' "${served}" | head -20 >&2
  exit 1
fi
kc -n "${REPO_NS}" exec "${pod}" -- wget -qO /dev/null "http://127.0.0.1:8080/${name}-${version}.tgz" \
  || { echo "chart-repo does not serve ${name}-${version}.tgz" >&2; exit 1; }
echo "   chart-repo serves ${name} ${version}"
