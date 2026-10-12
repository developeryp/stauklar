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
                Section {
                    if push.authorized {
                        Label("Benachrichtigungen sind an", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        DatePicker("Morgenlage um", selection: digestBinding, displayedComponents: .hourAndMinute)
                        Toggle("Sofort bei neuen Vollsperrungen", isOn: .constant(true)).disabled(true)
                        Button("In den iOS-Einstellungen ändern") { openSystemSettings() }
                    } else if push.denied {
                        Label("In den iOS-Einstellungen ausgeschaltet", systemImage: "bell.slash").foregroundStyle(.secondary)
                        Button("iOS-Einstellungen öffnen") { openSystemSettings() }
                    } else {
                        Button {
                            Task { await push.enable() }
                        } label: {
                            Label("Benachrichtigungen einschalten", systemImage: "bell.badge.fill")
                        }
                    }
                    if let e = push.lastError { Text(e).font(.caption).foregroundStyle(.secondary) }
                } header: {
                    Text("Benachrichtigungen")
                } footer: {
                    Text(store.favorites.isEmpty
                         ? "Gilt für deine Strecken. Du hast noch keine: Tipp auf einer Autobahn-Seite auf den Stern."
                         : "Morgens zur Wunschzeit die Lage auf deinen Strecken, nur wenn dort etwas gesperrt ist. Dazu sofort eine Nachricht bei jeder neuen Vollsperrung, auch nachts.")
                }

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
                    Link(destination: URL(string: "mailto:hallo@stauklar.de?subject=Stauklar%20App")!) {
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
