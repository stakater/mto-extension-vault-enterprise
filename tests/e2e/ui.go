package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// The docs tenant: names that read well in documentation. Only the ui step
// creates it, so no other step sees it.
const (
	docsTenant = "acme"
	docsNS     = "acme-shop"
	docsApp    = "checkout"

	uiNS     = "e2e-ui"
	uiPod    = "ui-flows"
	uiSecret = "ui-flow-secrets"
)

// The flows and their config live with the docs they illustrate.
const (
	uiFlowsDir  = "../../docs/screenshots/flows"
	uiConfigEnv = "../../docs/screenshots/config.env"
	uiOutDir    = "../../e2e-logs/screenshots"
)

// docsUsers are the Keycloak users in the docs tenant's groups (make
// lab-keycloak), and the tier each one's group gives.
var docsUsers = map[string]string{"alice": "editor", "bob": "viewer", "dave": "audit-read"}

var (
	dnsLabel = regexp.MustCompile(`^[a-z0-9]([-a-z0-9]*[a-z0-9])?$`)
	envKey   = regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)
)

// runUISteps seeds the docs tenant, logs its users in, and runs the flows.
func runUISteps(t *testing.T) {
	t.Helper()
	createTenant(t, docsTenant, docsNS)
	createServiceAccount(t, docsNS, docsApp, map[string]string{annPrefix + "kv": "true", annPrefix + "tier": "editor"})
	waitTIReady(t, tiPrefix+docsTenant)
	role := roleName(docsTenant, docsNS, docsApp)
	waitVCO(t, "policies", role)
	waitVCO(t, "kubernetesauthengineroles", role)
	waitVCO(t, "jwtoidcauthengineconfigs", docsTenant+"-oidc-config")
	for _, tier := range docsUsers {
		waitVCO(t, "policies", ssoRole(docsTenant, tier))
		waitVCO(t, "jwtoidcauthengineroles", ssoRole(docsTenant, tier))
	}

	// The secrets the screenshots show, written by the app itself, with
	// example values only.
	appToken, _ := vaultLogin(t, docsTenant, role, saToken(t, docsNS, docsApp))
	for leaf, kv := range map[string][]string{
		"db":              {"username=checkout", "password=example-only"},
		"payment-gateway": {"api-key=example-only"},
	} {
		if err := kvPut(t, appToken, docsTenant, appPath(docsNS, docsApp, leaf), kv...); err != nil {
			t.Fatalf("%s could not write its secret %s: %v", docsApp, leaf, err)
		}
	}
	// What its namespace shares with the tenant's other namespaces: an editor
	// app writes the namespace's _shared/ area.
	if err := kvPut(t, appToken, docsTenant, sharedPath(docsNS, "db-endpoint"), "host=db.acme-shop.internal", "port=5432"); err != nil {
		t.Fatalf("%s could not write its namespace's _shared/: %v", docsApp, err)
	}

	// Each user logs in through Keycloak and Dex over HTTP (sso.go), and the
	// flows log in to the UI with the Vault token that gives: the same
	// policies as the UI's own SSO login, which opens a popup that
	// browser-runner cannot drive yet.
	c := newSSOClient(t)
	secrets := map[string]string{}
	for user, tier := range docsUsers {
		token, pols, err := oidcLogin(t, c, docsTenant, ssoRole(docsTenant, tier), user, testUserPassword(t, user))
		if err != nil || !slices.Contains(pols, ssoRole(docsTenant, tier)) {
			t.Fatalf("%s could not log in to %s as %s: policies %v, err %v", user, docsTenant, tier, pols, err)
		}
		secrets[strings.ToUpper(user)+"_TOKEN"] = token
	}
	// The SSO login flows sign in through the UI itself: alice with her
	// group's role, and bob with a role his group does not give.
	secrets["ALICE_PASSWORD"] = testUserPassword(t, "alice")
	secrets["BOB_PASSWORD"] = testUserPassword(t, "bob")
	runUIFlows(t, secrets)
}

