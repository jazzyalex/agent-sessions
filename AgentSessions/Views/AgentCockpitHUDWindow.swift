import SwiftUI
import AppKit

struct AgentCockpitHUDWindowConfigurator: NSViewRepresentable {
    let isPinned: Bool
    let shownSessionCount: Int
    let isCompact: Bool
    let activeEnabled: Bool
    let compactToolbarVisible: Bool
    let groupByProject: Bool
    let compactPreferredRows: Int
    let compactAutoFitEnabled: Bool

    private var styleInputs: Coordinator.StyleInputs {
        Coordinator.StyleInputs(
            isPinned: isPinned,
            shownSessionCount: shownSessionCount,
            isCompact: isCompact,
            activeEnabled: activeEnabled,
            compactToolbarVisible: compactToolbarVisible,
            groupByProject: groupByProject,
            compactPreferredRows: compactPreferredRows,
            compactAutoFitEnabled: compactAutoFitEnabled
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
        private enum Mode: Hashable {
            case full
            case compact
        }

        struct StyleInputs: Equatable {
            let isPinned: Bool
            let shownSessionCount: Int
            let isCompact: Bool
            let activeEnabled: Bool
            let compactToolbarVisible: Bool
            let groupByProject: Bool
            let compactPreferredRows: Int
            let compactAutoFitEnabled: Bool
        }

        private weak var window: NSWindow?
        private var baselineLevel: NSWindow.Level = .normal
        private var baselineCollectionBehavior: NSWindow.CollectionBehavior = []
        private var baselineHidesOnDeactivate: Bool = false
        private var baselineStyleMask: NSWindow.StyleMask = []
        private let fallbackStandardStyleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        private var currentMode: Mode?
        // Keep pinned cockpit above regular windows without covering system tooltip windows.
        private static let pinnedWindowLevel: NSWindow.Level = .statusBar
        private static let pinnedCollectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        private let fullAutosaveName = "AgentCockpitHUDWindow.full"
        private let compactAutosaveName = "AgentCockpitHUDWindow.compact"
        private let rowResizeStep: CGFloat = 31
        private let compactDefaultRowsWhenToolbarVisible: CGFloat = 6
        private let compactDefaultRowsWhenToolbarHidden: CGFloat = 4
        private let compactMinimumRowsWhenToolbarVisible: CGFloat = 1
        private let compactMinimumRowsWhenToolbarHidden: CGFloat = 3
        private let compactMaximumRowsWhenToolbarVisible: CGFloat = 10
        private let compactMinimumWidth: CGFloat = 330
        private let compactDefaultFrameWidth: CGFloat = 330
        private let compactHeaderHeight: CGFloat = 44.5
        private let compactDisabledCalloutHeight: CGFloat = 56
        private let fullDefaultFrameSize = NSSize(width: 644, height: 320)
        private var cachedFrameByMode: [Mode: NSRect] = [:]
        private var lastAppliedCompactToolbarVisibility: Bool?
        private var lastAppliedCompactPreferredRows: Int?
        private var lastAppliedCompactAutoFitEnabled: Bool?
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
            captureBaselineWindowStateIfSafe(from: newWindow)
            captureBaselineStyleMaskIfNeeded(from: newWindow.styleMask)
        }

        deinit {
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
                shownSessionCount: inputs.shownSessionCount,
                isCompact: inputs.isCompact,
                activeEnabled: inputs.activeEnabled,
                compactToolbarVisible: inputs.compactToolbarVisible,
                groupByProject: inputs.groupByProject,
                compactPreferredRows: inputs.compactPreferredRows,
                compactAutoFitEnabled: inputs.compactAutoFitEnabled
            )
            lastAppliedStyleInputs = inputs
        }

