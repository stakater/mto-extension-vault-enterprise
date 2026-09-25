// Package e2e drives the two charts against a live cluster running
// template-operator-v2, vault-config-operator (VCO), Vault Enterprise, External
// Secrets Operator and Stakater Reloader.
//
// It is the only layer where anything reconciles. hack/chart-render-tests.sh
// proves what the templates PRODUCE and `make crd-validate` proves the API
// server would ACCEPT it; neither can say what template-operator-v2 does with a
// Tenant, what VCO then writes into Vault, or whether a workload can afterwards
// log in and read its own secret — and not its neighbour's.
//
//	make e2e-kind VAULT_LICENSE_FILE=<.hclic>
//
// builds the lab cluster and runs this suite. Against a lab that is already up:
//
//	make e2e-test
//
// Variables:
//
//	E2E=1                  the gate; without it the package exits 0 having run nothing
//	KUBE_CONTEXT           required — the suite refuses the ambient current-context,
//	                       because it installs, deletes and relabels real objects
//	E2E_CHART_REPO_URL     required — where template-operator-v2 pulls THIS checkout's
//	                       tenant chart from (make lab-chart-repo). Without it the
//	                       bootstrap would point at ghcr.io and test the last release
//	E2E_TOV2_SA            template-operator-v2's ServiceAccount, as
//	                       system:serviceaccount:<ns>:<name>
//	E2E_CONFIG_NAMESPACE, E2E_VAULT_NAMESPACE, E2E_VAULT_POD, E2E_VAULT_SERVER
//	                       defaults match the lab
//	E2E_WAIT_TIMEOUT       per-wait budget (Go duration, default 4m)
//	E2E_VCO_SYNC_PERIOD    VCO's drift period (SYNC_PERIOD_SECONDS) as a Go duration;
//	                       the suite watches objects across it (default 30s, the lab's)
//	E2E_KEEP=1             skip the final uninstall, to inspect the cluster afterwards
//
// The suite needs Vault ENTERPRISE: tenant isolation is one Vault namespace per
// tenant, and Community Edition ignores namespaces. It checks the edition first
// and refuses to run on Community Edition rather than report collisions as
// passes. SSO is not covered: it needs an OIDC provider, and nothing here stands
// one up.
package e2e

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	authenticationv1 "k8s.io/api/authentication/v1"
	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

const (
	releaseName = "mto-extension-vault-enterprise-bootstrap"
	parentName  = "mto-extension-vault-enterprise-parent"
	tiPrefix    = "mto-extension-vault-enterprise-"

	// Chart defaults the suite depends on and never overrides, so a change to
	// one without the other fails loudly here.
	tenantLabel  = "stakater.com/tenant"
	annPrefix    = "vault.stakater.com/"
	env          = "dev"
	sharedNS     = "shared"
	k8sAuthMount = "kubernetes/workloads"

	// ESO re-reads Vault at this interval. Short, so the rotation scenario does
	// not wait an hour; set through the bootstrap value it is plumbed from.
	esoRefresh = "10s"
)

var (
	kubeContext  string
	configNS     string
	vaultNS      string
	vaultPod     string
	vaultServer  string
	chartRepoURL string
	tov2SA       string
	waitTimeout  time.Duration
	vcoSync      time.Duration

	dyn  dynamic.Interface
	kube kubernetes.Interface
	ctx  = context.Background()
)

var (
	gvrTemplateInstance = schema.GroupVersionResource{Group: "templates.v2.stakater.com", Version: "v2alpha1", Resource: "templateinstances"}
	gvrTenant           = schema.GroupVersionResource{Group: "tenantoperator.stakater.com", Version: "v1beta3", Resource: "tenants"}
	gvrExternalSecret   = schema.GroupVersionResource{Group: "external-secrets.io", Version: "v1", Resource: "externalsecrets"}

	// Every VCO kind the charts render. Teardown waits for all of them.
	vcoKinds = []string{"namespaces", "secretenginemounts", "authenginemounts", "kubernetesauthengineconfigs",
		"kubernetesauthengineroles", "policies", "jwtoidcauthengineconfigs", "jwtoidcauthengineroles"}
)

