# Policy for the vault-config-operator login in the lab, written in the root
# namespace. It differs from the production policy
# (charts/examples/vco-admin-policy.hcl) in one way: it allows DELETE on
# namespaces and mounts, so the e2e teardown can finish. It grants nothing in
# root beyond creating namespaces — VCO writes only inside tenant namespaces, and
# a grant on root's sys/policy or auth would let VCO rewrite its own policy.

# Tenant namespaces are created from root.
path "sys/namespaces" {
  capabilities = ["list"]
}
path "sys/namespaces/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

# Objects in a tenant namespace, one level below root, written with the login
# above and spec.authentication.targetNamespace. "+" matches one namespace
# segment (verified on Vault Enterprise 2.1.1). VCO's Policy kind writes
# sys/policy/<name>, or sys/policies/<type>/<name> when spec.type is set.
path "+/sys/policy/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "+/sys/policies/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "+/sys/mounts" {
  capabilities = ["read", "list"]
}
path "+/sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "+/sys/auth" {
  capabilities = ["read", "list"]
}
path "+/sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "+/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
