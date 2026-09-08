import Foundation

/// The chosen photos, in the order they were chosen. Order matters once the
/// user goes over the Lightroom limit: "keep the first 50" has to mean the
/// first 50 they actually picked.
struct Selection: Equatable {
    private(set) var order: [String] = []
    private var members: Set<String> = []

    var count: Int { order.count }
    var isEmpty: Bool { order.isEmpty }
    var ids: Set<String> { members }

    func contains(_ id: String) -> Bool { members.contains(id) }

    mutating func insert(_ id: String) {
        guard members.insert(id).inserted else { return }
        order.append(id)
    }

    mutating func remove(_ id: String) {
        guard members.remove(id) != nil else { return }
        order.removeAll { $0 == id }
    }

    mutating func toggle(_ id: String) {
        if contains(id) { remove(id) } else { insert(id) }
    }

    mutating func formUnion(_ ids: some Sequence<String>) {
        for id in ids { insert(id) }
    }

    mutating func subtract(_ ids: some Sequence<String>) {
        let gone = Set(ids)
        members.subtract(gone)
        order.removeAll { gone.contains($0) }
    }

    mutating func removeAll() {
        order = []
        members = []
    }

    /// Keep the first `limit` picked, drop the rest.
    mutating func trim(to limit: Int) {
        guard order.count > limit else { return }
        order = Array(order.prefix(limit))
        members = Set(order)
    }

    init() {}
    init(_ ids: some Sequence<String>) { formUnion(ids) }
}
