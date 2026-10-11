import Foundation

/// Staumeldungen direkt von der Autobahn GmbH, weil sie sich minütlich ändern.
enum Live {
    private struct Response: Decodable { let warning: [Entry] }
    private struct Entry: Decodable {
        let title: String?
        let subtitle: String?
        let description: [String]?
        let geometry: Geometry?
        struct Geometry: Decodable {
            let type: String?
            let coordinates: [[Double]]?
        }
    }

    static func warnings(for road: String, axis: Axis?) async -> [Warn]? {
        guard let url = URL(string: "https://verkehr.autobahn.de/o/autobahn/\(road)/services/warning") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let resp = try? JSONDecoder().decode(Response.self, from: data) else { return nil }
        let prefix = "\(road) |"
        return resp.warning.enumerated().map { n, w in
            var title = (w.title ?? "").trimmingCharacters(in: .whitespaces)
            if title.hasPrefix(prefix) { title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
            let text = (w.description ?? [])
                .filter { !$0.isEmpty && !$0.hasPrefix("Beginn:") && $0 != "Ereignismeldung:" }
                .prefix(4)
                .map { $0.replacingOccurrences(of: "->", with: "→") }
            let geom = (w.geometry?.type == "LineString" ? w.geometry?.coordinates : nil) ?? []
            var t = 0.0, d = ""
            let mid = geom.isEmpty ? nil : geom[geom.count / 2]
            if let axis, let first = geom.first, let last = geom.last, let mid {
                t = axis.along(lon: mid[0], lat: mid[1])
                let delta = axis.along(lon: last[0], lat: last[1]) - axis.along(lon: first[0], lat: first[1])
                if abs(delta) > 0.03 { d = delta > 0 ? "plus" : "minus" }
            }
            return Warn(id: "w\(n)", title: title,
                        dir: (w.subtitle ?? "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "->", with: "→"),
                        d: d, t: t, text: Array(text), lat: mid?[1] ?? 0, lon: mid?[0] ?? 0, geom: geom)
        }
    }
}
