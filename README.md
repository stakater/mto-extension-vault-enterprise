# mto-extension-vault-enterprise

Per-tenant Vault Enterprise configuration for Stakater Multi-Tenant Operator
(MTO): template-operator-v2 (t-op-v2) renders one set of
[vault-config-operator](https://github.com/redhat-cop/vault-config-operator)
(VCO) CRs per MTO `Tenant`.

Status: charts for KV, kubernetes auth, sharing, SSO and ESO are built and
render-tested, and the e2e suite runs them end to end on Vault Enterprise;
transit and PKI are not supported yet. The charts need vault-config-operator
v1.0.3 or later (see
[charts/README.md → Prerequisites](charts/README.md#prerequisites)).

| Path | What |
|---|---|
| [charts/](charts/) | the two charts and their user documentation |
| [hack/chart-render-tests.sh](hack/chart-render-tests.sh) | the render tests (38 checks) — the quality gate |
| [hack/crd-validate/](hack/crd-validate/) | validates rendered VCO CRs through the apiserver's admission pipeline |
| [hack/render-fixtures/](hack/render-fixtures/) | fixtures and the golden render |
| [hack/lab/](hack/lab/) | the local kind lab |

```bash
make                  # everything CI runs: lint, render tests, CRD validation
make vco-crds-sync    # refresh the vendored VCO CRDs from the VCO_VERSION release
```

`crd-validate` checks against a vendored copy of the VCO v1.0.3 CRDs in
[hack/vco-crds/](hack/vco-crds/), so CI needs no cluster and no network call.

## E2E

[tests/e2e](tests/e2e/) runs the charts against a live lab: one ordered test,
one install. It installs the bootstrap chart itself (ESO on, 10s refresh),
brings its own tenants `e2e-alpha` and `e2e-beta`, and ends with the documented
uninstall.

| Step | Proves |
|---|---|
| render | every TemplateInstance Ready; one Vault namespace per tenant with its own `kv/` and `kubernetes/workloads/` |
| vco drift | the tenants' `Namespace` CRs stay error-free across two VCO drift reconciles |
| kv | a workload logs in with its ServiceAccount token and reads and writes its own prefix; the token is a service token with a TTL of 3600 s or less |
| isolation | a sibling app's prefix, another tenant's namespace and another tenant's role are refused (403); a viewer cannot write; the other tenant's role works for its own ServiceAccount |
| versions | an editor writes two versions, reads version 1 and patches one field; an editor cannot soft-delete and a viewer cannot patch; an admin soft-deletes and undeletes |
| own prefix | an app lists its own prefix, but not its namespace level (which names the other apps), and cannot read a sibling's metadata |
| vco revert | a policy widened by hand in Vault works at first; VCO's drift detection rewrites it, and the same write is refused again |
| vco move | VCO's webhook refuses to change a CR's `targetNamespace`, and accepts an update that keeps it |
| tiers | admin can destroy versions, an editor cannot; audit-read can list but not read |
| sso | Keycloak users log in through Dex; a group gives exactly its tier, in its own tenant only (see below) |
| sso tiers | audit-read lists and reads no data; the editor cannot destroy a version, the admin can |
| configmap | `vault-config-<sa>` has the right values, and logging in and reading with exactly those values works; `vault-apps` indexes the app |
| template-operator | a deleted `vault-config-<sa>` comes back with the same values (`sync.mode=revert`) |
| eso | a Deployment's `kv-secret.<name>` becomes a Kubernetes Secret, and the pod sees it |
| reloader | a value rotated in Vault reaches the Secret, and Reloader rolls a new pod that sees it |
| eso, whole secret | `kv-secret.<name>: <leaf>` with no `#key` copies every key of the leaf into one Secret |
| intra-tenant, one namespace | an editor writes `_shared/from-<ns>/`; another app in the namespace reads it and cannot write it |
| intra-tenant, subscription | an editor in a second namespace with `kv-subscribe-ns` reads it (directly and through ESO) but cannot write or delete its metadata; an app without the annotation is refused |
| app annotation | `app` names the prefix, not the ServiceAccount; when two ServiceAccounts claim one app, both get an error ConfigMap and no login role; when one gives the name up, the other's access returns and its data is still there |
| one app, two namespaces | ServiceAccounts with one name in two namespaces are two apps: each reads its own prefix and not the other's |
| guards, ServiceAccount | no tier, an unknown tier, a `kv` value that is not `true`/`false`, a misspelled key, `transit`, and the `default` ServiceAccount each get an error ConfigMap and no login role; the other ServiceAccounts still work |
| guards, Deployment | a Deployment that asks for a secret its ServiceAccount does not grant gets a `deploy-error` ConfigMap and no ExternalSecret |
| tier change | lowering editor to viewer rewrites the policy in place; the token issued at editor and a new login both lose write, and keep read |
| removal | removing a ServiceAccount's annotations deletes its Policy, Role, Vault role and ConfigMap, and its login is refused |
| share | e2e-alpha writes a share, e2e-beta reads it through ESO and cannot write it; each tenant's ServiceAccount is refused by the other's share role |
| lifetime | deleting e2e-beta's last namespace removes its workload render but keeps its Vault namespace, kv mount and secrets; a new namespace brings the render back |
| offboarding | with the production VCO policy ([vco-admin-policy.hcl](charts/examples/vco-admin-policy.hcl)), deleting Tenant e2e-beta and its namespace removes its grants and e2e-alpha's share role to it, but VCO is refused the delete of its Vault namespace and kv mount: the secret and both shares stay, and the two CRs stay `Terminating`; then the documented admin procedure (delete the namespace, remove the finalizers) finishes it |
| teardown | the documented uninstall order leaves no CR and deletes the tenants' Vault namespaces |

Every access check runs as the workload (its own ServiceAccount token), never
as root. A denial counts only when Vault answers 403, and each has a matching
allow on the same path, because for a non-root token a wrong path or a missing
mount is a 403 too. The preflight asks the Vault **server** for its version and
a live licence, refuses Community Edition, and clears Vault namespaces a failed
run left behind (the tenants' and `shared`). The teardown runs from
`t.Cleanup`, so it also runs after a failure — except under `make e2e-kind`,
which keeps a failed run's state for `e2e-diagnostics`. Every command and API
call has a timeout, and a login error never prints the ServiceAccount JWT.

SSO runs as in production: Vault → Dex (configured by the Dex Config Operator) →
Keycloak, all in the lab (`make lab-keycloak`, `make lab-dex`). Keycloak's realm
`mto` has a group per tenant tier (`<tenant>-<tier>s`) and five test users:
`alice` (e2e-alpha-editors), `bob` (e2e-alpha-viewers), `carol`
(e2e-beta-admins), `dave` (e2e-alpha-audit-reads) and `erin`
(e2e-alpha-admins); their passwords are in Secret
`keycloak/keycloak-test-users`. The suite logs them in with no browser, over
HTTP through port-forwards, and checks that a group gives exactly its tier (bob
cannot take the editor role), in its own tenant only (alice cannot log in to
e2e-beta, and her token cannot read it).

A denial is trusted only after a live mutation: break the guard, run the
suite, and see exactly that check fail. The package comment in
[tests/e2e/e2e_test.go](tests/e2e/e2e_test.go) lists which checks have had one.

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
| [e2e.yaml](.github/workflows/e2e.yaml) | PR approval, label `ok-to-test/kubernetes`, dispatch | `make e2e-kind` on a kind cluster. Needs `secrets.VAULT_LICENSE`. |

`helm-release` never overwrites a published version (GHCR allows tag
overwrite, and `helm push` would silently replace what tenants pull): it
**skips** a version that is already published, so a push that changes no chart
does not fail. `make version-bump-check` on every PR fails a chart that changed
without a `Chart.yaml` version bump — otherwise that change would never be
released. The CI jobs use the pinned helm and yq, not the runner's. `push.yaml` needs the
`GHCR_USERNAME` / `GHCR_TOKEN` secrets with package-write access, and
`STAKATER_DELIVERY_SLACK_WEBHOOK` for the failure notice. A commit message
containing `[skip-ci]` skips the release job.

## Local lab

```bash
make lab-up VAULT_LICENSE_FILE=~/vault.hclic   # Vault Enterprise 2.1.1
make lab-up VAULT_EDITION=ce                    # no licence: Community Edition, no namespaces
make lab-render                                  # two sample Tenants, labelled namespaces, annotated SAs
make lab-vco-src                                 # build VCO from VCO_SRC instead of the release
make lab-down
```

| Component | Why |
|---|---|
| kind (Kubernetes 1.33) | t-op-v2's CRDs do not install on 1.31 |
| cert-manager | t-op-v2's and VCO's webhook certificates |
| MTO `Tenant` CRD | the Template's input; MTO itself is not installed |
| template-operator-v2 0.0.7 | the renderer; the release name must be `template-operator-v2` |
| External Secrets Operator, Reloader | the ESO slice's SecretStores and ExternalSecrets; restarts on a rotated Secret |
| Vault Enterprise 2.1.1, dev mode | in-memory, root token `root`; a pod restart wipes it, then run `make lab-vault-bootstrap` |
| VCO v1.0.3 (`VCO_VERSION`) | from its release chart; `make lab-vco-src` builds `VCO_SRC` instead, to test an unreleased change |
| Keycloak 26.4.0 | SSO users and groups: realm `mto`, client `dex` |
| DCO 0.0.7 and Dex 2.45.1 | SSO: Dex, configured by the Dex Config Operator, in front of Keycloak |

`lab-up` also serves this checkout's tenant chart from an in-cluster HTTP repo
(`lab-chart-repo`) and installs the bootstrap chart from this checkout
(`lab-bootstrap`, with SSO through the lab's Dex).
After a tenant-chart edit, run `make lab-chart-repo`.

VCO logs in once, in Vault's **root** namespace, as `vault-config/vco-admin`
([vault-bootstrap.sh](hack/lab/vault-bootstrap.sh),
[vco-admin-policy.hcl](hack/lab/vco-admin-policy.hcl)). Tenant objects reach
the tenant's Vault namespace through `spec.authentication.targetNamespace`,
which VCO has since v1.0.3 (upstream PR
[#373](https://github.com/redhat-cop/vault-config-operator/pull/373)), together
with the `Namespace` controller fix.

### Known VCO problems the lab shows

- A `SecretEngineMount` or `AuthEngineMount` without `spec.config` never gets
  VCO's finalizer, in every release including v1.0.3: VCO's update sends
  `listingVisibility: ""` (the Go field has no `omitempty`), and its own CRD
  enum refuses it (`Unsupported value: ""`). Deleting such a CR deletes nothing
  in Vault. The charts set `config.listingVisibility: hidden`, Vault's default;
  the render check `listingvis` and the e2e render step guard it.
- The `Namespace` kind panics on every reconcile, in every release since
  v0.8.50: `interface conversion: interface {} is nil, not *api.Client` at
  `internal/controller/namespace_controller.go:77`. The CR never gets a status.
  Fixed in v1.0.3.
- VCO's status cannot show current health: `ReconcileSuccessful` and
  `ReconcileFailed` sit side by side and both timestamps freeze.
- On Enterprise, every reconcile of a `Namespace` after the first fails:
  Vault's read never matches VCO's desired state, so VCO writes again and Vault
  answers `namespace "<x>/" already exists`. Per-object back-off grows to about
  16 minutes, and deleting a tenant then waits for it. Fixed in v1.0.3
  (`IsEquivalentToDesiredState`); the e2e `vco drift` step catches it.
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
- **Do not upgrade a lab install made before the tenant's Vault namespace and
  kv mount moved to the parent.** Those CRs moved from the child
  TemplateInstances to the parent one, and on an in-place upgrade the child can
  delete them before the parent takes them over; the lab's Vault policy allows
  the delete, so VCO then deletes the tenants' Vault namespaces. Uninstall in
  the documented order (charts/README.md → Uninstall), or `make lab-down`, and
  install again.
