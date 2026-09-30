# Least-privilege policy for the vault-config-operator (VCO) login, written in
# vco.namespace (root by default). "+/" matches one child namespace: every
# tenant namespace and the shared one.
#
# Only the paths the two charts make VCO call, derived from VCO's own code
# (api/v1alpha1/*_types.go GetPath, and the engine-list reads in
# api/v1alpha1/utils/vaultengineobject.go). It assumes the chart defaults:
#   kv mount            kv                    (SecretEngineMount name kv)
#   workload auth mount kubernetes/workloads  (kubernetesAuth.path / .name)
#   SSO auth mount      oidc/sso              (sso.mount.path / .name)
# Change a mount value and the matching paths here must change with it.
#
# Deletes follow the data:
#   - NO delete on a tenant's Vault namespace or its kv mount. Deleting a
#     Namespace or SecretEngineMount CR (offboarding, a rename, a mistake) is
#     refused, the secrets stay, and the CR stays Terminating on VCO's
#     finalizer until a person decides (charts/README.md → Deletion).
#   - Delete on policies, roles and auth mounts: they hold grants, not data,
#     and go when a ServiceAccount loses its annotation or a tenant its last
#     labelled namespace. Offboarding still revokes access.
# Auth config objects need no delete: VCO never deletes them (IsDeletable).
#
# Nothing here reaches the root namespace's own policies, mounts or auth
# methods, so VCO cannot widen its own policy or log in as anything else.

# Tenant and shared Vault namespaces, created in the login namespace.
path "sys/namespaces/*" {
  capabilities = ["create", "read", "update"]
}

# The kv mount of each namespace. VCO reads the mount table to find it.
path "+/sys/mounts" {
  capabilities = ["read"]
}
path "+/sys/mounts/kv" {
  capabilities = ["create", "read", "update"]
}
path "+/sys/mounts/kv/tune" {
  capabilities = ["create", "read", "update"]
}

# The two auth mounts. Enabling and tuning an auth method needs sudo. The auth
# table is also read by the Policy kind, to resolve accessor placeholders.
path "+/sys/auth" {
  capabilities = ["read"]
}
path "+/sys/auth/kubernetes/workloads" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}
path "+/sys/auth/kubernetes/workloads/tune" {
  capabilities = ["create", "read", "update", "sudo"]
}
path "+/sys/auth/oidc/sso" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}
path "+/sys/auth/oidc/sso/tune" {
  capabilities = ["create", "read", "update", "sudo"]
}

# Their configuration and roles.
path "+/auth/kubernetes/workloads/config" {
  capabilities = ["create", "read", "update"]
}
path "+/auth/kubernetes/workloads/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "+/auth/oidc/sso/config" {
  capabilities = ["create", "read", "update"]
}
path "+/auth/oidc/sso/role/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# The policies the charts render. VCO's Policy kind writes sys/policy/<name>
# (sys/policies/<type>/<name> only when spec.type is set, which the charts
# never set).
path "+/sys/policy/*" {
  capabilities = ["create", "read", "update", "delete"]
}
