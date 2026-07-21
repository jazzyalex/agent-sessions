import SwiftUI
import AppKit

/// Which edge stays put when the Quota Meter window resizes.
///
/// The window is a pinned widget the user parks somewhere deliberate, so a
/// reveal/collapse round trip has to leave it exactly where it started. Growth
/// direction is chosen from the screen room available — near the bottom of the
/// display it grows *upward*, pinning its bottom edge — so the matching shrink
/// cannot simply pin the top: it has to release whichever edge that growth
/// pinned. Deciding independently is what made the window walk up the screen by
/// one toolbar height per right-click.
enum HUDLimitsResizeAnchor {
    /// - Parameters:
    ///   - isGrowing: target height exceeds the current height.
    ///   - growsDown: for a growth, whether there is room to expand downward.
    ///   - lastGrowAnchoredTop: what the most recent growth decided; a shrink
    ///     mirrors it instead of re-deciding.
    /// - Returns: true when the top edge stays fixed and the bottom edge moves.
    static func anchorsTop(isGrowing: Bool, growsDown: Bool, lastGrowAnchoredTop: Bool) -> Bool {
        isGrowing ? growsDown : lastGrowAnchoredTop
    }
}

struct AgentCockpitHUDWindowConfigurator: NSViewRepresentable {
    let isPinned: Bool
    let limitsContentHeight: CGFloat
    let limitsContentWidth: CGFloat
    let activeEnabled: Bool
    let compactToolbarVisible: Bool

