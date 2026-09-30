package e2e

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// cmdTimeout bounds every CLI call the suite makes: a hung exec must fail the
// step, not stall the whole run until the CI job times out.
const cmdTimeout = 2 * time.Minute

// The suite reaches Vault through the `vault` CLI that ships in the Vault pod,
// over `kubectl exec`: no port-forward, no extra image, and the same path an
// operator debugging the cluster would use. Dev mode's root token is "root".
//
// Two token rules. The ROOT token only ever inspects state — which namespaces,
// mounts and policies exist. Anything that asserts what a WORKLOAD can do runs
// with a token that workload obtained by logging in with its own ServiceAccount
// JWT (vaultLogin), so a permission the chart failed to grant, or granted too
// widely, fails here instead of being papered over by root.

const vaultRootToken = "root"

// vaultRun runs `vault args...` in the Vault pod. token "" sends no VAULT_TOKEN
// (login is unauthenticated); ns "" is the root namespace. stderr travels in the
// error so a refused request says why.
func vaultRun(t *testing.T, token, ns string, args ...string) (string, error) {
	t.Helper()
	env := []string{"env"}
	if token != "" {
		env = append(env, "VAULT_TOKEN="+token)
	}
	if ns != "" {
		env = append(env, "VAULT_NAMESPACE="+ns)
	}
	full := append([]string{"--context", kubeContext, "-n", vaultNS, "exec", "-i", vaultPod, "--"}, env...)
	full = append(full, "vault")
	full = append(full, args...)
	cctx, cancel := context.WithTimeout(context.Background(), cmdTimeout)
	defer cancel()
	cmd := exec.CommandContext(cctx, kubectlBin(), full...)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return string(out), &vaultError{args: args, ns: ns, stderr: stderr.String(), err: err}
	}
	return string(out), nil
}

type vaultError struct {
	args   []string
	ns     string
	stderr string
	err    error
}

// Error never includes a secret argument: a failed login carries the
// ServiceAccount JWT as jwt=…, and this string ends up in the CI log.
func (e *vaultError) Error() string {
	shown := make([]string, len(e.args))
	for i, a := range e.args {
		if k, _, ok := strings.Cut(a, "="); ok && (k == "jwt" || k == "token" || k == "password" || k == "code") {
			a = k + "=<redacted>"
		}
		shown[i] = a
	}
	return "vault " + strings.Join(shown, " ") + " (namespace " + e.ns + "): " + e.err.Error() + "\n" + strings.TrimSpace(e.stderr)
}

// refused reports whether err is Vault saying no to an AUTHENTICATED caller —
// the only acceptable failure for an "is denied" assertion. It rejects a
// network error or an exec failure, but NOT a wrong path or a missing mount:
// for a non-root token Vault answers those with a 403 too. So every refusal
// needs a matching allow — the same call on the same path succeeding for a
// caller that is granted it — or data seeded at that path by root.
func refused(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "Code: 403") || strings.Contains(s, "permission denied")
}

// vaultGone is for waits on a deletion. It reads as root and returns "" only
// when Vault reports the object absent ("No value found" from `vault read`,
// "No policy named" from `vault policy read`); otherwise "still present", or
// the unexpected error, so a network error or a wrong path never reads as
// "deleted".
func vaultGone(t *testing.T, ns string, args ...string) string {
	t.Helper()
	_, err := vaultRun(t, vaultRootToken, ns, args...)
	switch {
	case err == nil:
		return "still present"
	case strings.Contains(err.Error(), "No value found"), strings.Contains(err.Error(), "No policy named"):
		return ""
	default:
		return err.Error()
	}
}

// vaultIn runs as root in the given namespace and fails the test on any error.
func vaultIn(t *testing.T, ns string, args ...string) string {
	t.Helper()
	out, err := vaultRun(t, vaultRootToken, ns, args...)
	if err != nil {
		t.Fatalf("%v", err)
	}
	return out
}

func jsonMap(t *testing.T, out string) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatalf("vault output is not a JSON object: %v\n%s", err, out)
	}
	return m
}

