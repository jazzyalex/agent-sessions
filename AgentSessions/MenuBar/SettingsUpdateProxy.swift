import SwiftUI

// Tiny helper to observe AppStorage changes at the scene level and call back into App code.
struct SettingsUpdateProxy: View {
    @Binding var menuBarEnabled: Bool
    var onToggle: (Bool) -> Void

    init(menuBarEnabled: Binding<Bool>, onToggle: @escaping (Bool) -> Void) {
        self._menuBarEnabled = menuBarEnabled
        self.onToggle = onToggle
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: menuBarEnabled) { _, newValue in
                onToggle(newValue)
            }
    }
}

