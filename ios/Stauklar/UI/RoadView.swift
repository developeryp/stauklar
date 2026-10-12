import SwiftUI
import MapKit

/// Eine Autobahn: Lagebericht, Karte, Filter und die Meldungen in Streckenreihenfolge.
struct RoadView: View {
    let roadID: String
    /// Meldung (Item- oder Stau-ID), die beim Öffnen aufgeklappt und auf der Karte gezeigt wird
    var focusItem: String? = nil
    @EnvironmentObject private var store: Store
    @State private var detail: RoadDetail?
    @State private var failed = false
    @State private var when: When = .heute
    @State private var dir = ""
    @State private var showDauer = false
    @State private var expanded: Set<String> = []
    @State private var selected: String?
    @State private var camera: MapCameraPosition = .automatic
    @State private var fullMap = false
    @State private var scrollTarget: String?

    enum When: String, CaseIterable, Identifiable {
        case heute = "Heute", woche = "7 Tage", geplant = "Geplant", alle = "Alles"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let d = detail { content(d) } else if failed { failedView } else { loadingView }
            }
            .onChange(of: scrollTarget) { _, id in
                guard let id else { return }
                withAnimation(.snappy) { proxy.scrollTo(id, anchor: id == "map" ? .top : .center) }
                scrollTarget = nil
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(roadID)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.toggleFavorite(roadID)
                } label: {
                    Image(systemName: store.isFavorite(roadID) ? "star.fill" : "star")
                }
                .accessibilityLabel(store.isFavorite(roadID) ? "Aus meinen Strecken entfernen" : "Zu meinen Strecken")
            }
        }
        .task { await load() }
    }

    // MARK: - Laden

    private func load() async {
        guard let slug = store.road(roadID)?.slug ?? Optional(roadID.lowercased()) else { return }
        do {
            var d: RoadDetail = try await API.shared.get("road/\(slug).json")
            if let live = await Live.warnings(for: roadID, axis: d.axis) { d.warns = live }
            detail = d
            showDauer = d.voll == 0 && d.kurz == 0 && d.warns.isEmpty
            if visible(d).isEmpty && when == .heute { when = d.groups.contains { $0.woche } ? .woche : .alle }
            fitAll(d)
            if let fi = focusItem { openItem(fi, in: d) }
        } catch {
            failed = true
        }
    }

    // MARK: - Filter

    private func matches(_ g: Group, _ d: RoadDetail) -> Bool {
        let w = Self.inWindow(g, when)
        return w && (dir.isEmpty || g.d.isEmpty || g.d.contains(dir)) && (showDauer || g.severity != .dauer)
    }

    /// Einzelmeldungen, die zu den sichtbaren Maßnahmen gehören (für die Karte)
    private func visibleItems(_ d: RoadDetail) -> [Item] {
        let ids = Set(visible(d).flatMap(\.items))
        return d.items.filter { ids.contains($0.id) }
    }

    /// Heute = gilt bis morgen früh, 7 Tage = beginnt innerhalb einer Woche, Geplant = beginnt erst nach heute
    private static func inWindow(_ g: Group, _ w: When) -> Bool {
        switch w {
        case .heute: return g.heute
        case .woche: return g.woche
        case .geplant: return !g.heute
        case .alle: return true
        }
    }

    private func visible(_ d: RoadDetail) -> [Group] {
        let list = d.groups.filter { matches($0, d) }.sorted { $0.t < $1.t }
        return dir == "minus" ? list.reversed() : list
    }

    private func visibleWarns(_ d: RoadDetail) -> [Warn] {
        if when == .geplant { return [] }
        let list = d.warns.filter { dir.isEmpty || $0.d.isEmpty || $0.d == dir }.sorted { $0.t < $1.t }
        return dir == "minus" ? list.reversed() : list
    }

    private func count(_ w: When, _ d: RoadDetail) -> Int {
        d.groups.filter { g in
            let m = Self.inWindow(g, w)
            return m && (dir.isEmpty || g.d.isEmpty || g.d.contains(dir)) && (showDauer || g.severity != .dauer)
        }.count + (w == .geplant ? 0 : d.warns.count)
    }

    // MARK: - Inhalt

    /// Dauerbaustellen, die der Schalter gerade versteckt (im aktuellen Zeitraum/Richtung)
    private func hiddenDauer(_ d: RoadDetail) -> Int {
        guard !showDauer else { return 0 }
        return d.groups.filter { g in g.severity == .dauer && Self.inWindow(g, when) && (dir.isEmpty || g.d.isEmpty || g.d.contains(dir)) }.count
    }

    private func content(_ d: RoadDetail) -> some View {
        let groups = visible(d)
        let items = visibleItems(d)
        let warns = visibleWarns(d)
        // Maßnahmen und Staus gemeinsam in Streckenreihenfolge
        let rows: [Row] = (groups.map { Row.group($0) } + warns.map { Row.warn($0) })
            .sorted { dir == "minus" ? $0.t > $1.t : $0.t < $1.t }
        let ends = d.ends.count == 2 ? (dir == "minus" ? (d.ends[1], d.ends[0]) : (d.ends[0], d.ends[1])) : nil

        return LazyVStack(alignment: .leading, spacing: 22) {
            header(d)
            map(d, items: items, warns: warns)
            filters(d)
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Entlang der Strecke", detail: "\(rows.count)")
                if hiddenDauer(d) > 0 { hiddenNote(d) }
                if let ends { RouteEnd(text: ends.0) }
                if rows.isEmpty {
                    emptyHint(d)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(rows) { row in
                            switch row {
                            case .group(let g): GroupRow(group: g, labels: d.labels, expanded: binding(g.id)) { focus(g.id, d.items.filter { g.items.contains($0.id) }.flatMap(\.coordinates)) }.id(g.id)
                            case .warn(let w): WarnRow(warn: w, label: dirText(w.d, w.dir, d), expanded: binding(w.id)) { focus(w.id, w.coordinates) }.id(w.id)
                            }
                        }
                    }
                    .background(alignment: .leading) {
                        Rectangle().fill(Color(.separator)).frame(width: 2).padding(.leading, 10)
                    }
                }
                if let ends { RouteEnd(text: ends.1) }
            }
            if !d.parking.isEmpty || !d.charging.isEmpty { services(d) }
            if !d.near.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "In der Nähe")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(d.near, id: \.self) { r in NavigationLink(value: r) { Shield(id: r, size: 15) } }
                        }
                    }
                }
            }
            Text("Stand \(standText(d.stand)). Staus live von der Autobahn GmbH. Alle Angaben ohne Gewähr.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .padding(.bottom, 30)
    }

    private func header(_ d: RoadDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Shield(id: d.id, size: 24)
                StatusPill(status: d.status, text: d.statusText)
            }
            Text("\(d.id) heute")
                .font(.system(size: 34, weight: .bold)).tracking(-0.8)
            Text(d.lage)
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                KPI(value: d.voll, label: "Vollsperrungen", color: Theme.color(.voll))
                KPI(value: d.kurz, label: "kurzfristig bis morgen früh", color: Theme.color(.kurz))
                KPI(value: d.warns.count, label: "Staus & Gefahren", color: Theme.color(.live))
                KPI(value: d.dauer, label: "Dauerbaustellen", color: Theme.color(.dauer))
            }
        }
    }

    private func map(_ d: RoadDetail, items: [Item], warns: [Warn]) -> some View {
        // Verschieben und Zoomen auch in der Seite; zum Scrollen neben der Karte wischen. Vollbild über den Knopf.
        RoadMap(detail: d, items: items, warns: warns, selected: $selected, camera: $camera, modes: [.pan, .zoom], onSelect: select)
            .id("map")
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .topLeading) {
                Button("Ganze Strecke") { selected = nil; fitAll(d) }
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
            }
            .overlay(alignment: .bottom) { callout(d) }
            .overlay(alignment: .bottomLeading) { if selected == nil && hiddenDauer(d) > 0 { hiddenNote(d).padding(10) } }
            .overlay(alignment: .topTrailing) {
                Button { fullMap = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.semibold))
                        .padding(9)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel("Karte im Vollbild")
                .padding(10)
            }
            .fullScreenCover(isPresented: $fullMap) {
                NavigationStack {
                    RoadMap(detail: d, items: items, warns: warns, selected: $selected, camera: $camera, modes: .all, onSelect: select)
                        .ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            if let sel = selected, let g = d.groups.first(where: { $0.id == sel }) ?? nil {
                                Button { fullMap = false; scrollTarget = sel } label: {
                                    HStack(spacing: 10) {
                                        Circle().fill(Theme.color(g.severity)).frame(width: 10, height: 10)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(g.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                            Text("\(g.label) · \(g.when)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 4)
                                        Text("Details").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                }
                                .buttonStyle(.plain).foregroundStyle(.primary).padding(12)
                            }
                        }
                        .navigationTitle(d.id)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) { Button("Ganze Strecke") { selected = nil; fitAll(d) } }
                            ToolbarItem(placement: .topBarTrailing) { Button("Fertig") { fullMap = false } }
                        }
                }
            }
    }

    private func filters(_ d: RoadDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Zeitraum", selection: $when) {
                ForEach(When.allCases) { w in Text(w == .geplant ? w.rawValue : "\(w.rawValue) \(count(w, d))").tag(w) }
            }
            .pickerStyle(.segmented)
            HStack(spacing: 10) {
                if d.labels.count == 2 {
                    Menu {
                        Picker("Richtung", selection: $dir) {
                            Text("Beide Richtungen").tag("")
                            ForEach(["minus", "plus"], id: \.self) { k in
                                if let l = d.labels[k] { Text("\(l.sym) \(l.name)").tag(k) }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(dir.isEmpty ? "Beide Richtungen" : "\(d.labels[dir]?.sym ?? "") \(d.labels[dir]?.name ?? "")")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                        }
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(.secondarySystemBackground), in: Capsule())
                    }
                    .tint(.primary)
                }
                Toggle(isOn: $showDauer) { Text("Dauerbaustellen").font(.subheadline.weight(.medium)) }
                    .toggleStyle(.switch)
                    .labelsHidden()
                Text("Dauerbaustellen").font(.subheadline.weight(.medium)).lineLimit(1).fixedSize()
                Spacer()
            }
        }
        .onChange(of: when) { _, _ in fitVisible(d) }
        .onChange(of: dir) { _, _ in fitVisible(d) }
        .onChange(of: showDauer) { _, _ in fitVisible(d) }
    }

    private func hiddenNote(_ d: RoadDetail) -> some View {
        let n = hiddenDauer(d)
        return Button { withAnimation { showDauer = true } } label: {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash").font(.caption)
                Text("\(n) Dauerbaustelle\(n == 1 ? "" : "n") ausgeblendet")
                Text("Einblenden").foregroundStyle(Theme.accent).fontWeight(.semibold)
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private func emptyHint(_ d: RoadDetail) -> some View {
        VStack(spacing: 8) {
            Text(when == .heute ? "Für heute ist hier nichts gemeldet. Gute Fahrt!" : "Für diese Auswahl ist nichts gemeldet.")
                .foregroundStyle(.secondary)
            if !showDauer && d.dauer > 0 {
                Button("Dauerbaustellen anzeigen") { showDauer = true }.font(.subheadline.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    private func services(_ d: RoadDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Pause machen")
            if !d.parking.isEmpty {
                DisclosureGroup("\(d.parking.count) Rast- und Parkplätze") {
                    VStack(alignment: .leading, spacing: 4) { ForEach(d.parking, id: \.self) { Text($0).font(.subheadline) } }.padding(.top, 6)
                }
                .tint(.primary).card()
            }
            if !d.charging.isEmpty {
                DisclosureGroup("\(d.charging.count) Ladesäulen-Standorte") {
                    VStack(alignment: .leading, spacing: 4) { ForEach(d.charging, id: \.self) { Text($0).font(.subheadline) } }.padding(.top, 6)
                }
                .tint(.primary).card()
            }
        }
    }

    private var loadingView: some View {
        HStack(spacing: 10) { ProgressView(); Text("Lade \(roadID) …").foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var failedView: some View {
        ContentUnavailableView {
            Label("Keine Daten", systemImage: "wifi.slash")
        } description: {
            Text("Die \(roadID) konnte nicht geladen werden. Prüfe deine Internetverbindung.")
        } actions: {
            Button("Erneut versuchen") { failed = false; Task { await load() } }.buttonStyle(.bordered)
        }
    }

    // MARK: - Helfer

    private enum Row: Identifiable {
        case group(Group), warn(Warn)
        var id: String { switch self { case .group(let g): return g.id; case .warn(let w): return w.id } }
        var t: Double { switch self { case .group(let g): return g.t; case .warn(let w): return w.t } }
    }

    private func dirText(_ d: String, _ raw: String, _ detail: RoadDetail) -> String {
        if let l = detail.labels[d] { return "\(l.sym) Richtung \(l.name)" }
        return raw.isEmpty ? "" : "Richtung \(raw)"
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { on in if on { expanded.insert(id) } else { expanded.remove(id) } })
    }

    /// Aus Startseite oder Umkreis kommend: zugehörige Maßnahme finden, Filter passend setzen, aufklappen, hinzoomen
    private func openItem(_ itemID: String, in d: RoadDetail) {
        let gid = d.groups.first { $0.items.contains(itemID) }?.id ?? (d.warns.contains { $0.id == itemID } ? itemID : nil)
        guard let gid else { return }
        if let g = d.groups.first(where: { $0.id == gid }) {
            if !Self.inWindow(g, when) { when = g.heute ? .heute : (g.woche ? .woche : .alle) }
            if g.severity == .dauer { showDauer = true }
            if !dir.isEmpty && !g.d.isEmpty && !g.d.contains(dir) { dir = "" }
        }
        selected = gid
        expanded.insert(gid)
        let members = Set(d.groups.first(where: { $0.id == gid })?.items ?? [])
        let coords = d.items.filter { members.contains($0.id) }.flatMap(\.coordinates) + d.warns.filter { $0.id == gid }.flatMap(\.coordinates)
        if !coords.isEmpty { camera = .region(region(for: coords, minSpan: 0.03)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { scrollTarget = gid }
    }

    private func select(_ id: String) {
        withAnimation(.snappy) {
            selected = id
            expanded.insert(id)
        }
        // Karte samt Sprechblase ganz ins Bild holen
        if !fullMap { scrollTarget = "map" }
    }

    /// Sprechblase auf der Karte für die angetippte Meldung
    @ViewBuilder
    private func callout(_ d: RoadDetail) -> some View {
        if let sel = selected {
            let g = d.groups.first { $0.id == sel }
            let w = d.warns.first { $0.id == sel }
            if g != nil || w != nil {
                Button {
                    scrollTarget = sel
                } label: {
                    HStack(spacing: 10) {
                        Circle().fill(Theme.color(g?.severity ?? .live)).frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(g?.title ?? w?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(g.map { $0.active ? $0.when.replacingOccurrences(of: "jetzt ", with: "jetzt, ") : $0.when } ?? (w?.text.first ?? "Stau oder Gefahr"))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text("Details").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .padding(10)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func focus(_ id: String, _ coords: [CLLocationCoordinate2D]) {
        selected = id
        withAnimation { camera = .region(region(for: coords, minSpan: 0.03)) }
    }

    private func fitAll(_ d: RoadDetail) {
        withAnimation { camera = .region(region(for: d.items.flatMap(\.coordinates), minSpan: 0.3)) }
    }

    private func fitVisible(_ d: RoadDetail) {
        let coords = visibleItems(d).flatMap(\.coordinates) + visibleWarns(d).flatMap(\.coordinates)
        guard !coords.isEmpty else { return }
        withAnimation { camera = .region(region(for: coords, minSpan: 0.3)) }
    }

    private func region(for coords: [CLLocationCoordinate2D], minSpan: Double) -> MKCoordinateRegion {
        guard let first = coords.first else {
            return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 51.1, longitude: 10.4), span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8))
        }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for c in coords {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.3, minSpan), longitudeDelta: max((maxLon - minLon) * 1.3, minSpan))
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2), span: span)
    }

    private func standText(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return "" }
        return d.formatted(date: .omitted, time: .shortened) + " Uhr"
    }
}

struct RouteEnd: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary).padding(.leading, 34)
    }
}

/// Eine Meldung in der Streckenliste, aufklappbar
struct StopRow: View {
    let item: Item
    let label: String
    @Binding var expanded: Bool
    let onMap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Circle().fill(Theme.color(item.severity)).frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                .padding(.leading, 4).padding(.top, 20)
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                if item.active { Badge(text: "jetzt", color: Theme.color(item.severity)) }
                                Text(item.active ? item.when.replacingOccurrences(of: "jetzt ", with: "") : item.when)
                                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.color(item.severity))
                            }
                            Text(item.title).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                            Text([item.label, label].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            if !item.lanes.isEmpty && !item.laneText.isEmpty {
                                HStack(spacing: 8) {
                                    LaneGraphic(symbols: item.lanes)
                                    Text(item.laneText).font(.caption.weight(.medium))
                                }
                                .padding(.top, 4)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        detail("Zeitraum", windowText)
                        if item.windows.count > 1 { detail("Weitere Termine", "\(item.windows.count - 1) weitere") }
                        if let total = item.total, let d = ISO8601DateFormatter().date(from: total), total != item.end {
                            detail("Gesamte Maßnahme bis", d.formatted(date: .numeric, time: .omitted))
                        }
                        if !item.info.isEmpty { detail("Abschnitt", item.info.replacingOccurrences(of: " | ", with: " · ").replacingOccurrences(of: "Maximale Durchfahrtsbreite", with: "Breite")) }
                        if !item.place.isEmpty { detail("Lage", item.place) }
                        if !item.project.isEmpty && item.project != item.place { detail("Maßnahme", item.project) }
                        if item.geom.count > 1 {
                            Button("Auf der Karte", action: onMap)
                                .font(.subheadline.weight(.medium))
                                .buttonStyle(.bordered).buttonBorderShape(.capsule)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 14)
                    .transition(.opacity)
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.leading, 12)
        }
    }

    private var windowText: String {
        let f = ISO8601DateFormatter()
        guard let s = item.start.flatMap(f.date(from:)), let e = item.end.flatMap(f.date(from:)) else { return item.when }
        let day = Date.FormatStyle().day(.twoDigits).month(.twoDigits).year()
        let time = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute()
        return "\(s.formatted(day)) \(s.formatted(time)) – \(e.formatted(day)) \(e.formatted(time)) Uhr"
    }

    private func detail(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.subheadline)
        }
    }
}

