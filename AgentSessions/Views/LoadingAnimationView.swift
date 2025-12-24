import SwiftUI

struct LoadingAnimationView: View {
    let codexColor: Color
    let claudeColor: Color

    @Environment(\.colorScheme) private var scheme
    @State private var currentWordIndex = 0
    @State private var opacity: Double = 0.0

    // Cycle order: Agent Sessions → Codex CLI → Claude Code → Gemini CLI → OpenCode → GitHub Copilot CLI → repeat
    private let words = ["Agent Sessions", "Codex CLI", "Claude Code", "Gemini CLI", "OpenCode", "GitHub Copilot CLI"]

    var body: some View {
        ZStack {
            // Background
            (scheme == .dark
                ? Color(.sRGB, red: 18/255, green: 18/255, blue: 18/255, opacity: 1)
                : Color(.sRGB, red: 250/255, green: 246/255, blue: 238/255, opacity: 1))

            // Fading text
            Text(words[currentWordIndex])
                .font(.system(size: 72, weight: .black, design: .monospaced))
                .foregroundColor(scheme == .dark ? .white : .black)
                .opacity(opacity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Never block mouse/trackpad interaction for underlying content.
        // Loading animations are visual-only; users must be able to keep clicking in lists/transcripts.
        .allowsHitTesting(false)
        .task(id: words.count) {
            await startFadingLoop()
        }
    }

    private func startFadingLoop() async {
        await MainActor.run {
            currentWordIndex = 0
            opacity = 0.0
        }

        while !Task.isCancelled {
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.8)) {
                    opacity = 0.4
                }
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)

            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.6)) {
                    opacity = 0.0
                }
            }
            try? await Task.sleep(nanoseconds: 600_000_000)

            await MainActor.run {
                currentWordIndex = (currentWordIndex + 1) % max(words.count, 1)
            }
        }
    }
}
