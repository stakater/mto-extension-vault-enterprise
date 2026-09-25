# mto-extension-vault-enterprise

Per-tenant Vault Enterprise configuration for Stakater Multi-Tenant Operator
(MTO): template-operator-v2 (t-op-v2) renders one set of
[vault-config-operator](https://github.com/redhat-cop/vault-config-operator)
(VCO) CRs per MTO `Tenant`.

Status: charts for KV, kubernetes auth, sharing, SSO and ESO are built and
render-tested; transit and PKI are not supported yet. The charts need a
vault-config-operator build with two unreleased changes (see
[charts/README.md → Prerequisites](charts/README.md#prerequisites)), and a live
test on Vault Enterprise is still to do.

| Path | What |
|---|---|
| [charts/](charts/) | the two charts and their user documentation |
| [hack/chart-render-tests.sh](hack/chart-render-tests.sh) | the render tests — the quality gate |
| [hack/crd-validate/](hack/crd-validate/) | validates rendered VCO CRs through the apiserver's admission pipeline |
| [hack/render-fixtures/](hack/render-fixtures/) | fixtures and the golden render |
| [hack/lab/](hack/lab/) | the local kind lab |

```bash
make                  # everything CI runs: lint, render tests, CRD validation
make vco-crds-sync VCO_SRC=../vault-config-operator   # refresh the vendored VCO CRDs
```

`crd-validate` checks against a vendored copy of the VCO CRDs in
[hack/vco-crds/](hack/vco-crds/), because the field the charts depend on is not
in a VCO release yet.

## E2E

[tests/e2e](tests/e2e/) runs the charts against a live lab: one ordered test,
one install. It installs the bootstrap chart itself (ESO on, 10s refresh),
brings its own tenants `e2e-alpha` and `e2e-beta`, and ends with the documented
uninstall.

| Step | Proves |
|---|---|
| render | every TemplateInstance Ready; one Vault namespace per tenant with its own `kv/` and `kubernetes/workloads/` |
| vco drift | the tenants' `Namespace` CRs stay error-free across two VCO drift reconciles |
| kv | a workload logs in with its ServiceAccount token and reads and writes its own prefix |
| isolation | a sibling app's prefix, another tenant's namespace and another tenant's role are refused; a viewer cannot write |
| eso | a Deployment's `kv-secret.<name>` becomes a Kubernetes Secret, and the pod sees it |
| reloader | a value rotated in Vault reaches the Secret, and Reloader rolls a new pod that sees it |
| intra-tenant, one namespace | an editor writes `_shared/from-<ns>/`; another app in the namespace reads it and cannot write it |
| intra-tenant, subscription | an app in a second namespace with `kv-subscribe-ns` reads it (directly and through ESO) but cannot write or delete its metadata; an app without the annotation is refused |
| share | e2e-alpha writes a share, e2e-beta reads it through ESO and cannot write it |
| teardown | the documented uninstall order leaves no CR and deletes the tenants' Vault namespaces |

Every access check runs as the workload (its own ServiceAccount token), never
as root; a denial counts only when Vault answers 403, not on a typo or a missing
mount. The suite refuses Community Edition, which ignores namespaces. Each denial and
the drift step were checked by a live mutation — breaking the chart or VCO
made exactly that step fail.

```bash
make e2e-kind VAULT_LICENSE_FILE=<.hclic>   # build the lab and run the suite
make e2e-up VAULT_LICENSE_FILE=<.hclic>     # the lab only, then iterate with:
make e2e-test                               # E2E_KEEP=1 keeps the install for inspection
```

The licence needs Vault Enterprise **2.1** or later: 2.0.4 rejects a current
licence with `invalid module: "agentic-iam"`. `VAULT_VERSION` defaults to 2.1.1.

## CI

| Workflow | Runs | Does |
|---|---|---|
| [pull_request.yaml](.github/workflows/pull_request.yaml) | PRs to `main` | `make all`. No secrets. |
| [push.yaml](.github/workflows/push.yaml) | pushes to `main` | `make all`, then `make helm-release`: both charts to `oci://ghcr.io/stakater/charts`, tenant chart first. |
| [e2e.yaml](.github/workflows/e2e.yaml) | PR approval, label `ok-to-test/kubernetes`, dispatch | `make e2e-kind` on a kind cluster. Needs `secrets.VAULT_LICENSE` and `vars.VCO_REPOSITORY` / `vars.VCO_REF` pointing at a VCO ref with both unreleased changes. |

`helm-release` refuses a chart version that is already published (GHCR allows
tag overwrite, and `helm push` would silently replace what tenants pull), so a
chart change needs a `Chart.yaml` version bump. `push.yaml` needs the
`GHCR_USERNAME` / `GHCR_TOKEN` secrets with package-write access, and
`STAKATER_DELIVERY_SLACK_WEBHOOK` for the failure notice. A commit message
containing `[skip-ci]` skips the release job.

## Local lab

```bash
make lab-up VAULT_LICENSE_FILE=~/vault.hclic   # Vault Enterprise 2.1.1
make lab-up VAULT_EDITION=ce                    # no licence: Community Edition, no namespaces
make lab-render                                  # two sample Tenants, labelled namespaces, annotated SAs
make lab-vco                                     # rebuild and redeploy VCO after an edit in VCO_SRC
make lab-down
```

| Component | Why |
|---|---|
| kind (Kubernetes 1.33) | t-op-v2's CRDs do not install on 1.31 |
| cert-manager | t-op-v2's and VCO's webhook certificates |
| MTO `Tenant` CRD | the Template's input; MTO itself is not installed |
| template-operator-v2 0.0.7 | the renderer; the release name must be `template-operator-v2` |
| Vault 2.0.4, dev mode | in-memory, root token `root`; a pod restart wipes it, then run `make lab-vault-bootstrap` |
| VCO from `VCO_SRC` (default `../vault-config-operator`) | built from a checkout, so unmerged fixes can be tested |

`lab-up` also serves this checkout's tenant chart from an in-cluster HTTP repo
(`lab-chart-repo`) and installs the bootstrap chart from this checkout
(`lab-bootstrap`, with `parent.eso=disabled` — ESO is not on the lab cluster).
After a tenant-chart edit, run `make lab-chart-repo`.

VCO logs in once, in Vault's **root** namespace, as `vault-config/vco-admin`
([vault-bootstrap.sh](hack/lab/vault-bootstrap.sh),
[vco-admin-policy.hcl](hack/lab/vco-admin-policy.hcl)). Tenant objects reach
the tenant's Vault namespace through `spec.authentication.targetNamespace`,
which exists only in the VCO branch `feat/target-namespace` (upstream issue
[#291](https://github.com/redhat-cop/vault-config-operator/issues/291)). The
lab's VCO build also carries the `Namespace` controller fix.

### Known VCO problems the lab shows

- The `Namespace` kind panics on every reconcile, in every release since
  v0.8.50: `interface conversion: interface {} is nil, not *api.Client` at
  `internal/controller/namespace_controller.go:77`. The CR never gets a status.
  Fixed in the lab's VCO build.
- VCO's status cannot show current health: `ReconcileSuccessful` and
  `ReconcileFailed` sit side by side and both timestamps freeze.
- On Enterprise, every reconcile of a `Namespace` after the first fails:
  Vault's read never matches VCO's desired state, so VCO writes again and Vault
  answers `namespace "<x>/" already exists`. Per-object back-off grows to about
  16 minutes, and deleting a tenant then waits for it. Fixed in the lab's VCO
  build (`IsEquivalentToDesiredState`); the e2e `vco drift` step catches it.
- On Community Edition, Vault ignores the namespace, so every tenant's objects
  land in root and collide: two tenants' `admin` policies become one.
- The VCO chart always renders a `ServiceMonitor` unless
  `enableMonitoring=false` (upstream issue #221).

### Lab gotchas

- `kind load docker-image` fails with "failed to detect containerd
  snapshotter" on older kind with Docker Desktop's containerd image store. The
  Makefile imports the image into the node's containerd instead.
- VCO's `make helmchart` needs GNU sed; the Makefile puts `gsed` first on PATH.
- The licence is read from `VAULT_LICENSE_FILE` into a Secret and never
  committed or echoed.
