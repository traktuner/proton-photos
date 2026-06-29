# GridZoomTransaction — engine-owned live zoom

Status: **IMPLEMENTED.** `GridZoomTransaction` is the engine-owned live-pinch / cursor-anchor transaction in
production, and continuous live pinch is the production default (driven via `PinchLiveZoomDriver` /
`GridTransitionController`; see `PHASE_B_GRID_EFFECTS_INTEGRATION.md`). The transaction model and the
continuity / anchor rules this document specifies below remain the contract.

## Why a transaction (and not a per-frame plan)

A continuous pinch must NOT be implemented by calling `zoomFramePlan(continuousLevel:)` every frame. That
re-resolves a whole grid from the apparent slot size, so `columnCount` changes mid-gesture and the placement
formula

    slot = emptyTopLeft + item ; row = slot / columns ; column = slot % columns

**rewraps every flat index** (and `emptyTopLeft` shifts each section's phase). Result: the thumbnails at every
screen position shuffle — the "jumps to unrelated index regions" failure seen on video. Holding one anchor
item does not help, because the whole neighbourhood rewraps around it.

## The model (owned by the engine)

`GridZoomTransaction` is captured ONCE at gesture start and resolves frames WITHOUT re-wrapping per frame:

Captured state:
- `sourceLevel`, `targetLevel` (the adjacent detent in the gesture direction; only crossed at a boundary)
- `sourceGrid: ResolvedGrid`, `targetGrid: ResolvedGrid` (both fixed for the gesture)
- `sourceFramePlan`, `targetFramePlan`
- `anchorItem` (global index) + `anchorLocalFraction`
- `anchorViewportPoint` (held fixed — zoom is directed here, the cursor)
- `focusRow`: the row under the cursor in the SOURCE grid
- `sourceFocusRowItems`: the global indices occupying that focus row at gesture start

Per-frame output (progress `t` in 0…1 toward the target detent):
- Interpolate apparent slot size / gap between source and target (visual scale only).
- Position cells from the FIXED source topology, scaled around `anchorViewportPoint` — **no re-wrap**.
- Only at a committed level boundary do we adopt `targetGrid`'s topology (one controlled transition).

## The focus-row rule (the hard requirement)

During the live drag, the **row under the cursor must keep its thumbnail identities** until late in the
transition. Slot size and gap may change; the *items* in that row may not be rewrapped early into unrelated
indices. Rows farther from the cursor may transition (re-wrap to the target topology) earlier. This is what
makes the zoom read as "directed toward the photo under the cursor" rather than a global reshuffle.

Concretely, a transition plan assigns each visible cell a source-identity and a target-identity plus a
per-cell progress that is **gated by focus distance**: focus-row cells reach the target topology last; far
cells first. (No crossfade/opacity work yet — identity/position continuity first.)

## Hard constraints (carried over from the canonical-engine rules)

- The engine owns ALL of this. The coordinator/renderer must not compute positions, gaps, columns, or
  edge-fill. No `sourcePlate` / `targetWall` / `exposedLeft/RightRect` coordinator hacks.
- No Apple-style crossfade and no thumbnail-transition work in this step — identity/position continuity only.
- `zoomFramePlan(continuousLevel:)` stays as a building block but must be wrapped by the transaction's
  source/target topology continuity, never called raw per frame.

## Acceptance (future)

- During a slow pinch, the focus-row photos stay identity-stable; the grid does not rewrap every frame.
- The anchor item stays under the cursor; the visible neighbourhood overlaps highly frame-to-frame
  (`GridZoomNeighborhoodTests` thresholds, extended to continuous frames).
- Release snaps to a detent with the cursor item preserved (already true for the discrete path).
