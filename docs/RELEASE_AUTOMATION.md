# Automated Release

This repository uses two GitHub Actions workflows:

- `.github/workflows/build.yml`: builds an unsigned Universal (`arm64 + x86_64`) Release app for pushes, pull requests, and manual runs, then uploads a ZIP artifact and SHA-256 checksum.
- `.github/workflows/release.yml`: when a `v*` tag is pushed, it builds the unsigned Release app, packages both ZIP and DMG files, generates SHA-256 checksums, and publishes them to the matching GitHub Release.

No Developer ID certificate, Apple notarization account, or repository secrets are required.

## Publishing a release

The Git tag is the source of truth for the app version. For example:

```bash
git checkout main
git pull
git tag v1.2.0
git push origin v1.2.0
```

The release workflow will:

1. Resolve `1.2.0` from tag `v1.2.0`.
2. Build Release for both `arm64` and `x86_64` with code signing disabled.
3. Verify the resulting app is a Universal binary and remains unsigned.
4. Set `CFBundleShortVersionString` from the tag.
5. Create `iClipboard-1.2.0.zip`.
6. Create `iClipboard-1.2.0.dmg` with an Applications shortcut.
7. Generate `SHA256SUMS.txt`.
8. Create or update the corresponding GitHub Release automatically.

The workflow also supports branch/manual runs for packaging tests. These test runs upload artifacts only and do not publish a GitHub Release.

## Note about unsigned builds

This intentionally matches the project's current distribution model: the app is not Developer ID signed or notarized. macOS Gatekeeper may therefore warn users when they open a downloaded build.
