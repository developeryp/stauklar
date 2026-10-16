import SwiftUI
import SafariServices
import UIKit

/// Einstellungen: Benachrichtigungen, Lieblingsstrecken, rechtliche Seiten, Infos zur App
struct SettingsView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var nav: Nav
    @ObservedObject private var push = PushManager.shared
    @State private var web: URL?

    private let site = URL(string: "https://stauklar.de")!

    var body: some View {
        NavigationStack {
            Form {
                // Ohne Erlaubnis von iOS: nur der Knopf zum Erlauben, alle Einstellungen darunter gesperrt
                if !push.authorized {
                    Section {
                        if push.denied {
                            Button { openSystemSettings() } label: {
                                Label("In den iOS-Einstellungen erlauben", systemImage: "bell.slash")
                            }
                        } else {
                            Button { Task { await push.enable() } } label: {
                                Label("Benachrichtigungen erlauben", systemImage: "bell.badge.fill")
                            }
                        }
                        if let e = push.lastError { Text(e).font(.caption).foregroundStyle(.secondary) }
                    } footer: {
                        Text(push.denied
                             ? "Benachrichtigungen sind für Stauklar in den iOS-Einstellungen ausgeschaltet."
                             : "Damit Stauklar dir Nachrichten schicken darf, braucht es einmal deine Erlaubnis.")
                    }
                }

                Section {
                    Toggle("Morgenlage", isOn: $push.digestOn)
                    if push.digestOn {
                        DatePicker("Uhrzeit", selection: digestBinding, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Benachrichtigungen")
                } footer: {
                    Text(store.favorites.isEmpty
                         ? "Gilt für deine Strecken. Du hast noch keine: Tipp auf einer Autobahn-Seite auf den Stern."
                         : "Zur Wunschzeit die Lage auf deinen Strecken, nur wenn dort etwas gesperrt ist.")
                }
                .disabled(!push.authorized)

                Section {
                    ForEach(SevChip.all, id: \.0) { s, t in
                        Toggle(isOn: kind(s.rawValue)) {
                            HStack(spacing: 10) {
                                Circle().fill(Theme.color(s)).frame(width: 10, height: 10)
                                Text(t)
                            }
                        }
                    }
                } header: {
                    Text("Sofort Bescheid bei neuer …")
                } footer: {
                    Text("Sobald auf deinen Strecken eine neue Meldung dieser Art auftaucht, auch nachts. Kommen mehrere gleichzeitig, gibt es eine Nachricht pro Autobahn.")
                }
                .disabled(!push.authorized)

                Section {
                    if store.favorites.isEmpty {
                        Text("Noch keine Strecken gespeichert.").foregroundStyle(.secondary)
                    } else {
                        ForEach(store.favorites, id: \.self) { id in
                            Button {
                                nav.open(road: id)
                            } label: {
                                HStack { Shield(id: id, size: 14); Text(store.road(id)?.statusText ?? "").foregroundStyle(.secondary).font(.subheadline); Spacer() }
                            }
                        }
                        .onDelete { idx in store.favorites.remove(atOffsets: idx) }
                    }
                } header: {
                    Text("Meine Strecken")
                } footer: {
                    Text("Nach links wischen zum Entfernen.")
                }

                Section("Standort") {
                    Text("Der Standort bleibt auf dem Gerät. Er wird nur für „In meiner Nähe“ und den Fahrmodus genutzt und nie übertragen.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Standort-Berechtigung ändern") { openSystemSettings() }
                }

                Section("Rechtliches") {
                    row("Impressum", "doc.text") { web = site.appending(path: "impressum/") }
                    row("Datenschutz", "hand.raised") { web = site.appending(path: "datenschutz/") }
                }

                Section {
                    row("stauklar.de", "safari") { web = site }
                    Link(destination: URL(string: "mailto:developeryp1@gmail.com?subject=Stauklar%20App")!) {
                        Label("Feedback senden", systemImage: "envelope")
                    }
                    if let url = URL(string: "https://apps.apple.com/app/id6821828685?action=write-review") {
                        Link(destination: url) { Label("App bewerten", systemImage: "star") }
                    }
                } header: {
                    Text("Über Stauklar")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"))")
                        Text("Daten: Die Autobahn GmbH des Bundes, alle 15 Minuten neu, Staus live. Stauklar ist ein privates Angebot ohne Verbindung zur Autobahn GmbH. Alle Angaben ohne Gewähr.")
                    }
                }
            }
            .navigationTitle("Einstellungen")
            .task { await push.refresh() }
            .sheet(item: $web) { SafariView(url: $0).ignoresSafeArea() }
        }
    }

    private func row(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Label(title, systemImage: icon).foregroundStyle(Color.primary); Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    /// Schalter für eine Art von Sofortmeldung
    private func kind(_ k: String) -> Binding<Bool> {
        Binding(get: { push.alertKinds.contains(k) },
                set: { on in if on { push.alertKinds.insert(k) } else { push.alertKinds.remove(k) } })
    }

    /// „HH:mm“ ↔ Date für den Zeitwähler
    private var digestBinding: Binding<Date> {
        Binding(
            get: {
                let p = push.digestTime.split(separator: ":").compactMap { Int($0) }
                // Auf den heutigen Tag legen: ein Datum ohne Tag landet im Jahr 1, dort gilt die historische Ortszeit
                // (z. B. Madrid −0:14:44 statt +1:00) und der Wähler verschiebt die Uhrzeit um über eine Stunde
                return Calendar.current.date(bySettingHour: p.first ?? 6, minute: p.count > 1 ? p[1] : 30, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                push.digestTime = String(format: "%02d:%02d", c.hour ?? 6, c.minute ?? 30)
            })
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Webseite in der App (Impressum, Datenschutz)
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
