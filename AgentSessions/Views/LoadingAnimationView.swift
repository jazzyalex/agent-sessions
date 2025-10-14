import SwiftUI

struct LoadingAnimationView: View {
    let codexColor: Color
    let claudeColor: Color

    @Environment(\.colorScheme) private var scheme
    @State private var currentWordIndex = 0
    @State private var opacity: Double = 0.0

    // Cycle order: Agent Sessions → Codex CLI → Claude Code → Gemini CLI → repeat
    private let words = ["Agent Sessions", "Codex CLI", "Claude Code", "Gemini CLI"]

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
        .onAppear {
            startFading()
        }
    }

    private func startFading() {
        // Fade in
        withAnimation(.easeInOut(duration: 0.8)) {
            opacity = 0.4
        }

        // After fade in, wait then fade out and cycle to next word
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.6)) {
                opacity = 0.0
            }

            // Switch to next word after fade out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                currentWordIndex = (currentWordIndex + 1) % words.count
                startFading()
            }
        }
    }
}
