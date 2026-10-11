import Foundation
import CoreLocation
import SwiftUI

/// Gemeinsamer Zustand: Übersicht aller Autobahnen, Punkte für die Umkreissuche, Favoriten.
@MainActor
final class Store: ObservableObject {
    @Published var roads: [RoadSummary] = []
    @Published var points: [Point] = []
    @Published var cities: [City] = []
    @Published var stand: Date?
    @Published var loading = false
    @Published var error: String?
    @Published var favorites: [String] {
        didSet { UserDefaults.standard.set(favorites, forKey: "favorites") }
    }

    init() {
        favorites = UserDefaults.standard.stringArray(forKey: "favorites") ?? []
    }

    var totals: (voll: Int, kurz: Int, live: Int) {
        (roads.reduce(0) { $0 + $1.voll }, roads.reduce(0) { $0 + $1.kurz }, roads.reduce(0) { $0 + $1.live })
    }

    var busiest: [RoadSummary] { roads.sorted { $0.score > $1.score }.prefix(6).map { $0 } }

    func road(_ id: String) -> RoadSummary? { roads.first { $0.id == id } }

    func isFavorite(_ id: String) -> Bool { favorites.contains(id) }

    func toggleFavorite(_ id: String) {
        if let i = favorites.firstIndex(of: id) { favorites.remove(at: i) } else { favorites.append(id) }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            async let r: RoadsResponse = API.shared.get("roads.json")
            async let p: PointsResponse = API.shared.get("points.json")
            async let c: [City] = API.shared.get("cities.json")
            let (rr, pp, cc) = try await (r, p, c)
            roads = rr.roads.sorted { roadSortKey($0.id) < roadSortKey($1.id) }
            points = pp.points
            cities = cc
            stand = ISO8601DateFormatter().date(from: rr.stand)
            error = nil
        } catch {
            if roads.isEmpty {
                self.error = "Die Daten konnten nicht geladen werden. Prüfe deine Internetverbindung und zieh die Liste nach unten, um es erneut zu versuchen."
            }
        }
    }

    /// Meldungen im Umkreis, nach Wichtigkeit und Entfernung sortiert
    func nearby(_ center: CLLocationCoordinate2D, km radius: Double) -> [(point: Point, km: Double)] {
        points.compactMap { p in
            let d = kilometers(center, p.coordinate)
            return d <= radius ? (p, d) : nil
        }
        .sorted { a, b in
            if a.point.severity.rank != b.point.severity.rank { return a.point.severity.rank < b.point.severity.rank }
            return a.km < b.km
        }
    }

    /// Suche nach Autobahn („A7“, „7“, „a 7“) oder Stadt
    func search(_ q: String) -> (roads: [RoadSummary], cities: [City]) {
        let n = q.lowercased().replacingOccurrences(of: " ", with: "").folding(options: .diacriticInsensitive, locale: .current)
        guard !n.isEmpty else { return ([], []) }
        var asRoad = n
        if asRoad.first?.isNumber == true { asRoad = "a" + asRoad }
        let rs = asRoad.hasPrefix("a") && asRoad.count > 1
            ? roads.filter { $0.id.lowercased().hasPrefix(asRoad) }
            : []
        let cs = cities.filter { $0.name.lowercased().folding(options: .diacriticInsensitive, locale: .current).contains(n) }
            .sorted { a, b in
                let pa = a.name.lowercased().hasPrefix(n), pb = b.name.lowercased().hasPrefix(n)
                return pa != pb ? pa : a.name < b.name
            }
        return (rs, Array(cs.prefix(6)))
    }
}
