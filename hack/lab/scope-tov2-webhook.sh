#!/usr/bin/env bash
#
# Make sure template-operator-v2's sync-enforcement webhook is scoped to the
# objects the operator manages, and scope it if it is not.
#
# WHY THIS EXISTS
#
# The webhook matches UPDATE and DELETE on `*/*/*` with failurePolicy: Fail. A
# matchConditions CEL filter is what narrows it to objects carrying the
# templates.v2.stakater.com/instance label -- and helmify DROPS
# .webhooks[].matchConditions when it generates the chart. tov2 re-injects it in
# a release-time postprocess step, so whether an install is scoped depends on
# which copy of the chart you used:
#
#   published 0.0.6 (ghcr.io/stakater/public/charts/...)  scoped -- checked
#   charts/ in a tov2 checkout at 8a44194                 NOT scoped
#
# So on the published chart this script is a no-op that CONFIRMS the scoping is
# present, and it does the repair if a future chart ships without it. Copied
# from mto-extension-argocd's hack/e2e, where the deadlock was first measured.
#
# Unscoped, the failure is not "a bit broad". It is a permanent, unrecoverable
# deadlock of the whole cluster, and it happens during install:
#
#   1. the webhook exists before the operator pod is ready, so every UPDATE in
#      the cluster fails closed -- including kube-controller-manager renewing
#      its leader-election Lease;
#   2. a controller-manager that cannot hold leadership does not run the
#      EndpointSlice controller, so the webhook's own Service never gets an
#      endpoint;
#   3. the webhook therefore stays unreachable for ever. `helm install --wait`
#      times out, Deployments never report Available, and nothing self-heals.
#
# Measured on a fresh kind cluster, not theorised (mto-extension-argocd records
# it as TOV2-9). It is also why the charts README can claim a bounded blast
# radius for sync.mode=strict at all.
#
# Patching an admission webhook out from under an unhealthy cluster works
# because the API server does not consult webhooks for requests on
# admissionregistration.k8s.io objects -- checked, on a cluster already wedged
# by exactly this.
set -euo pipefail

KUBECTL=${KUBECTL:-kubectl}
CONTEXT=${E2E_CONTEXT:?E2E_CONTEXT must be set}
NAME=${WEBHOOK_NAME:-template-operator-v2-template-operator-v2-sync-enforcement}

command -v jq >/dev/null 2>&1 || { echo "jq is required but is not on PATH" >&2; exit 1; }

kc() { "${KUBECTL}" --context "${CONTEXT}" "$@"; }

# Copied verbatim from template-operator-v2 config/webhook/manifests.yaml. Keep
# it that way: a filter that differs from the operator's own would let through
# objects the operator then refuses to reconcile, or vice versa.
EXPRESSION="(object != null && has(object.metadata.labels) && 'templates.v2.stakater.com/instance' in object.metadata.labels) || (oldObject != null && has(oldObject.metadata.labels) && 'templates.v2.stakater.com/instance' in oldObject.metadata.labels)"

for _ in $(seq 1 30); do
	kc get validatingwebhookconfiguration "${NAME}" >/dev/null 2>&1 && break
	sleep 2
done
if ! kc get validatingwebhookconfiguration "${NAME}" >/dev/null 2>&1; then
	echo "sync-enforcement webhook ${NAME} never appeared" >&2
	exit 1
fi

# One fetch, failing loudly. This script guards against a cluster-wide
# deadlock, so a GET failure shrugged into "not scoped" -- or into "already
# scoped" -- is the one thing it must never do; set -e surfaces it here.
webhooks_json=$(kc get validatingwebhookconfiguration "${NAME}" -o json)

# Only .webhooks[0] is inspected and patched below. A second entry could still
# carry the unscoped */*/* match, so "already scoped" would be a false positive
# on any future chart that ships more than one -- refuse rather than guess.
count=$(printf '%s' "${webhooks_json}" | jq '.webhooks | length')
if [ "${count}" != "1" ]; then
	echo "expected exactly 1 webhook entry in ${NAME}, found ${count}." >&2
	echo "This script only knows how to scope .webhooks[0]; another entry could still" >&2
	echo "carry the unscoped */*/* match that deadlocks the cluster (TOV2-9)." >&2
	echo "Inspect the configuration and update this script before continuing." >&2
	exit 1
fi

existing=$(printf '%s' "${webhooks_json}" | jq -r '.webhooks[0].matchConditions[0].name // ""')
existing_expr=$(printf '%s' "${webhooks_json}" | jq -r '.webhooks[0].matchConditions[0].expression // ""')
if [ -n "${existing}" ]; then
	if [ "${existing_expr}" = "${EXPRESSION}" ]; then
		echo "sync-enforcement webhook already scoped by matchConditions/${existing}"
	elif printf '%s' "${existing_expr}" | grep -qF "templates.v2.stakater.com/instance"; then
		# Scoped, and the filter still keys on the operator's instance label,
		# so the TOV2-9 deadlock cannot happen -- but a filter that differs
		# from the one this script carries means the operator's own changed
		# upstream, and EXPRESSION here is stale.
		echo "NOTE: sync-enforcement webhook is scoped by matchConditions/${existing}, but its"
		echo "      expression differs from this script's copy. Update EXPRESSION here from"
		echo "      template-operator-v2 config/webhook/manifests.yaml."
	else
		# "Scoped by SOMETHING" is not proof of safety: a matchCondition whose
		# expression is effectively `true`, or keyed on the wrong label, still
		# matches every UPDATE and DELETE cluster-wide with failurePolicy Fail.
		# In a CI job a NOTE scrolls past unread, so this one fails.
		echo "ERROR: sync-enforcement webhook is scoped by matchConditions/${existing}, but its" >&2
		echo "       expression does not reference the templates.v2.stakater.com/instance label:" >&2
		echo "         ${existing_expr}" >&2
		echo "       A filter that matches more than the operator's own objects keeps the TOV2-9" >&2
		echo "       cluster-deadlock blast radius. Update EXPRESSION here from template-operator-v2" >&2
		echo "       config/webhook/manifests.yaml and inspect the live configuration." >&2
		exit 1
	fi
	exit 0
fi

echo "WARNING: sync-enforcement webhook has no matchConditions -- it matches UPDATE and DELETE"
echo "         on every resource in the cluster with failurePolicy: Fail. Scoping it to"
echo "         templates.v2.stakater.com/instance. See TOV2-9 in docs/upstream-issues.md."

patch=$(printf '%s' "${EXPRESSION}" \
	| jq -Rs '[{"op":"add","path":"/webhooks/0/matchConditions","value":[{"name":"managed-by-template-operator","expression":.}]}]')
kc patch validatingwebhookconfiguration "${NAME}" --type=json --patch "${patch}"
