import SwiftUI
import UserNotifications
import AppIntents

@main
struct RA7ALOBDApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.locale, Locale(identifier: "ar"))
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            if !OBDLink.isUITesting { AlertCenter.shared.requestPermission() }
            _ = OBDLink.shared   // starts Bluetooth; iOS relaunches the app in background when the adapter appears
        }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

/// «فحص شامل» — usable from Shortcuts automations (e.g. "When CarPlay connects") and Siri.
struct StartScanIntent: AppIntent {
    static var title: LocalizedStringResource = "فحص شامل للسيارة"
    static var description = IntentDescription("يفتح RA7AL OBD ويبدأ فحصًا شاملًا للسيارة.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .ra7alStartScan, object: nil)
        OBDLink.shared.requestScan()
        return .result()
    }
}

struct RA7ALShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartScanIntent(), phrases: ["افحص السيارة في \(.applicationName)", "Scan car with \(.applicationName)"],
                    shortTitle: "فحص شامل", systemImageName: "checkmark.shield.fill")
    }
}
