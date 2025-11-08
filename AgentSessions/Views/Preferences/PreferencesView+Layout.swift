import SwiftUI

let labelColumnWidth: CGFloat = 170

struct PreferenceKeyValueRow<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .frame(width: labelColumnWidth, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PreferenceCallout<Content: View>: View {
    let iconName: String
    let tint: Color
    let backgroundColor: Color
    let content: Content

    init(iconName: String = "exclamationmark.triangle.fill",
         tint: Color = .orange,
         backgroundColor: Color? = nil,
         @ViewBuilder content: () -> Content) {
        self.iconName = iconName
        self.tint = tint
        self.backgroundColor = backgroundColor ?? tint.opacity(0.12)
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(tint)
                .font(.caption)
            content
        }
        .padding(8)
        .background(backgroundColor)
        .cornerRadius(6)
    }
}

extension PreferencesView {
    // Shared toggle row for label + switch alignment
    func toggleRow(_ label: String, isOn: Binding<Bool>, help: String) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .frame(width: labelColumnWidth, alignment: .leading)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(Text(label))
                .help(help)
        }
    }

    func labeledRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        PreferenceKeyValueRow(label: label, content: content)
    }

    func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .fontWeight(.semibold)
            Divider()
        }
    }
}
