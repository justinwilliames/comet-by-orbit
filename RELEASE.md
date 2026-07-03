# Release runbook — Comet

How to ship Comet, and what to do if the Sparkle signing key is ever lost or compromised.

---

## Normal release flow

```bash
# from repo root
git tag v0.X.Y
git push origin v0.X.Y
```

CI (`.github/workflows/release.yml`):
1. Skip-duplicate gate (avoids rebuilding tagged commits also pushed to `main`).
2. Generates Xcode project via `xcodegen`.
3. Builds an unsigned `Comet.app`, then **replaces the linker-signed stamp with an explicit ad-hoc signature** (`codesign --force --deep --sign -`). This is the highest-trust signature macOS will treat as a stable identity for unsigned distribution; TCC honours it.
4. Packages as `Comet-vX.Y.Z.dmg`.
5. Signs the `.dmg` with the Ed25519 Sparkle key (secret `SPARKLE_ED_PRIVATE_KEY`).
6. Generates `appcast.xml`.
7. Creates a tagged GitHub Release (non-prerelease) with both files attached.

Pushing to `main` without a tag publishes a rolling `latest` prerelease.

**Internal Swift symbols and the Xcode target/module are named `Comet`** (`CometApp`, module `Comet`, `CometTests`, `Comet.xcodeproj`). This diverges from upstream `Whispur`, so a `git merge upstream/main` may conflict on the renamed `@main` app struct and the module name — resolve those in favour of the `Comet` names. Behaviour-level fork-local files (`Prompts.swift`, `DictationPipeline.swift`) still align with upstream and remain candidates to offer back.

---

## Sparkle keys — what's where

| Item | Location | Purpose |
|---|---|---|
| Public key | `Sources/Resources/Info.plist` → `SUPublicEDKey` | Baked into every shipped `.app`. **Do not change** unless rotating (see below). |
| Private key | GitHub Actions secret `SPARKLE_ED_PRIVATE_KEY` on `justinwilliames/comet-by-orbit` | Signs the `.dmg` in CI. Cannot be read back once set. |
| Local Keychain copy | macOS Keychain, account `orbit-dictation` (per memory rule) | Local development copy. Treat as authoritative second source. |
| Offline backup | **Required** — see DR section below. | If the GH secret AND Keychain are both lost, this is the only path back. |

---

## ⚠️ Sparkle private-key disaster recovery

**If the Sparkle private key is lost from all locations, every existing install loses its update chain forever** unless you migrate users to a new key.

### 1. Verify all three sources are populated and aligned

Run this once per release cycle:

1. Confirm GH Actions secret `SPARKLE_ED_PRIVATE_KEY` is set on the repo.
2. Confirm the Keychain entry exists (`security find-generic-password -s 'Sparkle Sign Update' -a 'orbit-dictation'`) and matches.
3. Confirm an encrypted offline backup exists in 1Password (account: `Comet Sparkle Ed25519 private key`).

The matching public key (from `Info.plist`'s `SUPublicEDKey`) should be derivable from any of the three private-key copies — Sparkle's `sign_update` tool prints the public key it would sign with, useful for cross-check.

### 2. Backups (do this NOW if you haven't)

GitHub does not allow reading a secret back. If the repo is deleted or the secret is rotated, the key is gone.

**Recommended belt-and-braces backup:**

1. **Local Keychain entry** — already in place per the memory rule (`account: orbit-dictation`).
2. **1Password vault entry** — secure note labelled `Comet Sparkle Ed25519 private key` in a vault you control. Include the matching public key for cross-check.
3. **Encrypted off-site archive** — encrypted APFS sparse bundle on a second machine or external drive.

### 3. If the key is lost — choose a path

**Option A: Recover from offline backup.**
Restore from 1Password or Keychain into the GH Actions secret. Update flow resumes. No user impact.

**Option B: Generate a new keypair (only if A is impossible).**

1. Generate a new Ed25519 keypair using Sparkle's `generate_keys`.
2. Update `SUPublicEDKey` in `Sources/Resources/Info.plist` to the new public key.
3. Set the new private key as `SPARKLE_ED_PRIVATE_KEY` in GH Actions secrets, plus the local Keychain copy.
4. Ship a new tagged release.

**The cost:** every existing install still has the *old* `SUPublicEDKey` baked in. Sparkle will refuse to install the new release because the signature won't verify. Existing users are stuck on the previous version forever — there is no automated migration path. They must manually re-download from GitHub Releases (or `get.yourorbit.team` once that hosts a download link) and re-install.

This is why offline backup matters.

### 4. If the key is leaked (publicly disclosed)

A leaked private key means an attacker can sign their own `.dmg` and trick Sparkle into installing it as an "update."

1. **Immediate:** rotate to a new keypair (Option B), accepting user-impact cost.
2. **Notify:** post in the repo, README, and on the website. Users should manually re-download.
3. **Audit:** scan GitHub Releases for any `.dmg` you didn't sign. Delete the artifact and tag if found.

---

## Other ops notes

- **Notarization is not configured.** The app ships ad-hoc-signed (no Apple Developer ID). Users must run `xattr -dr com.apple.quarantine "/Applications/Comet.app"` after each install. Once the Developer ID is provisioned:
  - Replace the ad-hoc `codesign --sign -` step with `codesign --sign "Developer ID Application: ..."`.
  - Add `xcrun notarytool submit` + `xcrun stapler staple` after `.dmg` creation.
  - Remove the ad-hoc-signing block — at that point macOS handles trust via notarization.
  - Drop `CODE_SIGNING_ALLOWED=NO` from the `xcodebuild` step.
- **Hardened runtime is intentionally NOT enabled** in the ad-hoc path. Sparkle.framework fails to load when hardened-runtime is on without matching entitlements. Revisit when notarization lands.
- **Fork hygiene:** any improvements to upstream-aligned files (Prompts.swift, DictationPipeline.swift output guardrails) are candidates to offer back to Whispur upstream rather than diverge silently.
