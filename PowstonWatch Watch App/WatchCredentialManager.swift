//
//  WatchCredentialManager.swift
//  PowstonWatch
//
//  Manages credentials with priority: iCloud KVS → Watch Connectivity → Manual Entry
//

import Foundation
import WatchConnectivity
import WidgetKit
import Combine

@MainActor
class WatchCredentialManager: NSObject, ObservableObject {
    static let shared = WatchCredentialManager()
    
    @Published private(set) var apiKey: String = ""
    @Published private(set) var baseURL: String = "https://app.powston.com"
    @Published private(set) var siteId: Int = 0
    @Published private(set) var siteName: String = "My Site"
    @Published private(set) var isDemoMode: Bool = false
    @Published private(set) var authSource: AuthSource = .none
    
    enum AuthSource: String {
        case none = "Not configured"
        case iCloud = "iCloud"
        case watchConnectivity = "iPhone"
        case manual = "Manual"
        case demo = "Demo"
    }
    
    var isConfigured: Bool {
        isDemoMode || (!apiKey.isEmpty && siteId > 0)
    }
    
    private let store = NSUbiquitousKeyValueStore.default
    private var wcSession: WCSession?
    private var iCloudObserver: NSObjectProtocol?
    
    // App group for sharing data with widget extension
    private let watchAppGroup = "group.com.bollar.powston.watch"
    
    // iCloud KVS keys (must match iOS app's CloudCredentialSync)
    private enum CloudKeys {
        static let apiKey = "powston_cloud_api_key"
        static let baseURL = "powston_cloud_base_url"
        static let siteId = "powston_cloud_site_id"
        static let siteName = "powston_cloud_site_name"
        static let demoMode = "powston_cloud_demo_mode"
    }
    
    // Local storage keys
    private enum LocalKeys {
        static let apiKey = "watch_api_key"
        static let baseURL = "watch_base_url"
        static let siteId = "watch_site_id"
        static let siteName = "watch_site_name"
        static let demoMode = "watch_demo_mode"
        static let authSource = "watch_auth_source"
    }
    
    override init() {
        super.init()
        
        // Load cached credentials first (instant)
        loadLocalCredentials()
        
        // Set up Watch Connectivity
        setupWatchConnectivity()
        
        // Set up iCloud observation
        setupiCloudObserver()
        
        // Try to sync from iCloud (may update async)
        Task {
            await syncFromiCloud()
        }
    }
    
    // MARK: - iCloud Sync
    
