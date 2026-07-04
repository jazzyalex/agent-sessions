import Foundation

/// Pure, `Sendable` extraction of `UnifiedSessionsView.updateCachedRows()`'s heavy
/// phases (hierarchy build + row-derived state), so the computation can run off
/// the main actor and be applied as a generation-checked snapshot.
///
/// Deliberately narrow scope: this does NOT include `rows` (the filtered/sorted
/// session list `UnifiedSessionsView` derives before calling the builder) — that
/// filter depends on `CodexActiveSessionsModel.presence(for:)`, a main-actor
/// lookup against live, frequently-mutated presence caches (see docs plan W3
/// Task 1/3). Folding that in is out of scope for this extraction; `nextRows` is
/// passed in already computed by the caller on main.
enum SessionRowsBuilder {
    /// Cheap identity signature for the fallback-presence map's inputs (E3).
    /// `buildFallbackPresenceMap` is the heaviest single step in `build` (W7
    /// Task 0 fingerprint: 43ms/call, 170 samples on main before this moved
    /// off-main) and it depends only on `allSessions`, `presences`, and the
    /// direct-join key set -- none of which change on every rebuild trigger.
    /// In particular `UnifiedSessionsView.onChange(of: unified.sessions)`
    /// fires on the ~2s live-poll cadence even when `allSessions` is
    /// content-identical (a republish, not a real change), so recomputing the
    /// map on every such tick was pure waste.
    ///
    /// Deliberately a cheap per-session (id, modifiedAt) signature rather than
    /// a full deep-equality check -- matches the identity semantics already
    /// used elsewhere in this pipeline (`UnifiedTableIdentityPolicy`,
    /// `SessionListFingerprint`) that a session is "the same" for rebuild
    /// purposes when its id and modifiedAt haven't changed.
    struct FallbackPresenceSignature: Equatable {
        private struct SessionIdentity: Equatable {
            let id: String
            let modifiedAt: Date
        }

        private let sessionIdentities: [SessionIdentity]
        private let presences: [CodexActivePresence]
        private let directJoinFallbackKeys: Set<String>

        init(allSessions: [Session], presences: [CodexActivePresence], directJoinFallbackKeys: Set<String>) {
            self.sessionIdentities = allSessions.map { SessionIdentity(id: $0.id, modifiedAt: $0.modifiedAt) }
            self.presences = presences
            self.directJoinFallbackKeys = directJoinFallbackKeys
        }
    }

    /// Thread-safety note: `build(input:)` runs off-main via `Task.detached`
    /// (see doc comment below) and successive rebuild triggers can overlap in
    /// flight before an earlier one's generation-check drops it on apply, so
    /// this cache is lock-protected rather than a plain `static var`.
    private static let fallbackPresenceCacheLock = NSLock()
    nonisolated(unsafe) private static var _fallbackPresenceCache: (signature: FallbackPresenceSignature, map: [String: CodexActivePresence])?
#if DEBUG
    nonisolated(unsafe) private static var _fallbackPresenceComputeCount: UInt64 = 0

    /// Test hook only: number of times `buildFallbackPresenceMap` actually ran
    /// (as opposed to being served from `_fallbackPresenceCache`). Lets the E3
    /// regression test assert on cache reuse without depending on object
    /// identity of the returned dictionary (which Swift's `Dictionary` COW
    /// representation doesn't guarantee to preserve across an equal-input
    /// no-op path anyway).
    static func debugFallbackPresenceComputeCount() -> UInt64 {
        fallbackPresenceCacheLock.lock()
        defer { fallbackPresenceCacheLock.unlock() }
        return _fallbackPresenceComputeCount
    }

    static func debugResetFallbackPresenceCache() {
        fallbackPresenceCacheLock.lock()
        _fallbackPresenceCache = nil
        _fallbackPresenceComputeCount = 0
        fallbackPresenceCacheLock.unlock()
    }
#endif

    private static func fallbackPresenceCache(matching signature: FallbackPresenceSignature) -> [String: CodexActivePresence]? {
        fallbackPresenceCacheLock.lock()
        defer { fallbackPresenceCacheLock.unlock() }
        guard let cached = _fallbackPresenceCache, cached.signature == signature else { return nil }
        return cached.map
    }

