package e2e

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os/exec"
	"regexp"
	"strings"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// Human SSO, as in production: person -> Vault (oidc/sso) -> Dex -> Keycloak.
// The lab's Keycloak (make lab-keycloak) holds the users and their groups;
// Dex (make lab-dex, configured by DCO) fronts it through Keycloak's "dex"
// client. Each tenant's Vault namespace has an oidc/sso mount with one role per
// tier, bound to the group <tenant>-<tier>s.
//
// There is no browser. oidcLogin does what `vault login -method=oidc` and a
// person at the keyboard do together, over plain HTTP.

const (
	ssoMount = "oidc/sso"
	// The vault CLI's loopback callback: the tenant chart's default redirect
	// URI, which the e2e install allows explicitly next to the Vault UI's
	// (helmInstall), and one of Dex's "vault" client. Nothing listens there;
	// the client stops at the redirect and reads code and state.
	cliCallback     = "http://localhost:8250/oidc/callback"
	cliCallbackHost = "localhost:8250"
	// The phrase Vault's JWT/OIDC plugin refuses a login with when the token's
	// groups are not the role's bound group. A refused SSO login must say this:
	// an error for any other reason is not proof that the binding works.
	claimMismatch = "does not match any associated bound claim values"
)

// ssoRole is the tenant chart's vault.ssoRoleName: sso.<tenant>.<tier>.
func ssoRole(tenant, tier string) string { return "sso." + tenant + "." + tier }

// newSSOClient returns an HTTP client that reaches Dex and Keycloak through
// port-forwards while keeping their in-cluster URLs, so every issuer and
// redirect is the same string Vault and Dex see inside the cluster. Any other
// host fails the request, so a redirect somewhere unexpected cannot pass.
func newSSOClient(t *testing.T) *http.Client {
	t.Helper()
	routes := map[string]string{}
	for _, f := range []struct{ ns, svc, base string }{{dexNS, "dex", dexIssuer}, {keycloakNS, "keycloak", keycloakURL}} {
		u, err := url.Parse(f.base)
		if err != nil || u.Port() == "" {
			t.Fatalf("%s must be a URL with a port, got %q", f.svc, f.base)
		}
		routes[u.Host] = portForward(t, f.ns, "svc/"+f.svc, u.Port())
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	// No cookie jar here: oidcLogin gives every login its own.
	return &http.Client{
		Timeout: time.Minute,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				local, ok := routes[addr]
				if !ok {
					return nil, fmt.Errorf("the SSO login tried to reach %s, which is neither Dex nor Keycloak", addr)
				}
				return dialer.DialContext(ctx, network, local)
			},
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if req.URL.Host == cliCallbackHost {
				return http.ErrUseLastResponse
			}
			if len(via) > 20 {
				return errors.New("more than 20 redirects")
			}
			return nil
		},
	}
}

var forwardingRE = regexp.MustCompile(`Forwarding from 127\.0\.0\.1:(\d+) ->`)

// portForward starts `kubectl port-forward <target> :<port>` for the rest of
// the test and returns the local address.
func portForward(t *testing.T, ns, target, port string) string {
	t.Helper()
	cmd := exec.Command(kubectlBin(), "--context", kubeContext, "-n", ns, "port-forward", target, ":"+port)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("port-forward %s/%s: %v", ns, target, err)
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("port-forward %s/%s: %v", ns, target, err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})
	local := make(chan string, 1)
	go func() {
		// Keep reading after the first line: kubectl logs every connection, and
		// a full pipe would block it.
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			if m := forwardingRE.FindStringSubmatch(sc.Text()); m != nil {
				select {
				case local <- "127.0.0.1:" + m[1]:
				default:
				}
			}
		}
	}()
	select {
	case addr := <-local:
		return addr
	case <-time.After(30 * time.Second):
		t.Fatalf("port-forward %s/%s did not start: %s", ns, target, stderr.String())
		return ""
	}
}

var (
	kcFormRE   = regexp.MustCompile(`(?s)<form\b[^>]*\bid="kc-form-login"[^>]*>`)
	kcActionRE = regexp.MustCompile(`\baction="([^"]*)"`)
	kcErrorRE  = regexp.MustCompile(`(?s)id="input-error"[^>]*>(.*?)<`)
)

