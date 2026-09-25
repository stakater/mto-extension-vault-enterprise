package e2e

import (
	"encoding/json"
	"os/exec"
	"strings"
	"testing"
)

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
	cmd := exec.Command(kubectlBin(), full...)
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

func (e *vaultError) Error() string {
	return "vault " + strings.Join(e.args, " ") + " (namespace " + e.ns + "): " + e.err.Error() + "\n" + strings.TrimSpace(e.stderr)
}

// refused reports whether err is Vault saying no to an AUTHENTICATED caller —
// the only acceptable failure for an "is denied" assertion. A typo in a path, a
// missing mount or a network error must not pass as a denial.
func refused(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "Code: 403") || strings.Contains(s, "permission denied")
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
	out, err := vaultRun(t, "", ns, "write", "-format=json", "auth/"+k8sAuthMount+"/login", "role="+role, "jwt="+jwt)
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

// kvMetadataDelete deletes a secret's metadata — every version — as the given
// token. KV v2 metadata is not a read-only view: this is the destructive call a
// read-only subscriber must not be able to make.
func kvMetadataDelete(t *testing.T, token, ns, path string) error {
	t.Helper()
	_, err := vaultRun(t, token, ns, "kv", "metadata", "delete", "-mount=kv", path)
	return err
}

// kvGet reads one field of kv/<path> as the given token.
func kvGet(t *testing.T, token, ns, path, field string) (string, error) {
	t.Helper()
	out, err := vaultRun(t, token, ns, "kv", "get", "-mount=kv", "-field="+field, path)
	return strings.TrimSpace(out), err
}
