import SwiftUI

struct CodexLiveStatusDot: View {
    let state: CodexLiveState
    var color: Color
    var size: CGFloat = 6
    var lastSeenAt: Date? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatePulse: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(pulseScale)
            .opacity(pulseOpacity)
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
        return animatePulse ? 0.72 : 1.0
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
