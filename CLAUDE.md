# Agent briefing — proton-photos

NOTE for opencode: this file is auto-loaded every task (project AGENTS.md/CLAUDE.md). The
always-loaded global rules (~/.config/opencode/rules/*: Lumo constraints, guardrails incl.
definition-of-done, engineering principles) also apply. Routing reminder: Basic for volume,
Plus for reasoning, Codex only via the gated codex-escalate tool; delegated diffs are proposals
until reviewed.

## Product & architecture invariants (apply to EVERY change — read first)

1. **Cross-platform by default.** Features are CORE features and run on macOS AND iOS/iPadOS.
   Put logic in a shared `Packages/ProtonPhotosKit/Sources/*Core` (or `*Feature`) module; only
   genuine view-hosting goes in `*UIKitAdapter` (iOS) / `*AppKitAdapter` (macOS). About to write
   the same behavior twice per platform? STOP — extract it to Core.
2. **Shared code exists ONCE.** Before adding any helper, SEARCH for an existing one and reuse it —
   never duplicate. Mandatory reuse (do not re-implement):
   - Reverse-geocoding / place names → `PhotoViewerCore/PlaceNameResolver.swift`
     (never call CLGeocoder directly in a view).
   - Location index / clustering → `MediaLocationCore` (PhotoLocationIndex, LocationCrawl).
   - Title/place formatting → `PhotoViewerCore/ViewerTitleFormatter.swift`.
   - Grid / selection / share / trash → reuse the existing `GridCore` + timeline feature/adapters
     and the existing selection paths; do not invent new interaction paths for a new screen.
   When unsure something exists, grep the `Sources/*Core` modules first.
3. **Generic, not one-off.** Solve the general case; no bespoke copy for a single screen.
4. **Liquid Glass is mandatory** for chrome (toolbars, badges, back buttons, overlays): use the
   shared `DesignSystemCore` + platform adapters; follow the repo's `LIQUID_GLASS_*.md` notes.
   Don't hand-roll divergent materials.
5. **Deep-dive docs** live in `*_DESIGN.md` / `*_AUDIT.md` / `LIQUID_GLASS_*.md` — consult the
   relevant one before touching that subsystem (e.g. `MAP_VIEW_DESIGN.md` for the map).

## Git rules (HARD — enforced by a pre-commit hook)

- **NEVER commit to `master`/`main`.** At the start of a change, create/switch to a
  `work/<topic>` branch (`git switch -c work/<topic>`) and commit THERE. The user merges into
  master deliberately. A `pre-commit` hook rejects direct commits on master.
- **NEVER** run `git reset --hard`, `git clean -fd`, `git commit --amend` on shared history,
  force-push, or `git add -f` a gitignored file (e.g. the xcodegen-generated
  `ProtonPhotos.xcodeproj/` — line 9 of .gitignore; regenerate with `xcodegen generate`, never
  commit it). These have twice destroyed uncommitted work here.
- Small, single-purpose commits. A delegated diff is a proposal until reviewed.

## Build protocol for agent loops (fast inner loop, one final gate)

HARD RULE — network repo: this repo lives on a TrueNAS SMB share (/Volumes/tom/...). NOTHING may
be built into the repo tree (no `.build/`, no `build/`, no DerivedData in the repo) — every object
file would go over the network. All build output goes to the local Mac under
`$PROTONPHOTOS_BUILD_ROOT` (default `~/Developer/xcode/ProtonPhotos`):
- SPM scratch: `~/Developer/xcode/ProtonPhotos/SPM.noindex` (ALWAYS pass `--scratch-path`)
- App derived data: `~/Developer/xcode/ProtonPhotos/DD.noindex` (scripts do this; ad-hoc
  xcodebuild must pass `-derivedDataPath` accordingly)

Builds here are EXPENSIVE (app xcodebuild 50-70s; Scripts/rebuild.sh does clean + tests + TWO
destination builds; verify-universal-core.sh loops schemes x destinations). Therefore:
- Inner loop (while iterating): target-scoped only — `swift build --package-path
  Packages/ProtonPhotosKit --scratch-path ~/Developer/xcode/ProtonPhotos/SPM.noindex --target
  <ChangedTarget>` (seconds), or `swift test --package-path Packages/ProtonPhotosKit
  --scratch-path ~/Developer/xcode/ProtonPhotos/SPM.noindex --filter <RelevantTests>`.
  NEVER run rebuild.sh / verify-*.sh here.
- Final gate (ONCE, when the change is believed complete). IMPORTANT: xcode-select on this
  machine points to CommandLineTools — bare `xcodebuild` fails and `sudo xcode-select` is NOT
  available to agents (no TTY). ALWAYS prefix DEVELOPER_DIR; never attempt sudo:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
   -project ProtonPhotos.xcodeproj -scheme ProtonPhotos -configuration Debug \
   -destination 'platform=macOS,arch=arm64' -derivedDataPath \
   ~/Developer/xcode/ProtonPhotos/DD.noindex -quiet -skipMacroValidation \
   -skipPackagePluginValidation -disableAutomaticPackageResolution build`
- Scripts/rebuild.sh and verify-*.sh are CI/user-invoked gates — run them only when explicitly asked.
