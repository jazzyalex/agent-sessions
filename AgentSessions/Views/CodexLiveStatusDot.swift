import SwiftUI

struct CodexLiveStatusDot: View {
    let state: CodexLiveState
    var color: Color
    var size: CGFloat = 7
    var lastSeenAt: Date? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var animatePulse: Bool = false

    var body: some View {
        Circle()
            .fill(fillColor)
            .frame(width: size, height: size)
            .scaleEffect(pulseScale)
            .opacity(pulseOpacity)
            .shadow(color: haloColor.opacity(haloOpacity), radius: haloRadius)
            .onAppear { updateAnimation() }
            .onChange(of: state) { _, _ in updateAnimation() }
            .onChange(of: lastSeenAt) { _, _ in updateAnimation() }
            .onChange(of: reduceMotion) { _, _ in updateAnimation() }
            .accessibilityLabel(Text(accessibilityLabel))
    }

    private var shouldPulse: Bool {
        state == .openIdle && !reduceMotion
    }

    private var idleBaseColor: Color {
        colorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600")
    }

    private var pulseScale: CGFloat {
        guard shouldPulse else { return 1.0 }
        return animatePulse ? 1.25 : 1.0
    }

    private var pulseOpacity: Double {
        guard shouldPulse else { return 1.0 }
        return animatePulse ? 1.0 : 0.88
    }

    private var fillColor: Color {
        guard state == .openIdle else { return color }
        return idleBaseColor
    }

    private var haloColor: Color {
        idleBaseColor
    }

    private var haloOpacity: Double {
        guard state == .openIdle else { return 0 }
        guard shouldPulse else { return 0 }
        return animatePulse ? 0.65 : 0.22
    }

    private var haloRadius: CGFloat {
        guard state == .openIdle else { return 0 }
        guard shouldPulse else { return 0 }
        return animatePulse ? 4.8 : 3.2
    }

    private func updateAnimation() {
        guard shouldPulse else {
            animatePulse = false
            return
        }
        animatePulse = false
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            animatePulse = true
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .activeWorking: return "Active session"
        case .openIdle: return "Open session"
        }
    }
}