    private static func storeFallbackPresenceCache(signature: FallbackPresenceSignature, map: [String: CodexActivePresence]) {
        fallbackPresenceCacheLock.lock()
        _fallbackPresenceCache = (signature, map)
#if DEBUG
        _fallbackPresenceComputeCount &+= 1
#endif
        fallbackPresenceCacheLock.unlock()
    }

    /// Snapshot of everything the heavy phases need. Every field is `Sendable`
    /// value data so this can cross into a detached task with no isolation
    /// concerns.
    struct RowsInput: Sendable {
        /// The already filtered + sorted session list (`UnifiedSessionsView.rows`
        /// at the moment the rebuild was triggered).
        let nextRows: [Session]
        /// `unified.allSessions` — needed for side-chat parent-title resolution,
        /// which may reference a parent session outside the current filtered set.
        let allSessions: [Session]
        /// The previous `cachedRows`, used to detect a large wholesale reorder.
        let previousCachedRows: [Session]
        let collapsedParents: Set<String>
        let showSubagentHierarchy: Bool
        /// True when a search query is active — hierarchy nesting is suppressed
        /// while searching (matches must be shown flat).
        let searchActive: Bool
        /// `isHierarchyBrowsing` at trigger time — gates whether
        /// `cachedExpandableParentIDs` is computed at all.
        let isHierarchyBrowsing: Bool
        /// `activeCodexSessions.presences` snapshot (Sendable value data) and the
        /// set of fallback keys that already resolved via a direct join (computed
        /// on main -- see `UnifiedSessionsView.directJoinFallbackKeys`, which is
        /// the one part of this pipeline that cannot move off-main because it
        /// calls into `CodexActiveSessionsModel`'s private lookup caches). The
        /// heavy grouping/sorting in `buildFallbackPresenceMap` itself is pure
        /// and runs here, off-main (W7 Task 1 Step 6c).
        let presences: [CodexActivePresence]
        let directJoinFallbackKeys: Set<String>

        init(nextRows: [Session],
             allSessions: [Session],
             previousCachedRows: [Session],
             collapsedParents: Set<String>,
             showSubagentHierarchy: Bool,
             searchActive: Bool,
             isHierarchyBrowsing: Bool,
             presences: [CodexActivePresence],
             directJoinFallbackKeys: Set<String>) {
            self.nextRows = nextRows
            self.allSessions = allSessions
            self.previousCachedRows = previousCachedRows
            self.collapsedParents = collapsedParents
            self.showSubagentHierarchy = showSubagentHierarchy
            self.searchActive = searchActive
            self.isHierarchyBrowsing = isHierarchyBrowsing
            self.presences = presences
            self.directJoinFallbackKeys = directJoinFallbackKeys
        }
    }

    /// Result of the heavy phases, ready to be assigned to `UnifiedSessionsView`'s
    /// `@State` on the main actor in one turn.
    struct RowsOutput: Sendable {
        let cachedRows: [Session]
        let hierarchyRowMeta: [String: SubagentRowMeta]
        let sideChatParentContextByID: [String: String]
        let cachedRowIDs: [String]
        let cachedVisibleRowIDs: Set<String>
        let cachedExpandableParentIDs: Set<String>
        /// O(1) id -> row lookup, built once per rebuild so callers (selection
        /// bookkeeping, cockpit navigation) stop doing O(n) `first(where:)` scans
        /// per click.
        let cachedRowByID: [String: Session]
        /// Whether `previousCachedRows` -> `cachedRows` is a large wholesale
        /// reorder (see `UnifiedTableIdentityPolicy.isLargeReorder`). The caller
        /// bumps `tableReorderGeneration` on apply when this is true — that bump
        /// must happen in the same main-actor turn as assigning `cachedRows`.
        let isLargeReorder: Bool
        /// Precomputed `UnifiedSessionsView.staticSurfacePills(for:)` per row, so
        /// `cellSource(for:)` stops allocating a pills array + doing lowercased
        /// string compares on every row-body call (W7 Task 0 fingerprint). Static
        /// only -- the live Claude Desktop `isArchived` bit is patched in at
        /// render time via `applyingLiveClaudeArchiveState`.
        let surfacePillsBySessionID: [String: [UnifiedSessionsView.CodexSurfacePill]]
        /// `UnifiedSessionsView.buildFallbackPresenceMap` result, computed here
        /// off-main instead of on every `prepareRowsRebuild()` call (W7 Task 1
        /// Step 6c; Task 0 fingerprint: `fallbackPresences` span, 43ms/call, 170
        /// samples on main).
        let fallbackPresenceBySessionKey: [String: CodexActivePresence]
    }

