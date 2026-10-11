import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: Store
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if query.isEmpty { overview } else { searchResults }
            }
            .background(Color(.systemBackground))
            .navigationTitle("Stauklar")
            .navigationDestination(for: String.self) { RoadView(roadID: $0) }
            .navigationDestination(for: NearbyTarget.self) { NearbyView(target: $0) }
            .searchable(text: $query, prompt: "Autobahn oder Stadt")
            .refreshable { await store.load() }
            .task { if store.roads.isEmpty { await store.load() } }
        }
    }

    // MARK: - Übersicht

    private var overview: some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            germany
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
            }
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
