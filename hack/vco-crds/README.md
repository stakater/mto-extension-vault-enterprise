# Vendored vault-config-operator CRDs

The 8 VCO CRDs the charts render, used by `make crd-validate`. Vendored because
the charts depend on two VCO changes that are in no release yet:

- `spec.authentication.targetNamespace` (upstream issue
  [#291](https://github.com/redhat-cop/vault-config-operator/issues/291)) — in
  every CRD here.
- The `Namespace` controller fix — a controller change, not a schema change.

Source: `redhat-cop/vault-config-operator` at `af9eeb1` (2026-09-03) plus the
unmerged `feat/target-namespace` change, generated with `make manifests`.

Refresh with `make vco-crds-sync VCO_SRC=<checkout>` and update the source line
above. Once a VCO release contains the field, replace this copy with that
release's CRDs.

A kind the charts render without a CRD here fails `crd-validate` ("no CRD for
…"), so adding a kind means adding its CRD.
