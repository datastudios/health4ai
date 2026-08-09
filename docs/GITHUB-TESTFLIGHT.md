# GitHub → TestFlight releases

Health4AI releases are deliberately gated. The workflow in
`.github/workflows/testflight.yml` runs only when manually dispatched in
GitHub Actions or when an explicit `health4ai-v*` tag is pushed. Normal branch
pushes, pull requests, and merges do not upload a binary.

## One-time GitHub setup

Create a protected GitHub environment named `testflight` before adding these
environment secrets. Configure it with all of the following controls:

- Require at least one reviewer before a job can access its secrets.
- Restrict deployment branches/tags to `main` and `health4ai-v*`.
- Disable administrator bypass for this environment.
- Do not add environment secrets at repository scope.

These are mandatory release controls, not optional hardening. Protect `main`
and limit creation of `health4ai-v*` tags to trusted maintainers as well. The
workflow independently refuses manual dispatches from any ref other than
`main`, but GitHub environment rules protect the secrets even if workflow code
is changed in an untrusted branch.

Keep secret values out of the repository, logs, and chat.

| Secret | Value |
| --- | --- |
| `APPSTORE_CONNECT_API_KEY_ID` | App-scoped individual App Store Connect API key ID with the narrowest upload-capable role (Developer is preferred) |
| `APPSTORE_CONNECT_ISSUER_ID` | App Store Connect API issuer UUID |
| `APPSTORE_CONNECT_PRIVATE_KEY` | Full contents of the matching `.p8` private-key file |
| `APPLE_DISTRIBUTION_CERTIFICATE_BASE64` | Base64 of an Apple Distribution `.p12` certificate |
| `APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD` | Password for that `.p12` file |
| `IOS_APP_STORE_PROVISIONING_PROFILE_BASE64` | Base64 of the App Store provisioning profile for `com.jglittell.health4ai` |
| `KEYCHAIN_PASSWORD` | A unique random password used only for the ephemeral GitHub runner keychain |

Use an App Store provisioning profile and Apple Distribution certificate—not a
development profile/certificate. The runner imports them only for the job and
never writes them to the repository. The workflow does not create or modify
Apple certificates or provisioning profiles.

Do not use a team-wide API key or an App Manager key when an app-scoped
individual Developer key is available; the workflow only needs upload access
for Health4AI.

## Release procedure

1. Merge the intended, reviewed commit to `main`.
2. In GitHub Actions, run **Upload Health4AI to TestFlight** from `main`; or
   push a reviewed tag such as `health4ai-v1.0.1`. Tagged commits must be
   reachable from `main`; the workflow rejects tags on side branches.
3. The workflow stamps a UTC timestamp build number, archives, and uploads it.
4. Wait for App Store Connect processing. Verify the build is `VALID` and that
   its chosen TestFlight group is in the expected state before inviting anyone.

The workflow records the Xcode version used by the `macos-15` runner in its
job log. Treat a deliberate runner/Xcode update as a release-infrastructure
change and validate it with a manual dispatch before relying on it for a beta.

The workflow uploads an App Store Connect build eligible for either internal
or external TestFlight groups. External testers still require the normal Beta
App Review and should use their own Supabase project as described in
[`TESTFLIGHT-BETA.md`](TESTFLIGHT-BETA.md).

## Safety controls

- One release job at a time; queued jobs are never cancelled mid-upload.
- No TestFlight upload on ordinary pushes or pull requests.
- Secrets are scoped to the `testflight` environment, which must require a
  reviewer and restrict deployments to `main` / `health4ai-v*` before secrets
  are released to a runner.
- Build numbers come from UTC time, avoiding collisions with existing builds.