// runUIFlows runs every flow in one Pod. Each flow is an init container in
// browser-runner's probe mode: it always exits 0 and writes its verdict to a
// result file, so every flow runs even when an earlier one fails. The holder
// container then keeps /out until the results and screenshots are copied.
func runUIFlows(t *testing.T, secrets map[string]string) {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(uiFlowsDir, "*.yaml"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no flows in %s (err %v)", uiFlowsDir, err)
	}
	sort.Strings(files)
	flows := map[string]string{}
	var names []string
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("read flow %s: %v", f, err)
		}
		// The name becomes an init container name.
		name := strings.TrimSuffix(filepath.Base(f), ".yaml")
		if !dnsLabel.MatchString(name) || len(name) > 63 {
			t.Fatalf("flow file %s: the name must be a DNS label", f)
		}
		flows[name+".yaml"] = string(b)
		names = append(names, name)
	}
	var env []corev1.EnvVar
	config := readEnvFile(t, uiConfigEnv)
	keys := make([]string, 0, len(config))
	for k := range config {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		env = append(env, corev1.EnvVar{Name: k, Value: config[k]})
	}

	deleteUINamespace(t)
	if _, err := kube.CoreV1().Namespaces().Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: uiNS}}, metav1.CreateOptions{}); err != nil {
		t.Fatalf("create namespace %s: %v", uiNS, err)
	}
	t.Cleanup(func() {
		if !(t.Failed() && os.Getenv("E2E_KEEP_ON_FAILURE") != "") {
			deleteUINamespace(t)
		}
	})
	if _, err := kube.CoreV1().Secrets(uiNS).Create(ctx, &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: uiSecret}, StringData: secrets,
	}, metav1.CreateOptions{}); err != nil {
		t.Fatalf("create Secret %s/%s: %v", uiNS, uiSecret, err)
	}
	if _, err := kube.CoreV1().ConfigMaps(uiNS).Create(ctx, &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{Name: uiPod}, Data: flows,
	}, metav1.CreateOptions{}); err != nil {
		t.Fatalf("create ConfigMap %s/%s: %v", uiNS, uiPod, err)
	}

	mounts := []corev1.VolumeMount{
		{Name: "flows", MountPath: "/etc/e2e/flows", ReadOnly: true},
		{Name: "out", MountPath: "/out"},
		// Chromium's shared memory: the container default of 64Mi is too small.
		{Name: "shm", MountPath: "/dev/shm"},
	}
	var inits []corev1.Container
	for _, n := range names {
		inits = append(inits, corev1.Container{
			Name:            n,
			Image:           runnerImage,
			ImagePullPolicy: corev1.PullIfNotPresent,
			Command:         []string{"/runner/probe", "/etc/e2e/flows/" + n + ".yaml"},
			Env: append(slices.Clone(env),
				corev1.EnvVar{Name: "RESULT_FILE", Value: "/out/" + n + ".result.json"},
				corev1.EnvVar{Name: "E2E_ARTIFACTS_DIR", Value: "/out/" + n}),
			EnvFrom: []corev1.EnvFromSource{{SecretRef: &corev1.SecretEnvSource{
				LocalObjectReference: corev1.LocalObjectReference{Name: uiSecret}}}},
			VolumeMounts: mounts,
		})
	}
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: uiPod},
		Spec: corev1.PodSpec{
			RestartPolicy:  corev1.RestartPolicyNever,
			InitContainers: inits,
			Containers: []corev1.Container{{
				Name:         "holder",
				Image:        "busybox:1.37",
				Command:      []string{"sleep", "3600"},
				VolumeMounts: []corev1.VolumeMount{{Name: "out", MountPath: "/out"}},
			}},
			Volumes: []corev1.Volume{
				{Name: "flows", VolumeSource: corev1.VolumeSource{ConfigMap: &corev1.ConfigMapVolumeSource{
					LocalObjectReference: corev1.LocalObjectReference{Name: uiPod}}}},
				{Name: "out", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{}}},
				{Name: "shm", VolumeSource: corev1.VolumeSource{EmptyDir: &corev1.EmptyDirVolumeSource{Medium: corev1.StorageMediumMemory}}},
			},
		},
	}
	if _, err := kube.CoreV1().Pods(uiNS).Create(ctx, pod, metav1.CreateOptions{}); err != nil {
		t.Fatalf("create Pod %s/%s: %v", uiNS, uiPod, err)
	}

	// The flows run one after another: allow each its own wait budget.
	deadline := time.Now().Add(waitTimeout * time.Duration(len(names)))
	last := ""
	for {
		if last = uiPodState(t); last == "" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for the UI flows; last state: %s", last)
		}
		time.Sleep(3 * time.Second)
	}

	var failed []string
	for _, n := range names {
		out, err := kubectlOut("-n", uiNS, "exec", uiPod, "-c", "holder", "--", "cat", "/out/"+n+".result.json")
		var r struct {
			Status  string `json:"status"`
			Summary string `json:"summary"`
		}
		if err != nil || json.Unmarshal([]byte(out), &r) != nil {
			logs, _ := kubectlOut("-n", uiNS, "logs", uiPod, "-c", n, "--tail=30")
			failed = append(failed, fmt.Sprintf("%s: no result file (%v)\n%s", n, err, logs))
			continue
		}
		t.Logf("%s: %s", n, r.Summary)
		// Only "ok" passes: a skipped flow (an unset variable, an unreachable
		// URL) checked nothing.
		if r.Status != "ok" {
			failed = append(failed, n+": "+r.Summary)
		}
	}
	// Copied before the verdict, so a failed flow's on-failure screenshot is
	// there to look at.
	if err := os.RemoveAll(uiOutDir); err != nil {
		t.Fatalf("clear %s: %v", uiOutDir, err)
	}
	if err := os.MkdirAll(filepath.Dir(uiOutDir), 0o755); err != nil {
		t.Fatalf("create %s: %v", filepath.Dir(uiOutDir), err)
	}
	if out, err := kubectlOut("-n", uiNS, "cp", "-c", "holder", uiPod+":/out", uiOutDir); err != nil {
		t.Errorf("copy the screenshots: %v\n%s", err, out)
	}
	if len(failed) > 0 {
		t.Errorf("UI flows failed (screenshots in e2e-logs/screenshots/):\n%s", strings.Join(failed, "\n"))
	}
}

