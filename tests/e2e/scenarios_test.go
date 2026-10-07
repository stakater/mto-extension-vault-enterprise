package e2e

import (
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strconv"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

// The fixture: two tenants; e2e-alpha has two labelled namespaces.
//
//	e2e-alpha  e2e-alpha-dev    SA web     kv editor, exports to e2e-beta
//	                            SA viewer  kv viewer
//	                            SA admin   kv admin
//	                            SA auditor kv audit-read
//	                            SA temp    kv editor, its access is removed mid-run
//	                            SA lower   kv editor, lowered to viewer mid-run
//	                            SA billing-sa  kv editor, app "billing"; SA thief claims it too
//	                            SA api     kv editor (also in e2e-alpha-tools: two apps)
//	                            Deployment web: ESO secret web-db, Reloader on it
//	                            Deployment cfg-reader: ESO secret web-cfg, a whole leaf
//	           e2e-alpha-tools  SA sub     kv editor, subscribes to e2e-alpha-dev
//	                            SA nosub   kv editor, no subscription
//	                            SA web     no annotation: web's name in another namespace
//	                            SA api     kv editor
//	                            SA g-*, default   misconfigured: error ConfigMaps, no login
//	                            Deployment sub: ESO secret sub-common (the subscription)
//	                            Deployment g-deploy: asks for a secret nosub does not grant
//	e2e-beta   e2e-beta-dev     SA reader  kv viewer, imports from e2e-alpha; its
//	                                       namespace is deleted and created again
//	                            Deployment reader: ESO secret reader-handoff (the share)
//
// Keycloak users (make lab-keycloak), for SSO through Dex:
//
//	alice e2e-alpha-editors   bob e2e-alpha-viewers   dave e2e-alpha-audit-reads
//	erin  e2e-alpha-admins    carol e2e-beta-admins
//
// and in the docs tenant acme, which only the ui step creates (ui.go):
//
//	alice acme-editors        bob acme-viewers        dave acme-audit-reads
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

// roleName mirrors the tenant chart's vault.roleName: kv.<tenant>.<ns>.<sa>.
func roleName(tenant, ns, sa string) string { return "kv." + tenant + "." + ns + "." + sa }

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
		// rather than report that as a pass. Asked of the SERVER, not the CLI
		// binary in the pod: its version and a live, unexpired licence.
		var st struct{ Version string }
		if err := json.Unmarshal([]byte(vaultIn(t, "", "status", "-format=json")), &st); err != nil || !strings.Contains(st.Version, "+ent") {
			t.Fatalf("the Vault server is not Enterprise (version %q, err %v) — tenant isolation cannot be tested on Community Edition", st.Version, err)
		}
		lic, err := vaultRun(t, vaultRootToken, "", "read", "-format=json", "sys/license/status")
		if err != nil {
			t.Fatalf("cannot read the Vault licence: %v", err)
		}
		var ls struct {
			Data struct {
				Autoloaded struct {
					ExpirationTime time.Time `json:"expiration_time"`
				} `json:"autoloaded"`
			} `json:"data"`
		}
		if err := json.Unmarshal([]byte(lic), &ls); err != nil || !ls.Data.Autoloaded.ExpirationTime.After(time.Now()) {
			t.Fatalf("the Vault licence is missing or expired (expires %v, err %v)", ls.Data.Autoloaded.ExpirationTime, err)
		}
		// Every run starts from the customer's starting point: no install, no
		// fixture tenants.
		if releaseExists(t) || get(t, gvrTemplateInstance, configNS, parentName) != nil {
			uninstall(t)
		}
		deleteTenant(t, alpha, alphaNS, toolsNS)
		deleteTenant(t, beta, betaNS)
		deleteTenant(t, docsTenant, docsNS)
		deleteUINamespace(t)
		// Vault state a failed run left behind would make the root checks below
		// pass without this run creating anything. The lab Vault is dev mode, so
		// root may remove it.
		// The shared namespace too: the render step checks that it exists.
		leftover := []string{alpha, beta, docsTenant, sharedNS}
		for _, n := range leftover {
			if slices.Contains(vaultNamespaces(t), n) {
				vaultIn(t, "", "namespace", "delete", n)
			}
		}
		waitFor(t, "no e2e Vault namespace left from an earlier run", func() string {
			for _, n := range vaultNamespaces(t) {
				if slices.Contains(leftover, n) {
					return n + " still present"
				}
			}
			return ""
		})
		// SSO needs the lab's Dex and Keycloak. Checked here, so a lab without
		// them fails in one clear line instead of at the SSO step.
		if got := dexIssuerFromVault(t); got != dexIssuer {
			t.Fatalf("Dex names its issuer %q, want %q: tokens would not validate", got, dexIssuer)
		}
		// The SSO roles allow these two callbacks (helmInstall). Dex must too,
		// or it refuses the login with "Unregistered redirect_uri".
		dexRedirects := dexClientRedirects(t)
		for _, want := range []string{cliCallback, uiCallback(t)} {
			if !slices.Contains(dexRedirects, want) {
				t.Fatalf("Dex client %s/%s does not allow the redirect URI %s (it allows %v)", dexNS, dexClient, want, dexRedirects)
			}
		}
		for _, u := range []string{"alice", "bob", "carol", "dave", "erin"} {
			testUserPassword(t, u)
		}
	})

	// The teardown runs even when a step fails: t.Cleanup, not the last step.
	// A failed run otherwise left its install and fixtures behind for the next.
	// The one exception is E2E_KEEP_ON_FAILURE (set by make e2e-kind): its
	// e2e-diagnostics runs after go test exits, and a teardown first would
	// leave it nothing to dump. The next run's preflight removes that state.
	//
	// One cleanup per job, not one for all: they run in reverse order of registration, and
	// a t.Fatalf inside one ends only that one, so a failed uninstall does not
	// skip the tenant deletion.
	if os.Getenv("E2E_KEEP") == "" {
		keep := func() bool { return t.Failed() && os.Getenv("E2E_KEEP_ON_FAILURE") != "" }
		t.Cleanup(func() {
			if !keep() {
				deleteTenant(t, beta, betaNS)
			}
		})
		t.Cleanup(func() {
			if !keep() {
				deleteTenant(t, alpha, alphaNS, toolsNS)
			}
		})
		t.Cleanup(func() {
			if !keep() {
				deleteTenant(t, docsTenant, docsNS)
				deleteUINamespace(t)
			}
		})
		t.Cleanup(func() {
			if keep() {
				t.Log("the run failed and E2E_KEEP_ON_FAILURE is set: leaving the install and fixtures for diagnostics")
				return
			}
			uninstall(t)
		})
	}

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
		for sa, tier := range map[string]string{"admin": "admin", "auditor": "audit-read", "temp": "editor", "lower": "editor"} {
			createServiceAccount(t, alphaNS, sa, map[string]string{annPrefix + "kv": "true", annPrefix + "tier": tier})
		}
		// An editor: a read-only subscription must hold even for a tier that can
		// write its own prefixes — with viewer the refusals could not fail.
		createServiceAccount(t, toolsNS, "sub", map[string]string{
			annPrefix + "kv":              "true",
			annPrefix + "tier":            "editor",
			annPrefix + "kv-subscribe-ns": alphaNS,
		})
		createServiceAccount(t, toolsNS, "nosub", map[string]string{
			annPrefix + "kv":   "true",
			annPrefix + "tier": "editor",
		})
		// Named like web, in another namespace, with no annotation: a role binds
		// a ServiceAccount name AND a namespace, and the login refusals below
		// change one of the two at a time.
		createServiceAccount(t, toolsNS, "web", nil)
		createServiceAccount(t, betaNS, "reader", map[string]string{
			annPrefix + "kv":               "true",
			annPrefix + "tier":             "viewer",
			annPrefix + "kv-import-tenant": alpha,
		})
		copyOIDCClientSecret(t)
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
			roleName(alpha, alphaNS, "admin"), roleName(alpha, alphaNS, "auditor"), roleName(alpha, alphaNS, "temp"),
			roleName(alpha, alphaNS, "lower"),
			roleName(alpha, toolsNS, "sub"), roleName(alpha, toolsNS, "nosub"), roleName(beta, betaNS, "reader")} {
			waitVCO(t, "policies", r)
			waitVCO(t, "kubernetesauthengineroles", r)
		}
		// VCO deletes an object in Vault only through its finalizer, which it
		// adds after the first successful reconcile. A CR without it is deleted
		// at once and nothing happens in Vault. VCO's own update refused every
		// mount this way until the charts set config.listingVisibility.
		deletable := map[string]string{"namespaces": "Namespace", "secretenginemounts": "SecretEngineMount",
			"authenginemounts": "AuthEngineMount", "policies": "Policy",
			"kubernetesauthengineroles": "KubernetesAuthEngineRole", "jwtoidcauthengineroles": "JWTOIDCAuthEngineRole"}
		waitFor(t, "VCO's finalizer on every CR it deletes", func() string {
			var missing []string
			seen := 0
			for res, kind := range deletable {
				l, err := dyn.Resource(vcoGVR(res)).Namespace(configNS).List(ctx, metav1.ListOptions{})
				if err != nil {
					return err.Error()
				}
				for _, o := range l.Items {
					if tn := o.GetLabels()[tenantLabel]; tn != alpha && tn != beta && !strings.HasPrefix(o.GetName(), sharedNS) {
						continue
					}
					seen++
					if !slices.Contains(o.GetFinalizers(), "controller-"+strings.ToLower(kind)) {
						missing = append(missing, res+"/"+o.GetName())
					}
				}
			}
			slices.Sort(missing)
			switch {
			case seen == 0:
				return "no CR of the e2e tenants found"
			case len(missing) > 0:
				return "no VCO finalizer on " + strings.Join(missing, ", ")
			}
			return ""
		})
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
		//
		// The hold proves something only while VCO really reconciles in the
		// window: with drift off, or at another period, it passes on nothing.
		venv := deploymentEnv(t, vcoNS, vcoDeploy)
		if want := strconv.Itoa(int(vcoSync.Seconds())); venv["ENABLE_DRIFT_DETECTION"] != "true" || venv["SYNC_PERIOD_SECONDS"] != want {
			t.Fatalf("VCO drift is not on at the period this step waits for: ENABLE_DRIFT_DETECTION=%q SYNC_PERIOD_SECONDS=%q, want \"true\" and %q",
				venv["ENABLE_DRIFT_DETECTION"], venv["SYNC_PERIOD_SECONDS"], want)
		}
		// VCO never clears ReconcileFailed, so a failure from before the window
		// (a login race just after install) stays on the object. Only a NEW
		// message fails the hold — except "already exists", the failure this
		// step is for, which fails it whenever it happened.
		before := map[string]string{}
		for _, tn := range []string{alpha, beta} {
			o := get(t, vcoGVR("namespaces"), configNS, tn)
			if o == nil {
				t.Fatalf("Namespace %s absent", tn)
			}
			_, msg := condition(o, "ReconcileFailed")
			if strings.Contains(msg, "already exists") {
				t.Fatalf("Namespace %s failed a reconcile with %q: %s", tn, "already exists", msg)
			}
			if msg != "" {
				t.Logf("Namespace %s carries an earlier failure, ignored unless it changes: %s", tn, msg)
			}
			before[tn] = msg
		}
		holdFor(t, 2*vcoSync+15*time.Second, "tenant Namespace CRs across two drift reconciles", func() string {
			for _, tn := range []string{alpha, beta} {
				o := get(t, vcoGVR("namespaces"), configNS, tn)
				if o == nil {
					return "Namespace " + tn + " absent"
				}
				if _, msg := condition(o, "ReconcileFailed"); msg != before[tn] {
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
		// The token the role hands out: a service token (revocable), with the
		// chart's default ttl of 3600 s at most.
		out, err := vaultRun(t, webToken, alpha, "token", "lookup", "-format=json")
		if err != nil {
			t.Fatalf("look up the workload token: %v", err)
		}
		var tok struct {
			Data struct {
				Type string `json:"type"`
				TTL  int    `json:"ttl"`
			} `json:"data"`
		}
		if err := json.Unmarshal([]byte(out), &tok); err != nil || tok.Data.Type != "service" || tok.Data.TTL <= 0 || tok.Data.TTL > 3600 {
			t.Errorf("workload token: type %q, ttl %d s (err %v); want a service token with 0 < ttl <= 3600", tok.Data.Type, tok.Data.TTL, err)
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
		// The beta role works for its own ServiceAccount, and refuses alpha's.
		if _, pols, err := vaultTryLogin(t, beta, roleName(beta, betaNS, "reader"), saToken(t, betaNS, "reader")); err != nil || !slices.Contains(pols, roleName(beta, betaNS, "reader")) {
			t.Fatalf("e2e-beta's own ServiceAccount could not log in to its role: policies %v, err %v", pols, err)
		}
		if _, _, err := vaultTryLogin(t, beta, roleName(beta, betaNS, "reader"), saToken(t, alphaNS, "web")); !refused(err) {
			t.Errorf("e2e-alpha's ServiceAccount was not refused by an e2e-beta role; err: %v", err)
		}
		// The refusal above changes both the name and the namespace, so it fails
		// only if BOTH bindings are dropped. These change one each; web's own
		// login to the same role is the matching allow.
		webRole := roleName(alpha, alphaNS, "web")
		if _, _, err := vaultTryLogin(t, alpha, webRole, saToken(t, alphaNS, "viewer")); !refused(err) {
			t.Errorf("another ServiceAccount in web's namespace was not refused by web's role; err: %v", err)
		}
		if _, _, err := vaultTryLogin(t, alpha, webRole, saToken(t, toolsNS, "web")); !refused(err) {
			t.Errorf("a ServiceAccount named web in another namespace was not refused by web's role; err: %v", err)
		}

		viewerToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "viewer"), saToken(t, alphaNS, "viewer"))
		if got, err := kvGet(t, viewerToken, alpha, appPath(alphaNS, "viewer", "cfg"), "mode"); err != nil || got != "ro" {
			t.Errorf("viewer could not read its own secret: got %q, err %v", got, err)
		}
		if err := kvPut(t, viewerToken, alpha, appPath(alphaNS, "viewer", "cfg"), "mode=rw"); !refused(err) {
			t.Errorf("viewer tier wrote a secret; err: %v", err)
		}
	})

	step("kv: versions, patch and deletes follow the tier", func(t *testing.T) {
		// KV v2 keeps every version of a secret. What each tier may do with them:
		//   editor  write, read an old version, patch; no soft delete
		//   viewer  read; no patch
		//   admin   soft delete, then undelete
		p := appPath(alphaNS, "web", "versions")
		for _, v := range []string{"v=1", "v=2"} {
			if err := kvPut(t, webToken, alpha, p, v); err != nil {
				t.Fatalf("editor could not write %s: %v", v, err)
			}
		}
		if got, err := vaultRun(t, webToken, alpha, "kv", "get", "-mount=kv", "-version=1", "-field=v", p); err != nil || strings.TrimSpace(got) != "1" {
			t.Errorf("editor could not read version 1: got %q, err %v", got, err)
		}
		// patch changes one field and keeps the others, in one request.
		if _, err := vaultRun(t, webToken, alpha, "kv", "patch", "-mount=kv", p, "extra=x"); err != nil {
			t.Fatalf("editor could not patch its own secret: %v", err)
		}
		if got, err := kvGet(t, webToken, alpha, p, "v"); err != nil || got != "2" {
			t.Errorf("patch lost a field: v=%q, err %v", got, err)
		}
		// A soft delete needs the delete capability, which only admin has. The
		// admin's own delete below is the matching allow for the same call.
		if _, err := vaultRun(t, webToken, alpha, "kv", "delete", "-mount=kv", p); !refused(err) {
			t.Errorf("editor soft-deleted a secret; err: %v", err)
		}
		viewerToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "viewer"), saToken(t, alphaNS, "viewer"))
		if _, err := vaultRun(t, viewerToken, alpha, "kv", "patch", "-mount=kv", appPath(alphaNS, "viewer", "cfg"), "mode=patched"); !refused(err) {
			t.Errorf("viewer patched a secret; err: %v", err)
		}

		adminToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "admin"), saToken(t, alphaNS, "admin"))
		ap := appPath(alphaNS, "admin", "soft")
		if err := kvPut(t, adminToken, alpha, ap, "v=1"); err != nil {
			t.Fatalf("admin could not write: %v", err)
		}
		if _, err := vaultRun(t, adminToken, alpha, "kv", "delete", "-mount=kv", ap); err != nil {
			t.Fatalf("admin could not soft-delete its own secret: %v", err)
		}
		if got, err := kvGet(t, adminToken, alpha, ap, "v"); err == nil && got == "1" {
			t.Errorf("a soft-deleted secret still reads %q", got)
		}
		if _, err := vaultRun(t, adminToken, alpha, "kv", "undelete", "-mount=kv", "-versions=1", ap); err != nil {
			t.Fatalf("admin could not undelete: %v", err)
		}
		if got, err := kvGet(t, adminToken, alpha, ap, "v"); err != nil || got != "1" {
			t.Errorf("the undeleted secret reads %q, err %v; want 1", got, err)
		}
	})

	step("kv: an app sees only its own prefix, not the other apps of its namespace", func(t *testing.T) {
		// viewer/cfg exists (seeded as root above), so a refusal is about the caller.
		out, err := vaultRun(t, webToken, alpha, "kv", "list", "-mount=kv", "-format=json", env+"/"+alphaNS+"/web/")
		if err != nil || !strings.Contains(out, "db") {
			t.Fatalf("web could not list its own prefix: %q, err %v", out, err)
		}
		// Listing the namespace level would name every other app in it.
		if _, err := vaultRun(t, webToken, alpha, "kv", "list", "-mount=kv", env+"/"+alphaNS+"/"); !refused(err) {
			t.Errorf("web listed the apps of its namespace; err: %v", err)
		}
		if _, err := vaultRun(t, webToken, alpha, "kv", "metadata", "get", "-mount=kv", appPath(alphaNS, "viewer", "cfg")); !refused(err) {
			t.Errorf("web read another app's secret metadata; err: %v", err)
		}
	})

	step("vco: an out-of-band change in Vault is reverted", func(t *testing.T) {
		// Root plays an out-of-band admin who widens the viewer's policy in Vault.
		// It asserts nothing; every check runs as the viewer.
		role := roleName(alpha, alphaNS, "viewer")
		p := appPath(alphaNS, "viewer", "cfg")
		widened := policyRules(t, alpha, role) + "\npath \"kv/data/" + env + "/" + alphaNS + "/viewer/*\" { capabilities = [\"create\", \"update\"] }\n"
		vaultIn(t, alpha, "write", "sys/policy/"+role, "policy="+widened)
		viewerToken, _ := vaultLogin(t, alpha, role, saToken(t, alphaNS, "viewer"))
		// The change took effect: without it, the revert below would prove nothing.
		if err := kvPut(t, viewerToken, alpha, p, "mode=tampered"); err != nil {
			t.Fatalf("the widened policy did not take effect: %v", err)
		}
		// VCO's drift detection rewrites the policy from its CR within a sync period.
		waitFor(t, "VCO reverts the widened policy", func() string {
			err := kvPut(t, viewerToken, alpha, p, "mode=still-writable")
			switch {
			case err == nil:
				return "the viewer can still write"
			case !refused(err):
				return err.Error()
			}
			return ""
		})
		vaultIn(t, alpha, "kv", "put", "-mount=kv", p, "mode=ro")
	})

	step("vco: a resource cannot move to another Vault namespace", func(t *testing.T) {
		// VCO's webhook refuses to change a CR's Vault namespace: the object would
		// stay behind in the old one. Checked on the viewer's Policy CR.
		name := roleName(alpha, alphaNS, "viewer")
		move := []byte(`{"spec":{"authentication":{"targetNamespace":"` + beta + `"}}}`)
		_, err := dyn.Resource(vcoGVR("policies")).Namespace(configNS).Patch(ctx, name, types.MergePatchType, move, metav1.PatchOptions{})
		if err == nil || !strings.Contains(err.Error(), "cannot be updated to a different Vault namespace") {
			t.Errorf("moving a Policy to another Vault namespace was not refused by VCO's webhook: %v", err)
		}
		// The matching allow: an update that keeps the Vault namespace passes the
		// same webhook.
		keep := []byte(`{"metadata":{"annotations":{"e2e.stakater.com/touched":"true"}}}`)
		if _, err := dyn.Resource(vcoGVR("policies")).Namespace(configNS).Patch(ctx, name, types.MergePatchType, keep, metav1.PatchOptions{}); err != nil {
			t.Errorf("an update that keeps the Vault namespace was refused: %v", err)
		}
	})

	step("tiers: admin can destroy versions, audit-read can only list", func(t *testing.T) {
		adminToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "admin"), saToken(t, alphaNS, "admin"))
		p := appPath(alphaNS, "admin", "key")
		if err := kvPut(t, adminToken, alpha, p, "v=1"); err != nil {
			t.Fatalf("admin could not write: %v", err)
		}
		if _, err := vaultRun(t, adminToken, alpha, "kv", "destroy", "-mount=kv", "-versions=1", p); err != nil {
			t.Errorf("admin could not destroy a version of its own secret: %v", err)
		}
		// An editor cannot destroy history.
		if _, err := vaultRun(t, webToken, alpha, "kv", "destroy", "-mount=kv", "-versions=1", appPath(alphaNS, "web", "db")); !refused(err) {
			t.Errorf("editor destroyed a secret version; err: %v", err)
		}

		vaultIn(t, alpha, "kv", "put", "-mount=kv", appPath(alphaNS, "auditor", "item"), "v=1")
		auditToken, _ := vaultLogin(t, alpha, roleName(alpha, alphaNS, "auditor"), saToken(t, alphaNS, "auditor"))
		out, err := vaultRun(t, auditToken, alpha, "kv", "list", "-mount=kv", "-format=json", env+"/"+alphaNS+"/auditor/")
		if err != nil || !strings.Contains(out, "item") {
			t.Errorf("audit-read could not list its own prefix: %q, err %v", out, err)
		}
		if _, err := kvGet(t, auditToken, alpha, appPath(alphaNS, "auditor", "item"), "v"); !refused(err) {
			t.Errorf("audit-read read secret data; err: %v", err)
		}
	})

	step("sso: Keycloak users log in through Dex with their group's tier", func(t *testing.T) {
		// Keycloak holds the users and groups, Dex fronts it through Keycloak's
		// "dex" client, and each tenant's oidc/sso roles bind one group each
		// (<tenant>-<tier>s). The test users (make lab-keycloak):
		//   alice e2e-alpha-editors   bob e2e-alpha-viewers   carol e2e-beta-admins
		for _, tn := range []string{alpha, beta} {
			waitVCO(t, "jwtoidcauthengineconfigs", tn+"-oidc-config")
			for _, tier := range []string{"admin", "editor", "viewer"} {
				waitVCO(t, "jwtoidcauthengineroles", ssoRole(tn, tier))
			}
		}
		c := newSSOClient(t)
		note := env + "/sso/note"

		// The group gives the tier: alice's editor login writes.
		aliceToken, pols, err := oidcLogin(t, c, alpha, ssoRole(alpha, "editor"), "alice", testUserPassword(t, "alice"))
		if err != nil || !slices.Contains(pols, ssoRole(alpha, "editor")) {
			t.Fatalf("alice (e2e-alpha-editors) could not log in as editor: policies %v, err %v", pols, err)
		}
		if err := kvPut(t, aliceToken, alpha, note, "by=alice"); err != nil {
			t.Fatalf("the SSO editor could not write in its tenant: %v", err)
		}
		// bob's viewer login reads what alice wrote, and cannot write it:
		// alice's write above, same path, is the matching allow.
		bobToken, _, err := oidcLogin(t, c, alpha, ssoRole(alpha, "viewer"), "bob", testUserPassword(t, "bob"))
		if err != nil {
			t.Fatalf("bob (e2e-alpha-viewers) could not log in as viewer: %v", err)
		}
		if got, err := kvGet(t, bobToken, alpha, note, "by"); err != nil || got != "alice" {
			t.Errorf("the SSO viewer could not read in its tenant: got %q, err %v", got, err)
		}
		if err := kvPut(t, bobToken, alpha, note, "by=bob"); !refused(err) {
			t.Errorf("the SSO viewer wrote a secret; err: %v", err)
		}
		// A group gives only its own tier: bob cannot take the editor role.
		if _, _, err := oidcLogin(t, c, alpha, ssoRole(alpha, "editor"), "bob", testUserPassword(t, "bob")); !claimRefused(err) {
			t.Errorf("bob (e2e-alpha-viewers) was not refused the editor role for the group; err: %v", err)
		}

		// Tenants: carol (e2e-beta-admins) logs in to e2e-beta, and alice cannot.
		carolToken, _, err := oidcLogin(t, c, beta, ssoRole(beta, "admin"), "carol", testUserPassword(t, "carol"))
		if err != nil {
			t.Fatalf("carol (e2e-beta-admins) could not log in to e2e-beta: %v", err)
		}
		if _, _, err := oidcLogin(t, c, beta, ssoRole(beta, "editor"), "alice", testUserPassword(t, "alice")); !claimRefused(err) {
			t.Errorf("alice (e2e-alpha-editors) was not refused an e2e-beta role for the group; err: %v", err)
		}
		// And alice's e2e-alpha token does not reach e2e-beta's data, which carol reads.
		if err := kvPut(t, carolToken, beta, note, "by=carol"); err != nil {
			t.Fatalf("the SSO admin could not write in its tenant: %v", err)
		}
		if _, err := kvGet(t, aliceToken, beta, note, "by"); !refused(err) {
			t.Errorf("an e2e-alpha SSO token read e2e-beta's secret; err: %v", err)
		}
	})

	step("sso: audit-read lists and reads nothing, only admin destroys history", func(t *testing.T) {
		// dave (e2e-alpha-audit-reads) and erin (e2e-alpha-admins), on the note
		// alice wrote in the step above.
		c := newSSOClient(t)
		note := env + "/sso/note"
		daveToken, pols, err := oidcLogin(t, c, alpha, ssoRole(alpha, "audit-read"), "dave", testUserPassword(t, "dave"))
		if err != nil || !slices.Contains(pols, ssoRole(alpha, "audit-read")) {
			t.Fatalf("dave (e2e-alpha-audit-reads) could not log in as audit-read: policies %v, err %v", pols, err)
		}
		out, err := vaultRun(t, daveToken, alpha, "kv", "list", "-mount=kv", "-format=json", env+"/sso/")
		if err != nil || !strings.Contains(out, "note") {
			t.Errorf("audit-read could not list the tenant's secrets: %q, err %v", out, err)
		}
		erinToken, _, err := oidcLogin(t, c, alpha, ssoRole(alpha, "admin"), "erin", testUserPassword(t, "erin"))
		if err != nil {
			t.Fatalf("erin (e2e-alpha-admins) could not log in as admin: %v", err)
		}
		// erin's read is the matching allow for dave's refusal.
		if got, err := kvGet(t, erinToken, alpha, note, "by"); err != nil || got != "alice" {
			t.Fatalf("the SSO admin could not read the note: got %q, err %v", got, err)
		}
		if _, err := kvGet(t, daveToken, alpha, note, "by"); !refused(err) {
			t.Errorf("audit-read read secret data; err: %v", err)
		}
		// Destroying a version: the editor is refused, then the admin does it.
		aliceToken, _, err := oidcLogin(t, c, alpha, ssoRole(alpha, "editor"), "alice", testUserPassword(t, "alice"))
		if err != nil {
			t.Fatalf("alice could not log in again: %v", err)
		}
		if _, err := vaultRun(t, aliceToken, alpha, "kv", "destroy", "-mount=kv", "-versions=1", note); !refused(err) {
			t.Errorf("the SSO editor destroyed a version; err: %v", err)
		}
		if _, err := vaultRun(t, erinToken, alpha, "kv", "destroy", "-mount=kv", "-versions=1", note); err != nil {
			t.Errorf("the SSO admin could not destroy a version: %v", err)
		}
	})

	step("ui: the Vault UI shows each SSO tier its own view (browser-runner)", func(t *testing.T) {
		runUISteps(t)
	})

	step("configmap: vault-config-<sa> describes a working login", func(t *testing.T) {
		cm := configMapData(t, alphaNS, "vault-config-web")
		if cm == nil {
			t.Fatal("ConfigMap vault-config-web is missing")
		}
		want := map[string]string{
			"VAULT_ADDR":        vaultServer,
			"VAULT_NAMESPACE":   alpha,
			"VAULT_K8S_MOUNT":   k8sAuthMount,
			"VAULT_K8S_ROLE":    roleName(alpha, alphaNS, "web"),
			"VAULT_KV_APP_PATH": "kv/data/" + env + "/" + alphaNS + "/web/",
		}
		for k, v := range want {
			if cm[k] != v {
				t.Errorf("%s = %q, want %q", k, cm[k], v)
			}
		}
		// The values themselves must work: log in with exactly what the
		// ConfigMap says, and read the app's secret at the path it names.
		token, _, err := vaultTryLoginAt(t, cm["VAULT_NAMESPACE"], cm["VAULT_K8S_MOUNT"], cm["VAULT_K8S_ROLE"], saToken(t, alphaNS, "web"))
		if err != nil {
			t.Fatalf("login with the ConfigMap's values failed: %v", err)
		}
		leaf := strings.TrimPrefix(cm["VAULT_KV_APP_PATH"], "kv/data/") + "db"
		if got, err := kvGet(t, token, cm["VAULT_NAMESPACE"], leaf, "password"); err != nil || got == "" {
			t.Errorf("read at the ConfigMap's path %s: got %q, err %v", leaf, got, err)
		}
		if idx := configMapData(t, alphaNS, "vault-apps"); !strings.Contains(idx["web"], want["VAULT_KV_APP_PATH"]) {
			t.Errorf("vault-apps index has no entry for web with its path: %q", idx["web"])
		}
	})

	step("template-operator: a deleted ConfigMap comes back", func(t *testing.T) {
		// sync.mode=revert (the bootstrap default): template-operator-v2 puts back
		// what it rendered. Deleting the workload's environment is that kind of drift.
		before := configMapData(t, alphaNS, "vault-config-web")
		if before == nil {
			t.Fatal("ConfigMap vault-config-web is missing")
		}
		if err := kube.CoreV1().ConfigMaps(alphaNS).Delete(ctx, "vault-config-web", metav1.DeleteOptions{}); err != nil {
			t.Fatalf("delete ConfigMap vault-config-web: %v", err)
		}
		waitFor(t, "template-operator-v2 restores vault-config-web", func() string {
			got := configMapData(t, alphaNS, "vault-config-web")
			if got == nil {
				return "absent"
			}
			if got["VAULT_K8S_ROLE"] != before["VAULT_K8S_ROLE"] || got["VAULT_KV_APP_PATH"] != before["VAULT_KV_APP_PATH"] {
				return fmt.Sprintf("restored with other values: %v", got)
			}
			return ""
		})
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
			if v, err := podEnv(t, alphaNS, p, "PASSWORD"); err != nil {
				return err.Error()
			} else if v != "v1" {
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
			if v, err := podEnv(t, alphaNS, p, "PASSWORD"); err != nil {
				return err.Error()
			} else if v != "v2" {
				return "new pod " + p + " has PASSWORD=" + v
			}
			return ""
		})
	})

	step("eso: a whole secret becomes one Kubernetes Secret", func(t *testing.T) {
		// kv-secret.<name>: <leaf> with no #key copies every key of the leaf.
		if err := kvPut(t, webToken, alpha, appPath(alphaNS, "web", "cfg"), "host=db.internal", "port=5432"); err != nil {
			t.Fatalf("editor could not write the leaf: %v", err)
		}
		createDeployment(t, alphaNS, "cfg-reader", "web", map[string]string{annPrefix + "kv-secret.cfg": "cfg"}, nil)
		waitFor(t, "Secret web-cfg holds every key of the leaf", func() string {
			host, port := secretValue(t, alphaNS, "web-cfg", "host"), secretValue(t, alphaNS, "web-cfg", "port")
			if host != "db.internal" || port != "5432" {
				return fmt.Sprintf("host=%q port=%q", host, port)
			}
			return ""
		})
		deleteDeployment(t, alphaNS, "cfg-reader")
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
		// path too: KV v2 metadata update sets max_versions, which destroys
		// versions. sub is an editor, and its tier grants that update on its own
		// prefixes, so the refusal fails if the subscription grant is widened to
		// the tier's caps. (A metadata DELETE could not fail: no editor has it.)
		// The producer's update on the same path shows the call itself works.
		if err := kvPut(t, subToken, alpha, sharedPath(alphaNS, "common"), "url=tampered"); !refused(err) {
			t.Errorf("subscriber wrote to the producer's _shared/; err: %v", err)
		}
		if err := kvMetadataPut(t, webToken, alpha, sharedPath(alphaNS, "common"), "-max-versions=5"); err != nil {
			t.Fatalf("the producer could not update its own _shared/ metadata: %v", err)
		}
		if err := kvMetadataPut(t, subToken, alpha, sharedPath(alphaNS, "common"), "-max-versions=1"); !refused(err) {
			t.Errorf("subscriber updated the producer's secret metadata; err: %v", err)
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
			if v, err := podEnv(t, toolsNS, p, "DB_URL"); err != nil {
				return err.Error()
			} else if v != "https://db.internal" {
				return "DB_URL=" + v
			}
			return ""
		})
	})

	step("kv: the app annotation names the prefix, and two ServiceAccounts cannot share it", func(t *testing.T) {
		// billing-sa declares app "billing": its prefix is billing/, not billing-sa/.
		createServiceAccount(t, alphaNS, "billing-sa", map[string]string{
			annPrefix + "kv": "true", annPrefix + "tier": "editor", annPrefix + "app": "billing",
		})
		role := roleName(alpha, alphaNS, "billing-sa")
		waitVCO(t, "policies", role)
		waitVCO(t, "kubernetesauthengineroles", role)
		token, _ := vaultLogin(t, alpha, role, saToken(t, alphaNS, "billing-sa"))
		if err := kvPut(t, token, alpha, appPath(alphaNS, "billing", "k"), "v=1"); err != nil {
			t.Fatalf("billing-sa could not write under its app's prefix: %v", err)
		}
		// Seeded as root, so the refusal is about the caller.
		vaultIn(t, alpha, "kv", "put", "-mount=kv", appPath(alphaNS, "billing-sa", "k"), "v=root")
		if _, err := kvGet(t, token, alpha, appPath(alphaNS, "billing-sa", "k"), "v"); !refused(err) {
			t.Errorf("billing-sa read the prefix of its ServiceAccount name, not of its app; err: %v", err)
		}

		// thief claims app "billing" in the same namespace. Each app owns one
		// prefix, so the chart refuses BOTH until one gives the name up.
		createServiceAccount(t, alphaNS, "thief", map[string]string{
			annPrefix + "kv": "true", annPrefix + "tier": "viewer", annPrefix + "app": "billing",
		})
		for _, sa := range []string{"billing-sa", "thief"} {
			waitFor(t, "an error ConfigMap for "+sa, func() string {
				cm := configMapData(t, alphaNS, "vault-config-"+sa+".error")
				if cm == nil {
					return "absent"
				}
				if !strings.Contains(cm["ERROR"], "claimed by more than one ServiceAccount") {
					return "it says: " + cm["ERROR"]
				}
				return ""
			})
		}
		for _, k := range []string{"policies", "kubernetesauthengineroles"} {
			waitFor(t, "billing-sa's "+k+" CR is removed while the name is claimed twice", func() string {
				if get(t, vcoGVR(k), configNS, role) != nil {
					return "still present"
				}
				return ""
			})
		}
		if _, _, err := vaultTryLogin(t, alpha, roleName(alpha, alphaNS, "thief"), saToken(t, alphaNS, "thief")); err == nil || !strings.Contains(err.Error(), "invalid role name") {
			t.Errorf("thief logged in, or failed for another reason: %v", err)
		}
		// thief goes: billing-sa's access returns, and its secret stayed.
		deleteServiceAccount(t, alphaNS, "thief")
		// Both come back, in no fixed order: a token from a role whose policy is
		// not written yet is refused everything.
		waitVCO(t, "policies", role)
		waitVCO(t, "kubernetesauthengineroles", role)
		token, _ = vaultLogin(t, alpha, role, saToken(t, alphaNS, "billing-sa"))
		if got, err := kvGet(t, token, alpha, appPath(alphaNS, "billing", "k"), "v"); err != nil || got != "1" {
			t.Errorf("billing-sa's secret after the claim resolved: got %q, err %v", got, err)
		}
	})

	step("kv: one app name in two namespaces is two apps", func(t *testing.T) {
		for _, ns := range []string{alphaNS, toolsNS} {
			createServiceAccount(t, ns, "api", map[string]string{annPrefix + "kv": "true", annPrefix + "tier": "editor"})
		}
		tokens := map[string]string{}
		for _, ns := range []string{alphaNS, toolsNS} {
			role := roleName(alpha, ns, "api")
			waitVCO(t, "policies", role)
			waitVCO(t, "kubernetesauthengineroles", role)
			tokens[ns], _ = vaultLogin(t, alpha, role, saToken(t, ns, "api"))
			if err := kvPut(t, tokens[ns], alpha, appPath(ns, "api", "k"), "ns="+ns); err != nil {
				t.Fatalf("api in %s could not write its own secret: %v", ns, err)
			}
		}
		// Each reads its own, and not the other's: that one exists, written just above.
		for _, pair := range [][2]string{{alphaNS, toolsNS}, {toolsNS, alphaNS}} {
			own, other := pair[0], pair[1]
			if got, err := kvGet(t, tokens[own], alpha, appPath(own, "api", "k"), "ns"); err != nil || got != own {
				t.Errorf("api in %s read its own secret: got %q, err %v", own, got, err)
			}
			if _, err := kvGet(t, tokens[own], alpha, appPath(other, "api", "k"), "ns"); !refused(err) {
				t.Errorf("api in %s read api's secret in %s; err: %v", own, other, err)
			}
		}
	})

	step("guards: a misconfigured ServiceAccount gets an error ConfigMap and no login", func(t *testing.T) {
		cases := []struct {
			sa  string
			ann map[string]string
			msg string
		}{
			{"g-no-tier", map[string]string{annPrefix + "kv": "true"}, "tier is not set"},
			{"g-bad-tier", map[string]string{annPrefix + "kv": "true", annPrefix + "tier": "superuser"}, "is not a known tier"},
			{"g-kv-yes", map[string]string{annPrefix + "kv": "yes", annPrefix + "tier": "viewer"}, `must be "true" or "false"`},
			{"g-typo", map[string]string{annPrefix + "kvv": "true"}, "unknown annotation"},
			{"g-transit", map[string]string{annPrefix + "transit": "true"}, "is not supported"},
		}
		for _, c := range cases {
			createServiceAccount(t, toolsNS, c.sa, c.ann)
		}
		// The default ServiceAccount is refused too: every pod that names no
		// ServiceAccount runs as it. Its annotations are put back afterwards.
		orig := serviceAccountAnnotations(t, toolsNS, "default")
		t.Cleanup(func() { setServiceAccountAnnotations(t, toolsNS, "default", orig) })
		withKV := map[string]string{annPrefix + "kv": "true", annPrefix + "tier": "viewer"}
		for k, v := range orig {
			withKV[k] = v
		}
		setServiceAccountAnnotations(t, toolsNS, "default", withKV)
		cases = append(cases, struct {
			sa  string
			ann map[string]string
			msg string
		}{"default", nil, "the `default` ServiceAccount cannot be granted Vault access"})

		for _, c := range cases {
			waitFor(t, "an error ConfigMap for "+c.sa, func() string {
				cm := configMapData(t, toolsNS, "vault-config-"+c.sa+".error")
				if cm == nil {
					return "absent"
				}
				if !strings.Contains(cm["ERROR"], c.msg) {
					return "it says: " + cm["ERROR"]
				}
				return ""
			})
			if get(t, vcoGVR("kubernetesauthengineroles"), configNS, roleName(alpha, toolsNS, c.sa)) != nil {
				t.Errorf("%s got a login role despite its error", c.sa)
			}
			if _, _, err := vaultTryLogin(t, alpha, roleName(alpha, toolsNS, c.sa), saToken(t, toolsNS, c.sa)); err == nil || !strings.Contains(err.Error(), "invalid role name") {
				t.Errorf("%s logged in, or failed for another reason: %v", c.sa, err)
			}
		}
		// One ServiceAccount's error does not stop the others: sub still works.
		vaultLogin(t, alpha, roleName(alpha, toolsNS, "sub"), saToken(t, toolsNS, "sub"))
		for _, c := range cases[:len(cases)-1] {
			deleteServiceAccount(t, toolsNS, c.sa)
		}
	})

	step("guards: a Deployment asking for an ungranted secret gets a deploy-error", func(t *testing.T) {
		// nosub reads no other namespace's _shared/, so a Deployment running as it
		// cannot be given one: it gets a deploy-error ConfigMap, and no
		// ExternalSecret that would fail to sync for ever.
		createDeployment(t, toolsNS, "g-deploy", "nosub", map[string]string{
			annPrefix + "kv-subscribe.common": alphaNS + "/common#url",
		}, nil)
		waitFor(t, "a deploy-error ConfigMap for g-deploy", func() string {
			cm := configMapData(t, toolsNS, "vault-config-g-deploy.deploy-error")
			if cm == nil {
				return "absent"
			}
			if !strings.Contains(cm["ERROR"], "does not list it in") {
				return "it says: " + cm["ERROR"]
			}
			return ""
		})
		if get(t, gvrExternalSecret, toolsNS, "nosub-common") != nil {
			t.Errorf("an ExternalSecret was rendered for a secret the ServiceAccount does not grant")
		}
		deleteDeployment(t, toolsNS, "g-deploy")
	})

	step("tier change: lowering editor to viewer takes write away", func(t *testing.T) {
		role := roleName(alpha, alphaNS, "lower")
		leaf := appPath(alphaNS, "lower", "k")
		// The write before the change is the matching allow for the refusals
		// after it: same token, same path.
		lowerToken, _ := vaultLogin(t, alpha, role, saToken(t, alphaNS, "lower"))
		if err := kvPut(t, lowerToken, alpha, leaf, "v=1"); err != nil {
			t.Fatalf("editor could not write its own secret before the tier change: %v", err)
		}
		setServiceAccountAnnotations(t, alphaNS, "lower", map[string]string{annPrefix + "kv": "true", annPrefix + "tier": "viewer"})
		// The tier is not part of the policy name, so VCO rewrites the same
		// policy in place. Inspected as root: wait for the viewer version.
		waitFor(t, "Vault holds the viewer policy for lower", func() string {
			out, err := vaultRun(t, vaultRootToken, alpha, "policy", "read", role)
			if err != nil {
				return err.Error()
			}
			if strings.Contains(out, `"create"`) {
				return "the policy still grants create"
			}
			return ""
		})
		// Vault resolves a token's policies by name on every request, so the
		// token issued at editor follows the new tier at once.
		if err := kvPut(t, lowerToken, alpha, leaf, "v=2"); !refused(err) {
			t.Errorf("a token issued at editor still wrote after the tier was lowered; err: %v", err)
		}
		if got, err := kvGet(t, lowerToken, alpha, leaf, "v"); err != nil || got != "1" {
			t.Errorf("viewer could not read its own secret after the tier change: got %q, err %v", got, err)
		}
		newToken, _ := vaultLogin(t, alpha, role, saToken(t, alphaNS, "lower"))
		if err := kvPut(t, newToken, alpha, leaf, "v=3"); !refused(err) {
			t.Errorf("a new login after the tier change wrote a secret; err: %v", err)
		}
	})

	step("removal: dropping the annotation revokes the access", func(t *testing.T) {
		role := roleName(alpha, alphaNS, "temp")
		// A token issued BEFORE the removal, and a write with it: the matching
		// allow for the refusal after it.
		tempToken, _ := vaultLogin(t, alpha, role, saToken(t, alphaNS, "temp"))
		leaf := appPath(alphaNS, "temp", "k")
		if err := kvPut(t, tempToken, alpha, leaf, "v=1"); err != nil {
			t.Fatalf("temp could not write its own secret before removal: %v", err)
		}
		setServiceAccountAnnotations(t, alphaNS, "temp", nil)
		for _, k := range []string{"policies", "kubernetesauthengineroles"} {
			waitFor(t, k+"/"+role+" gone", func() string {
				if get(t, vcoGVR(k), configNS, role) != nil {
					return "still present"
				}
				return ""
			})
		}
		waitFor(t, "the Vault role and policy are deleted", func() string {
			if msg := vaultGone(t, alpha, "read", "auth/"+k8sAuthMount+"/role/"+role); msg != "" {
				return "role: " + msg
			}
			if msg := vaultGone(t, alpha, "policy", "read", role); msg != "" {
				return "policy: " + msg
			}
			return ""
		})
		// Vault resolves a token's policies by name on every request, so the
		// token issued before the removal loses its access with the policy.
		if _, err := kvGet(t, tempToken, alpha, leaf, "v"); !refused(err) {
			t.Errorf("a token issued before the removal still read temp's secret; err: %v", err)
		}
		// A new login fails because the role is gone, not for another reason.
		if _, _, err := vaultTryLogin(t, alpha, role, saToken(t, alphaNS, "temp")); err == nil || !strings.Contains(err.Error(), "invalid role name") {
			t.Errorf("login after removal: want Vault's \"invalid role name\", got %v", err)
		}
		if configMapData(t, alphaNS, "vault-config-temp") != nil {
			t.Errorf("ConfigMap vault-config-temp survived the removal")
		}
	})

	step("share: e2e-alpha exports, e2e-beta imports through ESO", func(t *testing.T) {
		outRole := "share." + alpha + "." + alphaNS + ".web.out." + beta
		inRole := "share." + beta + "." + betaNS + ".reader.in." + alpha
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
		// A share role binds one tenant's ServiceAccount: the other tenant's
		// ServiceAccount is refused by it, in both directions.
		if _, _, err := vaultTryLogin(t, sharedNS, outRole, saToken(t, betaNS, "reader")); !refused(err) {
			t.Errorf("e2e-beta's ServiceAccount was not refused by e2e-alpha's share-out role; err: %v", err)
		}
		if _, _, err := vaultTryLogin(t, sharedNS, inRole, saToken(t, alphaNS, "web")); !refused(err) {
			t.Errorf("e2e-alpha's ServiceAccount was not refused by e2e-beta's share-in role; err: %v", err)
		}
		// One binding changed at a time, as for the own-tenant role: the same
		// tenant's other ServiceAccount (no export annotation), and a
		// ServiceAccount named web in another namespace.
		if _, _, err := vaultTryLogin(t, sharedNS, outRole, saToken(t, alphaNS, "viewer")); !refused(err) {
			t.Errorf("a ServiceAccount without kv-export-tenant was not refused by web's share-out role; err: %v", err)
		}
		if _, _, err := vaultTryLogin(t, sharedNS, outRole, saToken(t, toolsNS, "web")); !refused(err) {
			t.Errorf("a ServiceAccount named web in another namespace was not refused by web's share-out role; err: %v", err)
		}
		// The reverse direction was never granted. Seeded as root, so the
		// refusal is about the caller, not a path with nothing at it.
		reversePath := env + "/from-" + beta + "/to-" + alpha + "/x"
		vaultIn(t, sharedNS, "kv", "put", "-mount=kv", reversePath, "token=r1")
		if _, err := kvGet(t, outToken, sharedNS, reversePath, "token"); !refused(err) {
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

	step("lifetime: a tenant keeps its Vault data without a labelled namespace", func(t *testing.T) {
		// The workload render exists only while a tenant has a labelled
		// namespace; the tenant's Vault namespace and kv mount are the parent's,
		// so they must outlive it. Deleting e2e-beta's last namespace must remove
		// its child TemplateInstances and nothing that holds data.
		readerRole := roleName(beta, betaNS, "reader")
		// What the workload render wrote: the grants, not the data.
		grants := []struct{ kind, name string }{
			{"authenginemounts", beta + "-kubernetes"},
			{"kubernetesauthengineconfigs", beta + "-kubernetes-config"},
			{"policies", readerRole},
			{"kubernetesauthengineroles", readerRole},
		}
		deleteTenantNamespace(t, betaNS)
		for _, ti := range []string{tiPrefix + beta, tiPrefix + beta + ".eso"} {
			waitFor(t, "TemplateInstance "+ti+" gone", func() string {
				if get(t, gvrTemplateInstance, configNS, ti) != nil {
					return "still present"
				}
				return ""
			})
		}
		// The grants go with the render. Waited for, too, so the render created
		// below never meets an old CR that VCO is still deleting.
		for _, o := range grants {
			waitFor(t, o.kind+"/"+o.name+" gone with the workload render", func() string {
				if get(t, vcoGVR(o.kind), configNS, o.name) != nil {
					return "still present"
				}
				return ""
			})
		}
		// Held across a VCO drift period, not read once: a deletion is
		// asynchronous (t-op-v2 prunes, then VCO deletes in Vault), so a
		// regression that put the Namespace back in the child chart could pass a
		// single read made just after the TemplateInstances went away.
		holdFor(t, vcoSync+15*time.Second, "e2e-beta's Vault data without a labelled namespace", func() string {
			for _, o := range []struct{ kind, name string }{{"namespaces", beta}, {"secretenginemounts", beta + "-kv"}} {
				if obj := get(t, vcoGVR(o.kind), configNS, o.name); obj == nil || obj.GetDeletionTimestamp() != nil {
					return o.kind + "/" + o.name + " was removed with the tenant's last namespace"
				}
			}
			if got, err := kvGet(t, vaultRootToken, beta, appPath(betaNS, "reader", "cfg"), "mode"); err != nil || got != "beta" {
				return fmt.Sprintf("the secret did not survive: got %q, err %v", got, err)
			}
			return ""
		})
		// A labelled namespace brings the workload render back, and the grants
		// find the data that stayed: the workload itself reads the secret
		// written before its namespace was deleted. Its ServiceAccount went with
		// the namespace, so it is created again.
		createTenant(t, beta, betaNS)
		waitTIReady(t, tiPrefix+beta)
		waitTIReady(t, tiPrefix+beta+".eso")
		createServiceAccount(t, betaNS, "reader", map[string]string{
			annPrefix + "kv":   "true",
			annPrefix + "tier": "viewer",
		})
		for _, o := range grants {
			waitVCO(t, o.kind, o.name)
		}
		readerToken, _ := vaultLogin(t, beta, readerRole, saToken(t, betaNS, "reader"))
		if got, err := kvGet(t, readerToken, beta, appPath(betaNS, "reader", "cfg"), "mode"); err != nil || got != "beta" {
			t.Fatalf("the workload could not read its surviving secret after its namespace came back: got %q, err %v", got, err)
		}
	})

	step("offboarding: deleting a Tenant keeps its Vault data under the production VCO policy", func(t *testing.T) {
		// The lab's VCO login policy allows every delete, so the teardown can
		// clean up. The production one (charts/examples/vco-admin-policy.hcl)
		// refuses a delete on a tenant's Vault namespace and kv mount: that
		// refusal is what keeps a tenant's secrets when its Tenant CR goes
		// (charts/README.md → Deletion). Root swaps it in for this step only.
		prod, err := os.ReadFile("../../charts/examples/vco-admin-policy.hcl")
		if err != nil {
			t.Fatalf("read the production VCO policy: %v", err)
		}
		lab := policyRules(t, "", vcoLogin)
		t.Cleanup(func() { vaultIn(t, "", "write", "sys/policy/"+vcoLogin, "policy="+lab) })
		vaultIn(t, "", "write", "sys/policy/"+vcoLogin, "policy="+string(prod))

		// The data that must stay: e2e-beta's own secret, and both shares with
		// e2e-alpha, which live in the shared Vault namespace. Inspected as
		// root: e2e-beta's workloads lose their logins with the Tenant.
		handoff := env + "/from-" + alpha + "/to-" + beta + "/handoff"
		reverse := env + "/from-" + beta + "/to-" + alpha + "/x"
		data := func() string {
			if got, err := kvGet(t, vaultRootToken, beta, appPath(betaNS, "reader", "cfg"), "mode"); err != nil || got != "beta" {
				return fmt.Sprintf("e2e-beta's secret: got %q, err %v", got, err)
			}
			if got, err := kvGet(t, vaultRootToken, sharedNS, handoff, "token"); err != nil || got != "t1" {
				return fmt.Sprintf("the share to e2e-beta: got %q, err %v", got, err)
			}
			if got, err := kvGet(t, vaultRootToken, sharedNS, reverse, "token"); err != nil || got != "r1" {
				return fmt.Sprintf("the share from e2e-beta: got %q, err %v", got, err)
			}
			return ""
		}
		if msg := data(); msg != "" {
			t.Fatalf("before the deletion: %s", msg)
		}

		// MTO deletes a Tenant together with its namespaces.
		deleteTenant(t, beta, betaNS)

		// The grants go, under the production policy too: every e2e-beta CR
		// except the two that hold data, and e2e-alpha's share role to the
		// tenant that is gone.
		dataCRs := []struct{ kind, name string }{{"namespaces", beta}, {"secretenginemounts", beta + "-kv"}}
		waitFor(t, "every e2e-beta CR gone except its data", func() string {
			objs := tenantVCOObjects(t, beta)
			var grants []string
			for _, o := range objs {
				if o != "namespaces/"+beta && o != "secretenginemounts/"+beta+"-kv" {
					grants = append(grants, o)
				}
			}
			switch {
			case len(grants) > 0:
				return "still present: " + strings.Join(grants, ", ")
			case len(objs) != len(dataCRs):
				return fmt.Sprintf("the data CRs are not both there: %v", objs)
			}
			return ""
		})
		outRole := "share." + alpha + "." + alphaNS + ".web.out." + beta
		for _, k := range []string{"policies", "kubernetesauthengineroles"} {
			waitFor(t, k+"/"+outRole+" gone with its peer", func() string {
				if get(t, vcoGVR(k), configNS, outRole) != nil {
					return "still present"
				}
				return ""
			})
		}
		if msg := vaultGone(t, sharedNS, "policy", "read", outRole); msg != "" {
			t.Errorf("e2e-alpha's share policy to e2e-beta is still in Vault: %s", msg)
		}

		// VCO tries to delete the data, Vault refuses, and VCO's finalizer holds
		// both CRs. Held across a drift period, as in the lifetime step.
		holdFor(t, vcoSync+15*time.Second, "e2e-beta's data after its Tenant was deleted", func() string {
			for _, o := range dataCRs {
				switch obj := get(t, vcoGVR(o.kind), configNS, o.name); {
				case obj == nil:
					return o.kind + "/" + o.name + " was deleted"
				case obj.GetDeletionTimestamp() == nil:
					return o.kind + "/" + o.name + " is not being deleted: the Tenant's deletion did not reach it"
				}
			}
			return data()
		})

		// The refusal is the policy's: VCO's own login reads the namespace and
		// the mount, and is refused the delete of each. Under the lab policy
		// both deletes would pass.
		vcoToken, _, err := vaultTryLoginAt(t, "", vcoLoginMount, vcoLogin, saToken(t, configNS, vcoLogin))
		if err != nil {
			t.Fatalf("log in as VCO: %v", err)
		}
		if _, err := vaultRun(t, vcoToken, "", "read", "sys/namespaces/"+beta); err != nil {
			t.Fatalf("VCO could not read e2e-beta's Vault namespace: %v", err)
		}
		if _, err := vaultRun(t, vcoToken, "", "namespace", "delete", beta); !refused(err) {
			t.Errorf("VCO's login deleted e2e-beta's Vault namespace; err: %v", err)
		}
		if _, err := vaultRun(t, vcoToken, beta, "read", "sys/mounts/kv"); err != nil {
			t.Fatalf("VCO could not read e2e-beta's kv mount: %v", err)
		}
		if _, err := vaultRun(t, vcoToken, beta, "secrets", "disable", "kv"); !refused(err) {
			t.Errorf("VCO's login disabled e2e-beta's kv mount; err: %v", err)
		}

		// The documented way to really delete a tenant (charts/README.md →
		// Deletion): a Vault admin deletes the namespace, then removes the
		// finalizers.
		vaultIn(t, "", "namespace", "delete", beta)
		waitFor(t, "e2e-beta's Vault namespace deleted", func() string {
			return vaultGone(t, "", "read", "sys/namespaces/"+beta)
		})
		for _, o := range dataCRs {
			removeFinalizers(t, vcoGVR(o.kind), configNS, o.name)
			waitFor(t, o.kind+"/"+o.name+" gone", func() string {
				if get(t, vcoGVR(o.kind), configNS, o.name) != nil {
					return "still present"
				}
				return ""
			})
		}
	})

	if os.Getenv("E2E_KEEP") != "" {
		t.Log("E2E_KEEP set: leaving the install and fixtures in place")
		return
	}

	step("teardown: the documented uninstall order", func(t *testing.T) {
		// Also registered with t.Cleanup; running it here makes its assertions
		// part of the result, and the cleanup then finds nothing left to do.
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
