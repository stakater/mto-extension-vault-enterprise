# UI screenshots

Screenshots of the Vault UI for the docs, taken by
[browser-runner](https://github.com/stakater-ab/browser-runner) flows. The same
run is an e2e check: every flow waits for the element that proves what it
shows, and a missing element fails the e2e job.

```
flows/       one browser-runner flow per view
config.env   the Vault URL and the docs tenant's names; no credentials
captured/    the images the docs use, committed
```

## How they run

The e2e suite's `ui` step ([tests/e2e/ui.go](../../tests/e2e/ui.go)) runs them
in the kind lab, in CI and locally:

1. It creates the docs tenant `acme` (namespace `acme-shop`, app `checkout`)
   and writes the app's secrets, with example values only.
2. It logs alice (editor), bob (viewer) and dave (audit-read) in through
   Keycloak and Dex, and passes each one's Vault token, user name and Keycloak
   password to the flows, in Secret `e2e-ui/ui-flow-secrets`. The step deletes
   that namespace afterwards; only a failed run with `E2E_KEEP_ON_FAILURE`
   keeps it.
3. It runs every flow in one Pod in the cluster, where the in-cluster names of
   Vault, Dex and Keycloak resolve: one init container per flow, in
   browser-runner's probe mode, so every flow runs and reports.
4. It copies the screenshots to `e2e-logs/screenshots/`, and fails if a flow
   failed.

Two flows sign in as users do, with "Sign in with OIDC Provider": the Vault
UI opens Dex and Keycloak in a popup window, which needs browser-runner's
popup support (`click` with `opensPopup`, steps with `page:`). The other flows
sign in with each user's Vault token, which has exactly the policies of that
SSO login and is faster.

## Updating the images

```bash
make e2e-test        # or make e2e-kind; CI uploads them as an artifact
make screenshots     # copy e2e-logs/screenshots/*/*.png into captured/
git diff --stat docs/screenshots/captured/
```

`make screenshots-check` (part of `make all`) fails when a Markdown file
references an image that is not in `captured/`, or when an image in
`captured/` is not used.

## Writing a flow

- Wait for the element that proves the state, then take the screenshot.
- Keep the viewport of the other flows (1440×900, scale 2, light) and use
  `fullPage: false`.
- Use the UI's own test attributes (`data-test-*` in the Vault UI), not layout
  classes. They are taken from the Vault UI source of the version the lab runs.
- Never take a screenshot of a filled credential field.
- Every variable a flow uses is listed under `requires.env`, so a missing one
  skips the flow, and the `ui` step fails on a skip.