func vcoGVR(resource string) schema.GroupVersionResource {
	return schema.GroupVersionResource{Group: "redhatcop.redhat.io", Version: "v1alpha1", Resource: resource}
}

func TestMain(m *testing.M) {
	if os.Getenv("E2E") == "" {
		println("e2e SKIPPED: set E2E=1 (see the package comment for the other variables)")
		os.Exit(0)
	}
	kubeContext = os.Getenv("KUBE_CONTEXT")
	if kubeContext == "" {
		println("e2e requires KUBE_CONTEXT — refusing to use the ambient current-context")
		os.Exit(1)
	}
	chartRepoURL = os.Getenv("E2E_CHART_REPO_URL")
	if chartRepoURL == "" {
		println("e2e requires E2E_CHART_REPO_URL — the in-cluster repo serving this checkout's tenant chart (make lab-chart-repo)")
		os.Exit(1)
	}
	configNS = envOr("E2E_CONFIG_NAMESPACE", "vault-config")
	vaultNS = envOr("E2E_VAULT_NAMESPACE", "vault")
	vaultPod = envOr("E2E_VAULT_POD", "vault-0")
	vaultServer = envOr("E2E_VAULT_SERVER", "http://vault.vault.svc:8200")
	tov2SA = os.Getenv("E2E_TOV2_SA")
	var err error
	if waitTimeout, err = time.ParseDuration(envOr("E2E_WAIT_TIMEOUT", "4m")); err != nil {
		println("E2E_WAIT_TIMEOUT:", err.Error())
		os.Exit(1)
	}
	if vcoSync, err = time.ParseDuration(envOr("E2E_VCO_SYNC_PERIOD", "30s")); err != nil {
		println("E2E_VCO_SYNC_PERIOD:", err.Error())
		os.Exit(1)
	}

	cfg, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		clientcmd.NewDefaultClientConfigLoadingRules(),
		&clientcmd.ConfigOverrides{CurrentContext: kubeContext},
	).ClientConfig()
	if err != nil {
		println("kubeconfig:", err.Error())
		os.Exit(1)
	}
	if dyn, err = dynamic.NewForConfig(cfg); err != nil {
		println("dynamic client:", err.Error())
		os.Exit(1)
	}
	if kube, err = kubernetes.NewForConfig(cfg); err != nil {
		println("clientset:", err.Error())
		os.Exit(1)
	}
	os.Exit(m.Run())
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func helmBin() string    { return envOr("HELM", "helm") }
func kubectlBin() string { return envOr("KUBECTL", "kubectl") }

// ------------------------------------------------------------------ helm

func chartDir(t *testing.T) string {
	t.Helper()
	abs, err := filepath.Abs("../../charts/mto-extension-vault-enterprise-bootstrap")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(abs, "Chart.yaml")); err != nil {
		t.Fatalf("bootstrap chart not found at %s: %v", abs, err)
	}
	return abs
}

// helmInstall installs the bootstrap chart from THIS checkout with the chart
// defaults plus exactly what the lab differs in.
func helmInstall(t *testing.T) {
	t.Helper()
	args := []string{"upgrade", "--install", releaseName, chartDir(t),
		"--kube-context", kubeContext, "-n", configNS, "--create-namespace", "--wait",
		"--set", "configNamespace=" + configNS,
		"--set", "tenantChart.registry=" + chartRepoURL,
		"--set", "parent.vaultServer=" + vaultServer,
		"--set", "parent.eso=enabled",
		"--set", "parent.externalSecretRefreshInterval=" + esoRefresh,
	}
	if tov2SA != "" {
		parts := strings.Split(strings.TrimPrefix(tov2SA, "system:serviceaccount:"), ":")
		if len(parts) != 2 {
			t.Fatalf("E2E_TOV2_SA=%q is not system:serviceaccount:<ns>:<name>", tov2SA)
		}
		args = append(args, "--set", "templateOperator.namespace="+parts[0], "--set", "templateOperator.serviceAccountName="+parts[1])
	}
	run(t, helmBin(), args...)
}

