# Automated Release Setup

The repository contains two workflows:

- `.github/workflows/build.yml`: builds a Universal (`arm64 + x86_64`) Release app on pushes, pull requests, or manual runs. The CI artifact is ad-hoc signed and is intended for testing only.
- `.github/workflows/release.yml`: when a `v*` tag is pushed, it builds, Developer ID-signs, notarizes, staples, packages a DMG, generates SHA-256 checksums, and publishes the GitHub Release.

## One-time GitHub Secrets

Add these repository secrets under **Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `MACOS_CERT_P12_BASE64` | Base64-encoded Developer ID Application `.p12` certificate + private key |
| `MACOS_CERT_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_API_KEY_P8_BASE64` | Base64-encoded App Store Connect API `.p8` key used by `notarytool` |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect issuer ID |

### Encode the signing certificate

Export your **Developer ID Application** certificate and its private key from Keychain Access as a password-protected `.p12`, then run:

```bash
base64 -i DeveloperID.p12 | pbcopy
```

Paste the result into `MACOS_CERT_P12_BASE64`.

### Encode the notarization API key

For the downloaded `AuthKey_XXXXXXXXXX.p8` file:

```bash
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

Paste the result into `APPLE_API_KEY_P8_BASE64`. Add the corresponding key ID and issuer ID to the other two secrets.

## Publishing a release

The tag is the source of truth for the app version. For example:

```bash
git checkout main
git pull
git tag v1.2.0
git push origin v1.2.0
```

The release workflow overrides `MARKETING_VERSION` with `1.2.0` and uses the GitHub Actions run number as `CURRENT_PROJECT_VERSION`.

The workflow then:

1. Builds Release for `arm64 + x86_64`.
2. Verifies bundle ID and version.
3. Imports the Developer ID certificate into a temporary keychain.
4. Signs `iClipboard.app` with Hardened Runtime and the checked-in entitlements.
5. Submits the app to Apple notarization and staples the result.
6. Creates `iClipboard-<version>.dmg` with an Applications shortcut.
7. Notarizes and staples the DMG.
8. Creates `SHA256SUMS.txt`.
9. Creates or updates the matching GitHub Release.
10. Deletes temporary signing/notarization credentials from the runner.

Do not use the CI artifact from `build.yml` as a public release; it is intentionally ad-hoc signed and not notarized.