// oidcLogin logs user in to the tenant's Vault namespace with role, through
// Dex and Keycloak:
//
//  1. Vault's auth_url for the role, with the CLI callback as redirect_uri
//  2. GET it: Vault's URL -> Dex -> Keycloak's login form
//  3. POST the form: Keycloak -> Dex /callback -> the CLI callback, where the
//     client stops and reads code and state from the redirect
//  4. Vault's callback with code and state, which returns the Vault token
//
// The returned error is Vault refusing step 4, for example groups that do not
// match the role. Any failure before it is a broken lab, and fails the test.
func oidcLogin(t *testing.T, base *http.Client, tenant, role, user, password string) (token string, policies []string, err error) {
	t.Helper()
	// A fresh cookie jar per login, like a new private browser window. With one
	// shared jar, Keycloak's session from the previous user skips the login
	// form and logs the next user in as the previous one.
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatalf("cookie jar: %v", err)
	}
	c := &http.Client{Transport: base.Transport, CheckRedirect: base.CheckRedirect, Timeout: base.Timeout, Jar: jar}

	out, err := vaultRun(t, "", tenant, "write", "-format=json", "auth/"+ssoMount+"/oidc/auth_url",
		"role="+role, "redirect_uri="+cliCallback)
	if err != nil {
		t.Fatalf("auth_url for role %s in %s: %v", role, tenant, err)
	}
	var au struct {
		Data struct {
			AuthURL string `json:"auth_url"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(out), &au); err != nil || au.Data.AuthURL == "" {
		// Vault answers an allowed request with an empty auth_url when the
		// redirect_uri is not one of the role's allowed ones.
		t.Fatalf("Vault gave no auth_url for role %s in %s (err %v): %s", role, tenant, err, out)
	}

	resp, err := c.Get(au.Data.AuthURL)
	if err != nil {
		t.Fatalf("open the login page for %s: %v", user, err)
	}
	page := readBody(t, resp)
	form := kcFormRE.FindString(page)
	action := kcActionRE.FindStringSubmatch(form)
	if resp.StatusCode != http.StatusOK || action == nil {
		t.Fatalf("expected Keycloak's login form for %s, got HTTP %d at %s", user, resp.StatusCode, resp.Request.URL.Host+resp.Request.URL.Path)
	}

	resp, err = c.PostForm(html.UnescapeString(action[1]), url.Values{
		"username": {user}, "password": {password}, "credentialId": {""},
	})
	if err != nil {
		t.Fatalf("submit %s's login: %v", user, err)
	}
	page = readBody(t, resp)
	loc, _ := resp.Location()
	if loc == nil || loc.Host != cliCallbackHost {
		msg := ""
		if m := kcErrorRE.FindStringSubmatch(page); m != nil {
			msg = strings.TrimSpace(html.UnescapeString(m[1]))
		}
		t.Fatalf("the login of %s did not come back to the CLI callback: HTTP %d at %s %s", user, resp.StatusCode, resp.Request.URL.Host+resp.Request.URL.Path, msg)
	}
	code, state := loc.Query().Get("code"), loc.Query().Get("state")
	if code == "" || state == "" {
		t.Fatalf("the CLI callback for %s carries no code or state (error %q)", user, loc.Query().Get("error"))
	}

	out, err = vaultRun(t, "", tenant, "read", "-format=json", "auth/"+ssoMount+"/oidc/callback",
		"state="+state, "code="+code)
	if err != nil {
		return "", nil, err
	}
	var cb struct {
		Auth struct {
			ClientToken string   `json:"client_token"`
			Policies    []string `json:"policies"`
		} `json:"auth"`
	}
	if err := json.Unmarshal([]byte(out), &cb); err != nil || cb.Auth.ClientToken == "" {
		t.Fatalf("Vault's callback for %s returned no token (err %v)", user, err)
	}
	return cb.Auth.ClientToken, cb.Auth.Policies, nil
}

// claimRefused reports whether err is Vault refusing an SSO login because the
// user's groups are not the role's bound group — and not for another reason.
func claimRefused(err error) bool {
	return err != nil && strings.Contains(err.Error(), claimMismatch)
}

func readBody(t *testing.T, resp *http.Response) string {
	t.Helper()
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		t.Fatalf("read %s: %v", resp.Request.URL.Host+resp.Request.URL.Path, err)
	}
	return string(b)
}

// testUserPassword returns a lab Keycloak user's password from the Secret
// make lab-keycloak made. It is never logged.
func testUserPassword(t *testing.T, user string) string {
	t.Helper()
	s, err := kube.CoreV1().Secrets(keycloakNS).Get(ctx, "keycloak-test-users", metav1.GetOptions{})
	if err != nil {
		t.Fatalf("read the Keycloak test users (make lab-keycloak): %v", err)
	}
	pw := string(s.Data[user])
	if pw == "" {
		t.Fatalf("Secret %s/keycloak-test-users has no password for %s", keycloakNS, user)
	}
	return pw
}

// copyOIDCClientSecret gives Vault's side the secret of Dex's "vault" client:
// Secret <configNS>/vault-oidc-client-secret, which every tenant's
// JWTOIDCAuthEngineConfig names.
func copyOIDCClientSecret(t *testing.T) {
	t.Helper()
	src, err := kube.CoreV1().Secrets(dexNS).Get(ctx, "dex-vault-client", metav1.GetOptions{})
	if err != nil {
		t.Fatalf("read Dex's vault client secret (make lab-dex): %v", err)
	}
	ns := &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{Name: configNS}}
	if _, err := kube.CoreV1().Namespaces().Create(ctx, ns, metav1.CreateOptions{}); err != nil && !apierrors.IsAlreadyExists(err) {
		t.Fatalf("create namespace %s: %v", configNS, err)
	}
	dst := &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{Name: "vault-oidc-client-secret", Namespace: configNS},
		Data:       map[string][]byte{"client-secret": src.Data["client-secret"]},
	}
	secrets := kube.CoreV1().Secrets(configNS)
	if _, err := secrets.Create(ctx, dst, metav1.CreateOptions{}); apierrors.IsAlreadyExists(err) {
		_, err = secrets.Update(ctx, dst, metav1.UpdateOptions{})
		if err != nil {
			t.Fatalf("update %s/vault-oidc-client-secret: %v", configNS, err)
		}
	} else if err != nil {
		t.Fatalf("create %s/vault-oidc-client-secret: %v", configNS, err)
	}
}

// dexIssuerFromVault fetches Dex's discovery document from inside the Vault
// pod — where Vault itself fetches it — and returns the issuer it names.
// dexClient is the Dex client Vault logs in through (hack/lab/dex-config.yaml),
// also the chart's default sso.oidc.clientId.
const dexClient = "vault"

// dexClientRedirects returns the redirect URIs Dex's client allows, from its
// Dex Config Operator Client resource.
func dexClientRedirects(t *testing.T) []string {
	t.Helper()
	gvr := schema.GroupVersionResource{Group: "auth.stakater.com", Version: "v1alpha1", Resource: "clients"}
	o := get(t, gvr, dexNS, dexClient)
	if o == nil {
		t.Fatalf("Dex client %s/%s does not exist (make lab-dex)", dexNS, dexClient)
	}
	uris, _, err := unstructured.NestedStringSlice(o.Object, "spec", "redirectURIs")
	if err != nil {
		t.Fatalf("read the redirect URIs of Dex client %s/%s: %v", dexNS, dexClient, err)
	}
	return uris
}

func dexIssuerFromVault(t *testing.T) string {
	t.Helper()
	cctx, cancel := context.WithTimeout(context.Background(), cmdTimeout)
	defer cancel()
	out, err := exec.CommandContext(cctx, kubectlBin(), "--context", kubeContext, "-n", vaultNS, "exec", vaultPod, "--",
		"wget", "-qO-", "-T", "10", dexIssuer+"/.well-known/openid-configuration").CombinedOutput()
	if err != nil {
		t.Fatalf("the Vault pod cannot reach Dex at %s (make lab-dex): %v: %s", dexIssuer, err, strings.TrimSpace(string(out)))
	}
	var doc struct {
		Issuer string `json:"issuer"`
	}
	if err := json.Unmarshal(out, &doc); err != nil {
		t.Fatalf("Dex's discovery document is not JSON: %v", err)
	}
	return doc.Issuer
}