    /// Build the hierarchy + row-derived state. Pure function — safe to call from
    /// any isolation context (this is what makes it runnable via
    /// `Task.detached`).
    static func build(input: RowsInput) -> RowsOutput {
        let hierarchyResult = SubagentHierarchyBuilder.build(
            sessions: input.nextRows,
            collapsedParents: input.collapsedParents,
            hierarchyEnabled: input.showSubagentHierarchy && !input.searchActive
        )
        let newRows = hierarchyResult.sessions

        let isLargeReorder = UnifiedTableIdentityPolicy.isLargeReorder(
            old: input.previousCachedRows,
            new: newRows
        )

        let sideChatParentContextByID = UnifiedSessionsView.sideChatParentContexts(
            for: newRows,
            allSessions: input.allSessions
        )

        let cachedRowIDs = newRows.map(\.id)
        let cachedVisibleRowIDs = Set(cachedRowIDs)
        var cachedRowByID: [String: Session] = [:]
        cachedRowByID.reserveCapacity(newRows.count)
        for row in newRows {
            cachedRowByID[row.id] = row
        }

        let cachedExpandableParentIDs: Set<String>
        if input.isHierarchyBrowsing {
            cachedExpandableParentIDs = Set(newRows.compactMap { session in
                hierarchyResult.rowMeta[session.id]?.hasChildren == true ? session.id : nil
            })
        } else {
            cachedExpandableParentIDs = []
        }

        var surfacePillsBySessionID: [String: [UnifiedSessionsView.CodexSurfacePill]] = [:]
        surfacePillsBySessionID.reserveCapacity(newRows.count)
        for row in newRows {
            surfacePillsBySessionID[row.id] = staticSurfacePills(for: row)
        }

        // E3: the fallback-presence map only depends on `allSessions` identity
        // (per-session id/modifiedAt) and the presence/direct-join inputs, but
        // this rebuild used to recompute it unconditionally on every trigger --
        // including the ~2s live-poll cadence
        // (`UnifiedSessionsView.onChange(of: unified.sessions)`), even when
        // none of those inputs actually changed. Reuse the cached map when the
        // signature matches; only recompute (and update the cache) on a
        // genuine change.
        let fallbackSignature = FallbackPresenceSignature(
            allSessions: input.allSessions,
            presences: input.presences,
            directJoinFallbackKeys: input.directJoinFallbackKeys
        )
        let fallbackPresenceBySessionKey: [String: CodexActivePresence]
        if let cached = fallbackPresenceCache(matching: fallbackSignature) {
            fallbackPresenceBySessionKey = cached
        } else {
#if DEBUG
            let _fpSpan = Perf.begin("fallbackPresences", thresholdMs: 4)
#endif
            fallbackPresenceBySessionKey = buildFallbackPresenceMap(
                sessions: input.allSessions,
                presences: input.presences,
                directJoinSessionKeys: input.directJoinFallbackKeys
            )
#if DEBUG
            Perf.end(_fpSpan)
#endif
            storeFallbackPresenceCache(signature: fallbackSignature, map: fallbackPresenceBySessionKey)
        }

        return RowsOutput(
            cachedRows: newRows,
            hierarchyRowMeta: hierarchyResult.rowMeta,
            sideChatParentContextByID: sideChatParentContextByID,
            cachedRowIDs: cachedRowIDs,
            cachedVisibleRowIDs: cachedVisibleRowIDs,
            cachedExpandableParentIDs: cachedExpandableParentIDs,
            cachedRowByID: cachedRowByID,
            isLargeReorder: isLargeReorder,
            surfacePillsBySessionID: surfacePillsBySessionID,
            fallbackPresenceBySessionKey: fallbackPresenceBySessionKey
        )
    }

