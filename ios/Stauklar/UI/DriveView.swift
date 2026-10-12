import SwiftUI
import CoreLocation
import MapKit
import UIKit

/// Fahrmodus: erkennt Autobahn und Fahrtrichtung aus dem Standort und zeigt, was voraus liegt, mit Entfernung.
struct DriveView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var model = DriveModel()
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var following = true
    /// Übersicht (ca. 5 km, von oben) oder Nah (3D in Fahrtrichtung wie eine Navigation)
    @AppStorage("driveClose") private var closeView = false
    @State private var showMap = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if showMap { driveMap }
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

    /// Karte, die der Position folgt und in Fahrtrichtung zeigt; Meldungen voraus farbig
    private var driveMap: some View {
        Map(position: $camera, interactionModes: [.zoom]) {
            UserAnnotation()
            // Solange keine Autobahn erkannt ist: Meldungen der Umgebung als Punkte, damit die Karte nie leer ist
            ForEach(model.nearPoints, id: \.key) { p in
                Annotation("", coordinate: p.coordinate) {
                    Circle().fill(Theme.color(p.severity)).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .opacity(p.heute ? 1 : 0.5)
                }
            }
            // Alle heutigen Meldungen der Autobahn; was voraus liegt kräftig, der Rest gedämpft
            ForEach(model.mapItems) { it in
                if it.geom.count > 1 {
                    // Ohne bekannte Richtung ist noch nichts „voraus“: dann alles kräftig zeichnen
                    let ahead = model.aheadItems.isEmpty || model.aheadItems.contains(it.id)
                    MapPolyline(coordinates: it.coordinates)
                        .stroke(Theme.color(it.severity).opacity(ahead ? 1 : 0.35), style: StrokeStyle(lineWidth: ahead ? 7 : 5, lineCap: .round, lineJoin: .round))
                }
            }
            // Nah-Ansicht: 3D-Gebäude verdecken Linien am Boden, deshalb zusätzlich ein Marker am Anfang jeder Meldung voraus
            if closeView {
                ForEach(model.mapItems.filter { model.aheadItems.contains($0.id) && $0.geom.count > 1 }) { it in
                    Annotation("", coordinate: model.start(of: it)) {
                        Image(systemName: it.severity == .dauer || it.severity == .kurz ? "cone.fill" : "xmark.octagon.fill")
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                            .padding(7).background(Theme.color(it.severity), in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
            ForEach(model.mapWarns) { w in
                if w.geom.count > 1 {
                    MapPolyline(coordinates: w.coordinates)
                        .stroke(Theme.color(.live), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .frame(height: closeView ? 360 : 280)
        // Kamera: ca. 5 km Sicht, in Fahrtrichtung gedreht, folgt der Position
        .onChange(of: model.cameraTick) { _, _ in
            guard following, let here = model.location?.coordinate else { return }
            // Ohne erkannte Autobahn: weit raus, damit die Meldungen der Umgebung zu sehen sind
            guard model.roadID != nil else {
                withAnimation(.linear(duration: 1)) { camera = .camera(MapCamera(centerCoordinate: here, distance: 60_000, heading: 0, pitch: 0)) }
                return
            }
            // Autobahn erkannt, Richtung noch nicht (z. B. im Stand): normale Übersicht nach Norden
            guard model.message == nil else {
                withAnimation(.linear(duration: 1)) { camera = .camera(MapCamera(centerCoordinate: here, distance: 6500, heading: 0, pitch: 0)) }
                return
            }
            // Blickpunkt voraus, damit das Auto unten im Bild steht und mehr Strecke vor dir zu sehen ist
            let c = here.moved(meters: closeView ? 200 : 1800, heading: model.heading)
            withAnimation(.linear(duration: 1)) {
                camera = .camera(MapCamera(centerCoordinate: c, distance: closeView ? 650 : 6500, heading: model.heading, pitch: closeView ? 50 : 0))
            }
        }
        .onChange(of: closeView) { _, _ in following = true; model.cameraTick += 1 }
        .overlay(alignment: .top) {
            if model.roadID != nil { Picker("Ansicht", selection: $closeView) {
                Text("Übersicht").tag(false)
                Text("Nah").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .padding(.top, 10) }
        }
        .overlay(alignment: .bottom) {
            // Nah-Ansicht: nächste Meldung mit großer Spuranzeige, wie ein Spurassistent
            if closeView, let next = model.upcoming.first {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.km < 0.3 ? "jetzt" : (next.km < 10 ? String(format: "%.1f km", next.km).replacingOccurrences(of: ".", with: ",") : "\(Int(next.km.rounded())) km"))
                            .font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                        Text(next.title).font(.footnote.weight(.semibold)).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if !next.lanes.isEmpty {
                        LaneGraphic(symbols: next.lanes).scaleEffect(1.6).padding(.horizontal, 24)
                    } else {
                        Circle().fill(Theme.color(next.severity)).frame(width: 14, height: 14)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(10)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { _ in }
        .overlay(alignment: .topTrailing) {
            Button { following.toggle() } label: {
                Image(systemName: following ? "location.fill" : "location").font(.body.weight(.semibold)).padding(9).background(.regularMaterial, in: Circle())
            }
            .padding(8)
            .accessibilityLabel(following ? "Karte folgt dir" : "Karte folgen lassen")
        }
        .overlay(alignment: .topLeading) {
            Button { withAnimation { showMap = false } } label: {
                Image(systemName: "chevron.up").font(.caption.weight(.bold)).padding(8).background(.regularMaterial, in: Circle())
            }
            .padding(8)
            .accessibilityLabel("Karte ausblenden")
        }
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
            if !showMap {
                Button { withAnimation { showMap = true } } label: { Image(systemName: "map").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 6)
            }
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
    @Published var mapItems: [Item] = []
    @Published var aheadItems: Set<String> = []
    @Published var mapWarns: [Warn] = []
    @Published var nearPoints: [Point] = []
    @Published var location: CLLocation?
    @Published var heading: Double = 0
    @Published var cameraTick = 0

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
        location = loc
        defer { cameraTick += 1 }
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
                if roadID == nil {
                    message = "Keine Autobahn in der Nähe. Der Fahrmodus startet, sobald du auf einer Autobahn bist."; icon = "road.lanes"
                    nearPoints = store.points.filter { kilometers(here, $0.coordinate) < 25 }
                }
                return
            }
            if road != roadID {
                roadID = road
                detail = nil
                load(road)
            }
        }
        guard let d = detail, let axis = d.axis else { return }
        nearPoints = []
        let todayGroups = Set(d.groups.filter(\.heute).flatMap(\.items))
        mapItems = d.items.filter { todayGroups.contains($0.id) }
        mapWarns = d.warns

        // Fahrtrichtung: aus dem Kurs des GPS, sonst aus der Bewegung seit der letzten Position
        var course = loc.course >= 0 && loc.speed > 2 ? loc.course : -1.0
        if course < 0, let prev = lastLoc, loc.distance(from: prev) > 40 {
            let dLon = (loc.coordinate.longitude - prev.coordinate.longitude) * cos(loc.coordinate.latitude * .pi / 180)
            let dLat = loc.coordinate.latitude - prev.coordinate.latitude
            course = atan2(dLon, dLat) * 180 / .pi
        }
        if course >= -180 && course != -1 {
            heading = (course + 360).truncatingRemainder(dividingBy: 360)
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
        aheadItems = Set(d.groups.filter { g in list.contains { $0.id == g.id } }.flatMap(\.items))
        stand = "Stand \(Date().formatted(date: .omitted, time: .shortened)) Uhr · \(upcoming.count) voraus"
    }

    /// Das dem Fahrer zugewandte Ende der Meldung (in Fahrtrichtung der Anfang)
    func start(of it: Item) -> CLLocationCoordinate2D {
        let c = it.coordinates
        guard let axis = detail?.axis, let f = c.first, let l = c.last else { return it.coordinates.first ?? CLLocationCoordinate2D() }
        let tf = axis.along(lon: f.longitude, lat: f.latitude), tl = axis.along(lon: l.longitude, lat: l.latitude)
        return (dir == "plus") == (tf <= tl) ? f : l
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

private extension CLLocationCoordinate2D {
    /// Punkt in `meters` Entfernung in Richtung `heading` (Grad, 0 = Norden)
    func moved(meters: Double, heading: Double) -> CLLocationCoordinate2D {
        let rad = heading * .pi / 180
        let dLat = meters * cos(rad) / 111_320
        let dLon = meters * sin(rad) / (111_320 * cos(latitude * .pi / 180))
        return CLLocationCoordinate2D(latitude: latitude + dLat, longitude: longitude + dLon)
    }
}
