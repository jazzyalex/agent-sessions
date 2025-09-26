import SwiftUI

struct SearchFiltersView: View {
    @EnvironmentObject var indexer: SessionIndexer
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search", text: $indexer.queryDraft)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 160)
                    .focused($isSearchFocused)
                    .onSubmit { indexer.applySearch() }

                Button(action: { indexer.applySearch() }) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Search transcripts")

                if !indexer.queryDraft.isEmpty {
                    Button(action: {
                        indexer.queryDraft = ""
                        indexer.query = ""
                        indexer.recomputeNow()
                    }) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.25)))
            .onReceive(indexer.$requestFocusSearch) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isSearchFocused = true
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
                    .help("Clear project filter")
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
