import Foundation
import FoundationModels

/// Asks the on-device Apple Intelligence model what a search means, for the
/// phrasings the keyword parser cannot untangle: "the diner with the green
/// glasses", "anything from my trip to japan". Runs on the phone; on devices
/// without Apple Intelligence it is simply never used.
enum QueryInterpreter {

    @Generable(description: "Filters for searching a photographer's own photo library")
    struct Interpretation {
        @Guide(description: "Things or scenes that would be visible in the photo, as simple lowercase English nouns. Prefer words from the provided label list.")
        var subjects: [String]
        @Guide(description: "Cities, neighbourhoods, regions or countries, spelled as on a map, e.g. New York City, Brooklyn, Japan")
        var places: [String]
        @Guide(description: "Camera brands or models, e.g. Fujifilm, X100V, Sony, Leica Q3")
        var cameras: [String]
        @Guide(description: "Words that would be printed or written somewhere in the photo, like a shop name or a sign")
        var printedWords: [String]
        @Guide(description: "A four digit year if one is mentioned, otherwise 0")
        var year: Int
        @Guide(description: "An English month or season name if one is mentioned, otherwise empty")
        var monthOrSeason: String
        @Guide(description: "True only if they ask for favourites, hearted or best photos")
        var favouritesOnly: Bool
        @Guide(description: "True only if they ask for photos not yet sent or exported to Lightroom")
        var notYetSent: Bool
    }

    static var isAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    /// nil when the model is unavailable, busy or unsure.
    static func plan(for query: String, knownSubjects: [String]) async -> SearchPlan? {
        guard isAvailable else { return nil }
        let labels = knownSubjects.prefix(160).joined(separator: ", ")
        let session = LanguageModelSession(instructions: """
            You turn a search typed into a photo app into filters. The photos are \
            one photographer's RAW files, already labelled by an image classifier. \
            Only fill in what the person actually asked for. Leave everything else empty.
            Labels the classifier has used in this library: \(labels)
            """)
        do {
            let response = try await session.respond(
                to: query,
                generating: Interpretation.self,
                options: GenerationOptions(temperature: 0)
            )
            return plan(from: response.content)
        } catch {
            return nil
        }
    }

    private static func plan(from answer: Interpretation) -> SearchPlan {
        var plan = SearchPlan()
        func term(_ phrase: String) {
            let words = SearchText.tokens(phrase)
            guard !words.isEmpty else { return }
            if words.count == 1 {
                plan.terms.append(QueryParser.spellings(of: words[0]))
            } else {
                plan.terms.append([words.joined(separator: " ")])
            }
            plan.summary.append(phrase.lowercased())
        }
        // One spelling per subject is too strict when the model offers three
        // overlapping ones ("diner", "restaurant", "food"): any of them will do.
        let subjects = answer.subjects.flatMap { SearchText.tokens($0) }
        if !subjects.isEmpty {
            plan.terms.append(subjects.flatMap { QueryParser.spellings(of: $0) })
            plan.summary.append(answer.subjects.joined(separator: " or ").lowercased())
        }
        answer.places.forEach(term)
        answer.cameras.forEach(term)
        answer.printedWords.forEach(term)
        if (1900...2100).contains(answer.year) { term("\(answer.year)") }
        if !answer.monthOrSeason.isEmpty { term(answer.monthOrSeason) }
        if answer.favouritesOnly { plan.favourites = true; plan.summary.append("favourites") }
        if answer.notYetSent { plan.sent = false; plan.summary.append("not sent") }
        return plan
    }
}
