import SwiftUI

struct CodexLiveStatusDot: View {
    let state: CodexLiveState
    var color: Color
    var size: CGFloat = 6
    var lastSeenAt: Date? = nil

    private let idleBaseColor = Color(hex: "ff9f0a")

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    private var idleNeedsAttention: Bool {
        guard state == .openIdle, let lastSeenAt else { return false }
        return Date().timeIntervalSince(lastSeenAt) >= 600
    }

    private var idleBaseScale: CGFloat {
        idleNeedsAttention ? 1.16 : 1.0
    }

    private var pulseScale: CGFloat {
        guard shouldPulse else { return idleBaseScale }
        return animatePulse ? idleBaseScale * 1.16 : idleBaseScale
    }

    private var pulseOpacity: Double {
        guard shouldPulse else { return 1.0 }
        return animatePulse ? 1.0 : 0.9
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
        guard shouldPulse else { return idleNeedsAttention ? 0.24 : 0.0 }
        return animatePulse ? 0.52 : 0.18
    }

    private var haloRadius: CGFloat {
        guard state == .openIdle else { return 0 }
        if shouldPulse {
            return animatePulse ? (idleNeedsAttention ? 5.0 : 3.8) : (idleNeedsAttention ? 3.4 : 2.2)
        }
        return idleNeedsAttention ? 3.0 : 0
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
