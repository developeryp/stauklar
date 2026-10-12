import SwiftUI
import CoreLocation
import UIKit

/// Fahrmodus: erkennt Autobahn und Fahrtrichtung aus dem Standort und zeigt, was voraus liegt, mit Entfernung.
struct DriveView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var model = DriveModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if let msg = model.message {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: model.icon).font(.system(size: 44)).foregroundStyle(.secondary)
                        Text(msg).font(.title3).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 30)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(model.upcoming) { u in UpcomingRow(u: u) }
                            if model.upcoming.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
                                    Text("Die nächsten \(Int(DriveModel.horizonKm)) km sind frei.").font(.title2.weight(.semibold))
                                    Text("Gute Fahrt!").foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity).padding(.top, 60)
                            }
                        }
                        .padding(16)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .navigationTitle("Fahrmodus")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.black, for: .navigationBar)
        .onAppear { model.start(store: store); UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { model.stop(); UIApplication.shared.isIdleTimerDisabled = false }
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let road = model.roadID {
                Shield(id: road, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.directionText).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(model.stand).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Autobahn wird gesucht …").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer()
            if let s = model.speedKmh {
                VStack(spacing: 0) {
                    Text("\(s)").font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("km/h").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(Color(white: 0.08))
    }
}

struct Upcoming: Identifiable {
    let id: String
    let km: Double
    let title: String
    let label: String
    let when: String
    let severity: Severity
    let lanes: [String]
    let laneText: String
    let active: Bool
}

struct UpcomingRow: View {
    let u: Upcoming

    private var distance: String {
        if u.km < 0.3 { return "jetzt hier" }
        if u.km < 10 { return String(format: "in %.1f km", u.km).replacingOccurrences(of: ".", with: ",") }
        return "in \(Int(u.km.rounded())) km"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 3).fill(Theme.color(u.severity)).frame(width: 6)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(distance).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Spacer()
                    Text(u.active ? u.label : "ab \(u.when)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.color(u.severity))
                }
                Text(u.title).font(.title3.weight(.semibold)).lineLimit(2)
                if !u.lanes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        LaneGraphic(symbols: u.lanes)
                        Text(u.laneText).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                } else if !u.active {
                    Text(u.label).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Standort → Autobahn → Fahrtrichtung → Meldungen voraus
@MainActor
final class DriveModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let horizonKm = 60.0
    @Published var roadID: String?
    @Published var directionText = ""
    @Published var upcoming: [Upcoming] = []
    @Published var speedKmh: Int?
    @Published var message: String? = "Standort wird bestimmt …"
    @Published var icon = "location"
    @Published var stand = ""

    private let manager = CLLocationManager()
    private weak var store: Store?
    private var detail: RoadDetail?
    private var dir = ""          // "plus" / "minus"
    private var lastDetect = Date.distantPast
    private var loading = false
    private var lastLoc: CLLocation?

    func start(store: Store) {
        self.store = store
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 25
        manager.activityType = .automotiveNavigation
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { await MainActor.run { self.update(loc) } }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let st = manager.authorizationStatus
        Task { await MainActor.run {
            if st == .denied || st == .restricted {
                self.message = "Ohne Standort geht der Fahrmodus nicht. Erlaube Stauklar den Zugriff unter Einstellungen → Datenschutz → Ortungsdienste."
                self.icon = "location.slash"
            } else if st == .authorizedWhenInUse || st == .authorizedAlways {
                manager.startUpdatingLocation()
            }
        } }
    }

    private func update(_ loc: CLLocation) {
        speedKmh = loc.speed >= 0 ? Int((loc.speed * 3.6).rounded()) : nil
        guard let store, !store.points.isEmpty else { message = "Daten werden geladen …"; return }
        let here = loc.coordinate

        // Autobahn: nächster bekannter Meldungspunkt in höchstens 3 km; alle 20 s neu prüfen
        if roadID == nil || Date().timeIntervalSince(lastDetect) > 20 {
            lastDetect = Date()
            var best: (String, Double)?
            for p in store.points {
                let d = kilometers(here, p.coordinate)
                if d < 3, best == nil || d < best!.1 { best = (p.road, d) }
            }
            guard let (road, _) = best else {
                if roadID == nil { message = "Keine Autobahn in der Nähe. Der Fahrmodus startet, sobald du auf einer Autobahn bist."; icon = "road.lanes" }
                return
            }
            if road != roadID {
                roadID = road
                detail = nil
                load(road)
            }
        }
        guard let d = detail, let axis = d.axis else { return }

        // Fahrtrichtung: aus dem Kurs des GPS, sonst aus der Bewegung seit der letzten Position
        var course = loc.course >= 0 && loc.speed > 2 ? loc.course : -1.0
        if course < 0, let prev = lastLoc, loc.distance(from: prev) > 40 {
            let dLon = (loc.coordinate.longitude - prev.coordinate.longitude) * cos(loc.coordinate.latitude * .pi / 180)
            let dLat = loc.coordinate.latitude - prev.coordinate.latitude
            course = atan2(dLon, dLat) * 180 / .pi
        }
        if course >= -180 && course != -1 {
            let rad = course * .pi / 180
            let dot = sin(rad) * axis.vx + cos(rad) * axis.vy
            dir = dot >= 0 ? "plus" : "minus"
        }
        if lastLoc == nil || loc.distance(from: lastLoc!) > 40 { lastLoc = loc }
        guard !dir.isEmpty else { message = "Fahr los, dann erkenne ich deine Richtung."; icon = "arrow.triangle.turn.up.right.diamond"; return }
        message = nil
        if let l = d.labels[dir] { directionText = "\(l.sym) Richtung \(l.name)" }

        let userT = axis.along(lon: here.longitude, lat: here.latitude)
        let ahead: (Double) -> Double? = { t in
            let delta = self.dir == "plus" ? t - userT : userT - t
            return delta > -0.3 && delta <= Self.horizonKm ? max(delta, 0) : nil
        }
        var list: [Upcoming] = []
        for g in d.groups where g.heute && (g.d.isEmpty || g.d.contains(dir)) {
            guard let km = ahead(g.t) else { continue }
            let line = g.dirs.first { $0.d == dir } ?? g.dirs.first
            list.append(Upcoming(id: g.id, km: km, title: g.title, label: g.label, when: g.when, severity: g.severity,
                                 lanes: line?.lanes ?? [], laneText: line?.laneText ?? "", active: g.active))
        }
        for w in d.warns where w.d.isEmpty || w.d == dir {
            guard let km = ahead(w.t) else { continue }
            list.append(Upcoming(id: w.id, km: km, title: w.title, label: w.text.first ?? "Stau oder Gefahr", when: "", severity: .live, lanes: [], laneText: "", active: true))
        }
        upcoming = list.sorted { $0.km < $1.km }
        stand = "Stand \(Date().formatted(date: .omitted, time: .shortened)) Uhr · \(upcoming.count) voraus"
    }

    private func load(_ road: String) {
        guard !loading else { return }
        loading = true
        message = "Lade \(road) …"
        Task {
            defer { loading = false }
            let slug = store?.road(road)?.slug ?? road.lowercased()
            if var d: RoadDetail = try? await API.shared.get("road/\(slug).json") {
                if let live = await Live.warnings(for: road, axis: d.axis) { d.warns = live }
                detail = d
                if let last = manager.location { update(last) }
            } else {
                message = "Die \(road) konnte nicht geladen werden."
                icon = "wifi.slash"
            }
        }
    }
}