// uiPodState returns "" once every flow has run (the holder container runs),
// or what the Pod is still doing.
func uiPodState(t *testing.T) string {
	t.Helper()
	p, err := kube.CoreV1().Pods(uiNS).Get(ctx, uiPod, metav1.GetOptions{})
	if err != nil {
		return err.Error()
	}
	if p.Status.Phase == corev1.PodFailed {
		t.Fatalf("the UI flow Pod failed: %s %s", p.Status.Reason, p.Status.Message)
	}
	for _, c := range p.Status.ContainerStatuses {
		if c.Name == "holder" && c.State.Running != nil {
			return ""
		}
	}
	for _, c := range p.Status.InitContainerStatuses {
		switch {
		case c.State.Running != nil:
			return "running flow " + c.Name
		case c.State.Waiting != nil:
			return fmt.Sprintf("flow %s waiting: %s %s", c.Name, c.State.Waiting.Reason, c.State.Waiting.Message)
		}
	}
	return "pod " + string(p.Status.Phase)
}

// readEnvFile reads KEY=VALUE lines; # starts a comment.
func readEnvFile(t *testing.T, path string) map[string]string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	env := map[string]string{}
	for i, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok || !envKey.MatchString(k) {
			t.Fatalf("%s:%d: want KEY=VALUE, got %q", path, i+1, line)
		}
		env[k] = v
	}
	return env
}

// deleteUINamespace removes the flow Pod's namespace and waits until it is gone.
func deleteUINamespace(t *testing.T) {
	t.Helper()
	deleteTenantNamespace(t, uiNS)
}

// kubectlOut runs kubectl against the suite's context and returns its output.
func kubectlOut(args ...string) (string, error) {
	cctx, cancel := context.WithTimeout(context.Background(), cmdTimeout)
	defer cancel()
	out, err := exec.CommandContext(cctx, kubectlBin(), append([]string{"--context", kubeContext}, args...)...).CombinedOutput()
	return string(out), err
}
