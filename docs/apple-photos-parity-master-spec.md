# Apple Photos Parity Master Spec

Status: AUTHORITATIVE PRODUCT SPEC.

This file is the product-level source of truth for ProtonPhotos. If this file conflicts with a lower-level
engine contract, implementation note, test name, previous prompt, or architecture convenience, this file wins.
The lower-level document or test must then be updated in the same change.

## Prime directive

ProtonPhotos must behave like Apple Photos wherever Apple Photos behavior is known from reference footage or
direct observation.

Architecture is not a product decision. If the current architecture cannot express accepted product behavior, the
architecture must change. Apple Photos is the default behavioral target; explicit product overrides in this file
are equally authoritative and exist only when strict Apple copying would hurt cross-screen or future iOS/iPad UX.

Allowed questions are only:
- whether Apple behavior is actually known for this exact case,
- which reference video/frame proves it,
- what the smallest regression-safe implementation plan is.

Forbidden questions:
- whether Apple parity is still desired,
- whether an existing ProtonPhotos engine model should be kept despite diverging from Apple,
- whether a non-Apple behavior is acceptable because it is easier,
- whether the grid should be a Swiss-army-knife UI instead of a Photos-like app.

Allowed product overrides:
- A deliberate responsive design choice may override an observed Apple detail when it makes ProtonPhotos scale
  better across compact Mac windows, wide/8K displays, iPad, and iPhone.
- Such an override must be written in this file, scoped narrowly, and must preserve the Apple-like feel: no
  abrupt jumps, no thumbnail squeezing, no tile breathing, no black frames, no interaction regression.

## Reference hierarchy

1. Apple Photos reference videos supplied by the user.
2. Frame-by-frame analysis derived from those videos.
3. This master spec.
4. Feature-specific specs and prompts.
5. Engine contracts and implementation docs.
6. Current code.

If current code or docs disagree with Apple behavior or an explicit product override in this file, they are stale.

Known reference files used repeatedly:
- `/Users/thomas/Desktop/grid zoom.mov`
- `/Users/thomas/Desktop/Bildschirmaufnahme 2026-06-24 um 10.35.59.mov`
- `/Users/thomas/Desktop/rezise.mov`
- `/Users/thomas/Desktop/seitenleiste aus-einblenden.mov`
- `/Users/thomas/Desktop/Bildschirmaufnahme 2026-06-26 um 21.29.51.mov`

## Grid resize truth

Apple Photos is the target. The **accepted resize model is FIXED-COLUMNS-PER-LEVEL + WIDTH-FILL** (decided
2026-06-28): each zoom level HOLDS a fixed column count (its density: 3/5/7/9/20/30); the square tile is sized to
FILL the viewport width exactly, so a wider window / hidden sidebar makes the tiles physically LARGER (more
pixels per photo) at the SAME column count. The column count changes ONLY on a zoom (level change), NEVER on a
window resize or sidebar toggle.