    // MARK: - Surface-pill classification (T2/S2)
    //
    // Moved from `UnifiedSessionsView` -- pure business logic over `Session`
    // data with no SwiftUI dependency. `CodexSurfacePill` itself stays on
    // `UnifiedSessionsView` since it carries presentation (`Color`/`Font`)
    // methods; these functions just classify which pill(s) apply and return
    // that View-owned type by qualified name.

    /// Live-presence-independent variant of `surfacePills`, always resolving the
    /// Claude Desktop `isArchived` bit to `false`. This is the part that's safe to
    /// precompute once per rows rebuild (`build` above) instead of per row-body
    /// call, since it depends only on static `Session` fields.
    /// `UnifiedSessionsView.cellSource(for:)` patches in the live
    /// `isArchivedClaudeDesktop` bit at render time via
    /// `applyingLiveClaudeArchiveState(to:session:isClaudeArchived:)` -- see
    /// that function's doc comment for why the patch is safe.
    static func staticSurfacePills(for session: Session) -> [UnifiedSessionsView.CodexSurfacePill] {
        surfacePills(for: session, isClaudeArchived: false)
    }

    /// Patches the live Claude Desktop archived bit into a precomputed static
    /// pills array: a lone unarchived "desk" pill on a non-side-chat `.claude`
    /// session becomes `[.desktop(isArchived: true)]` when the live archive
    /// join says the session is archived. No other pill shape is touched.
    ///
    /// DELIBERATE DIVERGENCE from the legacy single-call
    /// `surfacePills(for:isClaudeArchived:)`: a Claude session can reach a
    /// `[.desktop(isArchived: false)]` pill through the `surface == .desktop`
    /// SWITCH branch (e.g. `originSource == "claude-desktop"`, which
    /// `claudeDesktopSurfacePill` does NOT match) while
    /// `isArchivedClaudeDesktop` is true via the filename-UUID sidecar join
    /// (`Session.claudeArchiveJoinKey`). Legacy left that pill unarchived --
    /// the `isClaudeArchived` parameter was only ever consulted inside
    /// `claudeDesktopSurfacePill`, so the switch branch ignored it. This patch
    /// promotes it to archived. Adjudicated as the intended behavior in the
    /// 8a3512f0 review: an archived session should show the archived pill
    /// regardless of which heuristic classified it as Desktop; the legacy
    /// non-promotion was the bug. Pinned by
    /// `testApplyingLiveClaudeArchiveStatePromotesSwitchBranchDesktopPill`.
    ///
    /// `!session.isSideChat` matters: a side-chat session ALSO produces a
    /// `[.standard(label: "desk", ...)]` pill (surfacePills's `isSideChat`
    /// branch fires before `claudeDesktopSurfacePill` is ever consulted), which
    /// is label/isArchived-identical to an unarchived Claude Desktop pill but
    /// must never be promoted to an archived Desktop pill here.
    static func applyingLiveClaudeArchiveState(
        to staticPills: [UnifiedSessionsView.CodexSurfacePill],
        session: Session,
        isClaudeArchived: Bool
    ) -> [UnifiedSessionsView.CodexSurfacePill] {
        guard session.source == .claude,
              !session.isSideChat,
              isClaudeArchived,
              staticPills.count == 1,
              staticPills[0].label == "desk",
              staticPills[0].isArchived == false else {
            return staticPills
        }
        return [.desktop(isArchived: true)]
    }

