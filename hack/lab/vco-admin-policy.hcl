# Policy for the vault-config-operator login in the lab. It is written in the
# root namespace and is deliberately broad: the lab tests how VCO behaves, not
# how narrow its policy can be.

# Tenant namespaces are created from root.
path "sys/namespaces" {
  capabilities = ["list"]
}
path "sys/namespaces/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

# Objects in the root namespace.
# VCO's Policy kind writes sys/policy/<name>, or sys/policies/<type>/<name>
# when spec.type is set.
path "sys/policy/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/policies/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/mounts" {
  capabilities = ["read", "list"]
}
path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
path "sys/auth" {
  capabilities = ["read", "list"]
}
path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Objects in a tenant namespace, one level below root, written with the login
# above and spec.authentication.targetNamespace. The Vault docs do not show `+`
# on the namespace segment; vault/policy.go matches the policy path against the
# full request path including the namespace. This lab is where that is tested.
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