    private var styleInputs: Coordinator.StyleInputs {
        Coordinator.StyleInputs(
            isPinned: isPinned,
            limitsContentHeight: limitsContentHeight,
            limitsContentWidth: limitsContentWidth,
            activeEnabled: activeEnabled,
            compactToolbarVisible: compactToolbarVisible
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
            context.coordinator.applyStyleIfNeeded(styleInputs)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        context.coordinator.attach(to: window)
        context.coordinator.applyStyleIfNeeded(styleInputs)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
#if DEBUG
        private struct DebugAttachmentState {
            var activeConfiguratorCount: Int = 0
            var maxActiveConfiguratorCount: Int = 0
        }
        private static let debugAttachmentLock = NSLock()
        private static var debugAttachmentState = DebugAttachmentState()

        static func debugAttachmentSnapshot() -> (activeConfigurators: Int, maxActiveConfigurators: Int) {
            debugAttachmentLock.lock()
            let state = debugAttachmentState
            debugAttachmentLock.unlock()
            return (
                activeConfigurators: state.activeConfiguratorCount,
                maxActiveConfigurators: state.maxActiveConfiguratorCount
            )
        }

        private static func recordAttach() {
            debugAttachmentLock.lock()
            debugAttachmentState.activeConfiguratorCount += 1
            debugAttachmentState.maxActiveConfiguratorCount = max(
                debugAttachmentState.maxActiveConfiguratorCount,
                debugAttachmentState.activeConfiguratorCount
            )
            debugAttachmentLock.unlock()
        }

        private static func recordDetach() {
            debugAttachmentLock.lock()
            debugAttachmentState.activeConfiguratorCount = max(0, debugAttachmentState.activeConfiguratorCount - 1)
            debugAttachmentLock.unlock()
        }
#endif
        struct StyleInputs: Equatable {
            let isPinned: Bool
            let limitsContentHeight: CGFloat
            let limitsContentWidth: CGFloat
            let activeEnabled: Bool
            let compactToolbarVisible: Bool
        }

        private weak var window: NSWindow?
        private var baselineLevel: NSWindow.Level = .normal
        private var baselineCollectionBehavior: NSWindow.CollectionBehavior = []
        private var baselineHidesOnDeactivate: Bool = false
        private var baselineHasShadow: Bool = true
        private var baselineHasShadowCaptured = false
        private var baselineMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        private var baselineMaxSizeCaptured = false
        private var pendingFrameWorkItem: DispatchWorkItem?
        private var isApplyingFrame = false
        private var hasRestoredLimitsFrame = false
        // Keep pinned cockpit above regular windows without covering system tooltip windows.
        private static let pinnedWindowLevel: NSWindow.Level = .statusBar
        private static let pinnedCollectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        private let limitsAutosaveName = "AgentCockpitHUDWindow.limits"
        private let limitsMinimumWidth: CGFloat = 220
        private let limitsDefaultFrameWidth: CGFloat = 380
        private let limitsRowHeight: CGFloat = 30
        private let limitsMaximumRows: CGFloat = 9
        private let compactHeaderHeight: CGFloat = 44.5
        private let compactDisabledCalloutHeight: CGFloat = 56
        /// Which edge the last Quota Meter *growth* pinned, so the matching
        /// shrink can release the same one. See `HUDLimitsResizeAnchor`.
        private var lastLimitsGrowAnchoredTop: Bool = true
        private var lastAppliedCompactToolbarVisibility: Bool?
        private var lastAppliedStyleInputs: StyleInputs?

        func attach(to newWindow: NSWindow) {
            guard window !== newWindow else { return }
            if window != nil {
#if DEBUG
                Self.recordDetach()
#endif
            }
            window = newWindow
#if DEBUG
            Self.recordAttach()
#endif
            lastAppliedStyleInputs = nil
            hasRestoredLimitsFrame = false
            captureBaselineWindowStateIfSafe(from: newWindow)
        }

        deinit {
            pendingFrameWorkItem?.cancel()
            if window != nil {
#if DEBUG
                Self.recordDetach()
#endif
            }
        }

        func applyStyleIfNeeded(_ inputs: StyleInputs) {
            guard lastAppliedStyleInputs != inputs else { return }
            applyStyle(
                isPinned: inputs.isPinned,
                limitsContentHeight: inputs.limitsContentHeight,
                limitsContentWidth: inputs.limitsContentWidth,
                activeEnabled: inputs.activeEnabled,
                compactToolbarVisible: inputs.compactToolbarVisible
            )
            lastAppliedStyleInputs = inputs
        }

        func applyStyle(isPinned: Bool,
                        limitsContentHeight: CGFloat,
                        limitsContentWidth: CGFloat,
                        activeEnabled: Bool,
                        compactToolbarVisible: Bool) {
            guard let window else { return }
            captureBaselineWindowStateIfSafe(from: window)
            // The Quota Meter's chrome mode decides whether the toolbar is part
            // of the window at all, so unlike the retired Compact mode its
            // height does follow toolbar visibility.
            let includesToolbarForStableSizing = compactToolbarVisible

            if window.identifier?.rawValue != "AgentCockpit" {
                window.identifier = NSUserInterfaceItemIdentifier("AgentCockpit")
            }

            window.isMovableByWindowBackground = true
            window.isRestorable = true
            window.resizeIncrements = NSSize(width: 1, height: 1)
            window.contentResizeIncrements = NSSize(width: 1, height: 1)

            let previousCompactToolbarVisibility = lastAppliedCompactToolbarVisibility
            applyCompactChrome(to: window)

            let targetHeight = limitsWindowHeight(
                for: window,
                contentHeight: limitsContentHeight,
                includesDisabledCallout: !activeEnabled,
                includesToolbar: includesToolbarForStableSizing
            )
            // Hug the content width: fix the window to the limits row's natural
            // width so it never tucks wider than its content (no dead space on
            // the right). Resizes once when the Enlarged font toggles.
            let limitsWidth = max(limitsMinimumWidth, limitsContentWidth)
            window.minSize = NSSize(width: limitsWidth, height: targetHeight)
            window.maxSize = NSSize(width: limitsWidth, height: targetHeight)

            restoreLimitsFrameOnFirstAttach(
                window: window,
                activeEnabled: activeEnabled,
                compactToolbarVisible: includesToolbarForStableSizing,
                limitsContentHeight: limitsContentHeight
            )

            applyLimitsDefaultSize(
                to: window,
                contentHeight: limitsContentHeight,
                activeEnabled: activeEnabled,
                includesToolbar: compactToolbarVisible,
                appliesDefaultWidth: false,
                animated: previousCompactToolbarVisibility != compactToolbarVisible
            )
            lastAppliedCompactToolbarVisibility = compactToolbarVisible
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true

            if isPinned {
                window.level = Self.pinnedWindowLevel
                window.collectionBehavior = baselineCollectionBehavior.union(Self.pinnedCollectionBehavior)
                window.hidesOnDeactivate = false
            } else {
                // Restore non-pinned behavior to the window's baseline values.
                window.level = Self.sanitizedUnpinnedLevel(from: baselineLevel)
                window.collectionBehavior = Self.sanitizedUnpinnedCollectionBehavior(from: baselineCollectionBehavior)
                window.hidesOnDeactivate = baselineHidesOnDeactivate
            }
        }

        static func sanitizedUnpinnedLevel(from baselineLevel: NSWindow.Level) -> NSWindow.Level {
            if baselineLevel == .screenSaver || baselineLevel == pinnedWindowLevel {
                return .normal
            }
            return baselineLevel
        }

        static func sanitizedUnpinnedCollectionBehavior(from baselineCollectionBehavior: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
            baselineCollectionBehavior.subtracting(pinnedCollectionBehavior)
        }

        private func captureBaselineWindowStateIfSafe(from window: NSWindow) {
            // If the window is currently pinned, preserve the previous baseline so unpin restores
            // regular behavior instead of re-capturing pinned state as the baseline.
            guard window.level != .screenSaver,
                  window.level != Self.pinnedWindowLevel else { return }
            baselineLevel = window.level
            baselineCollectionBehavior = Self.sanitizedUnpinnedCollectionBehavior(from: window.collectionBehavior)
            baselineHidesOnDeactivate = window.hidesOnDeactivate
            if !baselineHasShadowCaptured {
                baselineHasShadow = window.hasShadow
                baselineHasShadowCaptured = true
            }
            if !baselineMaxSizeCaptured {
                baselineMaxSize = window.maxSize
                baselineMaxSizeCaptured = true
            }
        }

        private func applyCompactChrome(to window: NSWindow) {
            var compactMask = window.styleMask
            compactMask.remove(.titled)
            compactMask.insert(.fullSizeContentView)
            window.styleMask = compactMask
            window.title = ""
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            // Make the window transparent so the SwiftUI clipShape's rounded corners
            // are the only visible boundary — eliminates the double-corner artifact
            // caused by the NSWindow frame's own corner radius overlapping the view clip.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            applyClearHostingBackground(to: window)
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for buttonType in buttons {
                guard let button = window.standardWindowButton(buttonType) else { continue }
                button.isHidden = true
                button.isEnabled = false
            }
            if let container = window.standardWindowButton(.closeButton)?.superview {
                container.isHidden = true
            }
        }


        private func applyClearHostingBackground(to window: NSWindow) {
            for view in [window.contentView, window.contentView?.superview].compactMap({ $0 }) {
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }


        /// Restores the Quota Meter's saved position once per attach, falling back
        /// to a default size when nothing was saved.
        ///
        /// This replaced a three-mode transition system when Compact and Full were
        /// retired. With one mode there is nothing to transition *between*, so the
        /// per-mode frame cache and the save-the-outgoing-mode step are gone; AppKit's
        /// own autosave (enabled by `setFrameAutosaveName`) persists moves and resizes.
        private func restoreLimitsFrameOnFirstAttach(window: NSWindow,
                                                     activeEnabled: Bool,
                                                     compactToolbarVisible: Bool,
                                                     limitsContentHeight: CGFloat) {
            guard !hasRestoredLimitsFrame else { return }

            if window.frameAutosaveName != limitsAutosaveName {
                window.setFrameAutosaveName(limitsAutosaveName)
            }

            if !window.setFrameUsingName(limitsAutosaveName) {
                applyLimitsDefaultSize(
                    to: window,
                    contentHeight: limitsContentHeight,
                    activeEnabled: activeEnabled,
                    includesToolbar: compactToolbarVisible,
                    appliesDefaultWidth: true,
                    animated: false
                )
            }

            hasRestoredLimitsFrame = true
        }



        private func limitsWindowHeight(for window: NSWindow,
                                        contentHeight: CGFloat,
                                        includesDisabledCallout: Bool,
                                        includesToolbar: Bool) -> CGFloat {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let calloutHeight = includesDisabledCallout ? compactDisabledCalloutHeight : 0
            let clampedContentHeight = max(limitsRowHeight, min(contentHeight, limitsRowHeight * limitsMaximumRows))
            return (includesToolbar ? compactHeaderHeight + 0.5 : 0)
                + clampedContentHeight
                + calloutHeight
                + chromeHeight
        }







        private func applyLimitsDefaultSize(to window: NSWindow,
                                            contentHeight: CGFloat,
                                            activeEnabled: Bool,
                                            includesToolbar: Bool,
                                            appliesDefaultWidth: Bool,
                                            animated: Bool) {
            // Clamp to maxSize.width so the window snaps to the hugged content width
            // even when its saved/previous frame was wider than the content.
            let unclampedWidth = appliesDefaultWidth
                ? max(window.minSize.width, limitsDefaultFrameWidth)
                : max(window.minSize.width, window.frame.width)
            let targetWidth = min(window.maxSize.width, unclampedWidth)
            let targetHeight = max(
                window.minSize.height,
                self.limitsWindowHeight(
                    for: window,
                    contentHeight: contentHeight,
                    includesDisabledCallout: !activeEnabled,
                    includesToolbar: includesToolbar
                )
            )

            var frame = window.frame
            let oldHeight = frame.height
            guard abs(frame.width - targetWidth) > 1 || abs(frame.height - targetHeight) > 1 else {
                return
            }

            frame.size.width = targetWidth
            frame.size.height = targetHeight

            // Reveal and collapse must pin the same edge, or the window walks.
            // Growth picks its direction from available screen room; the shrink
            // mirrors that choice rather than deciding for itself.
            let isGrowing = targetHeight > oldHeight
            let growsDown = isGrowing
                ? shouldGrowLimitsWindowDown(window: window, targetHeight: targetHeight)
                : false
            let anchorsTop = HUDLimitsResizeAnchor.anchorsTop(
                isGrowing: isGrowing,
                growsDown: growsDown,
                lastGrowAnchoredTop: lastLimitsGrowAnchoredTop
            )
            if isGrowing {
                lastLimitsGrowAnchoredTop = anchorsTop
            }
            if anchorsTop {
                frame.origin.y += oldHeight - targetHeight
            }
            // Animate only when the toolbar is toggling, so the window resize
            // moves with the toolbar reveal/hide instead of snapping. Other
            // limits resizes (content height changes) stay instant.
            setWindowFrame(frame, display: true, animate: animated)
        }

        /// Whether the window grows downward (top edge pinned) given the room
        /// available on screen. Only meaningful while growing — the caller must
        /// not consult it on a shrink, where its `guard` would answer `true`
        /// unconditionally and pin the top regardless of which edge the matching
        /// growth actually pinned.
        private func shouldGrowLimitsWindowDown(window: NSWindow, targetHeight: CGFloat) -> Bool {
            guard targetHeight > window.frame.height,
                  let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
                return true
            }
            let frame = window.frame
            let extraHeight = targetHeight - frame.height
            let roomBelow = max(0, frame.minY - visibleFrame.minY)
            let roomAbove = max(0, visibleFrame.maxY - frame.maxY)
            if roomBelow >= extraHeight { return true }
            if roomAbove >= extraHeight { return false }
            return roomBelow >= roomAbove
        }

        private func setWindowFrame(_ frame: NSRect, display: Bool, animate: Bool) {
            guard let window else { return }
            let current = window.frame
            guard abs(current.origin.x - frame.origin.x) > 1 ||
                    abs(current.origin.y - frame.origin.y) > 1 ||
                    abs(current.width - frame.width) > 1 ||
                    abs(current.height - frame.height) > 1 else {
                return
            }

            pendingFrameWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak window] in
                guard let self, let window, !self.isApplyingFrame else { return }
                let current = window.frame
                guard abs(current.origin.x - frame.origin.x) > 1 ||
                        abs(current.origin.y - frame.origin.y) > 1 ||
                        abs(current.width - frame.width) > 1 ||
                        abs(current.height - frame.height) > 1 else {
                    return
                }
                self.isApplyingFrame = true
                window.setFrame(frame, display: display, animate: animate)
                self.isApplyingFrame = false
            }
            pendingFrameWorkItem = work
            DispatchQueue.main.async(execute: work)
        }
    }
}
