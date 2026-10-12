import SwiftUI
import MapKit

/// „In meiner Nähe“ bzw. „Rund um <Stadt>“: Meldungen aller Autobahnen im Umkreis.
struct NearbyView: View {
    let target: NearbyTarget
    @EnvironmentObject private var store: Store
    @State private var center: CLLocationCoordinate2D?
    @State private var name = ""
    @State private var error: String?
    @State private var radius = 30.0
    @State private var camera: MapCameraPosition = .automatic
    @State private var location = LocationService()

    private var hits: [(point: Point, km: Double)] {
        guard let center else { return [] }
        return store.nearby(center, km: radius)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let error {
                    ContentUnavailableView {
                        Label("Kein Standort", systemImage: "location.slash")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Erneut versuchen") { Task { await locate() } }.buttonStyle(.bordered)
                    }
                } else if center == nil {
                    HStack(spacing: 10) { ProgressView(); Text("Standort wird bestimmt …").foregroundStyle(.secondary) }
                        .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                } else {
                    content
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
        .navigationDestination(for: RoadTarget.self) { RoadView(roadID: $0.road, focusItem: $0.item) }
        .navigationTitle(name.isEmpty ? "In der Nähe" : "Rund um \(name)")
        .navigationBarTitleDisplayMode(.large)
        .task { await locate() }
    }

    private var content: some View {
        let relevant = hits.filter { $0.point.heute && $0.point.severity != .dauer }
        let dauer = hits.filter { $0.point.severity == .dauer }
        let roadsNear = Dictionary(grouping: hits, by: { $0.point.road })
            .map { ($0.key, $0.value.map(\.km).min() ?? 0) }
            .sorted { $0.1 < $1.1 }
        return VStack(alignment: .leading, spacing: 18) {
            Map(position: $camera) {
                if let center {
                    Annotation("", coordinate: center) {
                        Circle().fill(Color(red: 0.04, green: 0.52, blue: 1)).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(radius: 3)
                    }
                }
                ForEach(hits, id: \.point.key) { h in
                    Annotation("", coordinate: h.point.coordinate) {
                        Circle().fill(Theme.color(h.point.severity)).frame(width: 10, height: 10)
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                            .opacity(h.point.heute ? 1 : 0.5)
                    }
                }
            }
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text(relevant.isEmpty
                 ? "Im Umkreis von \(Int(radius)) km ist heute nichts Kurzfristiges gemeldet. Gute Fahrt!"
                 : "\(relevant.count) \(relevant.count == 1 ? "Meldung" : "Meldungen") für heute und heute Nacht im Umkreis von \(Int(radius)) km, die nächste zuerst.")
                .font(.subheadline).foregroundStyle(.secondary)

            if !roadsNear.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(roadsNear.prefix(10), id: \.0) { r in
                            NavigationLink(value: r.0) { Shield(id: r.0, size: 15) }
                        }
                    }
                }
            }

            VStack(spacing: 8) {
                ForEach(relevant.prefix(40), id: \.point.key) { h in
                    NavigationLink(value: RoadTarget(road: h.point.road, item: h.point.id)) { NearbyRow(point: h.point, km: h.km) }
                }
            }

            if !dauer.isEmpty {
                DisclosureGroup {
                    VStack(spacing: 8) {
                        ForEach(dauer.prefix(60), id: \.point.key) { h in
                            NavigationLink(value: RoadTarget(road: h.point.road, item: h.point.id)) { NearbyRow(point: h.point, km: h.km) }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("\(dauer.count) Dauerbaustellen in der Nähe").font(.body.weight(.medium))
                }
                .tint(.primary)
            }
        }
    }

    private func locate() async {
        error = nil
        switch target {
        case .place(let n, let lat, let lon):
            name = n
            apply(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        case .me:
            do {
                apply(try await location.request())
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func apply(_ c: CLLocationCoordinate2D) {
        center = c
        if store.nearby(c, km: 30).isEmpty { radius = 60 }
        let span = radius > 30 ? 1.2 : 0.6
        camera = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)))
    }
}

struct NearbyRow: View {
    let point: Point
    let km: Double

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(Theme.color(point.severity)).frame(width: 10, height: 10)
            Shield(id: point.road, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if point.active { Badge(text: "jetzt", color: Theme.color(point.severity)) }
                    Text(point.active ? point.when.replacingOccurrences(of: "jetzt ", with: "") : point.when)
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(point.title).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                Text(point.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(km < 1 ? "< 1 km" : "\(Int(km.rounded())) km")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(Color.primary)
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
