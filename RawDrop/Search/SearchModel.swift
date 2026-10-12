import Foundation
import Observation

/// What the search dock and the grid share: the query, its results, and the
/// suggestions offered before anything is typed.
@MainActor
@Observable
final class SearchModel {

    struct Results {
        /// The query these answer, as typed.
        let query: String
        let photos: [RawPhoto]
        let sections: [DaySection]
        let position: [String: Int]
        let summary: [String]
        /// Apple Intelligence read the query, not just the keyword parser.
        let interpreted: Bool
    }

    /// A row in the suggestion stack. Tapping it searches for `query`.
    struct Suggestion: Identifiable {
        enum Icon { case thumbnail(RawPhoto), symbol(String) }
        let id: String
        let title: String
        let detail: String?
        let query: String
        let icon: Icon
    }

    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    private(set) var results: Results?
    private(set) var isInterpreting = false
    private(set) var recent: [String]
    /// The photos the current results were drawn from have been tagged.
    private(set) var engine: SearchEngine?

    var isActive: Bool { !trimmed.isEmpty }
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    @ObservationIgnored private var source: [RawPhoto] = []
    @ObservationIgnored private var places: [Date: String] = [:]
    @ObservationIgnored private var favourites: Set<String> = []
    @ObservationIgnored private var sent: Set<String> = []
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var stale = false
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var interpretTask: Task<Void, Never>?
    /// Model answers by query, so retyping a phrase does not ask twice.
    @ObservationIgnored private var interpreted: [String: SearchPlan] = [:]

    private static let recentKey = "recentSearches"

    init() {
        recent = UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
    }

    // MARK: Inputs

    /// The photos in scope changed: a new album, a reload, a new photo.
    func setSource(_ photos: [RawPhoto], places: [Date: String]) {
        source = photos
        self.places = places
        rebuild()
    }

    /// New tags arrived from the indexer. Rebuilt now if someone is
    /// searching; otherwise left until the search field is next opened.
    func tagsChanged() {
        if isActive { rebuild() } else { stale = true }
    }

    /// The search field is opening: make sure suggestions are current.
    func prepare() {
        if stale || engine == nil { rebuild() }
    }

    func setFlags(favourites: Set<String>, sent: Set<String>) {
        guard favourites != self.favourites || sent != self.sent else { return }
        self.favourites = favourites
        self.sent = sent
        if isActive { run(immediately: true) }
    }

    func clear() {
        query = ""
    }

    /// Return key: remember it, and let the model have a go at long phrasing.
    func submit() {
        let q = trimmed
        guard !q.isEmpty else { return }
        remember(q)
        if SearchText.tokens(q).count >= 3 || results?.photos.isEmpty == true {
            interpret(q)
        }
    }

    func apply(_ suggestion: Suggestion) {
        query = suggestion.query
        remember(suggestion.query)
    }

    func forget(_ q: String) {
        recent.removeAll { $0 == q }
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }

    private func remember(_ q: String) {
        recent.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        recent.insert(q, at: 0)
        recent = Array(recent.prefix(5))
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }

    // MARK: Index

    private func rebuild() {
        stale = false
        buildTask?.cancel()
        let photos = source
        buildTask = Task.detached(priority: .userInitiated) { [weak self] in
            let tags = TagStore.shared.snapshot()
            let engine = SearchEngine.build(photos: photos, tags: tags)
            if Task.isCancelled { return }
            await self?.install(engine)
        }
    }

    private func install(_ engine: SearchEngine) {
        self.engine = engine
        interpreted = [:]
        if isActive { run(immediately: true) }
    }

    // MARK: Running

    private func queryChanged() {
        interpretTask?.cancel()
        isInterpreting = false
        if !isActive {
            runTask?.cancel()
            results = nil
            return
        }
        run(immediately: false)
    }