struct WarnRow: View {
    let warn: Warn
    let label: String
    @Binding var expanded: Bool
    let onMap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Circle().fill(Theme.color(.live)).frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                .padding(.leading, 4).padding(.top, 20)
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Badge(text: "live", color: Theme.color(.live))
                                Text(warn.text.first ?? "aktuell").font(.caption.weight(.semibold)).foregroundStyle(Theme.color(.live)).lineLimit(1)
                            }
                            Text(warn.title).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                            Text(["Stau, Unfall oder Gefahr", label].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        ForEach(warn.text.dropFirst(), id: \.self) { Text($0).font(.subheadline) }
                        if warn.geom.count > 1 {
                            Button("Auf der Karte", action: onMap).font(.subheadline.weight(.medium)).buttonStyle(.bordered).buttonBorderShape(.capsule)
                        }
                    }
                    .padding(.horizontal, 14).padding(.bottom, 14)
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.leading, 12)
        }
    }
}

/// Karte einer Autobahn: ganzer Verlauf dezent, gefilterte Meldungen farbig, Staus lila
struct RoadMap: View {
    let detail: RoadDetail
    let items: [Item]
    let warns: [Warn]
    @Binding var selected: String?
    @Binding var camera: MapCameraPosition
    var modes: MapInteractionModes = .all
    let onSelect: (String) -> Void

