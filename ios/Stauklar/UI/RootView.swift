import SwiftUI

/// Navigation über die Reiter hinweg: Start-Pfad und aktiver Reiter (für Deep Links und Push)
@MainActor
final class Nav: ObservableObject {
    enum Tab: Hashable { case start, nearby, drive, settings }
    @Published var tab: Tab = .start
    @Published var path = NavigationPath()

    func open(road: String) { tab = .start; path.append(road) }
    func open(_ target: NearbyTarget) { tab = .start; path.append(target) }
}

/// Reiter: Start, Nähe, Fahrmodus, Einstellungen
struct RootView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var nav = Nav()
    @ObservedObject private var push = PushManager.shared

    var body: some View {
        TabView(selection: $nav.tab) {
            HomeView()
                .tabItem { Label("Start", systemImage: "road.lanes") }
                .tag(Nav.Tab.start)
            NavigationStack {
                NearbyView(target: .me)
                    .navigationDestination(for: String.self) { RoadView(roadID: $0) }
            }
            .tabItem { Label("Nähe", systemImage: "location.fill") }
            .tag(Nav.Tab.nearby)
            NavigationStack { DriveView() }
                .tabItem { Label("Fahrmodus", systemImage: "car.fill") }
                .tag(Nav.Tab.drive)
            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gearshape.fill") }
                .tag(Nav.Tab.settings)
        }
        .environmentObject(nav)
        .task { if store.roads.isEmpty { await store.load() } }
        // Angetippte Benachrichtigung → Autobahn öffnen
        .onChange(of: push.pendingRoad) { _, road in
            if let road { nav.open(road: road); push.pendingRoad = nil }
        }
        // Universal Links (stauklar.de/app/open/a7/) und Smart-App-Banner (stauklar.de/a7/, ?ort=Berlin)
        .onOpenURL { url in
            let parts = url.pathComponents.filter { $0 != "/" }.map { $0.lowercased() }
            if let r = store.roads.first(where: { parts.contains($0.slug) }) {
                nav.open(road: r.id)
            } else if let ort = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "ort" })?.value,
                      let c = store.cities.first(where: { $0.name.lowercased() == ort.lowercased() }) {
                nav.open(.place(name: c.name, lat: c.lat, lon: c.lon))
            } else {
                nav.tab = .start
            }
        }
    }
}
