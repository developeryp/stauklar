import SwiftUI

/// Navigation über die Reiter hinweg: Start-Pfad und aktiver Reiter (für Deep Links und Push)
@MainActor
final class Nav: ObservableObject {
    enum Tab: Hashable { case start, nearby, drive, settings }
    @Published var tab: Tab = .start
    @Published var path = NavigationPath()

    func open(road: String) { tab = .start; path.append(road) }
    /// Aus einer Benachrichtigung: Startseite frisch, darauf die Autobahn bzw. die Meldung
    func open(road: String, item: String?, title: String? = nil) {
        tab = .start
        var p = NavigationPath()
        if let item { p.append(RoadTarget(road: road, item: item, title: title)) } else { p.append(road) }
        path = p
    }
    func open(_ target: NearbyTarget) { tab = .start; path.append(target) }
}

/// Reiter: Start, Nähe, Fahrmodus, Einstellungen
struct RootView: View {
    @EnvironmentObject private var store: Store
    @StateObject private var nav = Nav()
    @ObservedObject private var push = PushManager.shared
    @Environment(\.scenePhase) private var phase

    private func openPending() {
        if let road = push.pendingRoad {
            nav.open(road: road, item: push.pendingItem, title: push.pendingTitle)
            push.pendingRoad = nil; push.pendingItem = nil; push.pendingTitle = nil
        } else if push.pendingHome {
            nav.tab = .start; nav.path = NavigationPath()
            push.pendingHome = false
        }
    }

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
        // Beim Zurückkehren in die App und alle 5 Minuten im Vordergrund neu laden, damit die Zahlen aktuell sind
        .onChange(of: phase) { _, p in if p == .active { Task { await store.load() } } }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                if phase == .active { await store.load() }
            }
        }
        // Angetippte Benachrichtigung → Autobahn öffnen
        .onChange(of: push.pendingRoad) { _, _ in openPending() }
        .onChange(of: push.pendingHome) { _, _ in openPending() }
        // App war geschlossen: der Tipp kam vor dem ersten Bild an
        .onAppear { openPending() }
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