    var body: some View {
        Map(position: $camera, interactionModes: modes) {
            UserAnnotation()
            ForEach(detail.items) { it in
                if it.geom.count > 1 { MapPolyline(coordinates: it.coordinates).stroke(Theme.sign.opacity(0.22), lineWidth: 4) }
            }
            ForEach(items) { it in
                if it.geom.count > 1 {
                    MapPolyline(coordinates: it.coordinates)
                        .stroke(Theme.color(it.severity).opacity(it.active ? 1 : 0.6), style: StrokeStyle(lineWidth: selected == (it.g ?? it.id) ? 9 : 5, lineCap: .round, lineJoin: .round))
                }
                Annotation("", coordinate: it.mid) {
                    let on = selected == (it.g ?? it.id)
                    ZStack {
                        Color.clear.frame(width: 36, height: 36).contentShape(Circle())
                        Circle().fill(Theme.color(it.severity)).frame(width: on ? 18 : 12, height: on ? 18 : 12)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                    .onTapGesture { onSelect(it.g ?? it.id) }
                }
            }
            ForEach(warns) { w in
                if w.geom.count > 1 {
                    MapPolyline(coordinates: w.coordinates)
                        .stroke(Theme.color(.live), style: StrokeStyle(lineWidth: selected == w.id ? 9 : 5, lineCap: .round, lineJoin: .round))
                }
                Annotation("", coordinate: w.mid) {
                    ZStack {
                        Color.clear.frame(width: 36, height: 36).contentShape(Circle())
                        Circle().fill(Theme.color(.live)).frame(width: selected == w.id ? 18 : 12, height: selected == w.id ? 18 : 12)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                    .onTapGesture { onSelect(w.id) }
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
    }
}

/// Eine Maßnahme in der Streckenliste: je Fahrtrichtung eine Zeile, gesperrte Auf-/Abfahrten als Stichpunkte
struct GroupRow: View {
    let group: Group
    let labels: [String: DirLabel]
    @Binding var expanded: Bool
    let onMap: () -> Void

    private func dirName(_ d: DirLine) -> String {
        if let l = labels[d.d] { return "\(l.sym) \(l.name)" }
        return d.raw.isEmpty ? "Beide Richtungen" : d.raw
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Circle().fill(Theme.color(group.severity)).frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                .padding(.leading, 4).padding(.top, 20)
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                    HStack(alignment: .center, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if group.active { Badge(text: "jetzt", color: Theme.color(group.severity)) }
                                Text(group.active ? group.when.replacingOccurrences(of: "jetzt ", with: "") : group.when)
                                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.color(group.severity))
                            }
                            Text(group.title).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                            Text((group.what ?? "").isEmpty ? group.label : "\(group.label) · \(group.what!)")
                                .font(.caption).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(group.dirs.enumerated()), id: \.offset) { _, d in
                                    // Breite Spurgrafiken: Text darunter statt daneben, damit nichts gequetscht wird
                                    ViewThatFits(in: .horizontal) {
                                        HStack(spacing: 8) {
                                            Text(dirName(d)).font(.caption.weight(.semibold)).frame(width: 86, alignment: .leading).fixedSize()
                                            if !d.lanes.isEmpty { LaneGraphic(symbols: d.lanes) }
                                            Text(d.laneText.isEmpty ? (group.severity == .voll ? "gesperrt" : "Baustelle") : d.laneText)
                                                .font(.caption).foregroundStyle(.secondary).fixedSize()
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 8) {
                                                Text(dirName(d)).font(.caption.weight(.semibold)).frame(width: 86, alignment: .leading).fixedSize()
                                                if !d.lanes.isEmpty { LaneGraphic(symbols: d.lanes) }
                                            }
                                            Text(d.laneText.isEmpty ? (group.severity == .voll ? "gesperrt" : "Baustelle") : d.laneText)
                                                .font(.caption).foregroundStyle(.secondary)
                                                .padding(.leading, 94)
                                        }
                                    }
                                }
                                ForEach(group.ramps, id: \.self) { r in
                                    // „Auffahrt X gesperrt“ → rot; „Abfahrt Y: 1 Spur frei“ → neutral
                                    if r.hasSuffix(" gesperrt") {
                                        HStack(spacing: 8) {
                                            Text(String(r.dropLast(9))).font(.caption.weight(.medium))
                                            Text("gesperrt").font(.caption.weight(.semibold)).foregroundStyle(Theme.color(.sperr))
                                        }
                                    } else {
                                        Text(r).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 180 : 0))
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                        detail("Zeitraum", windowText)
                        if group.upcoming > 1 { detail("Weitere Termine", "\(group.upcoming - 1) weitere") }
                        if let total = group.total, let d = ISO8601DateFormatter().date(from: total), total != group.end {
                            detail("Gesamte Maßnahme bis", d.formatted(date: .numeric, time: .omitted))
                        }
                        ForEach(Array(group.dirs.enumerated()), id: \.offset) { _, d in
                            if !d.place.isEmpty { detail(dirName(d), d.place) }
                        }
                        if !group.project.isEmpty { detail("Originalmeldung", group.project) }
                        Button("Auf der Karte", action: onMap)
                            .font(.subheadline.weight(.medium))
                            .buttonStyle(.bordered).buttonBorderShape(.capsule)
                            .padding(.top, 2)
                    }
                    .padding(.horizontal, 14).padding(.bottom, 14)
                    .transition(.opacity)
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.leading, 12)
        }
    }

    private var windowText: String {
        let f = ISO8601DateFormatter()
        guard let s = group.start.flatMap(f.date(from:)), let e = group.end.flatMap(f.date(from:)) else { return group.when }
        let day = Date.FormatStyle().day(.twoDigits).month(.twoDigits).year()
        let time = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute()
        return "\(s.formatted(day)) \(s.formatted(time)) – \(e.formatted(day)) \(e.formatted(time)) Uhr"
    }

    private func detail(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.subheadline)
        }
    }
}
