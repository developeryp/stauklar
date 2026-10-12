import Foundation

/// Lädt die vorberechneten JSON-Dateien von stauklar.de. Fällt bei Netzproblemen auf den letzten Stand zurück.
actor API {
    static let shared = API()

    private let base = URL(string: "https://stauklar.de/api/v1")!
    private let decoder = JSONDecoder()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        // Immer frisch vom Server; der eigene Datei-Cache dient nur als Rückfall ohne Netz
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let url = base.appendingPathComponent(path)
        do {
            // Minutengenauer Zeitstempel umgeht den Zwischenspeicher von GitHub Pages (sonst bis zu 10 Minuten alte Daten)
            var c = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            c.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 / 60)))]
            let data = try await fetch(c.url ?? url)
            Self.writeCache(path, data)
            return try decoder.decode(T.self, from: data)
        } catch {
            // Übergangsweise: solange stauklar.de kein HTTPS-Zertifikat hat, per http versuchen
            if var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                c.scheme = "http"
                if let alt = c.url, let data = try? await fetch(alt), let r = try? decoder.decode(T.self, from: data) {
                    Self.writeCache(path, data)
                    return r
                }
            }
            if let data = Self.readCache(path), let r = try? decoder.decode(T.self, from: data) {
                return r
            }
            throw error
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    // MARK: - Einfacher Datei-Cache

    private static var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("api", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func cacheURL(_ path: String) -> URL {
        cacheDir.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
    }

    private static func writeCache(_ path: String, _ data: Data) {
        try? data.write(to: cacheURL(path), options: .atomic)
    }

    static func readCache(_ path: String) -> Data? {
        try? Data(contentsOf: cacheURL(path))
    }
}
