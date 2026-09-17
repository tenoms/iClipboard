# Automated Build and Release

The repository uses a single GitHub Actions workflow: `.github/workflows/build.yml`.

It builds the macOS Release app as a Universal binary (`arm64 + x86_64`) with Xcode project signing disabled. No Developer ID certificate, Apple notarization account, or repository secrets are required.

## When it runs

- Pull request to `main`: build and upload a test artifact.
- Push to `main`: build and upload a test artifact.
- Push a `v*` tag: build, package, and publish the matching GitHub Release.
- Manual run: build only, or provide a tag to publish/refresh that release.

The workflow uses concurrency cancellation for non-tag runs, so repeated updates to the same PR do not leave multiple active builds running.

## Publishing a release

The Git tag is the source of truth for `CFBundleShortVersionString`. For example:

```bash
git checkout main
git pull
git tag v1.2.0
git push origin v1.2.0
```

The workflow will:

1. Resolve `1.2.0` from tag `v1.2.0`.
2. Build Release for both `arm64` and `x86_64` with project code signing disabled.
3. Verify the Universal binary and bundle metadata.
4. Confirm no identity/Developer ID signing authority is present. A linker/ad-hoc signature produced by modern Xcode is allowed.
5. Package the app as `iClipboard.app.zip`.
6. Generate `SHA256SUMS.txt`.
7. If the release already exists, replace only its assets and keep the existing title/description unchanged.
8. Otherwise, create the GitHub Release automatically.

## Current release migration

The file `.github/repackage-current-release` is a one-time migration trigger. When this PR first lands on `main`, the workflow uses the current latest GitHub Release tag, rebuilds that same version automatically, replaces its package asset without changing the release description, deletes the migration branch, and removes the trigger in a `[skip ci]` cleanup commit.

## Note about distribution signing

This intentionally matches the project's current distribution model: there is no Developer ID signing or Apple notarization. macOS Gatekeeper may therefore warn users when opening a downloaded build.
