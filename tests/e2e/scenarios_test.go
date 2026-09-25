package e2e

import (
	"fmt"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
)

// The fixture: two tenants; e2e-alpha has two labelled namespaces.
//
//	e2e-alpha  e2e-alpha-dev    SA web     kv editor, exports to e2e-beta
//	                            SA viewer  kv viewer
//	                            Deployment web: ESO secret web-db, Reloader on it
//	           e2e-alpha-tools  SA sub     kv viewer, subscribes to e2e-alpha-dev
//	                            SA nosub   kv editor, no subscription
//	                            Deployment sub: ESO secret sub-common (the subscription)
//	e2e-beta   e2e-beta-dev     SA reader  kv viewer, imports from e2e-alpha
//	                            Deployment reader: ESO secret reader-handoff (the share)
//
// Names are short on purpose: the child TemplateInstance name is
// mto-extension-vault-enterprise-<tenant>[.eso], capped at 63 characters.
const (
	alpha   = "e2e-alpha"
	beta    = "e2e-beta"
	alphaNS = "e2e-alpha-dev"
	toolsNS = "e2e-alpha-tools"
	betaNS  = "e2e-beta-dev"
)

// roleName mirrors the tenant chart's vault.roleName: <tenant>-<ns>-<sa>.
func roleName(tenant, ns, sa string) string { return tenant + "-" + ns + "-" + sa }

// appPath is an app's own KV prefix: <env>/<ns>/<app>.
func appPath(ns, app, leaf string) string { return env + "/" + ns + "/" + app + "/" + leaf }

// sharedPath is a namespace's intra-tenant write area: <env>/_shared/from-<ns>.
func sharedPath(ns, leaf string) string { return env + "/_shared/from-" + ns + "/" + leaf }