    private func run(immediately: Bool) {
        runTask?.cancel()
        guard let engine else { return }
        let q = trimmed
        let plan = interpreted[q] ?? QueryParser.plan(q)
        let usedModel = interpreted[q] != nil
        let favourites = favourites, sent = sent, places = places

        runTask = Task.detached(priority: .userInitiated) { [weak self] in
            // Keystrokes arrive faster than results are worth drawing.
            if !immediately { try? await Task.sleep(for: .milliseconds(120)) }
            if Task.isCancelled { return }
            let hits = engine.run(plan, favourites: favourites, sent: sent).map { engine.photos[$0] }
            let results = Results(
                query: q,
                photos: hits,
                sections: DaySection.group(hits, places: places),
                position: Dictionary(uniqueKeysWithValues: hits.enumerated().map { ($1.id, $0) }),
                summary: plan.summary,
                interpreted: usedModel
            )
            if Task.isCancelled { return }
            await self?.publish(results, for: q)
        }
    }

    private func publish(_ results: Results, for q: String) {
        guard q == trimmed else { return }
        self.results = results
        // Nothing found for a few words typed and left: let the model try.
        if results.photos.isEmpty, !results.interpreted, SearchText.tokens(q).count >= 2 {
            interpret(q, after: .milliseconds(700))
        }
    }

    private func interpret(_ q: String, after delay: Duration = .zero) {
        guard QueryInterpreter.isAvailable, interpreted[q] == nil, let engine else { return }
        interpretTask?.cancel()
        let subjects = engine.knownSubjects
        interpretTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            self?.isInterpreting = true
            let plan = await QueryInterpreter.plan(for: q, knownSubjects: subjects)
            guard let self, !Task.isCancelled, q == self.trimmed else { return }
            self.isInterpreting = false
            guard let plan, !plan.isEmpty else { return }
            // Keep the model's reading only if it finds something the keywords did not.
            let found = engine.run(plan, favourites: self.favourites, sent: self.sent)
            if !found.isEmpty, found.count != self.results?.photos.count {
                self.interpreted[q] = plan
                self.run(immediately: true)
            }
        }
    }

    // MARK: Suggestions

    /// Before typing: favourites, what is waiting, recent searches, and the
    /// cameras, places and subjects this library is mostly made of. While
    /// typing: whichever of those the words so far could be the start of.
    func suggestions(favouriteCount: Int, latestFavourite: RawPhoto?, unsentCount: Int) -> [Suggestion] {
        let facets = engine?.facets ?? []
        let typed = SearchText.tokens(query)

        if typed.isEmpty {
            var out: [Suggestion] = []
            if favouriteCount > 0 {
                out.append(Suggestion(id: "fav", title: "Favourites", detail: favouriteCount.formatted(),
                                      query: "Favourites",
                                      icon: latestFavourite.map { .thumbnail($0) } ?? .symbol("heart.fill")))
            }
            if unsentCount > 0, unsentCount < (engine?.photos.count ?? 0) {
                out.append(Suggestion(id: "unsent", title: "Not sent yet", detail: unsentCount.formatted(),
                                      query: "Not sent", icon: .symbol("arrow.up.forward.app")))
            }
            for q in recent.prefix(2) {
                out.append(Suggestion(id: "recent-\(q)", title: q, detail: nil, query: q, icon: .symbol("clock")))
            }
            let picks = facets.filter { $0.kind == .camera }.prefix(1)
                + facets.filter { $0.kind == .place }.prefix(2)
                + facets.filter { $0.kind == .subject }.prefix(2)
            for facet in picks { out.append(suggestion(for: facet)) }
            return Array(out.prefix(7))
        }

        // Every typed word must start some word of the facet.
        let matching = facets.filter { facet in
            let words = facet.words
            return typed.allSatisfy { t in words.contains { $0.hasPrefix(t) } }
        }
        return matching.prefix(4).map(suggestion(for:))
    }

    private func suggestion(for facet: SearchEngine.Facet) -> Suggestion {
        Suggestion(id: facet.id, title: facet.kind == .subject ? facet.label.capitalized : facet.label,
                   detail: facet.count.formatted(), query: facet.label, icon: .thumbnail(facet.latest))
    }
}
