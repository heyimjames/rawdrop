import Foundation
import NaturalLanguage

/// Lowercase, accent-free words. Indexing and querying both go through here,
/// so they always agree on what a word is.
enum SearchText {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "en_US_POSIX"))
    }

    /// "Kellogg's ƒ/1.4 X100VI" → ["kelloggs", "f1.4", "x100vi"]
    static func tokens(_ s: String) -> [String] {
        let chars = Array(fold(s.replacingOccurrences(of: "ƒ", with: "f")))
        var out: [String] = []
        var current = ""
        for (i, c) in chars.enumerated() {
            let nextIsDigit = i + 1 < chars.count && chars[i + 1].isNumber
            if c.isLetter || c.isNumber {
                current.append(c)
            } else if c == "'" || c == "’" {
                continue                                        // kellogg's → kelloggs
            } else if c == ".", current.last?.isNumber == true, nextIsDigit {
                current.append(c)                               // 1.4 stays 1.4
            } else if c == "/", current == "f", nextIsDigit {
                continue                                        // f/1.4 → f1.4
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

/// A search, worked out. Every term must match; a term matches when any one
/// of its spellings does; a spelling of several words needs all of them.
struct SearchPlan: Equatable, Sendable {
    var terms: [[String]] = []
    var favourites = false
    var sent: Bool?
    var dates: ClosedRange<Date>?
    /// Plain words for what was understood, shown under the title.
    var summary: [String] = []

    var isEmpty: Bool { terms.isEmpty && !favourites && sent == nil && dates == nil }
}

/// Typed words → a plan, with no model involved. Handles the phrasing people
/// actually type: "shot on the fuji in nyc last summer", "favourites", "unsent".
enum QueryParser {

    static let stopwords: Set<String> = [
        "photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "shot", "shots",
        "raw", "raws", "of", "in", "at", "on", "the", "a", "an", "from", "with", "my", "me", "show",
        "find", "all", "taken", "and", "near", "around", "by", "some", "any", "that", "was", "were",
        "i", "we", "our", "to", "for", "is", "are", "where", "there", "using", "during",
        "things", "stuff", "yet", "ones", "everything", "anything", "have", "has", "had",
    ]

    static let negations: Set<String> = [
        "not", "never", "havent", "hasnt", "didnt", "dont", "wasnt", "werent", "isnt", "arent",
    ]

    static let favouriteWords: Set<String> = [
        "favourite", "favourites", "favorite", "favorites", "fav", "favs", "fave", "faves",
        "hearted", "loved", "liked", "starred",
    ]

    /// Other ways of saying what the index stores. Multi-word spellings must
    /// all match: "nyc" finds photos tagged both "new" and "york".
    static let aliases: [String: [String]] = [
        "fuji": ["fujifilm"], "nyc": ["new york city"], "ny": ["new york"], "la": ["los angeles"],
        "sf": ["san francisco"], "dc": ["washington"], "uk": ["united kingdom"], "gb": ["united kingdom"],
        "britain": ["united kingdom"], "usa": ["united states"], "us": ["united states"],
        "america": ["united states"], "nl": ["netherlands"], "holland": ["netherlands"],
        "friends": ["people"], "friend": ["people"], "humans": ["people"], "human": ["people"],
        "woman": ["people"], "women": ["people"], "man": ["people"], "men": ["people"],
        "girl": ["people"], "boy": ["people"], "someone": ["people"], "kids": ["child"],
        "fall": ["autumn"], "autumn": ["fall"], "dark": ["night"], "evening": ["evening", "night"],
        "selfie": ["people"], "portrait": ["portrait", "people"],
        "drinks": ["drink", "beverage"], "soda": ["drink", "beverage"], "coffee": ["coffee", "drink"],
        "sweets": ["candy", "dessert"], "snacks": ["food", "snack"],
        "shop": ["shop", "store", "grocery"], "store": ["store", "shop", "grocery"],
        "car": ["car", "vehicle", "automobile"], "cars": ["car", "vehicle", "automobile"],
        "street": ["street", "road", "sidewalk"], "streets": ["street", "road", "sidewalk"],
    ]

    /// Two-letter aliases. Matched exactly, or "us" would find every "used".
    static let shortAliases: Set<String> = Set(aliases.keys.filter { $0.count <= 2 })

    static func plan(_ query: String, now: Date = .now, calendar: Calendar = .current) -> SearchPlan {
        let words = SearchText.tokens(query)
        var plan = SearchPlan()
        /// "not", "haven't", "never": applies to the next sent-word only.
        var negated = false
        var i = 0
        while i < words.count {
            let word = words[i]
            let next = i + 1 < words.count ? words[i + 1] : nil

            if negations.contains(word) {
                negated = true; i += 1; continue
            }
            if word == "sent" || word == "lightroom" || word == "exported" || (word == "in" && next == "lightroom") {
                // "sent to lightroom" is one thought, not two: the first word decides.
                if plan.sent == nil {
                    plan.sent = !negated
                    plan.summary.append(negated ? "not sent" : "sent")
                }
                negated = false
                i += (word == "in") ? 2 : 1
                continue
            }
            if (word == "this" || word == "last" || word == "past"), let next,
               let range = relative(word, next, now: now, calendar: calendar) {
                plan.dates = range; plan.summary.append("\(word) \(next)"); i += 2; continue
            }
            if let range = relative(word, nil, now: now, calendar: calendar) {
                plan.dates = range; plan.summary.append(word); i += 1; continue
            }
            if favouriteWords.contains(word) {
                plan.favourites = true; plan.summary.append("favourites"); i += 1; continue
            }
            if word == "unsent" || word == "waiting" {
                plan.sent = false; plan.summary.append("not sent"); i += 1; continue
            }
            if stopwords.contains(word) { i += 1; continue }

            plan.terms.append(spellings(of: word))
            plan.summary.append(word)
            i += 1
        }
        return plan
    }

    /// The word, its aliases, and its singular.
    static func spellings(of word: String) -> [String] {
        var out = [word]
        out += aliases[word] ?? []
        let single = singular(word)
        if single != word { out.append(single); out += aliases[single] ?? [] }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    static func singular(_ word: String) -> String {
        guard word.count > 3, word.allSatisfy(\.isLetter) else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") || word.hasSuffix("ches") || word.hasSuffix("shes") { return String(word.dropLast(2)) }
        if word.hasSuffix("s") && !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    private static func relative(_ word: String, _ unit: String?, now: Date, calendar: Calendar) -> ClosedRange<Date>? {
        let today = calendar.startOfDay(for: now)
        func span(_ component: Calendar.Component, back: Int) -> ClosedRange<Date>? {
            guard let interval = calendar.dateInterval(of: component, for: now),
                  let start = calendar.date(byAdding: component, value: -back, to: interval.start),
                  let end = calendar.date(byAdding: component, value: 1, to: start) else { return nil }
            return start...min(end.addingTimeInterval(-1), now)
        }
        switch (word, unit) {
        case ("today", nil): return today...now
        case ("yesterday", nil):
            guard let start = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
            return start...today.addingTimeInterval(-1)
        case ("recent", nil), ("recently", nil):
            guard let start = calendar.date(byAdding: .day, value: -30, to: today) else { return nil }
            return start...now
        case ("this", "week"): return span(.weekOfYear, back: 0)
        case ("last", "week"), ("past", "week"): return span(.weekOfYear, back: 1)
        case ("this", "month"): return span(.month, back: 0)
        case ("last", "month"), ("past", "month"): return span(.month, back: 1)
        case ("this", "year"): return span(.year, back: 0)
        case ("last", "year"), ("past", "year"): return span(.year, back: 1)
        default: return nil
        }
    }
}

/// The inverted index over one scope's photos, and the facets (cameras,
/// places, subjects) that become suggestions. Immutable once built, so it is
/// built and queried off the main thread.
struct SearchEngine: @unchecked Sendable {

    struct Facet: Identifiable {
        enum Kind: Sendable { case camera, place, country, subject, lens }
        let kind: Kind
        let label: String
        let count: Int
        /// The newest photo it covers, for the suggestion's thumbnail.
        let latest: RawPhoto
        var id: String { "\(kind)-\(label)" }
        var words: [String] { SearchText.tokens(label) }
    }

    let photos: [RawPhoto]
    private let dates: [Date?]
    private let vocabulary: [String]                // sorted
    private let postings: [String: [Int32]]
    private let subjectWords: [String]
    let facets: [Facet]
    /// Photos with content tags. The rest are still found by date and the like.
    let taggedCount: Int

    // MARK: Building

    static func build(photos: [RawPhoto], tags: [String: PhotoTags], calendar: Calendar = .current) -> SearchEngine {
        var postings: [String: [Int32]] = [:]
        var facetCounts: [String: (kind: Facet.Kind, label: String, count: Int, latest: RawPhoto)] = [:]
        var subjectWords = Set<String>()
        var tagged = 0

        func count(_ kind: Facet.Kind, _ label: String?, _ photo: RawPhoto) {
            guard let label, !label.isEmpty else { return }
            let key = "\(kind)|\(label)"
            if let existing = facetCounts[key] {
                facetCounts[key] = (kind, label, existing.count + 1, existing.latest)
            } else {
                facetCounts[key] = (kind, label, 1, photo)
            }
        }

        for (index, photo) in photos.enumerated() {
            let photoTags = tags[photo.id]
            var tokens = dateTokens(photo, southern: (photo.asset.location?.coordinate.latitude ?? 1) < 0, calendar: calendar)
            if let photoTags {
                tokens.formUnion(Self.tokens(for: photoTags))
                if photoTags.sawImage { tagged += 1 }
                count(.camera, photoTags.camera, photo)
                count(.lens, photoTags.lens, photo)
                if let place = photoTags.place {
                    count(.place, place.metro ?? place.name, photo)
                    if place.metro != nil { count(.place, place.name, photo) }
                    count(.country, place.country, photo)
                }
                for subject in photoTags.subjects.prefix(3) where !genericSubjects.contains(subject) {
                    count(.subject, subject, photo)
                }
                for subject in photoTags.subjects {
                    subjectWords.formUnion(SearchText.tokens(subject))
                }
            }
            for token in tokens { postings[token, default: []].append(Int32(index)) }
        }

        let facets = facetCounts.values
            .map { Facet(kind: $0.kind, label: $0.label, count: $0.count, latest: $0.latest) }
            .sorted { $0.count > $1.count }

        return SearchEngine(
            photos: photos,
            dates: photos.map(\.creationDate),
            vocabulary: postings.keys.sorted(),
            postings: postings,
            subjectWords: subjectWords.sorted(),
            facets: facets,
            taggedCount: tagged
        )
    }

    /// Too vague to suggest, though still searchable.
    private static let genericSubjects: Set<String> = [
        "structure", "outdoor", "indoor", "material", "liquid", "consumables", "wood processed",
        "textile", "machine", "furniture", "conveyance", "document", "art", "paper",
    ]

    private static func tokens(for tags: PhotoTags) -> Set<String> {
        var out = Set<String>()
        func add(_ s: String?) { if let s { out.formUnion(SearchText.tokens(s)) } }

        add(tags.make)
        add(tags.camera)
        add(tags.lens)
        if let model = tags.model {
            add(model)
            out.insert(SearchText.tokens(model).joined())          // "ILCE-7RM5" → "ilce7rm5"
            // Sony writes "ILCE-7RM5" where everyone says "a7R V"; prefix
            // matching on "a7rm5" lets "a7" and "a7r" find it.
            if model.uppercased().hasPrefix("ILCE-") {
                out.insert("a" + model.dropFirst(5).lowercased())
            }
        }
        if tags.make?.lowercased().hasPrefix("fuji") == true { out.insert("fuji") }
        if let focal = tags.focal {
            out.insert("\(focal)mm")
            if focal <= 24 { out.insert("wide") }
            if focal >= 85 { out.formUnion(["telephoto", "tele", "zoom"]) }
        }
        if let f = tags.aperture {
            out.insert("f" + (f == f.rounded() ? "\(Int(f))" : String(format: "%.1f", f)))
        }
        if let iso = tags.iso { out.insert("iso\(iso)") }
        if let filename = tags.filename {
            let stem = (filename as NSString).deletingPathExtension
            add(stem)
            let digits = stem.filter(\.isNumber)
            if !digits.isEmpty { out.insert(digits) }
            add((filename as NSString).pathExtension)
        }
        for name in tags.place?.names ?? [] { add(name) }
        for subject in tags.subjects { add(subject) }
        out.formUnion(tags.words)
        if tags.people > 0 { out.formUnion(["people", "person"]) }
        if tags.people == 1 { out.insert("portrait") }
        if tags.people >= 3 { out.formUnion(["group", "crowd"]) }
        return out
    }

    private static let months = ["january", "february", "march", "april", "may", "june", "july",
                                 "august", "september", "october", "november", "december"]
    private static let days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    private static func dateTokens(_ photo: RawPhoto, southern: Bool, calendar: Calendar) -> Set<String> {
        guard let date = photo.creationDate else { return [] }
        let parts = calendar.dateComponents([.year, .month, .weekday, .hour], from: date)
        var out = Set<String>()
        if let year = parts.year { out.insert("\(year)") }
        if let month = parts.month {
            let name = months[month - 1]
            out.insert(name)
            out.insert(String(name.prefix(3)))
            if month == 9 { out.insert("sept") }
            let seasons = ["winter", "winter", "spring", "spring", "spring", "summer",
                           "summer", "summer", "autumn", "autumn", "autumn", "winter"]
            var season = seasons[month - 1]
            if southern {
                season = ["winter": "summer", "summer": "winter", "spring": "autumn", "autumn": "spring"][season] ?? season
            }
            out.insert(season)
            if season == "autumn" { out.insert("fall") }
        }
        if let weekday = parts.weekday {
            let name = days[weekday - 1]
            out.insert(name)
            out.insert(String(name.prefix(3)))
            out.insert(weekday == 1 || weekday == 7 ? "weekend" : "weekday")
        }
        if let hour = parts.hour {
            switch hour {
            case 5..<12: out.insert("morning")
            case 12..<17: out.insert("afternoon")
            case 17..<21: out.insert("evening")
            default: out.insert("night")
            }
        }
        return out
    }

    // MARK: Querying

    /// Indices into `photos`, newest first.
    func run(_ plan: SearchPlan, favourites: Set<String>, sent: Set<String>) -> [Int] {
        var mask = Bitset(count: photos.count, filled: true)
        for term in plan.terms {
            var any = Bitset(count: photos.count, filled: false)
            for spelling in term {
                var all = Bitset(count: photos.count, filled: true)
                for word in spelling.split(separator: " ").map(String.init) {
                    all.formIntersection(matches(word))
                }
                any.formUnion(all)
            }
            if any.isEmpty, let word = term.first {
                // Nothing by name. Try the nearest things Vision does know about.
                for related in related(to: word) { any.formUnion(matches(related)) }
            }
            mask.formIntersection(any)
            if mask.isEmpty { return [] }
        }

        var out: [Int] = []
        for index in mask.indices {
            let id = photos[index].id
            if plan.favourites && !favourites.contains(id) { continue }
            if let wantSent = plan.sent, sent.contains(id) != wantSent { continue }
            if let range = plan.dates {
                guard let date = dates[index], range.contains(date) else { continue }
            }
            out.append(index)
        }
        return out
    }

    /// Exact, or by prefix once there are two letters: "fuj" finds "fujifilm".
    /// Years stay exact, so "2024" never finds frame DSC_20241.
    private func matches(_ word: String) -> Bitset {
        var set = Bitset(count: photos.count, filled: false)
        let exactOnly = (word.count == 4 && word.allSatisfy(\.isNumber)) || QueryParser.shortAliases.contains(word)
        if exactOnly || word.count < 2 {
            for i in postings[word] ?? [] { set.insert(Int(i)) }
            return set
        }
        var lo = vocabulary.partitioningIndex { $0 >= word }
        while lo < vocabulary.count, vocabulary[lo].hasPrefix(word) {
            for i in postings[vocabulary[lo]] ?? [] { set.insert(Int(i)) }
            lo += 1
        }
        return set
    }

    /// Subject words in this library that the on-device word embedding puts
    /// close to `word`. A fallback only: it is fuzzy, so it never runs when
    /// the word matched something by name.
    private func related(to word: String) -> [String] {
        guard word.count >= 3, word.allSatisfy(\.isLetter),
              let embedding = Self.embedding,
              embedding.contains(word) else { return [] }
        return subjectWords
            .compactMap { candidate -> (String, Double)? in
                let d = embedding.distance(between: word, and: candidate)
                return d < 0.92 ? (candidate, d) : nil
            }
            .sorted { $0.1 < $1.1 }
            .prefix(2)
            .map(\.0)
    }

    /// Loaded once. The system maps it from disk, but opening it is not free.
    private static let embedding = NLEmbedding.wordEmbedding(for: .english)

    /// The labels this library actually has, most common first. Handed to the
    /// language model so it answers in words the index knows.
    var knownSubjects: [String] {
        facets.filter { $0.kind == .subject }.map(\.label)
    }
}

// MARK: - Bitset

struct Bitset {
    private var words: [UInt64]
    let count: Int

    init(count: Int, filled: Bool) {
        self.count = count
        words = Array(repeating: filled ? ~0 : 0, count: (count + 63) / 64)
        if filled, count % 64 != 0, !words.isEmpty {
            words[words.count - 1] = (1 << UInt64(count % 64)) - 1
        }
    }

    mutating func insert(_ i: Int) { words[i >> 6] |= 1 << UInt64(i & 63) }

    mutating func formUnion(_ other: Bitset) {
        for i in words.indices { words[i] |= other.words[i] }
    }

    mutating func formIntersection(_ other: Bitset) {
        for i in words.indices { words[i] &= other.words[i] }
    }

    var isEmpty: Bool { words.allSatisfy { $0 == 0 } }

    var indices: [Int] {
        var out: [Int] = []
        for (w, word) in words.enumerated() where word != 0 {
            var bits = word
            while bits != 0 {
                let t = bits.trailingZeroBitCount
                out.append(w << 6 + t)
                bits &= bits - 1
            }
        }
        return out
    }
}

private extension Array where Element == String {
    /// First index whose element satisfies `predicate`, for a sorted array.
    func partitioningIndex(where predicate: (String) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if predicate(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
