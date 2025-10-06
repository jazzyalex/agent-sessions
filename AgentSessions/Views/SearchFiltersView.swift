import SwiftUI

struct SearchFiltersView: View {
    @EnvironmentObject var indexer: SessionIndexer
    @FocusState private var isSearchFocused: Bool
    @State private var showSearchPopover: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Button(action: {
                    indexer.activeSearchUI = .sessionSearch
                }) {
                    Image(systemName: "magnifyingglass")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.secondary)
                        .imageScale(.large)
                        .font(.system(size: 14, weight: .regular))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: [.command, .option])
                .focusable(false)
                .help("Search sessions")

                .popover(isPresented: $showSearchPopover, arrowEdge: .bottom) {
                    HStack(spacing: 8) {
                        TextField("Search", text: $indexer.queryDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 220)
                            .focused($isSearchFocused)
                            .onSubmit { indexer.applySearch(); showSearchPopover = false }
                        Button("Find") { indexer.applySearch(); showSearchPopover = false }
                            .buttonStyle(.borderedProminent)
                        if !indexer.queryDraft.isEmpty {
                            Button(action: { indexer.queryDraft = ""; indexer.query = ""; indexer.recomputeNow() }) { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .help("Clear search")
                        }
                    }
                    .padding(10)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25)))
            .onChange(of: indexer.activeSearchUI) { _, newValue in
                if newValue == .sessionSearch {
                    showSearchPopover = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isSearchFocused = true
                    }
                } else {
                    isSearchFocused = false
                }
            }

            // Show active project filter with clear button
            if let projectFilter = indexer.projectFilter, !projectFilter.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                    Text(projectFilter)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Button(action: {
                        indexer.projectFilter = nil
                        indexer.recomputeNow()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove the project filter and show all sessions")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.1))
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.blue.opacity(0.3)))
            }

            Spacer(minLength: 0)
        }
    }
}