    static func surfacePills(for session: Session, isClaudeArchived: Bool = false) -> [UnifiedSessionsView.CodexSurfacePill] {
        if session.isSideChat {
            return [.standard(label: "desk", accessibilityLabel: "Desktop")]
        }
        if let claudeDesktopPill = claudeDesktopSurfacePill(for: session, isArchived: isClaudeArchived) {
            return [claudeDesktopPill]
        }

        switch session.surface ?? session.codexSurface {
        case .desktop:
            return [.desktop(isArchived: session.isArchivedCodexDesktopSession)]
        case .vscode:
            guard session.source == .codex else { return [] }
            return [.standard(label: "vsc", accessibilityLabel: "VS Code")]
        case .cli:
            guard supportsAgentSurfacePills(session) else { return [] }
            return [.standard(label: "cli", accessibilityLabel: "CLI")]
        case .subagent:
            guard session.source == .codex else { return [] }
            return codexOriginatorSurfacePill(for: session).map { [$0] } ?? []
        case .other, .unknown, .none:
            if session.isCodexDesktopSession {
                return [.desktop(isArchived: session.isArchivedCodexDesktopSession)]
            }
            guard supportsAgentSurfacePills(session) else { return [] }
            return session.isSubagent ? [] : [.standard(label: "cli", accessibilityLabel: "CLI")]
        }
    }

    private static func supportsAgentSurfacePills(_ session: Session) -> Bool {
        session.source == .codex || session.source == .claude
    }

    private static func claudeDesktopSurfacePill(for session: Session, isArchived: Bool) -> UnifiedSessionsView.CodexSurfacePill? {
        guard session.source == .claude else { return nil }
        let originator = session.originator?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let originSource = session.originSource?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if originator == "claude desktop" || originSource == "local-agent-mode" || isClaudeDesktopLocalAgentPath(session.filePath) {
            return .desktop(isArchived: isArchived)
        }
        return nil
    }

