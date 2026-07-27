# Beta release checklist

This checklist is for a direct-distribution beta. A release is not complete
until every required item is evidenced against the exact archive being
published.

## Prepare

- [ ] Choose a version and monotonically increasing build number.
- [ ] Confirm `main` is clean and points at the intended release commit.
- [ ] Review `README.md`, `docs/PRODUCT.md`, and `docs/ROADMAP.md` for claims
  that exceed implemented behaviour.
- [ ] Confirm no secrets, personal host names, user-specific paths, fixtures
  from real configurations, or generated build products are tracked.
- [ ] Run the release-candidate accessibility checks in
  `docs/ACCESSIBILITY_AUDIT.md`.
- [ ] Review `docs/PRIVACY.md` and `docs/SECURITY.md`.

## Verify

- [ ] Run `./scripts/verify.sh`.
- [ ] Review the documented safety invariants and run the full regression
  suite against the exact release commit.
- [ ] Exercise every required row of the release acceptance matrix with
  temporary local and disposable SSH fixtures.
- [ ] Confirm mutation tests never target the developer's real home directory
  or a production host.
- [ ] Confirm unknown, partial, denied, offline, and recovery states remain
  explicit.

## Sign and notarize

1. Store notarization credentials in Keychain:

   ```bash
   xcrun notarytool store-credentials KITROOM_NOTARY
   ```

2. Export the exact Developer ID Application identity and Keychain profile for
   the release shell:

   ```bash
   export KITROOM_SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)"
   export KITROOM_NOTARY_PROFILE="KITROOM_NOTARY"
   ```

3. Build, sign, package, notarize, staple, and assess:

   ```bash
   ./scripts/package-release.sh
   ```

The script refuses ad-hoc signing and does not accept Apple credentials on the
command line. It creates a ZIP in `dist/`, submits that ZIP with `notarytool`,
staples the ticket to the application bundle, verifies the ticket, rebuilds the
ZIP from the stapled bundle, and runs Gatekeeper assessment.

## Publish

- [ ] Record the SHA-256 digest and file size of the final ZIP.
- [ ] Install on a separate supported Mac that has never run this build.
- [ ] Confirm Gatekeeper opens the app without override instructions.
- [ ] Run a read-only local scan and an SSH-host discovery.
- [ ] Publish release notes, privacy documentation, known limitations, digest,
  and minimum macOS version.
- [ ] Keep update checking manual or notification-only for the first beta.

## Roll back a bad release

- [ ] Remove the affected download from the release page.
- [ ] Publish a clear advisory without including secrets or host details.
- [ ] Preserve the rejected artifact, notarization log, and release commit for
  investigation.
- [ ] Never silently replace an artifact while retaining its version or
  digest.
