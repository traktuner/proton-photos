# Security / E2EE Audit - 2026-06-30

Scope: local session handling, SDK secret cache, account-data cache, thumbnails, previews, originals, video block cache, export path, sign-out purge, and cold-start behavior.

## Result

No plaintext session store remains. The production session is stored only in macOS Keychain (`me.protonphotos.mac.session`) with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

Thumbnail, preview, and original disk caches are encrypted at rest with AES-GCM. The key is derived from the restored Proton session secret and account UID, so startup needs the session Keychain item only, not an additional cache-key prompt.

SDK decrypted key material is in-memory only. The app purges legacy `secrets.sqlite`, `secrets.sqlite-wal`, and `secrets.sqlite-shm`, and the SDK config deliberately omits `secretCachePath`.

Account data needed for offline cold start is encrypted at rest via AES-GCM and derived from the session secret. Sign-out clears it.

Video seek cache persists encrypted Proton blocks only, not decrypted video ranges.

## Fix Landed In This Pass

Live Photo motion playback had a plaintext local-file workaround: the paired motion video was downloaded/decrypted and written to a temporary `.mov` so `AVPlayer(url:)` could play it. That violates the local E2EE rule because a crash or filesystem inspection could expose decrypted video bytes outside Keychain-protected cache encryption.

The plaintext motion-tempfile path is removed. Live Photo stills and the badge remain, but motion playback is a no-op until it can use a stable secure streaming path. A guard test now forbids `temporaryDirectory`, `proton-motion-*`, and `AVPlayer(url:)` in `PhotoViewerModel`.

## Existing Guards

- `SessionHardeningTests`: no plaintext developer session switch and Keychain round trip.
- `SecureThumbnailCacheTests`: ciphertext does not contain PNG bytes, wrong account/key/context fails, corrupt blobs are deleted, sign-out removes blobs and keys, configured cache survives relaunch, originals use derivative-specific AAD, legacy plaintext dirs are purged.
- `ProductionRouteGuardTests`: shared configured grid cache, encrypted account data cache, originals read-before-network + purge wiring, SDK secret cache in-memory only, no decrypted Live Photo motion tempfiles.

## Keychain Password Prompt Explanation

The startup password dialog is consistent with macOS Keychain ACL behavior for development builds. Keychain access is tied to the app's code-signing requirement. Rebuilding, switching between debug/release, changing signing identity, or launching a fresh generated project can make macOS treat the app as a different accessor for the same `me.protonphotos.mac.session` item. The app also re-saves the restored session once to migrate older debug items under the current signature, but the first read can still trigger the system prompt.

Expected production behavior: a stable, signed/notarized app with a stable bundle identifier and signing team should stop prompting after the user allows access. In dev builds, "Immer erlauben" authorizes the current signing requirement; another rebuild/signing change can prompt again.

## Residual Risks / Follow-Ups

- The hardened-runtime entitlements currently include `disable-library-validation`, `allow-unsigned-executable-memory`, and `allow-jit` for the embedded Proton Drive SDK/.NET runtime. Before distribution, verify each entitlement is still required and remove any that is not strictly necessary.
- Live Photo motion playback is disabled by security policy until a memory-only or encrypted-at-rest streaming path is stable.
- Export intentionally writes decrypted originals to the user-selected destination. This is user-initiated output, not app cache. Partial ZIP exports are deleted on failure/cancel.
- Debug logging writes to `/tmp/protonphotos.log` only when `PROTONPHOTOS_DEBUG_LOG=1` in DEBUG builds. Keep it disabled for normal QA and release.

## Verification

Commands run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter GridResizePresentationTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProductionRouteGuardTests
```

All passed at the time of this audit.