    private func setupiCloudObserver() {
        iCloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.syncFromiCloud()
            }
        }
    }
    
    func syncFromiCloud() async {
        store.synchronize()
        
        // Check for demo mode first
        if store.bool(forKey: CloudKeys.demoMode) {
            isDemoMode = true
            authSource = .demo
            saveLocalCredentials()
            print("⌚ iCloud: Demo mode enabled")
            return
        }
        
        guard let cloudApiKey = store.string(forKey: CloudKeys.apiKey),
              !cloudApiKey.isEmpty else {
            print("⌚ iCloud: No credentials found")
            return
        }
        
        let cloudSiteId = Int(store.longLong(forKey: CloudKeys.siteId))
        guard cloudSiteId > 0 else {
            print("⌚ iCloud: No site ID")
            return
        }
        
        // Update credentials
        apiKey = cloudApiKey
        baseURL = store.string(forKey: CloudKeys.baseURL) ?? "https://app.powston.com"
        siteId = cloudSiteId
        siteName = store.string(forKey: CloudKeys.siteName) ?? "My Site"
        isDemoMode = false
        authSource = .iCloud
        
        saveLocalCredentials()
        print("⌚ iCloud: Loaded credentials for \(siteName)")
    }
    
    // MARK: - Watch Connectivity
    
    private func setupWatchConnectivity() {
        guard WCSession.isSupported() else { return }
        
        wcSession = WCSession.default
        wcSession?.delegate = self
        wcSession?.activate()
    }
    
    fileprivate func receiveFromiPhone(_ context: [String: Any]) {
        // Check demo mode
        if let demo = context["demo_mode"] as? Bool, demo {
            isDemoMode = true
            authSource = .demo
            saveLocalCredentials()
            print("⌚ WC: Demo mode from iPhone")
            return
        }
        
        guard let key = context["api_key"] as? String, !key.isEmpty else { return }
        
        apiKey = key
        baseURL = context["base_url"] as? String ?? "https://app.powston.com"
        siteId = context["site_id"] as? Int ?? 0
        siteName = context["site_name"] as? String ?? "My Site"
        isDemoMode = false
        authSource = .watchConnectivity
        
        saveLocalCredentials()
        print("⌚ WC: Received credentials for \(siteName)")
    }
    
    // MARK: - Complication Data Handling
    
    fileprivate func handleComplicationUpdate(_ userInfo: [String: Any]) {
        guard userInfo["complication_update"] as? Bool == true else { return }
        
        let soc = userInfo["soc"] as? Int ?? 0
        let batteryKw = userInfo["batteryKw"] as? Double ?? 0
        let isCharging = userInfo["isCharging"] as? Bool ?? false
        let buyPrice = userInfo["buyPrice"] as? Double ?? 0
        let sellPrice = userInfo["sellPrice"] as? Double ?? 0
        let action = userInfo["action"] as? String ?? "auto"
        let timestamp = userInfo["timestamp"] as? TimeInterval ?? Date().timeIntervalSince1970
        
        print("⌚ WC: Received complication update - SOC: \(soc)%, Action: \(action)")
        
        // Create complication data
        let complicationData = WatchComplicationData(
            soc: soc,
            batteryKw: batteryKw,
            isCharging: isCharging,
            buyPrice: buyPrice,
            sellPrice: sellPrice,
            action: action,
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
        
        // Cache to app group for widget extension
        cacheComplicationData(complicationData)
        
        // Reload complications
        WidgetCenter.shared.reloadAllTimelines()
        print("⌚ WC: Cached complication data and reloaded timelines")
    }
    
    private func cacheComplicationData(_ data: WatchComplicationData) {
        guard let sharedDefaults = UserDefaults(suiteName: watchAppGroup) else {
            print("⌚ Error: Cannot access app group \(watchAppGroup)")
            return
        }
        
        if let encoded = try? JSONEncoder().encode(data) {
            sharedDefaults.set(encoded, forKey: "cached_complication_data")
            sharedDefaults.synchronize()
            print("⌚ Cached complication data to app group")
        }
    }
    
    // MARK: - Manual Entry
    
    func setManualCredentials(apiKey: String, siteId: Int) {
        self.apiKey = apiKey
        self.siteId = siteId
        self.baseURL = "https://app.powston.com"
        self.siteName = "My Site"
        self.isDemoMode = false
        self.authSource = .manual
        
        saveLocalCredentials()
        print("⌚ Manual: Set credentials")
    }
    
    func enableDemoMode() {
        isDemoMode = true
        authSource = .demo
        saveLocalCredentials()
    }
    
    func clearCredentials() {
        apiKey = ""
        baseURL = "https://app.powston.com"
        siteId = 0
        siteName = "My Site"
        isDemoMode = false
        authSource = .none
        
        saveLocalCredentials()
    }
    
    // MARK: - Local Storage
    
    private func loadLocalCredentials() {
        let defaults = UserDefaults.standard
        apiKey = defaults.string(forKey: LocalKeys.apiKey) ?? ""
        baseURL = defaults.string(forKey: LocalKeys.baseURL) ?? "https://app.powston.com"
        siteId = defaults.integer(forKey: LocalKeys.siteId)
        siteName = defaults.string(forKey: LocalKeys.siteName) ?? "My Site"
        isDemoMode = defaults.bool(forKey: LocalKeys.demoMode)
        
        if let sourceString = defaults.string(forKey: LocalKeys.authSource),
           let source = AuthSource(rawValue: sourceString) {
            authSource = source
        }
    }
    
    private func saveLocalCredentials() {
        let defaults = UserDefaults.standard
        defaults.set(apiKey, forKey: LocalKeys.apiKey)
        defaults.set(baseURL, forKey: LocalKeys.baseURL)
        defaults.set(siteId, forKey: LocalKeys.siteId)
        defaults.set(siteName, forKey: LocalKeys.siteName)
        defaults.set(isDemoMode, forKey: LocalKeys.demoMode)
        defaults.set(authSource.rawValue, forKey: LocalKeys.authSource)
    }
    
    deinit {
        if let observer = iCloudObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchCredentialManager: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        print("⌚ WCSession activated: \(activationState.rawValue)")
        
        if !session.receivedApplicationContext.isEmpty {
            Task { @MainActor in
                self.receiveFromiPhone(session.receivedApplicationContext)
            }
        }
    }
    
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.receiveFromiPhone(applicationContext)
        }
    }
    
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.receiveFromiPhone(message)
        }
    }
    
    // Handle complication updates via transferCurrentComplicationUserInfo / transferUserInfo
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            if userInfo["complication_update"] != nil {
                self.handleComplicationUpdate(userInfo)
            } else {
                // Treat as credentials if not a complication update
                self.receiveFromiPhone(userInfo)
            }
        }
    }
}
