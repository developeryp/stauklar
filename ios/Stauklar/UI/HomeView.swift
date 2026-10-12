import SwiftUI
import MapKit

struct HomeView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var push = PushManager.shared
    @State private var query = ""
    @State private var path = NavigationPath()
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 51.2, longitude: 10.4), span: MKCoordinateSpan(latitudeDelta: 8.2, longitudeDelta: 8.2)))
    /// Meter pro Bildschirmpunkt beim aktuellen Zoom, damit die Punkte immer gleich groß bleiben
    @State private var metersPerPoint = 8.2 * 110_570 / 250
    private let mapHeight: CGFloat = 250

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if query.isEmpty { overview } else { searchResults }
            }
            .background(Color(.systemBackground))
            .navigationTitle("Stauklar")
            .navigationDestination(for: String.self) { RoadView(roadID: $0) }
            .navigationDestination(for: RoadTarget.self) { RoadView(roadID: $0.road, focusItem: $0.item) }
            .navigationDestination(for: NearbyTarget.self) { NearbyView(target: $0) }
            .searchable(text: $query, prompt: "Autobahn oder Stadt")
            .refreshable { await store.load() }
            .task { if store.roads.isEmpty { await store.load() } }
            .onChange(of: push.pendingRoad) { _, road in
                if let road { path.append(road); push.pendingRoad = nil }
            }
            // Universal Links: stauklar.de/a7/ öffnet die A7, stauklar.de/?ort=Berlin den Umkreis
            .onOpenURL { url in
                let parts = url.pathComponents.filter { $0 != "/" }
                if let first = parts.first, first.lowercased().hasPrefix("a"), first.count > 1, let r = store.roads.first(where: { $0.slug == first.lowercased() }) {
                    path.append(r.id)
                } else if let ort = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ort" })?.value,
                          let c = store.cities.first(where: { $0.name.lowercased() == ort.lowercased() }) {
                    path.append(NearbyTarget.place(name: c.name, lat: c.lat, lon: c.lon))
                }
            }
        }
    }

    // MARK: - Übersicht

    private var overview: some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            germany
            germanyMap
            favorites
            if !store.busiest.isEmpty { busiest }
            if !store.roads.isEmpty { allRoads }
            footer
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 30)
    }

    private var germany: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Wie frei ist deine Autobahn heute?")
                .font(.system(size: 30, weight: .bold))
                .tracking(-0.6)
                .fixedSize(horizontal: false, vertical: true)
            if let error = store.error {
                Text(error).font(.subheadline).foregroundStyle(.secondary)
            } else if store.roads.isEmpty {
                HStack(spacing: 10) { ProgressView(); Text("Lade aktuelle Lage …").foregroundStyle(.secondary) }
            } else {
                let t = store.totals
                HStack(spacing: 10) {
                    KPI(value: t.voll, label: "Vollsperrungen", color: Theme.color(.voll))
                    KPI(value: t.kurz, label: "kurzfristig bis morgen früh", color: Theme.color(.kurz))
                    KPI(value: t.live, label: "Staus & Gefahren", color: Theme.color(.live))
                }
            }
            NavigationLink(value: NearbyTarget.me) {
                Label("In meiner Nähe", systemImage: "location.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
    }

    /// Deutschlandkarte: alles, was heute gilt, als farbige Punkte. Tipp auf die Karte zeigt den Umkreis dort.
    private var germanyMap: some View {
        let pts = store.points.filter { $0.heute && $0.severity != .dauer }
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Deutschland heute", detail: pts.isEmpty ? nil : "\(pts.count)")
            MapReader { proxy in
                Map(position: $camera, interactionModes: [.pan, .zoom]) {
                    UserAnnotation()
                    ForEach(pts) { p in
                        // Radius in Metern läuft mit dem Zoom mit → Punkte bleiben immer ca. 4–5 Bildschirmpunkte groß
                        MapCircle(center: p.coordinate, radius: metersPerPoint * (p.severity == .kurz ? 3.5 : 4.5))
                            .foregroundStyle(Theme.color(p.severity).opacity(0.95))
                            .stroke(.white, lineWidth: 1)
                    }
                }
                .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
                // Nur am Ende einer Geste anpassen, sonst werden alle Punkte bei jedem Bild neu gezeichnet (ruckelt)
                .onMapCameraChange(frequency: .onEnd) { ctx in
                    let m = ctx.region.span.latitudeDelta * 110_570 / Double(mapHeight)
                    if abs(m - metersPerPoint) / metersPerPoint > 0.15 { metersPerPoint = m }
                }
                .onTapGesture { pt in
                    // Nächster Punkt im Umkreis von 18 Bildschirmpunkten → genau diese Meldung öffnen, sonst Umkreis dort
                    var best: (Point, CGFloat)?
                    for p in pts {
                        guard let sp = proxy.convert(p.coordinate, to: .local) else { continue }
                        let d = hypot(sp.x - pt.x, sp.y - pt.y)
                        if d < 18, best == nil || d < best!.1 { best = (p, d) }
                    }
                    if let hit = best?.0 {
                        path.append(RoadTarget(road: hit.road, item: hit.id))
                    } else if let c = proxy.convert(pt, from: .local) {
                        path.append(NearbyTarget.place(name: "diese Stelle", lat: c.latitude, lon: c.longitude))
                    }
                }
            }
            .frame(height: mapHeight)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            HStack(spacing: 14) {
                legend(.voll, "Vollsperrung"); legend(.sperr, "Sperrung"); legend(.kurz, "kurzfristig"); legend(.live, "Stau")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary)
            Text("Tipp auf einen Punkt, um die Meldung zu öffnen, oder auf eine freie Stelle für den Umkreis dort. Zum Scrollen neben der Karte wischen.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    /// „HH:mm“ ↔ Date für den Zeitwähler
    private var digestBinding: Binding<Date> {
        Binding(
            get: {
                let p = push.digestTime.split(separator: ":").compactMap { Int($0) }
                return Calendar.current.date(from: DateComponents(hour: p.first ?? 6, minute: p.count > 1 ? p[1] : 30)) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                push.digestTime = String(format: "%02d:%02d", c.hour ?? 6, c.minute ?? 30)
            })
    }

    private func legend(_ s: Severity, _ t: String) -> some View {
        HStack(spacing: 5) { Circle().fill(Theme.color(s)).frame(width: 8, height: 8); Text(t) }
    }

    private var favorites: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Meine Strecken")
            if store.favorites.isEmpty {
                Text("Tipp auf einer Autobahn-Seite auf den Stern, dann erscheint sie hier. So siehst du jeden Morgen auf einen Blick, ob deine Strecke frei ist.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .card()
            } else {
                VStack(spacing: 8) {
                    ForEach(store.favorites, id: \.self) { id in
                        if let r = store.road(id) {
                            NavigationLink(value: id) { RoadRow(road: r) }
                        }
                    }
                }
                pushCard
            }
        }
    }

    /// Einladung zu Benachrichtigungen, sobald es Lieblingsstrecken gibt
    @ViewBuilder
    private var pushCard: some View {
        if push.authorized {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge.fill").foregroundStyle(Theme.accent)
                    Text("Sofort Bescheid bei neuen Vollsperrungen, dazu jeden Morgen die Lage auf deinen Strecken.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Morgenlage um").font(.subheadline.weight(.medium))
                    Spacer()
                    DatePicker("Uhrzeit der Morgenlage", selection: digestBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
            }
            .card()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Morgens Bescheid bekommen?").font(.headline)
                Text("Stauklar meldet sich morgens zur Wunschzeit, wenn auf deinen Strecken heute etwas gesperrt ist, und sofort bei neuen Vollsperrungen.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button {
                    Task { await push.enable() }
                } label: {
                    Text("Benachrichtigungen einschalten").font(.subheadline.weight(.semibold)).padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                if let e = push.lastError { Text(e).font(.caption).foregroundStyle(.secondary) }
            }
            .card()
        }
    }

    private var busiest: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Heute viel los")
            VStack(spacing: 8) {
                ForEach(store.busiest) { r in
                    NavigationLink(value: r.id) { RoadRow(road: r, showLage: true) }
                }
            }
        }
    }

    private var allRoads: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Alle Autobahnen", detail: "\(store.roads.count)")
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(store.roads) { r in
                    NavigationLink(value: r.id) {
                        Shield(id: r.id)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Circle().fill(Theme.statusColor(r.status)).frame(width: 7, height: 7).padding(7)
                            }
                    }
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let stand = store.stand {
                Text("Stand \(stand.formatted(date: .omitted, time: .shortened)) Uhr, alle 15 Minuten neu. Staus live.")
            }
            Text("Daten: Die Autobahn GmbH des Bundes. Alle Angaben ohne Gewähr.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Suche

    private var searchResults: some View {
        let r = store.search(query)
        return LazyVStack(alignment: .leading, spacing: 8) {
            if r.roads.isEmpty && r.cities.isEmpty {
                Text("Nichts gefunden. Versuch eine Autobahnnummer wie „A7“ oder eine größere Stadt.")
                    .foregroundStyle(.secondary)
                    .padding(.top, 20)
            }
            ForEach(r.roads) { road in
                NavigationLink(value: road.id) { RoadRow(road: road) }
            }
            ForEach(r.cities) { c in
                NavigationLink(value: NearbyTarget.place(name: c.name, lat: c.lat, lon: c.lon)) {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.body.weight(.semibold))
                            Text("Alles im Umkreis von 30 km").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
    }
}

struct RoadRow: View {
    let road: RoadSummary
    var showLage = false

    var body: some View {
        HStack(spacing: 12) {
            Shield(id: road.id, size: 15)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.statusColor(road.status)).frame(width: 7, height: 7)
                    Text(road.statusText).font(.subheadline.weight(.semibold))
                }
                if showLage {
                    Text(road.lage.components(separatedBy: ". ").first ?? road.lage)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else {
                    Text("\(road.voll) voll gesperrt · \(road.kurz) kurzfristig · \(road.live) Staus")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(Color.primary)
    }
}