// uninstall runs the documented order (charts/README.md → Uninstall): the
// parent TemplateInstance first, then — only once no VCO CR is left — the
// release. A bare `helm uninstall` deletes the RBAC and the VCO login
// ServiceAccount the teardown still needs, and everything wedges Terminating.
func uninstall(t *testing.T) {
	t.Helper()
	deleteIfExists(t, gvrTemplateInstance, configNS, parentName)
	waitFor(t, "every TemplateInstance gone", func() string {
		if n := len(list(t, gvrTemplateInstance, configNS)); n > 0 {
			return fmt.Sprintf("%d TemplateInstances left", n)
		}
		return ""
	})
	waitFor(t, "every VCO CR gone", func() string {
		var left []string
		for _, k := range vcoKinds {
			for _, o := range list(t, vcoGVR(k), configNS) {
				left = append(left, k+"/"+o.GetName())
			}
		}
		if len(left) > 0 {
			return fmt.Sprintf("%d left: %s", len(left), strings.Join(left, ", "))
		}
		return ""
	})
	if releaseExists(t) {
		run(t, helmBin(), "uninstall", releaseName, "--kube-context", kubeContext, "-n", configNS, "--wait")
	}
}

func releaseExists(t *testing.T) bool {
	t.Helper()
	cmd := exec.Command(helmBin(), "status", releaseName, "--kube-context", kubeContext, "-n", configNS)
	return cmd.Run() == nil
}

func run(t *testing.T, bin string, args ...string) string {
	t.Helper()
	out, err := exec.Command(bin, args...).CombinedOutput()
	if err != nil {
		t.Fatalf("%s %s: %v\n%s", bin, strings.Join(args, " "), err, out)
	}
	return string(out)
}

// ------------------------------------------------------------------ waits and reads

// waitFor polls until state returns "" and fails with the last state on
// timeout, so a failure says what was still wrong rather than only "timed out".
func waitFor(t *testing.T, what string, state func() string) {
	t.Helper()
	deadline := time.Now().Add(waitTimeout)
	last := ""
	for time.Now().Before(deadline) {
		if last = state(); last == "" {
			return
		}
		time.Sleep(3 * time.Second)
	}
	t.Fatalf("timed out after %s waiting for %s; last state: %s", waitTimeout, what, last)
}

// holdFor checks bad() for the whole duration and fails the moment it reports
// something: waitFor proves a state is reached, holdFor proves it lasts.
func holdFor(t *testing.T, d time.Duration, what string, bad func() string) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if msg := bad(); msg != "" {
			t.Fatalf("%s: %s", what, msg)
		}
		time.Sleep(3 * time.Second)
	}
}

func list(t *testing.T, gvr schema.GroupVersionResource, ns string) []unstructured.Unstructured {
	t.Helper()
	l, err := dyn.Resource(gvr).Namespace(ns).List(ctx, metav1.ListOptions{})
	if err != nil {
		if apierrors.IsNotFound(err) {
			return nil
		}
		t.Fatalf("list %s in %s: %v", gvr.Resource, ns, err)
	}
	return l.Items
}

func get(t *testing.T, gvr schema.GroupVersionResource, ns, name string) *unstructured.Unstructured {
	t.Helper()
	o, err := dyn.Resource(gvr).Namespace(ns).Get(ctx, name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return nil
	}
	if err != nil {
		t.Fatalf("get %s %s/%s: %v", gvr.Resource, ns, name, err)
	}
	return o
}

func deleteIfExists(t *testing.T, gvr schema.GroupVersionResource, ns, name string) {
	t.Helper()
	err := dyn.Resource(gvr).Namespace(ns).Delete(ctx, name, metav1.DeleteOptions{})
	if err != nil && !apierrors.IsNotFound(err) {
		t.Fatalf("delete %s %s/%s: %v", gvr.Resource, ns, name, err)
	}
}

