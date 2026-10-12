import Foundation
import CoreLocation

// Datenmodell der JSON-API unter stauklar.de/api/v1 (erzeugt von build.py).

struct RoadsResponse: Codable {
    let stand: String
    let roads: [RoadSummary]
}

struct RoadSummary: Codable, Identifiable, Hashable {
    let id: String
    let slug: String
    let status: String
    let statusText: String
    let lage: String
    let voll: Int
    let kurz: Int
    let live: Int
    let dauer: Int
    let lat: Double?
    let lon: Double?

    /// Je höher, desto mehr ist heute los (für „Heute viel los“)
    var score: Int { voll * 5 + kurz * 2 + live * 3 }
}

struct RoadDetail: Codable {
    let id: String
    let stand: String
    let status: String
    let statusText: String
    let lage: String
    let voll: Int
    let kurz: Int
    let live: Int
    let dauer: Int
    let axis: Axis?
    let labels: [String: DirLabel]
    let ends: [String]
    let near: [String]
    var items: [Item]
    var warns: [Warn]
    let groups: [Group]
    let parking: [String]
    let charging: [String]
}

/// Eine Baumaßnahme mit ihren Folgen je Fahrtrichtung (die API meldet sie als mehrere Einträge)
struct Group: Codable, Identifiable, Hashable {
    let id: String
    let items: [String]
    let title: String
    let section: String
    let what: String?
    let sev: String
    let label: String
    let active: Bool
    let heute: Bool
    let woche: Bool
    let morgen: Bool?
    let when: String
    let start: String?
    let end: String?
    let total: String?
    let upcoming: Int
    /// Weitere Zeitfenster als Text, z. B. „täglich 09:00–18:00 Uhr, vom 13.10. bis 23.10.“
    let terms: String?
    /// z. B. „Zusätzlich zur Dauerbaustelle an dieser Stelle (läuft bis 12.11.2026)“
    let context: String?
    let dirs: [DirLine]
    let ramps: [String]
    let project: String
    let t: Double
    let d: [String]
    let lat: Double
    let lon: Double

    var severity: Severity { Severity(rawValue: sev) ?? .dauer }
}

struct DirLine: Codable, Hashable {
    let d: String
    let raw: String
    let lanes: [String]
    let laneText: String
    let place: String
    let info: String

    enum CodingKeys: String, CodingKey { case d, raw, lanes, laneText, place = "where", info }
}

struct Axis: Codable {
    let lat0: Double
    let mx: Double
    let my: Double
    let vx: Double
    let vy: Double
    let ns: Bool

    /// Position entlang der Hauptachse der Autobahn in km (für die Reihenfolge der Liste)
    func along(lon: Double, lat: Double) -> Double {
        let x = lon * 111.32 * cos(lat0 * .pi / 180)
        let y = lat * 110.57
        return (x - mx) * vx + (y - my) * vy
    }
}

struct DirLabel: Codable {
    let name: String
    let compass: String
    let sym: String
    let n: Int
}

enum Severity: String, Codable, CaseIterable {
    case voll, sperr, kurz, dauer, live

    var rank: Int {
        switch self {
        case .live: return 0
        case .voll: return 1
        case .sperr: return 2
        case .kurz: return 3
        case .dauer: return 4
        }
    }
}

struct Item: Codable, Identifiable, Hashable {
    let id: String
    let g: String?
    let title: String
    let dir: String
    let d: String
    let t: Double
    let sev: String
    let label: String
    let active: Bool
    let heute: Bool
    let woche: Bool
    let when: String
    let start: String?
    let end: String?
    let total: String?
    let windows: [[String?]]
    let place: String
    let info: String
    let project: String
    let lanes: [String]
    let laneText: String
    let lat: Double
    let lon: Double
    let geom: [[Double]]

    enum CodingKeys: String, CodingKey {
        case id, g, title, dir, d, t, sev, label, active, heute, woche, when, start, end, total, windows
        case place = "where"
        case info, project, lanes, laneText, lat, lon, geom
    }

    var severity: Severity { Severity(rawValue: sev) ?? .dauer }
    var coordinates: [CLLocationCoordinate2D] { geom.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) } }
    var mid: CLLocationCoordinate2D {
        guard !geom.isEmpty else { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
        let g = geom[geom.count / 2]
        return CLLocationCoordinate2D(latitude: g[1], longitude: g[0])
    }
}

struct Warn: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let dir: String
    var d: String
    var t: Double
    let text: [String]
    let lat: Double
    let lon: Double
    let geom: [[Double]]

    var coordinates: [CLLocationCoordinate2D] { geom.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) } }
    var mid: CLLocationCoordinate2D {
        guard !geom.isEmpty else { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
        let g = geom[geom.count / 2]
        return CLLocationCoordinate2D(latitude: g[1], longitude: g[0])
    }
}

struct PointsResponse: Codable {
    let stand: String
    let points: [Point]
}

struct Point: Codable, Identifiable, Hashable {
    let road: String
    let id: String
    let lat: Double
    let lon: Double
    let sev: String
    let heute: Bool
    let title: String
    let when: String
    let label: String
    let active: Bool

    var key: String { "\(road)/\(id)" }
    var severity: Severity { Severity(rawValue: sev) ?? .dauer }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

struct City: Codable, Identifiable, Hashable {
    let name: String
    let lat: Double
    let lon: Double
    var id: String { name }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// Autobahn-Seite mit einer bestimmten Meldung, die aufgeklappt und auf der Karte markiert wird
struct RoadTarget: Hashable, Identifiable {
    let road: String
    let item: String?
    /// Titel der Meldung, falls die Nummer inzwischen neu vergeben wurde (z. B. aus einer älteren Benachrichtigung)
    var title: String? = nil
    var id: String { "\(road)/\(item ?? "")" }
}

/// Fahrmodus
struct DriveTarget: Hashable {}

/// Ziel der Umkreisansicht: eigener Standort oder ein Ort
enum NearbyTarget: Hashable {
    case me
    case place(name: String, lat: Double, lon: Double)
}

func kilometers(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    let dx = (a.longitude - b.longitude) * 111.32 * cos(a.latitude * .pi / 180)
    let dy = (a.latitude - b.latitude) * 110.57
    return (dx * dx + dy * dy).squareRoot()
}

/// Autobahnen numerisch sortieren: A1, A2, …, A10, A100
func roadSortKey(_ id: String) -> (Int, String) {
    let digits = id.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
    return (Int(digits) ?? 9999, id)
}

extension String {
    /// nil statt leerer Zeichenkette
    var nonEmpty: String? { isEmpty ? nil : self }
}
