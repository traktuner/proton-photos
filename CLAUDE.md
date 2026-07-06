# Agent briefing — proton-photos

NOTE for opencode: this project file REPLACES the global ~/.config/opencode/AGENTS.md (no merge).
The always-loaded global rules (~/.config/opencode/rules/*: Lumo constraints, guardrails incl.
definition-of-done, engineering principles) still apply. Routing reminder: Basic for volume,
Plus for reasoning, Codex only via the gated codex-escalate tool; delegated diffs are proposals
until reviewed.

## Build protocol for agent loops (fast inner loop, one final gate)

Builds here are EXPENSIVE (app xcodebuild 50-70s; Scripts/rebuild.sh does clean + tests + TWO
destination builds; verify-universal-core.sh loops schemes x destinations). Therefore:
- Inner loop (while iterating): target-scoped only — `swift build --package-path
  Packages/ProtonPhotosKit --target <ChangedTarget>` (seconds), or `swift test --package-path
  Packages/ProtonPhotosKit --filter <RelevantTests>`. NEVER run rebuild.sh / verify-*.sh here.
- Final gate (ONCE, when the change is believed complete). IMPORTANT: xcode-select on this
  machine points to CommandLineTools — bare `xcodebuild` fails and `sudo xcode-select` is NOT
  available to agents (no TTY). ALWAYS prefix DEVELOPER_DIR; never attempt sudo:
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
   -project ProtonPhotos.xcodeproj -scheme ProtonPhotos -configuration Debug \
   -destination 'platform=macOS,arch=arm64' -quiet -skipMacroValidation \
   -skipPackagePluginValidation -disableAutomaticPackageResolution build`
- Scripts/rebuild.sh and verify-*.sh are CI/user-invoked gates — run them only when explicitly asked.
