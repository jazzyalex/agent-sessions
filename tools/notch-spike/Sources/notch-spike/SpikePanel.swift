import AppKit
import NotchSpikeCore

final class SpikePanel: NSPanel {
    let role: String
    let generation: Int
    private let log: SpikeLog

    init(frame: CGRect, role: String, generation: Int, opaqueBlack: Bool, log: SpikeLog) {
        self.role = role
        self.generation = generation
        self.log = log
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier("notch-spike.\(role)")
        level = .statusBar
        hidesOnDeactivate = false
        isOpaque = false
        hasShadow = false
        backgroundColor = opaqueBlack ? .black : .clear
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    deinit {
        log.write("panel.deinit", ["role": role, "gen": String(generation)])
    }
}
