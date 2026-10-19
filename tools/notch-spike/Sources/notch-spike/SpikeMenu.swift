import AppKit
import NotchSpikeCore

@MainActor
final class SpikeMenu: NSObject {
    /// Popped up from the strip on click; no status item (the strip replaces it).
    let menu = NSMenu()
    private let controller: SpikeController
    private let log: SpikeLog

    init(controller: SpikeController, log: SpikeLog) {
        self.controller = controller
        self.log = log
        super.init()
        add(menu, "Style: Wings", #selector(styleWings))
        add(menu, "Style: Minimal", #selector(styleMinimal))
        menu.addItem(.separator())
        add(menu, "Mark checklist step…", #selector(mark))
        add(menu, "Open log", #selector(openLog))
        add(menu, "Quit", #selector(quit))
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
    }

    @objc private func styleWings() { controller.style = .wings }
    @objc private func styleMinimal() { controller.style = .minimal }

    @objc private func mark() {
        let alert = NSAlert()
        alert.messageText = "Checklist step"
        alert.informativeText = "Step ID, e.g. C3"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Mark")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = field.stringValue.replacingOccurrences(of: " ", with: "_")
        log.write("mark", ["label": label.isEmpty ? "-" : label])
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/AgentSessions-NotchSpike/spike.log"))
    }

    @objc private func quit() {
        log.write("quit")
        log.flushForTesting()
        NSApp.terminate(nil)
    }
}
