import UIKit
import UserNotifications

/// Empfängt das Push-Token von iOS und reicht Benachrichtigungen weiter.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = PushManager.shared
        Task { await PushManager.shared.refresh() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await PushManager.shared.register(token: hex) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { await MainActor.run { PushManager.shared.lastError = error.localizedDescription } }
    }
}

/// Benachrichtigungen: morgens die Lage auf den eigenen Strecken, sofort bei neuen Vollsperrungen.
@MainActor
final class PushManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = PushManager()

    @Published var authorized = false
    @Published var denied = false
    @Published var lastError: String?
    /// Autobahn, die aus einer angetippten Benachrichtigung geöffnet werden soll
    @Published var pendingRoad: String?

    /// Wunschzeit der Morgenlage als „HH:mm“
    @Published var digestTime: String = UserDefaults.standard.string(forKey: "digestTime") ?? "06:30" {
        didSet {
            UserDefaults.standard.set(digestTime, forKey: "digestTime")
            Task { await sync() }
        }
    }

    private var token: String? {
        get { UserDefaults.standard.string(forKey: "apnsToken") }
        set { UserDefaults.standard.set(newValue, forKey: "apnsToken") }
    }

    func refresh() async {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        authorized = s.authorizationStatus == .authorized
        denied = s.authorizationStatus == .denied
        if authorized { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Fragt die Erlaubnis ab und meldet das Gerät an
    func enable() async {
        do {
            let ok = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            authorized = ok
            if ok { UIApplication.shared.registerForRemoteNotifications() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func register(token: String) async {
        self.token = token
        await sync()
    }

    /// Meldet Token und Lieblingsstrecken an den Server (bei jeder Änderung der Favoriten)
    func sync() async {
        guard let token, Config.supabaseKey != "SUPABASE_ANON_KEY" else { return }
        let roads = UserDefaults.standard.stringArray(forKey: "favorites") ?? []
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        // Serverfunktion register_device: legt an oder aktualisiert, ohne dass die App die Tabelle lesen darf
        let body: [String: Any] = ["p_token": token, "p_platform": "ios", "p_env": env, "p_roads": roads,
                                   "p_tz": TimeZone.current.identifier, "p_digest_time": digestTime]
        var req = URLRequest(url: Config.supabaseURL.appendingPathComponent("rest/v1/rpc/register_device"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.supabaseKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(Config.supabaseKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                lastError = "Server antwortete mit \(http.statusCode)"
            } else {
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let road = response.notification.request.content.userInfo["road"] as? String
        await MainActor.run { PushManager.shared.pendingRoad = road }
    }
}
