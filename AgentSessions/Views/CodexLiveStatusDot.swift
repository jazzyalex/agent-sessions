import SwiftUI

struct CodexLiveStatusDot: View {
    let state: CodexLiveState
    var color: Color
    var size: CGFloat = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatePulse: Bool = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(pulseScale)
            .opacity(pulseOpacity)
            .onAppear {
                guard shouldPulse else { return }
                animatePulse = true
            }
            .onChange(of: shouldPulse) { _, pulse in
                if pulse {
                    animatePulse = true
                } else {
                    animatePulse = false
                }
            }
            .animation(pulseAnimation, value: animatePulse)
            .accessibilityLabel(Text(accessibilityLabel))
    }

    private var shouldPulse: Bool {
        state == .activeWorking && !reduceMotion
    }

    private var pulseScale: CGFloat {
        guard shouldPulse else { return 1.0 }
        return animatePulse ? 1.18 : 0.92
    }

    private var pulseOpacity: Double {
        guard shouldPulse else { return 1.0 }
        return animatePulse ? 1.0 : 0.55
    }

    private var pulseAnimation: Animation? {
        guard shouldPulse else { return nil }
        return .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
    }

    private var accessibilityLabel: String {
        switch state {
        case .activeWorking: return "Active session"
        case .openIdle: return "Open session"
        }
    }
}