The grid resize model must never squeeze or distort thumbnails:
- A zoom level defines an Apple-like density / thumbnail-scale policy, not arbitrary per-frame stretching.
- A window/sidebar width change SCALES the tile to fill the new width at the level's fixed column count - a smooth
  uniform scale (Apple's "scale the surface like a photo"), not a column reflow and not a squeeze.
- A vertical resize clips/reveals rows at a constant column count and constant tile size.
- A corner resize composes the two: scale-to-fill horizontally, clip/reveal vertically; thumbnails are never
  distorted.
- The grid FILLS the width (no trailing gutter); slots stay square; media aspect-fits inside the square slot.

A **responsive level policy** (column caps / per-size-class scaling for very wide or future iOS/iPad displays)
remains an **explicitly RESERVED future option** - see `GridSizePolicy` - but is **NOT the currently-adopted
rule**. Today, on every desktop width, a level shows its fixed column count and scales the tile to fill. `L0 =
Apple's largest-photo feel` is the product requirement; `L0 = 3 columns` holds at every desktop width today. Any
future responsive policy must be explicit, platform-neutral, test-covered, and must still never breathe/squeeze
during a live resize (use clip/reveal + discrete steps).

## Grid zoom truth

Apple Photos zoom/pinch behavior is the target.

Required behavior:
- Pinch is continuous and finger-driven.
- Slow pinch maps one-to-one to grid progress.
- The user can pause, micro-adjust, and continue while the grid follows.
- Fast pinch behaves like a quick detent step.
- Short decisive pinch gestures settle to the next appropriate level.
- The item or region under the cursor/fingers remains the zoom anchor.
- Release settles smoothly to the nearest or velocity-biased detent.
- No release may jump to an unrelated photo or region.
- No topology pop is allowed at commit.

Implementation detail:
- If a current detent ladder, column phase, or focus-row model conflicts with this behavior, redesign it.
- Do not weaken Apple parity to preserve an older detent implementation.

## Sidebar truth

Apple Photos sidebar behavior is the target.

Required behavior:
- The sidebar may be Liquid Glass/transparent according to current Apple design.
- Photos may visually move behind the sidebar during pinch/resize when Apple does that.
- Photos behind the sidebar must not be clickable.
- There must be normal grid breathing room after the sidebar in settled layout when Apple shows it.
- Sidebar show/hide must not jitter the grid.
- Sidebar show/hide is a resize/layout event, not a fade or snapshot trick.

## Window resize truth

Apple Photos window resize behavior is the target.

Required behavior:
- Pure height resize clips/reveals vertically without reflow jitter.
- Pure width resize scales the tile to fill the new width at a constant column count (columns change only on zoom).
- Corner resize follows Apple's observed behavior, not ProtonPhotos convenience behavior.
- No black frames, empty holes, late jumps, or scroll snaps after resize.

## UI truth

Apple-native UI is the target.

Required behavior:
- Use native AppKit/SwiftUI controls and materials where Apple provides them.
- Liquid Glass should be a system-native direction, not a hand-painted approximation, whenever the SDK supports it.
- Toolbars, sidebars, modals, popovers, buttons, checkboxes, sliders, onboarding, loading surfaces, and viewer chrome
  must be reviewed against Apple Photos-like native behavior.
- ProtonPhotos-specific controls are allowed only where the product needs them, such as upload/download.

## Security truth

Proton-style E2EE expectations are non-negotiable.

Required behavior:
- Local decrypted media, thumbnails, cache metadata, and secrets must be protected at rest.
- Keychain-backed access must be deliberate and auditable.
- If a cache cannot be wrapped safely, it must be in-memory only or explicitly blocked.
- SDK behavior may be used when it matches Proton security expectations; otherwise document and fix the gap.

## Prompting rule for future agents

Every future agent prompt for grid, resize, zoom, sidebar, or UI work must include:

> Apple Photos parity is mandatory unless this master spec defines a narrow product override. Do not ask whether
> Apple parity is desired. If current architecture conflicts with observed Apple behavior or an explicit override,
> propose or implement the architecture change needed to match the accepted product behavior, with tests.

For implementation tasks, agents must:
- inspect current dirty worktree first,
- avoid overwriting unrelated uncommitted work,
- cite the relevant Apple reference file(s),
- state whether they changed product behavior or only implementation,
- add regression tests for every changed invariant.

## Forbidden fallback language

Do not write or accept:
- "good enough for ProtonPhotos" when Apple behavior is known,
- "current engine does not support it" as a stopping point,
- "keep fixed columns because the engine is built that way",
- "corner resize can be different because it is easier",
- "fixed size everywhere because it is simpler" when a responsive policy is the accepted product behavior,
- "we can tune this later" for abrupt jumps, snaps, or topology pops.

The correct framing is always:

Accepted product behavior first. Architecture follows.
