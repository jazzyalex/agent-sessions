import Foundation

/// Bounded, thread-safe least-recently-used cache with O(1) get/set/remove/evict.
///
/// Entries live in an intrusive doubly-linked list (most-recently-used at `head`,
/// least at `tail`) beside a dictionary, so an insert that overflows a cap drops
/// the tail without scanning the whole map. `prev` is weak so the list holds no
/// retain cycles. All mutation is guarded by a single `NSLock`.
///
/// Two eviction caps are enforced together:
/// - `maxEntries`: hard upper bound on the number of resident entries.
/// - `maxTotalCost` (optional): hard upper bound on the summed per-entry cost,
///   where cost is computed by the `cost` closure supplied at init (default 1
///   per entry, i.e. count-only). Overflowing either cap evicts from the tail
///   until both hold.
///
/// This is a hot path; callers layer their own bookkeeping (indexing flags, miss
/// counters) on top and treat this purely as the storage/eviction primitive.
final class LRUCache<Key: Hashable, Value>: @unchecked Sendable {
    private final class Node {
        let key: Key
        var value: Value
        var cost: Int
        var next: Node?
        weak var prev: Node?

        init(key: Key, value: Value, cost: Int) {
            self.key = key
            self.value = value
            self.cost = cost
        }
    }

    private let lock = NSLock()
    private var nodes: [Key: Node] = [:]
    private var head: Node?              // most recently used
    private var tail: Node?              // least recently used
    private var totalCost: Int = 0

    private let maxEntries: Int
    private let maxTotalCost: Int?
    private let cost: (Value) -> Int

    /// - Parameters:
    ///   - maxEntries: hard cap on resident entry count.
    ///   - maxTotalCost: optional hard cap on summed per-entry cost.
    ///   - cost: per-entry cost function; defaults to 1 (count-only). Each entry's
    ///     cost is clamped to at least 1 so a zero-cost value can still be evicted.
    init(maxEntries: Int, maxTotalCost: Int? = nil, cost: @escaping (Value) -> Int = { _ in 1 }) {
        self.maxEntries = maxEntries
        self.maxTotalCost = maxTotalCost
        self.cost = cost
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Intrusive LRU list (all callers must hold `lock`)

    private func addToFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func detach(_ node: Node) {
        let p = node.prev
        let n = node.next
        p?.next = n
        n?.prev = p
        if head === node { head = n }
        if tail === node { tail = p }
        node.prev = nil
        node.next = nil
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        detach(node)
        addToFront(node)
    }

    private func removeNode(_ node: Node) {
        detach(node)
        nodes.removeValue(forKey: node.key)
        totalCost = max(0, totalCost - node.cost)
    }

    private func evictIfNeeded() {
        while nodes.count > maxEntries || (maxTotalCost.map { totalCost > $0 } ?? false) {
            guard let lru = tail else { break }
            removeNode(lru)
        }
    }

    // MARK: - Public API

    /// Retrieve the value for `key`, marking it most-recently-used (thread-safe).
    func get(_ key: Key) -> Value? {
        withLock {
            guard let node = nodes[key] else { return nil }
            moveToFront(node)
            return node.value
        }
    }

    /// Store `value` for `key`, marking it most-recently-used and evicting as
    /// needed to honor the caps (thread-safe).
    func set(_ key: Key, _ value: Value) {
        withLock {
            let newCost = max(1, cost(value))
            if let existing = nodes[key] {
                totalCost = max(0, totalCost - existing.cost)
                existing.value = value
                existing.cost = newCost
                totalCost += newCost
                moveToFront(existing)
            } else {
                let node = Node(key: key, value: value, cost: newCost)
                nodes[key] = node
                addToFront(node)
                totalCost += newCost
            }
            evictIfNeeded()
        }
    }

    /// Whether `key` is resident, without touching recency (thread-safe).
    func contains(_ key: Key) -> Bool {
        withLock { nodes[key] != nil }
    }

    /// Remove a single entry (thread-safe).
    func remove(_ key: Key) {
        withLock {
            guard let node = nodes[key] else { return }
            removeNode(node)
        }
    }

    /// Remove all entries (thread-safe).
    func removeAll() {
        withLock {
            nodes.removeAll()
            head = nil
            tail = nil
            totalCost = 0
        }
    }

    /// Current resident entry count (thread-safe).
    var count: Int {
        withLock { nodes.count }
    }
}

/// Reference box so an `NSCache` can hold a value type — including an *optional*
/// value. `NSCache` can't store `nil` (it treats it as "no entry"), so memoizing
/// a function whose miss result is `nil` requires wrapping the result in an object;
/// a boxed `.some(nil)` is a genuine cache hit, distinct from an absent key.
final class MemoBox<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Thin, string-keyed memoization wrapper over `NSCache` that boxes values through
/// `MemoBox`, so the same three-line "box class + static NSCache + reset hook"
/// scaffold isn't hand-rolled per call site. `Value` may itself be optional to
/// memoize functions whose miss result is `nil` (the box preserves that `nil` as
/// a real hit). `NSCache` handles its own eviction and thread-safety.
final class NSCacheMemo<Value>: @unchecked Sendable {
    private let cache = NSCache<NSString, MemoBox<Value>>()

    /// - Parameter countLimit: optional entry cap; `nil` leaves NSCache unbounded
    ///   (it still evicts under memory pressure).
    init(countLimit: Int? = nil) {
        if let countLimit { cache.countLimit = countLimit }
    }

    /// Cached value for `key`, or `nil` if the key is absent. Note: for an
    /// optional `Value`, a present-but-`nil` entry returns `.some(nil)`, so callers
    /// distinguishing "absent" from "cached nil" should compare against `nil` box
    /// membership via `contains` if needed.
    func object(forKey key: NSString) -> Value? {
        cache.object(forKey: key)?.value
    }

    /// Whether `key` has a cached entry (including a cached-`nil` entry).
    func contains(_ key: NSString) -> Bool {
        cache.object(forKey: key) != nil
    }

    func setObject(_ value: Value, forKey key: NSString) {
        cache.setObject(MemoBox(value), forKey: key)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
