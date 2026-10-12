import CoreLocation
import Foundation

/// Where a photo was taken, in words.
struct Place: Hashable, Codable, Sendable {
    /// The nearest town or neighbourhood: "Williamsburg".
    let name: String
    /// The big city it belongs to, when that is somewhere else: "New York City".
    let metro: String?
    /// "New York"
    let region: String?
    /// "United States"
    let country: String?

    /// "Williamsburg, New York City" or just "Lisbon".
    var short: String {
        if let metro, metro != name { return "\(name), \(metro)" }
        return name
    }

    /// Every name a search might use for it.
    var names: [String] {
        [name, metro, region, country].compactMap { $0 }
    }
}

/// Names a coordinate without asking a server. Every town over 15,000 people
/// (GeoNames, CC BY 4.0) ships in the app; the nearest one wins.
///
/// Loaded once, off the main thread, on first use. About 34,000 rows in a
/// coarse grid, so a lookup only ever looks at a few hundred.
final class PlaceIndex: @unchecked Sendable {
    static let shared = PlaceIndex()

    private struct Row {
        let name: String
        let lat: Double
        let lon: Double
        let population: Int
        let region: String    // "US.NY"
    }

    /// One-degree cells. Near the poles a degree of longitude is short, which
    /// only means a few more cells get searched; nothing is missed.
    private var cells: [Int: [Row]] = [:]
    private var countries: [String: String] = [:]
    private var regions: [String: String] = [:]
    private var loaded = false
    private let lock = NSLock()

    /// Nothing is called a place more than this far from the photo.
    private let reach: CLLocationDistance = 30_000
    /// A city at least this big, this close, is what people call the area.
    private let metroPopulation = 1_000_000
    private let metroReach: CLLocationDistance = 40_000

    func place(for location: CLLocation) -> Place? {
        loadIfNeeded()
        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        guard (-90...90).contains(lat), (-180...180).contains(lon), !(lat == 0 && lon == 0) else { return nil }

        var nearest: (row: Row, distance: Double)?
        var metro: (row: Row, distance: Double)?

        let cy = Int(lat.rounded(.down)), cx = Int(lon.rounded(.down))
        for dy in -1...1 {
            for dx in -1...1 {
                for row in cells[key(cy + dy, wrap(cx + dx))] ?? [] {
                    let d = distance(lat, lon, row.lat, row.lon)
                    if d <= reach, d < (nearest?.distance ?? .infinity) {
                        nearest = (row, d)
                    }
                    if row.population >= metroPopulation, d <= metroReach,
                       row.population > (metro?.row.population ?? 0) {
                        metro = (row, d)
                    }
                }
            }
        }

        guard let nearest else { return nil }
        let cc = String(nearest.row.region.prefix { $0 != "." })
        return Place(
            name: nearest.row.name,
            metro: metro.map(\.row.name).flatMap { $0 == nearest.row.name ? nil : $0 },
            region: regions[nearest.row.region],
            country: countries[cc]
        )
    }

    // MARK: Loading

    private func loadIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true

        guard let url = Bundle.main.url(forResource: "places", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            switch cols.first {
            case "C" where cols.count >= 3:
                countries[String(cols[1])] = String(cols[2])
            case "A" where cols.count >= 3:
                regions[String(cols[1])] = String(cols[2])
            case "P" where cols.count >= 6:
                guard let lat = Double(cols[2]), let lon = Double(cols[3]) else { continue }
                let row = Row(name: String(cols[1]), lat: lat, lon: lon,
                              population: Int(cols[4]) ?? 0, region: String(cols[5]))
                cells[key(Int(lat.rounded(.down)), Int(lon.rounded(.down))), default: []].append(row)
            default:
                continue
            }
        }
    }

    private func key(_ lat: Int, _ lon: Int) -> Int { (lat + 90) * 1000 + (lon + 180) }

    private func wrap(_ lon: Int) -> Int {
        if lon < -180 { return lon + 360 }
        if lon >= 180 { return lon - 360 }
        return lon
    }

    /// Haversine, in metres. Plenty for "which town is closest".
    private func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}
