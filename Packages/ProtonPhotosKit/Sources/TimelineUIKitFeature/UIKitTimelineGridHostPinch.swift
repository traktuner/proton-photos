#if canImport(UIKit)
import CoreGraphics
import GridCore
import MetalGridTextureCore
import MetalGridTextureUIKitAdapter
import PhotosCore
import UIKit

/// Live pinch zoom for the iOS grid host: the engine-owned `GridZoomTransaction`, the shared
/// lattice / reflow / overview-dissolve routing, and the release/settle/commit paths. Gesture and
/// presentation state only — the render loop in `UIKitTimelineGridHost.swift` draws whatever state
/// this machine leaves behind.
extension UIKitTimelineGridHostView {
    @objc func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let ctx = currentGridContext() else { return }
        let viewportPoint = gesture.location(in: self)
        switch gesture.state {
        case .began:
            beginLivePinch(ctx: ctx, viewportPoint: viewportPoint)
        case .changed:
            guard let startLevel = pinchStartLevel, zoomTransaction != nil else { return }
            let rawLevel = livePinchRawLevel(startLevel: startLevel, scale: gesture.scale)
            driveLivePinch(rawLevel: rawLevel, ctx: ctx)
            requestRender()
        case .ended, .cancelled, .failed:
            guard let startLevel = pinchStartLevel else {
                cancelLiveZoomState()
                requestRender()
                return
            }
            let rawLevel = livePinchRawLevel(startLevel: startLevel, scale: gesture.scale)
            endLivePinch(cancelled: gesture.state != .ended, rawLevel: rawLevel, startLevel: startLevel, ctx: ctx)
        default:
            break
        }
    }

    /// UIKit reports a cumulative scale; GridCore owns the shared logarithmic ladder tuning. Scale > 1 means zoom
    /// in, so the raw level moves toward lower ids.
    private func livePinchRawLevel(startLevel: Int, scale: CGFloat) -> CGFloat {
        CGFloat(startLevel) - GridPinchDensityPolicy.continuousLevelDelta(pinchScale: scale)
    }

    private func beginLivePinch(
        ctx: (engine: SquareTileGridEngine, level: Int, profile: GridLevelProfile),
        viewportPoint: CGPoint
    ) {
        finishInFlightPinchPresentation(engine: ctx.engine)
        commitBridgeTransaction = nil
        commitBridgeStart = 0
        pinchStartLevel = ctx.level
        pinchLockedOffsetY = scrollView.contentOffset.y
        let contentPoint = CGPoint(x: viewportPoint.x, y: viewportPoint.y + scrollView.contentOffset.y)
        zoomTransaction = ctx.engine.beginZoomTransaction(
            cursorContentPoint: contentPoint,
            viewportPoint: viewportPoint,
            level: ctx.level,
            width: bounds.width,
            columnPhase: committedPhase
        )
        guard zoomTransaction != nil else { return }
        zoomTransactionLevel = CGFloat(ctx.level)
        pinchMode = .undecided
        pinchSettling = false
        pinchBuiltSegment = nil
        pinchChainBand = eligiblePinchChainBand(engine: ctx.engine, startLevel: ctx.level)
        pinchDriver = PinchLiveZoomDriver(tuning: .init(from: gridTransition.tuning))
        pinchPrevSampleTime = CACurrentMediaTime()
        pinchAdvancePrevTime = 0
        userHasScrolledTimeline = true
        requestRender()
    }

    private func driveLivePinch(
        rawLevel: CGFloat,
        ctx: (engine: SquareTileGridEngine, level: Int, profile: GridLevelProfile)
    ) {
        let now = CACurrentMediaTime()
        let dt = pinchPrevSampleTime == 0 ? 1.0 / 60.0 : max(0, now - pinchPrevSampleTime)
        pinchPrevSampleTime = now
        switch pinchMode {
        case .lattice:
            let update = pinchDriver.update(continuousLevel: Double(rawLevel), dt: dt)
            if !applyLatticeSegment(update, engine: ctx.engine) {
                pinchMode = .reflow
                updateReflow(rawLevel: rawLevel, engine: ctx.engine)
            }
        case .overviewDissolve:
            driveOverviewDissolve(rawLevel: rawLevel)
        case .reflow:
            updateReflow(rawLevel: rawLevel, engine: ctx.engine)
        case .undecided:
            guard let start = pinchStartLevel else { return }
            let delta = Double(rawLevel) - Double(start)
            guard abs(delta) >= pinchDriver.tuning.directionResolveQ else { return }
            let next = start + (rawLevel < CGFloat(start) ? -1 : 1)
            if next >= pinchChainBand.lo, next <= pinchChainBand.hi {
                pinchMode = .lattice
                pinchDriver.begin(startLevel: start, chainLo: pinchChainBand.lo, chainHi: pinchChainBand.hi)
                let update = pinchDriver.update(continuousLevel: Double(rawLevel), dt: dt)
                if !applyLatticeSegment(update, engine: ctx.engine) {
                    pinchMode = .reflow
                    updateReflow(rawLevel: rawLevel, engine: ctx.engine)
                }
            } else if beginOverviewDissolveIfPossible(source: start, target: next, engine: ctx.engine) {
                pinchMode = .overviewDissolve
                pinchOverviewSource = start
                pinchOverviewTarget = next
                driveOverviewDissolve(rawLevel: rawLevel)
            } else {
                pinchMode = .reflow
                updateReflow(rawLevel: rawLevel, engine: ctx.engine)
            }
        }
    }

    private func updateReflow(rawLevel: CGFloat, engine: SquareTileGridEngine) {
        zoomTransactionLevel = GridLiveZoomBounds.visualLevel(rawLevel: rawLevel, levelCount: engine.levelCount)
    }

    private func endLivePinch(
        cancelled: Bool,
        rawLevel: CGFloat,
        startLevel: Int,
        ctx: (engine: SquareTileGridEngine, level: Int, profile: GridLevelProfile)
    ) {
        switch pinchMode {
        case .lattice:
            pinchDriver.release(cancelled: cancelled)
            pinchSettling = true
            pinchAdvancePrevTime = 0
            requestRender()
        case .overviewDissolve:
            pinchOverviewSettleFrom = pinchOverviewQ
            pinchOverviewSettleTo = (!cancelled && pinchOverviewQ >= 0.5) ? 1 : 0
            pinchOverviewSettleStart = CACurrentMediaTime()
            pinchSettling = true
            requestRender()
        case .reflow:
            let finalLevel = ctx.profile.clampLevel(Int(rawLevel.rounded()))
            if !cancelled, finalLevel != startLevel {
                commitLiveZoom(to: finalLevel, engine: ctx.engine)
            } else {
                returnLiveZoomToCurrentLevel()
            }
        case .undecided:
            if !beginShortPinchStep(cancelled: cancelled, rawLevel: rawLevel, startLevel: startLevel, engine: ctx.engine) {
                returnLiveZoomToCurrentLevel()
            }
        }
    }

    @discardableResult
    private func applyLatticeSegment(_ update: PinchLiveZoomDriver.Update, engine: SquareTileGridEngine) -> Bool {
        guard update.hasSegment else { return false }
        let segment = (update.segmentSource, update.segmentTarget)
        if pinchBuiltSegment == nil || pinchBuiltSegment! != segment {
            guard tryBuildPinchSegment(source: update.segmentSource, target: update.segmentTarget, engine: engine) else {
                gridTransition.end()
                pinchBuiltSegment = nil
                return false
            }
            pinchBuiltSegment = segment
        }
        gridTransition.setProgress(update.segmentQ)
        return true
    }

    private func tryBuildPinchSegment(source: Int, target: Int, engine: SquareTileGridEngine) -> Bool {
        guard let tx = zoomTransaction else { return false }
        let s = engine.clampLevel(source)
        let t = engine.clampLevel(target)
        guard abs(s - t) == 1 else { return false }
        guard engine.metrics(level: min(s, t)).transitionKindToNext == .focusRowRelayout else { return false }
        let viewportSize = bounds.size
        let overscan = (texturePolicy?.budget.overscanFraction ?? 0.8) * viewportSize.height
        let sp = pinchDetentParams(level: s, engine: engine, viewportSize: viewportSize)
        let tp = pinchDetentParams(level: t, engine: engine, viewportSize: viewportSize)
        let sourcePlan = engine.framePlan(
            level: s,
            viewportSize: viewportSize,
            scrollOffset: CGPoint(x: 0, y: sp.scrollY),
            overscan: overscan,
            columnPhase: sp.phase
        )
        let targetPlan = engine.framePlan(
            level: t,
            viewportSize: viewportSize,
            scrollOffset: CGPoint(x: 0, y: tp.scrollY),
            overscan: overscan,
            columnPhase: tp.phase
        )
        let built = gridTransition.beginPinch(
            source: sourcePlan,
            target: targetPlan,
            anchorIndex: tx.anchorGlobalIndex,
            viewportSize: viewportSize,
            selection: selectedFlatIndices()
        )
        if built {
            let targetUIDs = targetPlan.visibleSlots.compactMap { slot -> PhotoUID? in
                slot.index >= 0 && slot.index < itemUIDs.count ? itemUIDs[slot.index] : nil
            }
            warmTargetDetent(targetUIDs, slotSidePoints: targetPlan.slotSide)
        }
        return built
    }

    private func pinchDetentParams(
        level: Int,
        engine: SquareTileGridEngine,
        viewportSize: CGSize
    ) -> (phase: Int?, scrollY: CGFloat) {
        if level == pinchStartLevel {
            return (committedPhase, min(max(pinchLockedOffsetY ?? scrollView.contentOffset.y, 0), maxContentOffsetY))
        }
        guard let tx = zoomTransaction else {
            return (committedPhase, min(max(pinchLockedOffsetY ?? scrollView.contentOffset.y, 0), maxContentOffsetY))
        }
        let desiredColumn = engine.cursorColumn(viewportX: tx.anchorViewportPoint.x, level: level, width: bounds.width)
        let phase = engine.columnPhase(forItem: tx.anchorGlobalIndex, targetColumn: desiredColumn, level: level, width: bounds.width)
        let rawY = engine.anchoredScrollOffset(
            flatIndex: tx.anchorGlobalIndex,
            localFraction: tx.anchorLocalFraction,
            viewportPoint: tx.anchorViewportPoint,
            level: level,
            width: bounds.width,
            columnPhase: phase
        ).y
        let maxY = engine.clampScrollOffsetY(
            rawY,
            level: level,
            width: bounds.width,
            viewportHeight: viewportSize.height,
            columnPhase: phase
        )
        return (phase, maxY)
    }

    private func eligiblePinchChainBand(engine: SquareTileGridEngine, startLevel: Int) -> (lo: Int, hi: Int) {
        var lo = startLevel
        while lo > 0, engine.metrics(level: lo - 1).transitionKindToNext == .focusRowRelayout { lo -= 1 }
        var hi = startLevel
        while hi < engine.levelCount - 1, engine.metrics(level: hi).transitionKindToNext == .focusRowRelayout { hi += 1 }
        return (lo, hi)
    }

    private func selectedFlatIndices() -> Set<Int> {
        guard selectionMode, !selectedUIDs.isEmpty else { return [] }
        return Set(selectedUIDs.compactMap { itemIndexByUID[$0] })
    }

    private func beginOverviewDissolveIfPossible(source: Int, target: Int, engine: SquareTileGridEngine) -> Bool {
        guard let tx = zoomTransaction,
              target >= 0, target < engine.levelCount,
              engine.isOverviewBoundary(source, target),
              let renderer else { return false }
        let viewportSize = bounds.size
        let sourceScrollY = min(max(pinchLockedOffsetY ?? scrollView.contentOffset.y, 0), maxContentOffsetY)
        let anchorContentPoint = CGPoint(x: tx.anchorViewportPoint.x, y: tx.anchorViewportPoint.y + sourceScrollY)
        let overscan = (texturePolicy?.budget.overscanFraction ?? 0.8) * viewportSize.height
        guard let plan = engine.overviewLayerDissolvePlan(
            from: source,
            to: target,
            viewportSize: viewportSize,
            targetViewportSize: viewportSize,
            sourceScrollY: sourceScrollY,
            sourceColumnPhase: committedPhase,
            preferredNormalMode: displayMode,
            anchorContentPoint: anchorContentPoint,
            anchorViewportPoint: tx.anchorViewportPoint,
            overscan: overscan
        ) else { return false }
        overviewDissolve = plan
        renderer.invalidateDissolveLayers()
        return true
    }

    private func driveOverviewDissolve(rawLevel: CGFloat) {
        let s = CGFloat(pinchOverviewSource)
        let t = CGFloat(pinchOverviewTarget)
        let q = t > s ? rawLevel - s : s - rawLevel
        pinchOverviewQ = Double(min(1, max(0, q)))
        if let plan = overviewDissolve {
            overviewDissolve = plan.withProgress(pinchOverviewQ)
        }
    }

    private func beginShortPinchStep(cancelled: Bool, rawLevel: CGFloat, startLevel: Int, engine: SquareTileGridEngine) -> Bool {
        guard !cancelled, abs(rawLevel - CGFloat(startLevel)) > 1e-6 else { return false }
        let direction = rawLevel < CGFloat(startLevel) ? -1 : 1
        let next = startLevel + direction
        guard next >= 0, next < engine.levelCount else { return false }
        if next >= pinchChainBand.lo, next <= pinchChainBand.hi {
            pinchMode = .lattice
            pinchDriver.begin(startLevel: startLevel, chainLo: pinchChainBand.lo, chainHi: pinchChainBand.hi)
            let update = pinchDriver.releaseTowardAdjacent(direction: direction)
            guard applyLatticeSegment(update, engine: engine) else { return false }
            pinchSettling = true
            pinchAdvancePrevTime = 0
            requestRender()
            return true
        }
        if beginOverviewDissolveIfPossible(source: startLevel, target: next, engine: engine) {
            pinchMode = .overviewDissolve
            pinchOverviewSource = startLevel
            pinchOverviewTarget = next
            pinchOverviewQ = 0
            if let plan = overviewDissolve { overviewDissolve = plan.withProgress(0) }
            pinchOverviewSettleFrom = 0
            pinchOverviewSettleTo = 1
            pinchOverviewSettleStart = CACurrentMediaTime()
            pinchSettling = true
            requestRender()
            return true
        }
        return false
    }

    private func commitLiveZoom(to targetLevel: Int, engine: SquareTileGridEngine) {
        guard let tx = zoomTransaction else {
            cancelLiveZoomState()
            requestRender()
            return
        }
        let level = engine.clampLevel(targetLevel)
        let desiredColumn = engine.cursorColumn(viewportX: tx.anchorViewportPoint.x, level: level, width: bounds.width)
        let phase = engine.columnPhase(forItem: tx.anchorGlobalIndex, targetColumn: desiredColumn, level: level, width: bounds.width)
        let rawY = engine.anchoredScrollOffset(
            flatIndex: tx.anchorGlobalIndex,
            localFraction: tx.anchorLocalFraction,
            viewportPoint: tx.anchorViewportPoint,
            level: level,
            width: bounds.width,
            columnPhase: phase
        ).y
        let targetContent = engine.contentSize(level: level, width: bounds.width, columnPhase: phase)
        let targetMaxY = max(0, max(bounds.height + 1, targetContent.height) - bounds.height + scrollView.contentInset.bottom)
        let scrollY = min(max(0, rawY), targetMaxY)

        committedPhase = phase
        interactiveLevel = level
        commitBridgeTransaction = tx
        commitBridgeLevel = level
        commitBridgeScrollY = scrollY
        commitBridgePhase = phase
        commitBridgeStart = CACurrentMediaTime()
        zoomTransaction = nil
        pinchStartLevel = nil
        pinchLockedOffsetY = nil

        refreshContentSize()
        isApplyingProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollY), animated: false)
        isApplyingProgrammaticScroll = false
        requestRender()
    }

    private func returnLiveZoomToCurrentLevel() {
        guard let tx = zoomTransaction, let startLevel = pinchStartLevel else {
            cancelLiveZoomState()
            requestRender()
            return
        }
        let scrollY = min(max(pinchLockedOffsetY ?? scrollView.contentOffset.y, 0), maxContentOffsetY)
        commitBridgeTransaction = tx
        commitBridgeLevel = startLevel
        commitBridgeScrollY = scrollY
        commitBridgePhase = committedPhase
        commitBridgeStart = CACurrentMediaTime()
        zoomTransaction = nil
        pinchStartLevel = nil
        pinchLockedOffsetY = nil
        requestRender()
    }

    func advancePinchSettleIfNeeded() {
        guard pinchSettling else { return }
        let profile = currentProfile()
        let engine = currentEngine(profile: profile)
        switch pinchMode {
        case .lattice:
            let now = CACurrentMediaTime()
            let dt = pinchAdvancePrevTime == 0 ? 1.0 / 60.0 : max(0, now - pinchAdvancePrevTime)
            pinchAdvancePrevTime = now
            let q = pinchDriver.advance(dt: dt)
            let update = PinchLiveZoomDriver.Update(
                segmentSource: pinchDriver.segmentSource,
                segmentTarget: pinchDriver.segmentTarget,
                segmentQ: q,
                hasSegment: true
            )
            _ = applyLatticeSegment(update, engine: engine)
            if pinchDriver.isCommitted {
                commitPinchChain(toLevel: pinchDriver.finalLevel, engine: engine)
            }
        case .overviewDissolve:
            let elapsed = CACurrentMediaTime() - pinchOverviewSettleStart
            let f = pinchOverviewSettleDuration > 0 ? min(1, elapsed / pinchOverviewSettleDuration) : 1
            pinchOverviewQ = pinchOverviewSettleFrom + (pinchOverviewSettleTo - pinchOverviewSettleFrom) * f
            if let plan = overviewDissolve { overviewDissolve = plan.withProgress(pinchOverviewQ) }
            if f >= 1 { commitOverviewDissolve() }
        case .reflow, .undecided:
            pinchSettling = false
        }
    }

    private func finishInFlightPinchPresentation(engine: SquareTileGridEngine) {
        guard pinchSettling || gridTransition.isActive || overviewDissolve != nil else { return }
        switch pinchMode {
        case .lattice:
            pinchDriver.advance(dt: 10)
            commitPinchChain(toLevel: pinchDriver.finalLevel, engine: engine)
        case .overviewDissolve:
            commitOverviewDissolve()
        case .reflow, .undecided:
            cancelLiveZoomState()
        }
    }

    private func commitPinchChain(toLevel finalLevel: Int, engine: SquareTileGridEngine) {
        let level = engine.clampLevel(finalLevel)
        let params = pinchDetentParams(level: level, engine: engine, viewportSize: bounds.size)
        if level != pinchStartLevel {
            committedPhase = params.phase
            interactiveLevel = level
        }
        gridTransition.end()
        zoomTransaction = nil
        pinchSettling = false
        pinchMode = .undecided
        pinchBuiltSegment = nil
        pinchStartLevel = nil
        pinchLockedOffsetY = nil
        pinchAdvancePrevTime = 0
        refreshContentSize()
        isApplyingProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: 0, y: min(max(0, params.scrollY), maxContentOffsetY)), animated: false)
        isApplyingProgrammaticScroll = false
        requestRender()
    }

    private func commitOverviewDissolve() {
        guard let plan = overviewDissolve else {
            cancelLiveZoomState()
            return
        }
        let toTarget = pinchOverviewSettleTo >= 0.5
        let scrollY: CGFloat
        if toTarget {
            committedPhase = plan.targetColumnPhase
            interactiveLevel = plan.targetLevel
            scrollY = plan.targetScrollY
        } else {
            scrollY = min(max(pinchLockedOffsetY ?? scrollView.contentOffset.y, 0), maxContentOffsetY)
        }
        overviewDissolve = nil
        renderer?.endLayerDissolve()
        zoomTransaction = nil
        gridTransition.end()
        pinchSettling = false
        pinchMode = .undecided
        pinchBuiltSegment = nil
        pinchStartLevel = nil
        pinchLockedOffsetY = nil
        refreshContentSize()
        isApplyingProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: 0, y: min(max(0, scrollY), maxContentOffsetY)), animated: false)
        isApplyingProgrammaticScroll = false
        requestRender()
    }

    private func warmTargetDetent(_ uids: [PhotoUID], slotSidePoints: CGFloat) {
        guard let textureCache else { return }
        scheduleWarmIfNeeded(
            newestFirst(uniqueUIDs(uids)),
            pixelSize: transitionUploadPixels(slotSidePoints: slotSidePoints, textureCache: textureCache)
        )
    }

    func cancelLiveZoomState() {
        zoomTransaction = nil
        pinchStartLevel = nil
        pinchLockedOffsetY = nil
        commitBridgeTransaction = nil
        commitBridgeStart = 0
        gridTransition.end()
        overviewDissolve = nil
        renderer?.endLayerDissolve()
        pinchDriver.reset()
        pinchMode = .undecided
        pinchSettling = false
        pinchBuiltSegment = nil
        pinchPrevSampleTime = 0
        pinchAdvancePrevTime = 0
    }
}
#endif
