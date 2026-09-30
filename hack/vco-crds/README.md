# Vendored vault-config-operator CRDs

The 8 VCO CRDs the charts render, used by `make crd-validate`, so the render
tests validate against the exact schema the lab and CI install, without a
cluster or a network call.

Source: the `vault-config-operator` **v1.0.3** release chart
(`https://redhat-cop.github.io/vault-config-operator`), the first release with
`spec.authentication.targetNamespace` and the `Namespace` controller fix
(upstream PR [#373](https://github.com/redhat-cop/vault-config-operator/pull/373)).

Refresh with `make vco-crds-sync` (from the `VCO_VERSION` release chart) and
update the source line above. To test an unreleased VCO change, use
`make vco-crds-sync-src VCO_SRC=<checkout>` instead.

A kind the charts render without a CRD here fails `crd-validate` ("no CRD for
…"), so adding a kind means adding its CRD.