func jsonList(t *testing.T, out string) []string {
	t.Helper()
	var l []string
	if err := json.Unmarshal([]byte(out), &l); err != nil {
		t.Fatalf("vault output is not a JSON list: %v\n%s", err, out)
	}
	return l
}

// vaultNamespaces lists the child namespaces of root, without the trailing "/".
func vaultNamespaces(t *testing.T) []string {
	t.Helper()
	out, err := vaultRun(t, vaultRootToken, "", "namespace", "list", "-format=json")
	if err != nil {
		// With no namespaces the CLI prints {} and exits 2 — not an empty JSON
		// list. Matched exactly: a real failure never prints {}.
		if strings.TrimSpace(out) == "{}" {
			return nil
		}
		t.Fatalf("%v", err)
	}
	var names []string
	for _, n := range jsonList(t, out) {
		names = append(names, strings.TrimSuffix(n, "/"))
	}
	return names
}

// vaultKeys returns the keys of a `vault … list -format=json`-style map output
// (secrets list, auth list), e.g. "kv/".
func vaultKeys(t *testing.T, ns string, args ...string) []string {
	t.Helper()
	m := jsonMap(t, vaultIn(t, ns, args...))
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	return keys
}

// vaultLogin logs in to the workload kubernetes auth mount of a namespace with a
// ServiceAccount JWT and returns the client token and the policies Vault
// attached. This is exactly what a workload — or ESO on its behalf — does.
func vaultLogin(t *testing.T, ns, role, jwt string) (token string, policies []string) {
	t.Helper()
	token, policies, err := vaultTryLogin(t, ns, role, jwt)
	if err != nil {
		t.Fatalf("login to %s as role %s: %v", ns, role, err)
	}
	return token, policies
}

// vaultTryLogin is vaultLogin for the cases that must fail.
func vaultTryLogin(t *testing.T, ns, role, jwt string) (string, []string, error) {
	t.Helper()
	return vaultTryLoginAt(t, ns, k8sAuthMount, role, jwt)
}

// vaultTryLoginAt logs in at an explicit auth mount — used to prove that the
// values a workload's vault-config ConfigMap gives it actually work.
func vaultTryLoginAt(t *testing.T, ns, mount, role, jwt string) (string, []string, error) {
	t.Helper()
	out, err := vaultRun(t, "", ns, "write", "-format=json", "auth/"+mount+"/login", "role="+role, "jwt="+jwt)
	if err != nil {
		return "", nil, err
	}
	auth, _ := jsonMap(t, out)["auth"].(map[string]any)
	token, _ := auth["client_token"].(string)
	if token == "" {
		t.Fatalf("login to %s as role %s returned no client_token:\n%s", ns, role, out)
	}
	var policies []string
	if ps, ok := auth["token_policies"].([]any); ok {
		for _, p := range ps {
			if s, ok := p.(string); ok {
				policies = append(policies, s)
			}
		}
	}
	return token, policies, nil
}

// kvPut writes key=value pairs to kv/<path> as the given token.
func kvPut(t *testing.T, token, ns, path string, kv ...string) error {
	t.Helper()
	args := append([]string{"kv", "put", "-mount=kv", path}, kv...)
	_, err := vaultRun(t, token, ns, args...)
	return err
}

// kvMetadataPut updates a secret's metadata (flags such as -max-versions=1) as
// the given token. KV v2 metadata is not a read-only view: max_versions and
// delete_version_after destroy versions, so this is a call a read-only
// subscriber must not be able to make.
func kvMetadataPut(t *testing.T, token, ns, path string, flags ...string) error {
	t.Helper()
	args := append(append([]string{"kv", "metadata", "put", "-mount=kv"}, flags...), path)
	_, err := vaultRun(t, token, ns, args...)
	return err
}

// kvGet reads one field of kv/<path> as the given token.
func kvGet(t *testing.T, token, ns, path, field string) (string, error) {
	t.Helper()
	out, err := vaultRun(t, token, ns, "kv", "get", "-mount=kv", "-field="+field, path)
	return strings.TrimSpace(out), err
}
