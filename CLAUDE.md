# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Helm charts that give every Stakater Multi-Tenant Operator (MTO) `Tenant` its own **Vault Enterprise** namespace. The charts only *describe* configuration — they emit [vault-config-operator](https://github.com/redhat-cop/vault-config-operator) (VCO) custom resources (`redhatcop.redhat.io/v1alpha1`), and VCO writes them to Vault.

The sister project for OpenBao is `stakater-ab/mto-extension-openbao`; its charts are the reference design this repo ports. Transit and PKI are not ported yet.

| Chart | Installed | Role |
|---|---|---|
| [charts/mto-extension-vault-enterprise-bootstrap/](charts/mto-extension-vault-enterprise-bootstrap/) | once per cluster | Watches `Tenant` CRs, fans out one child TI per tenant per slice, renders the shared Vault namespace, creates the VCO login ServiceAccount. |
| [charts/mto-extension-vault-enterprise/](charts/mto-extension-vault-enterprise/) | never by hand | Per-tenant template, pulled and rendered by template-operator-v2. |

[charts/README.md](charts/README.md) is the user-facing documentation.

## VCO facts the design depends on

- **VCO v1.0.3 or later.** It is the first release with `spec.authentication.targetNamespace` (upstream #373 — VCO logs in once and writes into a child namespace) and the `Namespace` fix: before it the controller panicked in every release since v0.8.50, and `IsEquivalentToDesiredState` never matched Vault's read, so every reconcile after the first failed "already exists" and back-off delayed deletes up to ~16 min. The lab and CI install `VCO_VERSION` from its release chart; `make lab-vco-src` builds a local checkout (`VCO_SRC`) instead, to test an unreleased VCO change. `crd-validate` reads a vendored copy of the 8 CRDs the charts render ([hack/vco-crds/](hack/vco-crds/), refreshed from the release chart by `make vco-crds-sync`); against CRDs from before v1.0.3, 26 of 27 tenant objects fail. A new kind needs its CRD vendored, or `crd-validate` fails "no CRD for …".
- **Every mount sets `config.listingVisibility`.** VCO adds its finalizer with an update that sends `listingVisibility: ""` when it is unset, its own CRD enum refuses that, and the CR never gets the finalizer: deleting it deletes nothing in Vault. The `listingvis` check and the e2e render step (VCO's finalizer on every CR it deletes) guard this.
- **Every tenant CR except the `Namespace` must carry `targetNamespace`.** Without it the object lands in the login namespace (root) and tenants collide. The `targetns` check guards this.
- **`KubernetesAuthEngineRole` token fields are integer seconds**; the OIDC role's are duration strings.
- **VCO mounts auth engines at `<spec.path>/<spec.name>`** — hence `kubernetes/workloads` and `oidc/sso`. Its `Policy` kind writes `sys/policy/<name>`, not `sys/policies/acl/`.
- **VCO has no deletion policy.** Deleting a `Namespace` CR deletes the Vault namespace and its data. The protection is the VCO login policy denying `delete` (charts/README.md → Deletion).
- **VCO status cannot show current health**: `ReconcileSuccessful` and `ReconcileFailed` coexist and both timestamps freeze. The TI outputs say only "ever succeeded" and "last error ever".
- **Vault Community Edition ignores namespaces** and reports success on colliding objects. Anything tenant-shaped must be tested on Enterprise.

## Commands

```bash
make                  # default goal: lint + render tests + crd-validate
make helm-render-test
make crd-validate     # against hack/vco-crds
make vco-crds-sync    # refresh hack/vco-crds from the VCO_VERSION release chart
make helm-release     # CI only: push both charts, tenant first; refuses a published version
make lab-up VAULT_LICENSE_FILE=<.hclic>   # or VAULT_EDITION=ce
make lab-chart-repo   # after a tenant-chart edit
make lab-vco          # install VCO_VERSION; make lab-vco-src builds VCO_SRC instead
```

## The test harness is the entire quality gate

[hack/chart-render-tests.sh](hack/chart-render-tests.sh) is production code.

- **A check that can pass on its own failure is worse than no check.** Render on its own line and check the status; never inside `$(...)`.
- **Never pipe a producer into `grep -q`.** Under `pipefail`, grep's early exit SIGPIPEs the producer and the pipeline status stops meaning "matched". Use `yqs` (runs yq to completion, fails the run on a yq error) and grep the variable.
- **Every guard needs a check that fails when the guard is deleted.** Mutation-test new guards: break the guard in a copy of the repo and confirm the named check goes red.
- **t-op-v2 output field names must be unique across a Template's outputs**, or none resolve (`outputnames`).

## CI

[pull_request.yaml](.github/workflows/pull_request.yaml) runs `make all` (no secrets). [push.yaml](.github/workflows/push.yaml) runs `make all` then `make helm-release`. `paths-ignore: '*.md'` matches root-level Markdown only, so chart docs still run CI.

## The E2E suite

[tests/e2e](tests/e2e) is one ordered test against one install; `make e2e-test` against the lab, `make e2e-kind` from nothing. Rules on top of the harness rules:

- **Assert in Vault, as the workload.** Mint the ServiceAccount's token and log in with it. Root inspects state only.
- **A denial counts only as a 403, and needs a matching allow.** `refused()` rejects any other error, but for a non-root token Vault answers a wrong path or a missing mount with a 403 too. So pair every denial with the same call on the same path succeeding for a caller that is granted it, or seed the path as root first. A denial must also be able to fail: test a capability the caller's tier WOULD have if the guard broke (an editor has no `delete`, so a metadata-delete refusal proves nothing). A live mutation (viewer tier given write) failed exactly the viewer-write check — repeat that kind of mutation when adding a denial.
- **Enterprise only.** The preflight refuses Community Edition. Licences need Vault ≥ 2.1.
- **SSO goes through the real chain: Vault → Dex → Keycloak**, all in the lab, logged in without a browser (`tests/e2e/sso.go`). An SSO login refused for the group is not a 403: check `claimRefused()` (Vault's "does not match any associated bound claim values"), never a bare error, and pair it with a login of the right group that succeeds.
- **UI flows ([docs/screenshots/flows/](docs/screenshots/flows/)) use only selectors seen in the production HTML of the pinned Vault.** Its build strips `data-test-*` from the login form (ember-test-selectors) but keeps them in the KV pages, so read the real DOM, never the source alone. A UI denial (a button that is absent) needs its matching allow in another tier's flow, and a live mutation (the flow run with a stronger tier's token) that makes it fail. `make screenshots` puts a run's images in the docs; `screenshots-check` (in `make all`) fails on a missing or unused image.
- **The uninstall is the documented order** (parent TI, wait for zero VCO CRs, then the release), and the suite runs it every time (`t.Cleanup`). The one exception: a failed run with `E2E_KEEP_ON_FAILURE` (set by `make e2e-kind`) keeps its state for `e2e-diagnostics`, and the next run's preflight removes it.

## Chart conventions

- **A tenant's data objects belong to the parent.** The `Namespace` CR and the kv mount are rendered by the parent for every valid Tenant, so they live as long as the Tenant CR. Anything that holds secrets must not move into the tenant chart, whose TIs exist only while the tenant has a labelled namespace (`datalifetime` check, `lifetime` e2e step).
- **Compose names with dots**, never hyphens: `kv.<tenant>.<ns>.<sa>`. Every part is a dot-free DNS label (tenant names are checked), so the join is unambiguous. A new name family needs its own prefix and a part count no other family has (kv 4, sso 3, share 6), or it can collide with another family (`namecollide`).
- **Quote every value derived from a tenant name.** `1234` is a valid tenant name and a YAML number (`tenantname`).
- **Test a toggle only through `vault.on`**, never with a bare `if .Values.x.enabled`: the string `"false"` is true to Go templates, and the schema accepts it (`falsestring`).
- **CI's make is GNU make 4.x; macOS ships 3.81, which ignores `.SHELLFLAGS`.** So `-euo pipefail` applies to recipes only on CI. Under `-e`, `out=$(cmd); rc=$?` exits before `rc` is set — write `rc=0; out=$(cmd) || rc=$?`. Test recipe changes with GNU make (the golang container has it) before trusting a local green.
- **An expected failure in the harness goes inside `if`.** Under `set -e` a bare failing command ends the run silently, with no FAIL line. And a value with `{…}` goes in a values file, never `--set`, which reads braces as list syntax.
- **A new tenant chart value reaches clusters only through `tenantValues`** (t-op-v2 pulls the published chart). If the bootstrap must own it, add it to the `installWideValues` reserved list.

- Bump `Chart.yaml` `version` with any chart change, and keep the bootstrap's `tenantChart.version` equal to the tenant chart's (`versionpin`).
- Register new values in `values.schema.json`. A stringly toggle also needs a template guard that survives `--skip-schema-validation`.
- A new opt-in field needs a fixture that turns it on, or `crd-validate` never sees it.
- Regenerate the golden deliberately; the command is in the harness header.
