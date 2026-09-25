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

- **VCO needs two unreleased changes.** `spec.authentication.targetNamespace` (upstream #291 — VCO logs in once and writes into a child namespace) and the `Namespace` fix: the controller panics in every release since v0.8.50, and `IsEquivalentToDesiredState` never matches Vault's read, so every reconcile after the first fails "already exists" and back-off delays deletes up to ~16 min. Both live in a local VCO checkout (`VCO_SRC`, default `../vault-config-operator`, branch `feat/target-namespace`). `crd-validate` reads a vendored copy of the 8 CRDs the charts render ([hack/vco-crds/](hack/vco-crds/), refreshed by `make vco-crds-sync`); against upstream CRDs 26 of 27 tenant objects fail. A new kind needs its CRD vendored, or `crd-validate` fails "no CRD for …".
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
make vco-crds-sync    # refresh hack/vco-crds from VCO_SRC
make helm-release     # CI only: push both charts, tenant first; refuses a published version
make lab-up VAULT_LICENSE_FILE=<.hclic>   # or VAULT_EDITION=ce
make lab-chart-repo   # after a tenant-chart edit
make lab-vco          # after a VCO_SRC edit
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
- **A denial counts only as a 403.** `refused()` rejects any other error, so a wrong path or a missing mount cannot pass as isolation. A live mutation (viewer tier given write) failed exactly the viewer-write check — repeat that kind of mutation when adding a denial.
- **Enterprise only.** The preflight refuses Community Edition. Licences need Vault ≥ 2.1.
- **The uninstall is the documented order** (parent TI, wait for zero VCO CRs, then the release), and the suite runs it every time.

## Chart conventions

- Bump `Chart.yaml` `version` with any chart change, and keep the bootstrap's `tenantChart.version` equal to the tenant chart's (`versionpin`).
- Register new values in `values.schema.json`. A stringly toggle also needs a template guard that survives `--skip-schema-validation`.
- A new opt-in field needs a fixture that turns it on, or `crd-validate` never sees it.
- Regenerate the golden deliberately; the command is in the harness header.