// TestE2E is one ordered scenario against one install. Each step depends on the
// state the previous one left, so the steps are subtests of one test and a
// failure stops the run.
func TestE2E(t *testing.T) {
	step := func(name string, f func(t *testing.T)) {
		t.Helper()
		if !t.Run(name, f) {
			t.FailNow()
		}
	}

	step("preflight", func(t *testing.T) {
		// Community Edition ignores namespaces: every tenant would land in root,
		// collide, and most objects would still report success. Refuse to run
		// rather than report that as a pass.
		v := vaultIn(t, "", "version")
		if !strings.Contains(v, "+ent") {
			t.Fatalf("Vault is not Enterprise (%s) — tenant isolation cannot be tested on Community Edition", strings.TrimSpace(v))
		}
		// Every run starts from the customer's starting point: no install, no
		// fixture tenants.
		if releaseExists(t) || get(t, gvrTemplateInstance, configNS, parentName) != nil {
			uninstall(t)
		}
		deleteTenant(t, alpha, alphaNS, toolsNS)
		deleteTenant(t, beta, betaNS)
	})

	step("install", func(t *testing.T) {
		createTenant(t, alpha, alphaNS, toolsNS)
		createTenant(t, beta, betaNS)
		createServiceAccount(t, alphaNS, "web", map[string]string{
			annPrefix + "kv":               "true",
			annPrefix + "tier":             "editor",
			annPrefix + "kv-export-tenant": beta,
		})
		createServiceAccount(t, alphaNS, "viewer", map[string]string{
			annPrefix + "kv":   "true",
			annPrefix + "tier": "viewer",
		})
		createServiceAccount(t, toolsNS, "sub", map[string]string{
			annPrefix + "kv":              "true",
			annPrefix + "tier":            "viewer",
			annPrefix + "kv-subscribe-ns": alphaNS,
		})
		createServiceAccount(t, toolsNS, "nosub", map[string]string{
			annPrefix + "kv":   "true",
			annPrefix + "tier": "editor",
		})
		createServiceAccount(t, betaNS, "reader", map[string]string{
			annPrefix + "kv":               "true",
			annPrefix + "tier":             "viewer",
			annPrefix + "kv-import-tenant": alpha,
		})
		helmInstall(t)
		waitTIReady(t, parentName)
		for _, tn := range []string{alpha, beta} {
			waitTIReady(t, tiPrefix+tn)
			waitTIReady(t, tiPrefix+tn+".eso")
		}
	})

	step("render: one Vault namespace per tenant", func(t *testing.T) {
		for _, tn := range []string{alpha, beta} {
			for _, o := range []struct{ kind, name string }{
				{"namespaces", tn},
				{"secretenginemounts", tn + "-kv"},
				{"authenginemounts", tn + "-kubernetes"},
				{"kubernetesauthengineconfigs", tn + "-kubernetes-config"},
			} {
				waitVCO(t, o.kind, o.name)
			}
		}
		for _, r := range []string{roleName(alpha, alphaNS, "web"), roleName(alpha, alphaNS, "viewer"),
			roleName(alpha, toolsNS, "sub"), roleName(alpha, toolsNS, "nosub"), roleName(beta, betaNS, "reader")} {
			waitVCO(t, "policies", r)
			waitVCO(t, "kubernetesauthengineroles", r)
		}
		// Inspected as root: each tenant is a namespace with its own kv/ and its
		// own workload auth mount, and holds only its own policies.
		nss := vaultNamespaces(t)
		for _, want := range []string{alpha, beta, sharedNS} {
			if !slices.Contains(nss, want) {
				t.Fatalf("Vault namespace %q missing; namespaces: %v", want, nss)
			}
		}
		for _, tn := range []string{alpha, beta} {
			if m := vaultKeys(t, tn, "secrets", "list", "-format=json"); !slices.Contains(m, "kv/") {
				t.Errorf("namespace %s has no kv/ mount: %v", tn, m)
			}
			if a := vaultKeys(t, tn, "auth", "list", "-format=json"); !slices.Contains(a, k8sAuthMount+"/") {
				t.Errorf("namespace %s has no %s/ auth mount: %v", tn, k8sAuthMount, a)
			}
		}
		alphaPolicies := jsonList(t, vaultIn(t, alpha, "policy", "list", "-format=json"))
		if slices.Contains(alphaPolicies, roleName(beta, betaNS, "reader")) {
			t.Errorf("e2e-beta's policy is in e2e-alpha's namespace: %v", alphaPolicies)
		}
	})

	step("vco: a namespace stays clean across drift reconciles", func(t *testing.T) {
		// VCO re-reconciles every object each drift period. A namespace that
		// fails its SECOND reconcile — Vault rejects a rewrite with "already
		// exists" — builds per-object back-off of up to ~16 minutes, and a later
		// delete then waits for it. Watching across two periods catches that
		// directly, instead of as a teardown that sometimes stalls.
		holdFor(t, 2*vcoSync+15*time.Second, "tenant Namespace CRs across two drift reconciles", func() string {
			for _, tn := range []string{alpha, beta} {
				o := get(t, vcoGVR("namespaces"), configNS, tn)
				if o == nil {
					return "Namespace " + tn + " absent"
				}
				if _, msg := condition(o, "ReconcileFailed"); msg != "" {
					return "Namespace " + tn + " failed a reconcile: " + msg
				}
			}
			return ""
		})
	})

	var webToken string
	step("kv: a workload reads and writes its own secrets", func(t *testing.T) {
		var policies []string
		webToken, policies = vaultLogin(t, alpha, roleName(alpha, alphaNS, "web"), saToken(t, alphaNS, "web"))
		if !slices.Contains(policies, roleName(alpha, alphaNS, "web")) {
			t.Fatalf("login gave policies %v, want %s", policies, roleName(alpha, alphaNS, "web"))
		}
		if err := kvPut(t, webToken, alpha, appPath(alphaNS, "web", "db"), "password=v1"); err != nil {
			t.Fatalf("editor could not write its own secret: %v", err)
		}
		got, err := kvGet(t, webToken, alpha, appPath(alphaNS, "web", "db"), "password")
		if err != nil || got != "v1" {
			t.Fatalf("read own secret: got %q, err %v; want v1", got, err)
		}
	})

	step("kv: isolation between apps, tiers and tenants", func(t *testing.T) {
		// Seeded as root, so a refusal below is about the caller, not a missing secret.
		vaultIn(t, alpha, "kv", "put", "-mount=kv", appPath(alphaNS, "viewer", "cfg"), "mode=ro")
		vaultIn(t, beta, "kv", "put", "-mount=kv", appPath(betaNS, "reader", "cfg"), "mode=beta")

		if _, err := kvGet(t, webToken, alpha, appPath(alphaNS, "viewer", "cfg"), "mode"); !refused(err) {
			t.Errorf("web read a sibling app's secret in its own namespace; err: %v", err)
		}
		if _, err := kvGet(t, webToken, beta, appPath(betaNS, "reader", "cfg"), "mode"); !refused(err) {
			t.Errorf("an e2e-alpha token read e2e-beta's namespace; err: %v", err)
		}
		if _, _, err := vaultTryLogin(t, beta, roleName(beta, betaNS, "reader"), saToken(t, alphaNS, "web")); err == nil {
			t.Errorf("e2e-alpha's ServiceAccount logged in to an e2e-beta role")
		}

		viewerToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "viewer"), saToken(t, alphaNS, "viewer"))
		if got, err := kvGet(t, viewerToken, alpha, appPath(alphaNS, "viewer", "cfg"), "mode"); err != nil || got != "ro" {
			t.Errorf("viewer could not read its own secret: got %q, err %v", got, err)
		}
		if err := kvPut(t, viewerToken, alpha, appPath(alphaNS, "viewer", "cfg"), "mode=rw"); !refused(err) {
			t.Errorf("viewer tier wrote a secret; err: %v", err)
		}
	})

	step("eso: a Deployment gets its secret from Vault", func(t *testing.T) {
		createDeployment(t, alphaNS, "web", "web", map[string]string{
			annPrefix + "kv-secret.db": "db#password",
			// Reloader restarts the Deployment when this Secret changes.
			"secret.reloader.stakater.com/reload": "web-db",
		}, []corev1.EnvVar{secretEnv("PASSWORD", "web-db", "password")})
		waitFor(t, "ExternalSecret web-db synced", func() string {
			if v := secretValue(t, alphaNS, "web-db", "password"); v != "v1" {
				o := get(t, gvrExternalSecret, alphaNS, "web-db")
				if o == nil {
					return "ExternalSecret absent"
				}
				s, msg := condition(o, "Ready")
				return fmt.Sprintf("Secret password=%q; ExternalSecret Ready=%q %s", v, s, msg)
			}
			return ""
		})
		waitFor(t, "the web pod sees PASSWORD=v1", func() string {
			p := runningPod(t, alphaNS, "web")
			if p == "" {
				return "no single ready pod"
			}
			if v := podEnv(t, alphaNS, p, "PASSWORD"); v != "v1" {
				return "PASSWORD=" + v
			}
			return ""
		})
	})

	step("reloader: a rotated secret reaches a new pod", func(t *testing.T) {
		before := runningPod(t, alphaNS, "web")
		if before == "" {
			t.Fatal("no running web pod to compare against")
		}
		// Rotated as the WORKLOAD, through its own grant.
		if err := kvPut(t, webToken, alpha, appPath(alphaNS, "web", "db"), "password=v2"); err != nil {
			t.Fatalf("rotate: %v", err)
		}
		waitFor(t, "ESO refreshes Secret web-db to v2", func() string {
			if v := secretValue(t, alphaNS, "web-db", "password"); v != "v2" {
				return "password=" + v
			}
			return ""
		})
		// An env var is read once at container start, so only a NEW pod can see
		// v2: seeing it proves Reloader rolled the Deployment.
		waitFor(t, "Reloader rolls web and the new pod sees PASSWORD=v2", func() string {
			p := runningPod(t, alphaNS, "web")
			if p == "" || p == before {
				return "pod not replaced yet (current: " + p + ")"
			}
			if v := podEnv(t, alphaNS, p, "PASSWORD"); v != "v2" {
				return "new pod " + p + " has PASSWORD=" + v
			}
			return ""
		})
	})

	step("intra-tenant: apps in one namespace share through _shared/", func(t *testing.T) {
		// web (editor) writes its namespace's shared area; viewer, in the same
		// namespace, reads it without any annotation — and cannot write it.
		if err := kvPut(t, webToken, alpha, sharedPath(alphaNS, "common"), "url=https://db.internal"); err != nil {
			t.Fatalf("editor could not write its namespace's _shared/: %v", err)
		}
		viewerToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "viewer"), saToken(t, alphaNS, "viewer"))
		if got, err := kvGet(t, viewerToken, alpha, sharedPath(alphaNS, "common"), "url"); err != nil || got != "https://db.internal" {
			t.Fatalf("an app in the same namespace could not read _shared/: got %q, err %v", got, err)
		}
		if err := kvPut(t, viewerToken, alpha, sharedPath(alphaNS, "common"), "url=tampered"); !refused(err) {
			t.Errorf("viewer tier wrote to _shared/; err: %v", err)
		}
	})

	step("intra-tenant: another namespace subscribes with kv-subscribe-ns", func(t *testing.T) {
		subToken, _ := vaultLogin(t, alpha, roleName(alpha, toolsNS, "sub"), saToken(t, toolsNS, "sub"))
		if got, err := kvGet(t, subToken, alpha, sharedPath(alphaNS, "common"), "url"); err != nil || got != "https://db.internal" {
			t.Fatalf("subscriber could not read the producer's _shared/: got %q, err %v", got, err)
		}
		// A subscription is read-only on the producer's prefix, on the metadata
		// path too: KV v2 metadata delete removes every version.
		if err := kvPut(t, subToken, alpha, sharedPath(alphaNS, "common"), "url=tampered"); !refused(err) {
			t.Errorf("subscriber wrote to the producer's _shared/; err: %v", err)
		}
		if err := kvMetadataDelete(t, subToken, alpha, sharedPath(alphaNS, "common")); !refused(err) {
			t.Errorf("subscriber deleted the producer's secret metadata; err: %v", err)
		}
		// Same tenant, no annotation: no grant. An editor tier does not help.
		nosubToken, _ := vaultLogin(t, alpha, roleName(alpha, toolsNS, "nosub"), saToken(t, toolsNS, "nosub"))
		if _, err := kvGet(t, nosubToken, alpha, sharedPath(alphaNS, "common"), "url"); !refused(err) {
			t.Errorf("an unsubscribed app read another namespace's _shared/; err: %v", err)
		}
		// The value survived every refused write above.
		if got, err := kvGet(t, webToken, alpha, sharedPath(alphaNS, "common"), "url"); err != nil || got != "https://db.internal" {
			t.Errorf("_shared/ value changed: got %q, err %v", got, err)
		}

		createDeployment(t, toolsNS, "sub", "sub", map[string]string{
			annPrefix + "kv-subscribe.common": alphaNS + "/common#url",
		}, []corev1.EnvVar{secretEnv("DB_URL", "sub-common", "url")})
		waitFor(t, "ExternalSecret sub-common synced", func() string {
			if v := secretValue(t, toolsNS, "sub-common", "url"); v != "https://db.internal" {
				o := get(t, gvrExternalSecret, toolsNS, "sub-common")
				if o == nil {
					return "ExternalSecret absent"
				}
				s, msg := condition(o, "Ready")
				return fmt.Sprintf("Secret url=%q; ExternalSecret Ready=%q %s", v, s, msg)
			}
			return ""
		})
		waitFor(t, "the sub pod sees DB_URL", func() string {
			p := runningPod(t, toolsNS, "sub")
			if p == "" {
				return "no single ready pod"
			}
			if v := podEnv(t, toolsNS, p, "DB_URL"); v != "https://db.internal" {
				return "DB_URL=" + v
			}
			return ""
		})
	})

	step("share: e2e-alpha exports, e2e-beta imports through ESO", func(t *testing.T) {
		outRole := "share-" + alpha + "-" + alphaNS + "-web-out-" + beta
		inRole := "share-" + beta + "-" + betaNS + "-reader-in-" + alpha
		sharePath := env + "/from-" + alpha + "/to-" + beta + "/handoff"
		waitVCO(t, "kubernetesauthengineroles", outRole)
		waitVCO(t, "kubernetesauthengineroles", inRole)

		outToken, _ := vaultLogin(t, sharedNS, outRole, saToken(t, alphaNS, "web"))
		if err := kvPut(t, outToken, sharedNS, sharePath, "token=t1"); err != nil {
			t.Fatalf("exporter could not write the share: %v", err)
		}
		inToken, _ := vaultLogin(t, sharedNS, inRole, saToken(t, betaNS, "reader"))
		if got, err := kvGet(t, inToken, sharedNS, sharePath, "token"); err != nil || got != "t1" {
			t.Fatalf("importer read the share: got %q, err %v", got, err)
		}
		if err := kvPut(t, inToken, sharedNS, sharePath, "token=tampered"); !refused(err) {
			t.Errorf("importer wrote to a share it may only read; err: %v", err)
		}
		// The reverse direction was never granted.
		if _, err := kvGet(t, outToken, sharedNS, env+"/from-"+beta+"/to-"+alpha+"/x", "token"); !refused(err) {
			t.Errorf("exporter read the reverse share path; err: %v", err)
		}

		createDeployment(t, betaNS, "reader", "reader", map[string]string{
			annPrefix + "kv-import.handoff": alpha + "/handoff#token",
		}, []corev1.EnvVar{secretEnv("HANDOFF", "reader-handoff", "token")})
		waitFor(t, "ExternalSecret reader-handoff synced", func() string {
			if v := secretValue(t, betaNS, "reader-handoff", "token"); v != "t1" {
				o := get(t, gvrExternalSecret, betaNS, "reader-handoff")
				if o == nil {
					return "ExternalSecret absent"
				}
				s, msg := condition(o, "Ready")
				return fmt.Sprintf("Secret token=%q; ExternalSecret Ready=%q %s", v, s, msg)
			}
			return ""
		})
	})

	if os.Getenv("E2E_KEEP") != "" {
		t.Log("E2E_KEEP set: leaving the install and fixtures in place")
		return
	}

	step("teardown: the documented uninstall order", func(t *testing.T) {
		uninstall(t)
		// The lab's Vault policy allows deletes, so VCO removes the tenant
		// namespaces. A production policy denies them (charts/README.md → Deletion).
		waitFor(t, "the tenants' Vault namespaces are deleted", func() string {
			var left []string
			for _, n := range vaultNamespaces(t) {
				if n == alpha || n == beta {
					left = append(left, n)
				}
			}
			if len(left) > 0 {
				return "still present: " + strings.Join(left, ", ")
			}
			return ""
		})
		deleteTenant(t, alpha, alphaNS, toolsNS)
		deleteTenant(t, beta, betaNS)
	})
}
