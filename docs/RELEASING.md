# Release engineering

MarkUp prepares **Developer ID signed, notarized Universal macOS apps** for GitHub
Releases. The workflow uploads review artifacts only. It does **not** create a
GitHub Release, change repository visibility, publish an appcast, or submit to the
App Store. Those are separate owner-authorized actions. See [the Turkish owner
walkthrough](OWNER_SETUP_TR.md) before configuring credentials.

No Git remote or production feed was configured during initial implementation.
Confirm the repository owner, Team ID, `com.bgoktugozdemir.MarkUp` bundle identifier,
and hosting URLs before distributing. The development app has no production feed
or embedded token. Blank feed/key settings intentionally disable updating.

## Build and trust boundaries

- `Checks` runs for PRs and `main` without distribution secrets. It validates
  localization, pinned dependencies/resources, executes native tests, and compiles
  and inspects both `arm64` and `x86_64` slices. `generic/platform=macOS` and
  `ONLY_ACTIVE_ARCH=NO` are mandatory for package modules as well as the app.
- Release preparation runs for `vMAJOR.MINOR.PATCH` tags. Manual dispatch must
  select such a tag. A protected `release` environment must restrict deployment
  tags to `v*` and require an owner review. Protect tag creation/deletion with a
  repository ruleset; tag only reviewed commits. There is no `pull_request_target`
  workflow, artifact reuse from untrusted builds, or PR code checkout with secrets.
- Hosted `macos-15` runners select Xcode 26.3 explicitly. The official image
  inventory was checked on 2026-10-30. Runner images can drift: a missing Xcode
  fails clearly; update the selected path only after reviewing the current image.
  The runner's host architecture is recorded, not inferred from the compiled slices.
  macOS 14 runtime and Intel runtime checks still require appropriate test machines.
- SPM/Xcode versions and revisions live in both `Package.resolved` files.
  Workflows request `-onlyUsePackageVersionsFromResolvedFile`; do not regenerate
  them silently in release jobs. Sparkle is pinned to 2.10.1.
- `.github/actions-lock.json` separately pins official action commits. Checkout
  v7.0.1 and upload-artifact v7.0.2 were verified using official release metadata and
  `git ls-remote`. Monthly Dependabot PRs must update/review both workflow SHA
  references and the lock manifest. Verify new tags against the owning repository;
  run `actionlint` and `python3 scripts/release-check.py` before merging. Do not
  replace immutable references with floating tags.

