//
//  CloudCredentialSync.swift
//  Powston
//
//  iCloud Key-Value Store sync for cross-device credential sharing (iOS ↔ tvOS)
//

import Foundation

/// Syncs Powston credentials across devices via iCloud Key-Value Store
/// Used by iOS app to publish credentials and tvOS app to receive them
class CloudCredentialSync {
    static let shared = CloudCredentialSync()
    
    private let store = NSUbiquitousKeyValueStore.default
    
    private enum Keys {
        static let apiKey = "powston_cloud_api_key"
        static let baseURL = "powston_cloud_base_url"
        static let siteId = "powston_cloud_site_id"
        static let inverterId = "powston_cloud_inverter_id"
        static let lastSyncDate = "powston_cloud_last_sync"
    }
    
    private init() {
        // Synchronize on init to pull any existing iCloud data
        store.synchronize()
    }
    
    // MARK: - Save Credentials (called from iOS app)
    
    /// Saves credentials to iCloud Key-Value Store for sync to other devices
    func saveCredentials(apiKey: String, baseURL: String, siteId: Int, inverterId: Int) {
        store.set(apiKey, forKey: Keys.apiKey)
        store.set(baseURL, forKey: Keys.baseURL)
        store.set(siteId, forKey: Keys.siteId)
        store.set(inverterId, forKey: Keys.inverterId)
        store.set(Date().timeIntervalSince1970, forKey: Keys.lastSyncDate)
        
        // Request immediate sync
        store.synchronize()
        
        print("☁️ Saved credentials to iCloud KVS")
    }
    
    /// Clears credentials from iCloud (for logout)
    func clearCredentials() {
        store.removeObject(forKey: Keys.apiKey)
        store.removeObject(forKey: Keys.baseURL)
        store.removeObject(forKey: Keys.siteId)
        store.removeObject(forKey: Keys.inverterId)
        store.removeObject(forKey: Keys.lastSyncDate)
        store.synchronize()
        
        print("☁️ Cleared credentials from iCloud KVS")
    }
    
    // MARK: - Load Credentials (called from tvOS app)
    
    struct CloudCredentials {
        let apiKey: String
        let baseURL: String
        let siteId: Int
        let inverterId: Int
        let lastSyncDate: Date?
    }
    
    /// Retrieves credentials from iCloud Key-Value Store
    /// Returns nil if no credentials are stored or API key is empty
    func getCredentials() -> CloudCredentials? {
        // Force sync to get latest
        store.synchronize()
        
        guard let apiKey = store.string(forKey: Keys.apiKey),
              !apiKey.isEmpty else {
            return nil
        }
        
        let baseURL = store.string(forKey: Keys.baseURL) ?? "https://app.powston.com"
        let siteId = Int(store.longLong(forKey: Keys.siteId))
        let inverterId = Int(store.longLong(forKey: Keys.inverterId))
        
        let lastSyncTimestamp = store.double(forKey: Keys.lastSyncDate)
        let lastSyncDate = lastSyncTimestamp > 0 ? Date(timeIntervalSince1970: lastSyncTimestamp) : nil
        
        return CloudCredentials(
            apiKey: apiKey,
            baseURL: baseURL,
            siteId: siteId,
            inverterId: inverterId,
            lastSyncDate: lastSyncDate
        )
    }
    
    /// Check if credentials exist without loading them
    var hasCredentials: Bool {
        store.synchronize()
        guard let apiKey = store.string(forKey: Keys.apiKey) else { return false }
        return !apiKey.isEmpty
    }
    
    // MARK: - Change Observation
    
    private var observer: NSObjectProtocol?
    
    /// Observes iCloud KVS changes and calls handler when credentials update
    /// Call this on app launch to react to credential changes from iOS
    func observeChanges(handler: @escaping (CloudCredentials?) -> Void) {
        // Remove existing observer if any
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
        
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] notification in
            // Check what changed
            if let userInfo = notification.userInfo,
               let changedKeys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] {
                
                // Only trigger if credential keys changed
                let credentialKeys = [Keys.apiKey, Keys.siteId, Keys.inverterId, Keys.baseURL]
                let relevantChange = changedKeys.contains { credentialKeys.contains($0) }
                
                if relevantChange {
                    print("☁️ iCloud credentials changed externally")
                    handler(self?.getCredentials())
                }
            }
        }
        
        print("☁️ Observing iCloud KVS changes")
    }
    
    /// Stops observing changes
    func stopObserving() {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }
    
    deinit {
        stopObserving()
    }
}