    private static func isClaudeDesktopLocalAgentPath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        return components.contains("local-agent-mode-sessions") &&
            components.contains(".claude") &&
            components.contains("projects") &&
            components.contains { $0.hasPrefix("local_") }
    }

    private static func codexOriginatorSurfacePill(for session: Session) -> UnifiedSessionsView.CodexSurfacePill? {
        let originator = session.codexOriginator?.lowercased()
        if originator == "codex desktop" ||
            originator?.contains("desktop") == true ||
            originator?.contains("app") == true {
            return .desktop(isArchived: session.isArchivedCodexDesktopSession)
        }
        if originator == "codex_vscode" {
            return .standard(label: "vsc", accessibilityLabel: "VS Code")
        }
        if originator == "codex_cli_rs" || originator == "codex-tui" {
            return .standard(label: "cli", accessibilityLabel: "CLI")
        }
        return nil
    }

    // MARK: - Fallback-presence join (T2/S2)
    //
    // Moved from `UnifiedSessionsView` -- pure over `Sendable` inputs, no View
    // dependency. `directJoinFallbackKeys(for:presenceLookup:)` below is the
    // shared helper that replaces the byte-identical
    // `supportedFallbackSources`/`directJoinFallbackKeys` blocks that used to
    // live separately in `CockpitView.makeLiveRowsSnapshot()` and
    // `AgentCockpitHUDView.makeRowsSnapshot(...)` (S2).

    /// Builds the reverse (session -> presence) fallback join used when a session
    /// has no presence directly keyed to it (no session-specific join signals in
    /// the presence payload) but can still be matched by workspace/cwd or, failing
    /// that, by ordinal position within its source. Pure over `Sendable` inputs --
    /// runnable off the main actor via `build` above (W7 Task 1; Task 0
    /// fingerprint: 170 samples / 43ms-per-call spans on main).
    ///
    /// `directJoinSessionKeys` replaces the old `hasDirectJoin: (Session) -> Bool`
    /// closure parameter, which called `CodexActiveSessionsModel.presence(for:)`
    /// (main-actor: reads `latestSnapshot`/`lookupCacheEntry`, not just the
    /// Sendable `presences` array) -- that lookup itself cannot move off-main
    /// without duplicating the model's private cache logic, so the caller
    /// precomputes the direct-join key set on main (`directJoinFallbackKeys`,
    /// cheap: same call count as before) and hands it in as plain `Set<String>`
    /// data instead.
    static func buildFallbackPresenceMap(sessions: [Session],
                                         presences: [CodexActivePresence],
                                         directJoinSessionKeys: Set<String>) -> [String: CodexActivePresence] {
        let supportedSources: Set<SessionSource> = [.claude, .opencode]
        var fallbackBySessionKey: [String: CodexActivePresence] = [:]
        var fallbackEligibleBySource: [SessionSource: [Session]] = [:]
        var fallbackEligibleByWorkspace: [String: [Session]] = [:]

        for session in sessions where supportedSources.contains(session.source) {
            let key = fallbackPresenceKey(source: session.source, sessionID: session.id)
            guard !directJoinSessionKeys.contains(key) else { continue }
            fallbackEligibleBySource[session.source, default: []].append(session)

            guard let cwdRaw = session.cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cwdRaw.isEmpty else { continue }
            let normalizedCWD = CodexActiveSessionsModel.normalizePath(cwdRaw)
            guard !normalizedCWD.isEmpty else { continue }
            let workspaceKey = fallbackWorkspaceKey(source: session.source, normalizedCWD: normalizedCWD)
            fallbackEligibleByWorkspace[workspaceKey, default: []].append(session)
        }

        var claimableWorkspacePresences: [String: [CodexActivePresence]] = [:]
        var unresolvedPresencesBySource: [SessionSource: [CodexActivePresence]] = [:]

        for presence in presences where supportedSources.contains(presence.source) {
            if !presenceHasSessionSpecificJoinSignals(presence),
               let workspaceRaw = presence.workspaceRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
               !workspaceRaw.isEmpty {
                let normalizedWorkspace = CodexActiveSessionsModel.normalizePath(workspaceRaw)
                if !normalizedWorkspace.isEmpty {
                    let workspaceKey = fallbackWorkspaceKey(source: presence.source, normalizedCWD: normalizedWorkspace)
                    claimableWorkspacePresences[workspaceKey, default: []].append(presence)
                }
            }

            guard !presenceHasStrongJoinSignals(presence) else { continue }
            guard hasFallbackIdentitySignals(presence) else { continue }
            unresolvedPresencesBySource[presence.source, default: []].append(presence)
        }

        for (workspaceKey, candidateSessions) in fallbackEligibleByWorkspace {
            guard let workspacePresences = claimableWorkspacePresences[workspaceKey], !workspacePresences.isEmpty else {
                continue
            }
            let orderedSessions = candidateSessions.sorted(by: fallbackSessionSort)
            let orderedPresences = workspacePresences.sorted(by: fallbackPresenceSort)
            let limit = min(orderedSessions.count, orderedPresences.count)
            guard limit > 0 else { continue }
            for index in 0..<limit {
                let key = fallbackPresenceKey(
                    source: orderedSessions[index].source,
                    sessionID: orderedSessions[index].id
                )
                guard fallbackBySessionKey[key] == nil else { continue }
                fallbackBySessionKey[key] = orderedPresences[index]
            }
        }

        for source in supportedSources {
            guard let sourceSessions = fallbackEligibleBySource[source], !sourceSessions.isEmpty else { continue }
            guard let unresolvedPresences = unresolvedPresencesBySource[source], !unresolvedPresences.isEmpty else { continue }

            let remainingSessions = sourceSessions.filter {
                let key = fallbackPresenceKey(source: $0.source, sessionID: $0.id)
                return fallbackBySessionKey[key] == nil
            }
            guard !remainingSessions.isEmpty else { continue }

            let orderedSessions = remainingSessions.sorted(by: fallbackSessionSort)
            let orderedPresences = unresolvedPresences.sorted(by: fallbackPresenceSort)
            let limit = min(orderedSessions.count, orderedPresences.count)
            guard limit > 0 else { continue }
            for index in 0..<limit {
                let key = fallbackPresenceKey(
                    source: orderedSessions[index].source,
                    sessionID: orderedSessions[index].id
                )
                guard fallbackBySessionKey[key] == nil else { continue }
                fallbackBySessionKey[key] = orderedPresences[index]
            }
        }

        return fallbackBySessionKey
    }

    static func fallbackPresenceKey(source: SessionSource, sessionID: String) -> String {
        "\(source.rawValue)|session:\(sessionID)"
    }

    private static func fallbackWorkspaceKey(source: SessionSource, normalizedCWD: String) -> String {
        "\(source.rawValue)|cwd:\(normalizedCWD)"
    }

    private static func hasFallbackIdentitySignals(_ presence: CodexActivePresence) -> Bool {
        let hasTTY = presence.tty?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasPID = presence.pid != nil
        let hasITermID = presence.terminal?.itermSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasTTY || hasPID || hasITermID
    }

    private static func presenceHasSessionSpecificJoinSignals(_ presence: CodexActivePresence) -> Bool {
        let hasSessionID = presence.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasLogPath = presence.sessionLogPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasSessionID || hasLogPath
    }

    static func fallbackClaimedPresence(for session: Session,
                                        among candidateSessions: [Session],
                                        using fallbackPresences: [CodexActivePresence]) -> CodexActivePresence? {
        guard !candidateSessions.isEmpty, !fallbackPresences.isEmpty else { return nil }
        let orderedSessions = candidateSessions.sorted(by: fallbackSessionSort)
        guard let rank = orderedSessions.firstIndex(where: { $0.source == session.source && $0.id == session.id }) else {
            return nil
        }
        let orderedPresences = fallbackPresences.sorted(by: fallbackPresenceSort)
        guard rank < orderedPresences.count else { return nil }
        return orderedPresences[rank]
    }

    static func fallbackEligibleSessions(from candidateSessions: [Session],
                                         hasDirectJoin: (Session) -> Bool) -> [Session] {
        candidateSessions.filter { !hasDirectJoin($0) }
    }

    static func fallbackSessionSort(_ lhs: Session, _ rhs: Session) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        if lhs.startTime != rhs.startTime { return (lhs.startTime ?? .distantPast) > (rhs.startTime ?? .distantPast) }
        if lhs.filePath != rhs.filePath { return lhs.filePath < rhs.filePath }
        return lhs.id < rhs.id
    }

    static func fallbackPresenceSort(_ lhs: CodexActivePresence, _ rhs: CodexActivePresence) -> Bool {
        let leftSeen = lhs.lastSeenAt ?? .distantPast
        let rightSeen = rhs.lastSeenAt ?? .distantPast
        if leftSeen != rightSeen { return leftSeen > rightSeen }

        let leftStarted = lhs.startedAt ?? .distantPast
        let rightStarted = rhs.startedAt ?? .distantPast
        if leftStarted != rightStarted { return leftStarted > rightStarted }

        let leftKey = CodexActiveSessionsModel.presenceKey(for: lhs)
        let rightKey = CodexActiveSessionsModel.presenceKey(for: rhs)
        if leftKey != rightKey { return leftKey < rightKey }
        return (lhs.pid ?? .min) < (rhs.pid ?? .min)
    }

    private static func presenceHasStrongJoinSignals(_ presence: CodexActivePresence) -> Bool {
        let hasSessionID = presence.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasLogPath = presence.sessionLogPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasWorkspace = presence.workspaceRoot?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasSourcePath = presence.sourceFilePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasSessionID || hasLogPath || hasWorkspace || hasSourcePath
    }

    /// Shared helper (S2): the direct-join key set computation was
    /// byte-identical across `CockpitView.makeLiveRowsSnapshot()` and
    /// `AgentCockpitHUDView.makeRowsSnapshot(...)` (each had its own copy of
    /// `supportedFallbackSources`/`directJoinFallbackKeys`). `presenceLookup`
    /// stays a closure rather than a concrete `CodexActiveSessionsModel`
    /// parameter so this file doesn't need to import/depend on that type --
    /// callers pass `activeCodex.presence(for:)` directly.
    static func directJoinFallbackKeys(for sessions: [Session],
                                       presenceLookup: (Session) -> CodexActivePresence?) -> Set<String> {
        let supportedSources: Set<SessionSource> = [.claude, .opencode]
        var keys: Set<String> = []
        for session in sessions where supportedSources.contains(session.source) {
            guard presenceLookup(session) != nil else { continue }
            keys.insert(fallbackPresenceKey(source: session.source, sessionID: session.id))
        }
        return keys
    }
}
