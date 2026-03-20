//
//  AppDelegate.swift
//  Powston
//

import UIKit
import SwiftUI
import Combine
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.portrait
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // Clear badge on launch
        NotificationManager.shared.clearBadge()
        
        // Listen for app becoming active
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        
        // Register for remote notifications if already authorized
        registerForPushNotifications()
        
        return true
    }
    
    @objc func applicationDidBecomeActive() {
        NotificationManager.shared.clearBadge()
        
        // Check if we need to refresh after a silent push
        if UserDefaults.standard.bool(forKey: "needs_refresh_on_foreground") {
            UserDefaults.standard.set(false, forKey: "needs_refresh_on_foreground")
            print("📨 Refreshing after silent push flag")
            NotificationCenter.default.post(name: .refreshDataNeeded, object: nil)
        }
        
        // Trigger background sync of recent days if needed (daily)
        triggerBackgroundSyncIfNeeded()
    }

    private func triggerBackgroundSyncIfNeeded() {
        Task { @MainActor in
            // Get site/inverter info from shared state
            // PowstonDataStore needs to be configured with API first
            let dataStore = PowstonDataStore.shared
            
            // Read cached site info from UserDefaults (set during normal app use)
            guard let siteId = UserDefaults.standard.object(forKey: "selected_site_id") as? Int,
                  siteId > 0 else {
                print("📦 Background sync skipped - no site selected")
                return
            }
            
            // Get inverter IDs from cached list
            if let inverterData = UserDefaults.standard.data(forKey: "site_\(siteId)_inverter_ids"),
               let inverterIds = try? JSONDecoder().decode([Int].self, from: inverterData),
               !inverterIds.isEmpty {
                dataStore.scheduleBackgroundSyncIfNeeded(siteId: siteId, inverterIds: inverterIds)
            } else {
                print("📦 Background sync skipped - no inverter IDs cached")
            }
        }
    }
    
    // MARK: - Push Notifications
    
    private func registerForPushNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                print("🔔 Push: Not authorized for notifications yet")
                return
            }
            
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("📱 APNs Device Token: \(token)")
        
        // Store token for later use
        UserDefaults.standard.set(token, forKey: "apns_device_token")
        
        // Copy to clipboard in debug builds for easy testing
        #if DEBUG
        UIPasteboard.general.string = token
        print("📋 Token copied to clipboard")
        #endif
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("❌ Failed to register for remote notifications: \(error.localizedDescription)")
    }
    
    // Handle push received while app is in foreground or background
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        print("📬 Received remote notification: \(userInfo)")
        
        // Check if it's a silent price update notification
        if userInfo["price_update"] != nil {
            print("📨 Silent push received: price update")
            
            if application.applicationState == .active {
                // App is in foreground - refresh immediately
                print("📨 Foreground - refreshing now")
                NotificationCenter.default.post(name: .refreshDataNeeded, object: nil)
            } else {
                // App is in background - flag for refresh when returning
                print("📨 Background - flagging for refresh")
                UserDefaults.standard.set(true, forKey: "needs_refresh_on_foreground")
            }
            
            completionHandler(.newData)
            return
        }
        
        completionHandler(.noData)
    }
}

// MARK: - Orientation Manager
class OrientationManager: ObservableObject {
    static let shared = OrientationManager()

    @Published var isLandscapeAllowed = false

    // Track how many views want landscape (to handle tab switching)
    private var landscapeRequestCount = 0
    private var lockTask: Task<Void, Never>?

    func allowLandscape() {
        // Cancel any pending lock
        lockTask?.cancel()
        lockTask = nil

        landscapeRequestCount += 1
        isLandscapeAllowed = true
        AppDelegate.orientationLock = .allButUpsideDown
        notifyOrientationChange()
    }

    func lockToPortrait() {
        landscapeRequestCount = max(0, landscapeRequestCount - 1)

        // Only lock if no views want landscape anymore
        // Use a small delay to allow tab switching to call allowLandscape first
        lockTask?.cancel()
        lockTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second delay

            // Check if another view has requested landscape in the meantime
            guard !Task.isCancelled && self.landscapeRequestCount == 0 else { return }

            self.isLandscapeAllowed = false
            AppDelegate.orientationLock = .portrait
            notifyOrientationChange()

            // Force rotation back to portrait if currently in landscape
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }

    /// Notify the system that supported orientations have changed (required since iOS 16+)
    private func notifyOrientationChange() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        for window in windowScene.windows {
            // Notify entire view controller hierarchy
            notifyAllControllers(window.rootViewController)
        }
    }

    private func notifyAllControllers(_ vc: UIViewController?) {
        guard let vc = vc else { return }
        vc.setNeedsUpdateOfSupportedInterfaceOrientations()
        for child in vc.children {
            notifyAllControllers(child)
        }
        if let presented = vc.presentedViewController {
            notifyAllControllers(presented)
        }
    }
}

// MARK: - Landscape Container View
/// Full-screen container that forces landscape orientation for its content.
/// Use with .fullScreenCover to present landscape-only views (e.g. charts, tables).
struct LandscapeContainerView<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: { dismiss() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "xmark")
                                Text("Done")
                            }
                        }
                    }
                }
        }
        .onAppear {
            // Force landscape when presented
            AppDelegate.orientationLock = .landscape
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
                for window in windowScene.windows {
                    window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        }
        .onDisappear {
            // Restore portrait when dismissed
            AppDelegate.orientationLock = .portrait
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
                for window in windowScene.windows {
                    window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        }
    }
}
