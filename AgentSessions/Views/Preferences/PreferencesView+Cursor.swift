import SwiftUI

extension PreferencesView {
    var cursorTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Cursor").font(.title2).fontWeight(.semibold)

            if !cursorAgentEnabled {
                PreferenceCallout {
                    Text("This agent is disabled in General → Active CLI agents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                sectionHeader("Sessions Storage")
                VStack(alignment: .leading, spacing: 10) {
                    labeledRow("Status") {
                        let status = AgentEnablement.availabilityStatus(for: .cursor)
                        HStack(spacing: 4) {
                            Image(systemName: status.isAvailable ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundColor(status.isAvailable ? .green : .secondary)
                            Text(status.statusText)
                                .font(.caption)
                        }
                    }

                    labeledRow("Storage Root") {
                        Text("~/.cursor")
                            .font(.caption)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }

                    labeledRow("Transcripts") {
                        Text("~/.cursor/projects/*/agent-transcripts/")
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }

                    labeledRow("Chat Metadata") {
                        Text("~/.cursor/chats/*/*/store.db")
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.secondary)
                    }
                }

                sectionHeader("Custom Root Override")
                VStack(alignment: .leading, spacing: 6) {
                    @AppStorage(PreferencesKey.Paths.cursorSessionsRootOverride) var cursorRootOverride: String = ""

                    TextField("Custom root (leave empty for default)", text: $cursorRootOverride)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    Text("Override the default ~/.cursor path. Most users should leave this empty.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!cursorAgentEnabled)

            Spacer()
        }
    }
}
