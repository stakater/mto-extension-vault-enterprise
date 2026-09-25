#!/usr/bin/env bash
#
# Give vault-config-operator a login in the ROOT namespace of the lab Vault.
#
# - kubernetes auth at root, reviewing tokens with Vault's own ServiceAccount
# - the vco-admin policy and role, bound to one ServiceAccount in CONFIG_NS
#
# Every VCO CR that t-op-v2 renders lives in CONFIG_NS and names that
# ServiceAccount in spec.authentication.serviceAccount. The bootstrap chart
# creates the ServiceAccount; this script only binds it in Vault.
#
# The script ends by logging in as that ServiceAccount, so a green run proves
# the login works, not only that the writes were accepted.
set -euo pipefail

: "${CONTEXT:?CONTEXT must name the kube context}"
KUBECTL=${KUBECTL:-kubectl}
VAULT_NS=${VAULT_NS:-vault}
CONFIG_NS=${CONFIG_NS:-vault-config}
SA=${SA:-vco-admin}
ROLE=${ROLE:-vco-admin}
POLICY_FILE=${POLICY_FILE:-hack/lab/vco-admin-policy.hcl}
# 0 skips the login proof, for a lab where the bootstrap chart (which creates the
# ServiceAccount) is not installed yet — the e2e suite installs it itself, and
# nothing it renders reconciles unless this login works.
VERIFY_LOGIN=${VERIFY_LOGIN:-1}

kc() { "$KUBECTL" --context "$CONTEXT" "$@"; }
v() { kc -n "$VAULT_NS" exec -i vault-0 -- env VAULT_TOKEN=root VAULT_ADDR=http://127.0.0.1:8200 vault "$@"; }

echo "Vault: $(v version)"

# The bootstrap chart creates the ServiceAccount (make lab-bootstrap). It is
# not created here, so Helm owns it and the two cannot fight over it.
if [ "$VERIFY_LOGIN" = 1 ]; then
  kc -n "$CONFIG_NS" get serviceaccount "$SA" > /dev/null \
    || { echo "error: ServiceAccount $CONFIG_NS/$SA does not exist — install the bootstrap chart first (make lab-bootstrap), or set VERIFY_LOGIN=0" >&2; exit 1; }
fi

# Read the list on its own line: a failed `auth list` must stop the script,
# not look like "kubernetes is not enabled yet".
auth_list=$(v auth list -format=json)
if ! grep -q '"kubernetes/"' <<<"$auth_list"; then
  v auth enable kubernetes
fi
v write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443

v policy write "$ROLE" - <"$POLICY_FILE"
v write "auth/kubernetes/role/$ROLE" \
  bound_service_account_names="$SA" \
  bound_service_account_namespaces="$CONFIG_NS" \
  token_policies="$ROLE" \
  token_ttl=1h

if [ "$VERIFY_LOGIN" != 1 ]; then
  echo "Vault side configured; login proof SKIPPED (VERIFY_LOGIN=$VERIFY_LOGIN) — $CONFIG_NS/$SA does not exist yet"
  exit 0
fi
jwt=$(kc -n "$CONFIG_NS" create token "$SA")
policies=$(v write -field=token_policies auth/kubernetes/login role="$ROLE" jwt="$jwt")
case "$policies" in
  *"$ROLE"*) echo "login as $CONFIG_NS/$SA works; token policies: $policies" ;;
  *) echo "error: login as $CONFIG_NS/$SA returned policies '$policies', expected $ROLE" >&2; exit 1 ;;
esac