// condition returns a status condition's status and message ("" if absent).
func condition(o *unstructured.Unstructured, typ string) (status, message string) {
	conds, _, _ := unstructured.NestedSlice(o.Object, "status", "conditions")
	for _, c := range conds {
		m, _ := c.(map[string]any)
		if m["type"] == typ {
			s, _ := m["status"].(string)
			msg, _ := m["message"].(string)
			return s, msg
		}
	}
	return "", ""
}

// waitTIReady waits for a TemplateInstance to be Ready=True.
func waitTIReady(t *testing.T, name string) {
	t.Helper()
	waitFor(t, "TemplateInstance "+name+" Ready", func() string {
		o := get(t, gvrTemplateInstance, configNS, name)
		if o == nil {
			return "absent"
		}
		if s, msg := condition(o, "Ready"); s != "True" {
			return fmt.Sprintf("Ready=%q %s", s, msg)
		}
		return ""
	})
}

// waitVCO waits for a VCO CR to have been written to Vault. VCO's status has
// no "healthy now" signal (charts/README.md → Health): ReconcileSuccessful=True
// means "written at least once", and ReconcileFailed carries the last error,
// which is what a timeout reports.
func waitVCO(t *testing.T, kind, name string) {
	t.Helper()
	waitFor(t, "VCO "+kind+"/"+name+" reconciled", func() string {
		o := get(t, vcoGVR(kind), configNS, name)
		if o == nil {
			return "absent"
		}
		if s, _ := condition(o, "ReconcileSuccessful"); s == "True" {
			return ""
		}
		_, msg := condition(o, "ReconcileFailed")
		return "not yet reconciled; last error: " + msg
	})
}

// ------------------------------------------------------------------ fixtures

// createTenant creates a Tenant and its namespaces carrying the tenant label —
// what MTO would do. Only the Tenant CRD is installed, not MTO.
func createTenant(t *testing.T, tenant string, namespaces ...string) {
	t.Helper()
	obj := &unstructured.Unstructured{Object: map[string]any{
		"apiVersion": "tenantoperator.stakater.com/v1beta3",
		"kind":       "Tenant",
		"metadata":   map[string]any{"name": tenant},
		"spec":       map[string]any{"quota": "small"},
	}}
	if _, err := dyn.Resource(gvrTenant).Create(ctx, obj, metav1.CreateOptions{}); err != nil && !apierrors.IsAlreadyExists(err) {
		t.Fatalf("create Tenant %s: %v", tenant, err)
	}
	for _, ns := range namespaces {
		n := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: ns, Labels: map[string]string{tenantLabel: tenant}}}
		if _, err := kube.CoreV1().Namespaces().Create(ctx, n, metav1.CreateOptions{}); err != nil && !apierrors.IsAlreadyExists(err) {
			t.Fatalf("create namespace %s: %v", ns, err)
		}
	}
}

// deleteTenant removes a Tenant and its namespaces and waits for the
// namespaces to be gone, so the next run starts from nothing.
func deleteTenant(t *testing.T, tenant string, namespaces ...string) {
	t.Helper()
	if err := dyn.Resource(gvrTenant).Delete(ctx, tenant, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
		t.Fatalf("delete Tenant %s: %v", tenant, err)
	}
	for _, ns := range namespaces {
		if err := kube.CoreV1().Namespaces().Delete(ctx, ns, metav1.DeleteOptions{}); err != nil && !apierrors.IsNotFound(err) {
			t.Fatalf("delete namespace %s: %v", ns, err)
		}
	}
	for _, ns := range namespaces {
		waitFor(t, "namespace "+ns+" gone", func() string {
			if _, err := kube.CoreV1().Namespaces().Get(ctx, ns, metav1.GetOptions{}); err == nil {
				return "still present"
			}
			return ""
		})
	}
}

