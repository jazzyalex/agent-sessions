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
        Group {
            if state == .activeWorking {
                staticActiveDot
            } else {
                animatedIdleDot
            }
        }
        .onChange(of: state) { _, newState in
            if newState != .openIdle {
                stopPulseAnimation()
            }
        }
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var shouldPulse: Bool {
        state == .openIdle && !reduceMotion
    }

    private var idleBaseColor: Color {
        colorScheme == .dark ? Color(hex: "ffb340") : Color(hex: "e08600")
    }

    private var pulseScale: CGFloat {
        animatePulse ? 1.25 : 1.0
    }

    private var pulseOpacity: Double {
        return animatePulse ? 1.0 : 0.88
    }

    private var staticActiveDot: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .transaction { transaction in
                // Keep active (green) dots fully static even when parent rows animate.
                transaction.animation = nil
            }
    }

    private var animatedIdleDot: some View {
        Circle()
            .fill(idleBaseColor)
            .frame(width: size, height: size)
            .scaleEffect(pulseScale)
            .opacity(pulseOpacity)
            .shadow(color: idleBaseColor.opacity(haloOpacity), radius: haloRadius)
            .onAppear { updateAnimation() }
            .onChange(of: lastSeenAt) { _, _ in updateAnimation() }
            .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private var haloOpacity: Double {
        guard shouldPulse else { return 0 }
        return animatePulse ? 0.65 : 0.22
    }

    private var haloRadius: CGFloat {
        guard shouldPulse else { return 0 }
        return animatePulse ? 4.8 : 3.2
    }

    private func updateAnimation() {
        guard shouldPulse else {
            stopPulseAnimation()
            return
        }
        animatePulse = false
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
            animatePulse = true
        }
    }

    private func stopPulseAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            animatePulse = false
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .activeWorking: return "Active session"
        case .openIdle: return "Open session"
        }
    }
}