GitHub documents immutable pins and protected environment secrets in its [secure
use reference](https://docs.github.com/en/actions/reference/security/secure-use).
Current hosted tools are listed in the [macOS 15 image
inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md).

## Exact configuration

Create these **environment variables** in the protected `release` environment:

| Variable | Value / purpose |
| --- | --- |
| `RELEASE_ENABLED` | `true` only after the controls below are configured |
| `RELEASE_REPOSITORY` | The confirmed `OWNER/REPOSITORY`; must equal the running repository |
| `DEVELOPMENT_TEAM` | Ten-character Apple Developer Team ID |
| `DEVELOPER_ID_APPLICATION` | Full identity from `security find-identity -v -p codesigning`, e.g. `Developer ID Application: YOUR NAME (TEAMID)` |
| `MARKUP_UPDATE_FEED` | Public HTTPS URL for the owner's `appcast.xml`, without query/credentials |
| `MARKUP_UPDATE_PUBLIC_KEY` | Sparkle Ed25519 public key, base64 encoding of 32 bytes |
| `MARKUP_DOWNLOAD_URL_PREFIX` | Version-independent release base, e.g. `https://github.com/OWNER/REPOSITORY/releases/download`; script appends `/vVERSION/MarkUp-VERSION.zip` |

Create these **environment secrets**, never repository files or chat messages:

| Secret | Contents |
| --- | --- |
| `CERTIFICATE_P12_BASE64` | Base64 of exported Developer ID Application certificate **and private key** |
| `CERTIFICATE_P12_PASSWORD` | Strong password protecting that PKCS#12 export |
| `NOTARY_API_KEY_BASE64` | Base64 of a dedicated Team App Store Connect API `.p8` key |
| `NOTARY_KEY_ID` | The API Key ID |
| `NOTARY_ISSUER_ID` | The Team API key's Issuer UUID |
| `SPARKLE_PRIVATE_KEY` | Exact base64 text exported by Sparkle `generate_keys -x`; do not double-base64 it |

`RELEASE_VERSION_TAG` and `RELEASE_BUILD_NUMBER` are supplied by GitHub's tag name
and workflow run number. The latter is the app's monotonic `CFBundleVersion`, not
the marketing version. Never reuse or decrease it after a workflow migration.
No GitHub PAT or long-lived keychain password is needed. A random temporary
keychain password is generated per run and masked. GITHUB_TOKEN has contents-read
permissions only; artifact upload uses the Actions runtime token.

The script's `--preflight` mode reports missing names without importing secrets.
It validates base64 and expected key lengths before invoking Sparkle, because some
upstream invalid-input diagnostics can otherwise include malformed input.

## Certificate and notarization setup

The Account Holder creates/selects a **Developer ID Application** identity in
Xcode Settings → Accounts → Manage Certificates or the Developer portal. Developer
ID Installer is for signed installer packages and is not used for this app ZIP.
In Keychain Access → My Certificates, expand the identity and confirm its private
key exists before exporting both as a password-protected `.p12`. Exporting only
the public `.cer` cannot sign CI builds. Apple's [Developer ID certificate
guide](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
and [identity export
guide](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)
describe the account-owned operations.

Use a dedicated **Team API key** with the least role that passes notarization
validation for your team (start with Developer; avoid assigning Admin without a
specific need). The Account Holder/Admin must enable access and create the key.
Download the `.p8` once, store an encrypted offline backup, and record its Key ID
and Issuer ID. Team keys have broader account scope than a single app, so restrict
who can approve the environment. This workflow intentionally uses the Team-key
`--key/--key-id/--issuer` path. Individual-key eligibility differs across Apple
documentation/toolchain generations; do not substitute one without separately
validating the chosen Xcode. See Apple's [API key
guide](https://developer.apple.com/documentation/AppStoreConnectAPI/creating-api-keys-for-app-store-connect-api).

Validate locally without submitting an app:

```sh
xcrun notarytool store-credentials MarkUp-notary \
  --key /secure/location/AuthKey_KEYID.p8 --key-id YOUR_KEY_ID --issuer YOUR_ISSUER_UUID
```

If API-key creation is unavailable, the supported local fallback is an Apple
Account with 2FA, its **app-specific password**, and Team ID:

```sh
xcrun notarytool store-credentials MarkUp-notary \
  --apple-id YOUR_APPLE_ACCOUNT --team-id YOUR_TEAM_ID
# Enter the app-specific password at the secure prompt; never use the account password.
```

Then `notarytool submit --keychain-profile MarkUp-notary --wait ...` can be used
in a locally reviewed release procedure. The checked-in CI workflow uses API-key
secrets; changing CI to the fallback requires a reviewed adaptation of its secret
names/auth array. It is not silently selected. Apple's [notarization
workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
describes both authentication approaches and submission logs.

## Sparkle key and sandbox setup

After resolving the pinned Xcode packages:

```sh
.build/xcode-packages/artifacts/sparkle/Sparkle/bin/generate_keys --account MarkUp-release
.build/xcode-packages/artifacts/sparkle/Sparkle/bin/generate_keys --account MarkUp-release -x /secure/location/markup-update-private
```

The first command keeps the private seed in your login Keychain and displays the
public counterpart. Export only to encrypted/private storage, set
`SPARKLE_PRIVATE_KEY` from the export's contents, and put **only** the public key
in `MARKUP_UPDATE_PUBLIC_KEY`. Keep an offline encrypted recovery copy.

The app retains App Sandbox and enables Sparkle's Installer XPC service plus
the two bundle-specific `-spki`/`-spks` mach lookup entitlements. Its network-client
entitlement supports explicitly requested remote images and feed access, so the
Downloader service is not enabled separately. Xcode archive/export re-signs
Sparkle's nested services; the verifier checks the actual result. Follow
[Sparkle's sandbox
guide](https://sparkle-project.org/documentation/sandboxing/) instead of adding
`codesign --deep` to signing commands. `--deep` is used only for **verification**.

## What the release script does

1. Validate owner settings before keychain access; run secret-free static gates.
2. Create a private temporary directory/keychain, import the `.p12`, grant only
   signing-tool access, and preserve the prior user keychain search list.
3. Archive Release for `generic/platform=macOS` with both CPU architectures,
   Hardened Runtime, secure timestamps, manual Developer ID signing, and approved
   feed/public key build settings. Export with the checked-in developer-id plist
   template. No `-allowProvisioningUpdates` changes the owner's account implicitly.
4. Verify every actual Mach-O binary's two slices, nested signing team, runtime,
   timestamp, root sandbox, absence of get-task-allow, and embedded feed/key.
5. Submit an intermediate ZIP via `notarytool --wait`, retrieve the notarization
   log, require `Accepted`, staple the **app**, validate its ticket, and assess it
   with Gatekeeper. A 20-minute wait timeout fails rather than claiming success;
   use the printed submission ID with `notarytool log/history` to investigate.
6. Recreate the final ZIP using `ditto` to preserve framework symlinks. Only after
   stapling/package changes, sign these final bytes with Sparkle, verify the
   signature against the app's configured public key with CryptoKit, and generate
   the appcast. Require feed signature/length/download URL consistency.
7. Generate SHA-256 checksums and release evidence; move complete output to
   `artifacts/release`. Trap cleanup deletes credential files/keychain and restores
   the search list on success/failure/cancellation. Hosted runners are ephemeral;
   this workflow is not approved for persistent self-hosted runners.

This order follows [Sparkle's publishing
guide](https://sparkle-project.org/documentation/publishing/). Never edit the final
ZIP after signing, staple a ZIP, sign before stapling, or upload a preliminary ZIP.

## Owner review, update test, and publication

The preparation artifact includes `MarkUp-VERSION.zip`, `appcast.xml`, `SHA256SUMS`,
and `release-evidence.json`. CI artifacts are not public release assets. Confirm:

- Exact commit/tag, marketing/build versions, signing team, minimum macOS 14,
  both slices, notarization acceptance, ticket and Gatekeeper checks.
- Anonymous fixtures only; final app icon is still explicitly temporary until the
  separate GPT Image branding step. Replace the icon/assets before final archive.
- Runtime tests on Apple Silicon and Intel, macOS 14/15 fallback and current
  appearance, keyboard/VoiceOver, and performance gates recorded accurately.

Perform a **controlled N → N+1 test** in a disposable test user/VM or separate
staging app configuration with an isolated key, feed, and install path. The stock workflow/verifier intentionally requires `com.bgoktugozdemir.MarkUp`; use it only in a disposable VM or separate test account where no production installation or data exists. A distinct staging bundle ID requires a separately reviewed change to `project.yml`, the update entitlements, and `scripts/release-verify.py` before using this workflow.
Do not overwrite a real production installation. Build/install N, host N+1's
reviewed ZIP and staging appcast over HTTPS, check manually, then verify actual
download, installation, version change, relaunch, and sandbox access behavior.
Repeat offline, cancel, up-to-date, and update-failure states. In the isolated
feed, modify one ZIP byte without changing the signature; confirm rejection and
that N remains usable. Also test a wrong-key signature. Restore the valid feed.
The CryptoKit self-test in CI proves the cryptographic valid/tampered/wrong-key
boundary, **not** Sparkle installation/relaunch. Those end-to-end tests remain an
owner gate until real signing/feed setup exists.

After explicit publication approval, upload the final ZIP/checksums/evidence to
the matching GitHub tag release. Verify its public HTTPS download bytes against
`SHA256SUMS`, then publish the appcast at exactly `MARKUP_UPDATE_FEED`. Publish
the feed last so clients never see a missing archive. The initial generated feed
contains the prepared version only; when maintaining an established feed, merge
the reviewed new item into the existing feed and preserve supported older branch
items intentionally. No private GitHub token may be embedded in the app.

## Rotation, recovery, and the future App Store build

Rotate the certificate export/password before expiry and replace environment
secrets; validate a staged update first. Revoke compromised API keys in App Store
Connect, create a replacement with minimal scope, validate, and replace all three
notary secrets. Remove old GitHub secrets when no longer needed. If a credential
reaches a log, delete the log and rotate the credential; masking is not recovery.

Sparkle's two independent trust mechanisms permit rotating the EdDSA key or the
Developer ID identity in a bridging update, **not both at once**. Follow
[Sparkle's key-rotation
instructions](https://sparkle-project.org/documentation/) with a controlled staged
update before changing the production public key. Lost/compromised keys require
an explicit recovery plan; never weaken verification or silently replace keys.

A later App Store variant must remove `UpdateService`, Check for Updates and
automatic-update controls/localizations, the Sparkle package/framework/helpers,
`SU*` feed/key/service Info keys, and updater-only mach lookup exceptions. Retain
App Sandbox, user-selected access/bookmarks, Application Support annotations, and
user-controlled network access if remote images remain. Store-delivered updates
replace Sparkle. Decide data-container/bundle-ID migration explicitly. No App
Store target, purchases, subscriptions, or submission is implemented by this work.

## Readiness terminology

An unsigned development build proves compilation, not distribution trust. A
local archive adds archive evidence, not notarization. Signed/notarized assets
still need real architecture/OS/UI and controlled update-install checks plus owner
publication approval. Missing account credentials/hosting do not excuse skipping
independent development validation, and no unexecuted gate is marked passed.

Core performance can be reproduced separately, without private examples:

```sh
python3 scripts/generate-fixtures.py
MARKUP_RUN_PERFORMANCE=1 MARKUP_PERFORMANCE_REPORT=artifacts/core-performance.json \
  swift test -c release --disable-sandbox --filter PerformanceTests
```

The report records three samples for each 2,500/10,000/50,000-line public fixture,
actual host hardware/OS, parse/tokenization timing, and cumulative **test-process**
peak resident memory. It excludes app launch, image/layout/minimap work, display
readiness, app/helper memory, and idle CPU. Measure those through the real app
separately; do not compare core timings to the user-facing startup targets.