func createServiceAccount(t *testing.T, ns, name string, ann map[string]string) {
	t.Helper()
	sa := &corev1.ServiceAccount{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Annotations: ann}}
	if _, err := kube.CoreV1().ServiceAccounts(ns).Create(ctx, sa, metav1.CreateOptions{}); err != nil {
		t.Fatalf("create ServiceAccount %s/%s: %v", ns, name, err)
	}
}

// createDeployment creates a one-replica busybox Deployment running as sa, with
// the given annotations on the Deployment and env on the container.
func createDeployment(t *testing.T, ns, name, sa string, ann map[string]string, envs []corev1.EnvVar) {
	t.Helper()
	one := int32(1)
	labels := map[string]string{"app": name}
	d := &appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: ns, Annotations: ann},
		Spec: appsv1.DeploymentSpec{
			Replicas: &one,
			Selector: &metav1.LabelSelector{MatchLabels: labels},
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{Labels: labels},
				Spec: corev1.PodSpec{
					ServiceAccountName: sa,
					Containers: []corev1.Container{{
						Name:    "app",
						Image:   "busybox:1.37",
						Command: []string{"sh", "-c", "sleep 3600"},
						Env:     envs,
					}},
				},
			},
		},
	}
	if _, err := kube.AppsV1().Deployments(ns).Create(ctx, d, metav1.CreateOptions{}); err != nil {
		t.Fatalf("create Deployment %s/%s: %v", ns, name, err)
	}
}

// secretEnv is a container env var read from a Secret key.
func secretEnv(name, secret, key string) corev1.EnvVar {
	return corev1.EnvVar{Name: name, ValueFrom: &corev1.EnvVarSource{SecretKeyRef: &corev1.SecretKeySelector{
		LocalObjectReference: corev1.LocalObjectReference{Name: secret}, Key: key,
	}}}
}

// saToken mints a short-lived token for a ServiceAccount — what the kubelet
// projects into its pods.
func saToken(t *testing.T, ns, name string) string {
	t.Helper()
	exp := int64(600)
	tr, err := kube.CoreV1().ServiceAccounts(ns).CreateToken(ctx, name,
		&authenticationv1.TokenRequest{Spec: authenticationv1.TokenRequestSpec{ExpirationSeconds: &exp}}, metav1.CreateOptions{})
	if err != nil {
		t.Fatalf("token for %s/%s: %v", ns, name, err)
	}
	return tr.Status.Token
}

// secretValue returns a Secret key's value, or "" when the Secret or key is absent.
func secretValue(t *testing.T, ns, name, key string) string {
	t.Helper()
	s, err := kube.CoreV1().Secrets(ns).Get(ctx, name, metav1.GetOptions{})
	if apierrors.IsNotFound(err) {
		return ""
	}
	if err != nil {
		t.Fatalf("get Secret %s/%s: %v", ns, name, err)
	}
	return string(s.Data[key])
}

// runningPod returns the name of the one Running, Ready pod of a Deployment,
// or "" while there is not exactly one (a rollout in progress has two).
func runningPod(t *testing.T, ns, app string) string {
	t.Helper()
	pods, err := kube.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{LabelSelector: "app=" + app})
	if err != nil {
		t.Fatalf("list pods of %s/%s: %v", ns, app, err)
	}
	var ready []string
	for _, p := range pods.Items {
		if p.DeletionTimestamp != nil || p.Status.Phase != corev1.PodRunning {
			continue
		}
		for _, c := range p.Status.Conditions {
			if c.Type == corev1.PodReady && c.Status == corev1.ConditionTrue {
				ready = append(ready, p.Name)
			}
		}
	}
	if len(pods.Items) != 1 || len(ready) != 1 {
		return ""
	}
	return ready[0]
}

// podEnv reads an environment variable from inside a running pod — the value
// the application actually sees, not the value in the Secret.
func podEnv(t *testing.T, ns, pod, name string) string {
	t.Helper()
	out := run(t, kubectlBin(), "--context", kubeContext, "-n", ns, "exec", pod, "--", "printenv", name)
	return strings.TrimSpace(out)
}
