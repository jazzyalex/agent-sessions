import SwiftUI

/// Native one-question feedback ask. Shown after real usage (see
/// `OnboardingCoordinator.isFeedbackAskDue`). A single HTTPS POST fires only when
/// the user presses Send; failures preserve the text and surface GitHub fallbacks.
struct FeedbackPromptView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    /// Injected for testing; defaults to the live Google Form submitter.
    var submitter: FeedbackSubmitter = FeedbackSubmitter()
    /// Called after the prompt should be dismissed (sent, declined, or closed).
    var onFinished: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @State private var feedbackText: String = ""
    @State private var email: String = ""
    @State private var isSending: Bool = false
    @State private var showError: Bool = false

    private var palette: OnboardingPalette { OnboardingPalette(colorScheme: colorScheme) }

    private var canSend: Bool {
        !feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.accentBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's the one thing you wish Agent Sessions did better?")
                        .font(.system(size: 14, weight: .semibold, design: .default))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            TextEditor(text: $feedbackText)
                .font(.system(size: 13))
                .frame(minHeight: 90)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(palette.rowFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(palette.rowStroke, lineWidth: 1)
                )

            TextField("optional, if you'd like a reply", text: $email)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)

            Text("Sent to the developer via Google Forms, tagged with your app and macOS version. No tracking.")
                .font(.system(size: 11, weight: .regular, design: .default))
                .foregroundStyle(.secondary)

            if showError {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't send. Your note is still here — try again, or reach us on GitHub.")
                        .font(.system(size: 12, weight: .medium, design: .default))
                        .foregroundStyle(palette.accentOrange)
                    HStack(spacing: 14) {
                        Link("Open a GitHub issue", destination: FeedbackSubmitter.githubIssuesURL)
                            .font(.system(size: 12, weight: .semibold))
                        Link("GitHub Discussions", destination: FeedbackSubmitter.githubDiscussionsURL)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Not now") {
                    coordinator.recordFeedbackDeclined()
                    onFinished()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    Task { await send() }
                } label: {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Send")
                    }
                }
                .buttonStyle(OnboardingPrimaryButtonStyle(palette: palette, isFinal: true))
                .disabled(!canSend)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func send() async {
        showError = false
        isSending = true
        defer { isSending = false }

        let payload = FeedbackSubmitter.makePayload(
            feedback: feedbackText,
            email: email
        )
        do {
            try await submitter.submit(payload)
            coordinator.recordFeedbackSubmitted()
            onFinished()
        } catch {
            // Preserve the text; surface inline error + GitHub fallbacks.
            showError = true
        }
    }
}