        func applyStyle(isPinned: Bool,
                        shownSessionCount: Int,
                        isCompact: Bool,
                        activeEnabled: Bool,
                        compactToolbarVisible: Bool,
                        groupByProject: Bool,
                        compactPreferredRows: Int,
                        compactAutoFitEnabled: Bool) {
            guard let window else { return }
            captureBaselineWindowStateIfSafe(from: window)
            if let currentMode {
                cachedFrameByMode[currentMode] = window.frame
            }
            let clampedCompactPreferredRows = clampedPreferredCompactRows(compactPreferredRows)
            let includesToolbarForStableSizing = compactAutoFitEnabled ? compactToolbarVisible : true

            if window.identifier?.rawValue != "AgentCockpit" {
                window.identifier = NSUserInterfaceItemIdentifier("AgentCockpit")
            }

            window.isMovableByWindowBackground = true
            window.isRestorable = true
            // Keep vertical resize snapping aligned to row increments so partial rows
            // are not clipped at the window edge.
            window.resizeIncrements = NSSize(width: 1, height: rowResizeStep)
            window.contentResizeIncrements = NSSize(width: 1, height: rowResizeStep)

            if isCompact {
                let wasAlreadyCompact = currentMode == .compact
                let previousCompactToolbarVisibility = lastAppliedCompactToolbarVisibility
                applyCompactChrome(to: window)
                window.minSize = NSSize(
                    width: compactMinimumWidth,
                    height: compactMinimumWindowHeight(
                        for: window,
                        includesDisabledCallout: !activeEnabled,
                        includesToolbar: includesToolbarForStableSizing
                    )
                )
                applyModeTransition(
                    to: .compact,
                    window: window,
                    activeEnabled: activeEnabled,
                    compactToolbarVisible: includesToolbarForStableSizing,
                    compactPreferredRows: clampedCompactPreferredRows
                )
                if let previousCompactToolbarVisibility,
                   previousCompactToolbarVisibility != compactToolbarVisible,
                   compactAutoFitEnabled {
                    applyCompactToolbarVisibilityTransition(
                        to: compactToolbarVisible,
                        groupByProject: groupByProject,
                        window: window
                    )
                }
                if compactAutoFitEnabled,
                   compactToolbarVisible,
                   !groupByProject {
                    applyCompactVisibleRowsAutoHeight(
                        shownSessionCount: shownSessionCount,
                        activeEnabled: activeEnabled,
                        window: window
                    )
                } else if shouldApplyCompactBaselineHeight(
                    compactPreferredRows: clampedCompactPreferredRows,
                    compactAutoFitEnabled: compactAutoFitEnabled
                ), wasAlreadyCompact {
                    applyCompactBaselineHeight(
                        compactPreferredRows: clampedCompactPreferredRows,
                        activeEnabled: activeEnabled,
                        includesToolbar: includesToolbarForStableSizing,
                        window: window
                    )
                }
                lastAppliedCompactToolbarVisibility = compactToolbarVisible
                lastAppliedCompactPreferredRows = clampedCompactPreferredRows
                lastAppliedCompactAutoFitEnabled = compactAutoFitEnabled
                window.title = ""
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
            } else {
                captureBaselineStyleMaskIfNeeded(from: window.styleMask)
                restoreStandardChrome(to: window)
                window.minSize = NSSize(width: 560, height: 320)
                applyModeTransition(
                    to: .full,
                    window: window,
                    activeEnabled: activeEnabled,
                    compactToolbarVisible: true,
                    compactPreferredRows: clampedCompactPreferredRows
                )
                lastAppliedCompactToolbarVisibility = nil
                lastAppliedCompactPreferredRows = nil
                lastAppliedCompactAutoFitEnabled = nil
                window.title = "Agent Cockpit (\(shownSessionCount))"
                window.titleVisibility = .visible
                window.titlebarAppearsTransparent = false
            }

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

        private func restoreStandardChrome(to window: NSWindow) {
            var restoredMask = baselineStyleMask
            if !restoredMask.contains(.titled) {
                restoredMask.formUnion(fallbackStandardStyleMask)
                restoredMask.remove(.fullSizeContentView)
            }
            window.styleMask = restoredMask
            window.titlebarSeparatorStyle = .automatic
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            for buttonType in buttons {
                guard let button = window.standardWindowButton(buttonType) else { continue }
                button.isHidden = false
                button.isEnabled = true
            }
            if let container = window.standardWindowButton(.closeButton)?.superview {
                container.isHidden = false
            }
        }

        private func captureBaselineStyleMaskIfNeeded(from styleMask: NSWindow.StyleMask) {
            guard styleMask.contains(.titled) else {
                if baselineStyleMask.isEmpty {
                    baselineStyleMask = fallbackStandardStyleMask
                }
                return
            }
            baselineStyleMask = styleMask
        }

        private func applyModeTransition(to mode: Mode,
                                         window: NSWindow,
                                         activeEnabled: Bool,
                                         compactToolbarVisible: Bool,
                                         compactPreferredRows: Int) {
            guard currentMode != mode else { return }

            let previousMode = currentMode
                ?? inferredMode(from: window.frameAutosaveName)
            if let previousMode {
                persistFrame(window.frame, for: previousMode, window: window)
            }

            let targetAutosaveName = autosaveName(for: mode)
            if window.frameAutosaveName != targetAutosaveName {
                window.setFrameAutosaveName(targetAutosaveName)
            }

            let restoredFromCache: Bool = {
                guard let cached = cachedFrameByMode[mode] else { return false }
                window.setFrame(cached, display: true, animate: false)
                return true
            }()
            let restored = restoredFromCache || window.setFrameUsingName(targetAutosaveName)
            if !restored {
                switch mode {
                case .compact:
                    applyCompactDefaultSize(
                        to: window,
                        includesDisabledCallout: !activeEnabled,
                        includesToolbar: compactToolbarVisible,
                        compactPreferredRows: compactPreferredRows
                    )
                case .full:
                    applyFullDefaultSize(to: window)
                }
            }

            currentMode = mode
            cachedFrameByMode[mode] = window.frame
        }

        private func autosaveName(for mode: Mode) -> String {
            switch mode {
            case .full:
                return fullAutosaveName
            case .compact:
                return compactAutosaveName
            }
        }

        private func inferredMode(from autosaveName: String) -> Mode? {
            if autosaveName == fullAutosaveName { return .full }
            if autosaveName == compactAutosaveName { return .compact }
            return nil
        }

        private func persistFrame(_ frame: NSRect, for mode: Mode, window: NSWindow) {
            cachedFrameByMode[mode] = frame
            window.saveFrame(usingName: autosaveName(for: mode))
        }

        private func compactMinimumWindowHeight(for window: NSWindow,
                                                includesDisabledCallout: Bool,
                                                includesToolbar: Bool) -> CGFloat {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let calloutHeight = includesDisabledCallout ? compactDisabledCalloutHeight : 0
            let minimumRows = includesToolbar
                ? compactMinimumRowsWhenToolbarVisible
                : compactMinimumRowsWhenToolbarHidden
            return compactContentHeight(forRows: minimumRows, includesToolbar: includesToolbar) + calloutHeight + chromeHeight
        }

        private func compactContentHeight(forRows rows: CGFloat, includesToolbar: Bool) -> CGFloat {
            (includesToolbar ? compactHeaderHeight : 0) + (rows * rowResizeStep)
        }

        private func applyCompactDefaultSize(to window: NSWindow,
                                             includesDisabledCallout: Bool,
                                             includesToolbar: Bool,
                                             compactPreferredRows: Int) {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let calloutHeight = includesDisabledCallout ? compactDisabledCalloutHeight : 0
            let defaultRows = includesToolbar
                ? CGFloat(compactPreferredRows)
                : compactDefaultRowsWhenToolbarHidden
            let targetHeight = max(
                window.minSize.height,
                compactContentHeight(forRows: defaultRows, includesToolbar: includesToolbar) + calloutHeight + chromeHeight
            )
            let targetWidth = max(window.minSize.width, compactDefaultFrameWidth)

            var frame = window.frame
            let widthChanged = abs(frame.width - targetWidth) > 1
            let previousHeight = frame.height
            if widthChanged {
                frame.size.width = targetWidth
            }
            if abs(previousHeight - targetHeight) <= 1 {
                guard widthChanged else { return }
                window.setFrame(frame, display: true, animate: true)
                return
            }
            frame.origin.y += previousHeight - targetHeight
            frame.size.height = targetHeight
            window.setFrame(frame, display: true, animate: true)
        }

        private func clampedPreferredCompactRows(_ rows: Int) -> Int {
            max(Int(compactMinimumRowsWhenToolbarHidden), min(rows, Int(compactMaximumRowsWhenToolbarVisible)))
        }

        private func shouldApplyCompactBaselineHeight(compactPreferredRows: Int,
                                                      compactAutoFitEnabled: Bool) -> Bool {
            if lastAppliedCompactPreferredRows != compactPreferredRows {
                return true
            }
            if lastAppliedCompactAutoFitEnabled == true, !compactAutoFitEnabled {
                return true
            }
            return false
        }

        private func applyCompactBaselineHeight(compactPreferredRows: Int,
                                                activeEnabled: Bool,
                                                includesToolbar: Bool,
                                                window: NSWindow) {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let calloutHeight = activeEnabled ? 0 : compactDisabledCalloutHeight
            let targetHeight = max(
                window.minSize.height,
                compactContentHeight(
                    forRows: CGFloat(compactPreferredRows),
                    includesToolbar: includesToolbar
                ) + calloutHeight + chromeHeight
            )
            guard abs(window.frame.height - targetHeight) > 0.5 else { return }

            var frame = window.frame
            frame.origin.y += frame.height - targetHeight
            frame.size.height = targetHeight
            window.setFrame(frame, display: true, animate: false)
        }

        private func applyCompactToolbarVisibilityTransition(to isVisible: Bool,
                                                             groupByProject: Bool,
                                                             window: NSWindow) {
            let rowDelta = groupByProject
                ? 0
                : (compactDefaultRowsWhenToolbarVisible - compactDefaultRowsWhenToolbarHidden)
            let delta = compactHeaderHeight + (rowDelta * rowResizeStep)
            guard delta > 0 else { return }

            var frame = window.frame
            let proposedHeight = isVisible ? frame.height + delta : frame.height - delta
            let targetHeight = max(window.minSize.height, proposedHeight)
            guard abs(targetHeight - frame.height) > 0.5 else { return }

            frame.origin.y += frame.height - targetHeight
            frame.size.height = targetHeight
            window.setFrame(frame, display: true, animate: true)
        }

        private func applyCompactVisibleRowsAutoHeight(shownSessionCount: Int,
                                                       activeEnabled: Bool,
                                                       window: NSWindow) {
            let chromeHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
            let calloutHeight = activeEnabled ? 0 : compactDisabledCalloutHeight
            let clampedRows = max(
                Int(compactMinimumRowsWhenToolbarVisible),
                min(shownSessionCount, Int(compactMaximumRowsWhenToolbarVisible))
            )
            let targetHeight = max(
                window.minSize.height,
                compactContentHeight(forRows: CGFloat(clampedRows), includesToolbar: true) + calloutHeight + chromeHeight
            )

            guard abs(window.frame.height - targetHeight) > 0.5 else { return }
            var frame = window.frame
            frame.origin.y += frame.height - targetHeight
            frame.size.height = targetHeight
            window.setFrame(frame, display: true, animate: false)
        }

        private func applyFullDefaultSize(to window: NSWindow) {
            var frame = window.frame
            let targetWidth = max(window.minSize.width, fullDefaultFrameSize.width)
            let targetHeight = max(window.minSize.height, fullDefaultFrameSize.height)
            let oldHeight = frame.height

            guard abs(frame.width - targetWidth) > 1 || abs(frame.height - targetHeight) > 1 else {
                return
            }

            frame.size.width = targetWidth
            frame.size.height = targetHeight
            // Preserve top edge when applying first-run defaults.
            frame.origin.y += oldHeight - targetHeight
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
