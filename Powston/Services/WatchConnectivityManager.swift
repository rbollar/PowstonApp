//
//  WatchConnectivityManager.swift
//  Powston
//
//  Handles WatchConnectivity to send credentials to Apple Watch
//

import Foundation
import WatchConnectivity

class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()
    
    private var session: WCSession?
    @Published var isReachable = false
    @Published var isActivated = false
    
    private override init() {
        super.init()
        
        guard WCSession.isSupported() else {
            print("⌚ WatchConnectivity not supported on this device")
            return
        }
        
        session = WCSession.default
        session?.delegate = self
        session?.activate()
        print("⌚ iOS: WCSession activating...")
    }
    
    /// Send credentials to Watch via applicationContext (persists until Watch reads it)
    func sendCredentialsToWatch(apiKey: String, baseURL: String, siteId: Int) {
        guard let session = session, session.activationState == .activated else {
            print("⌚ iOS: WCSession not activated, credentials will send after activation")
            return
        }
        
        guard !apiKey.isEmpty, siteId > 0 else {
            print("⌚ iOS: Skipping Watch sync - no valid credentials")
            return
        }
        
        let context: [String: Any] = [
            SharedSettingsKey.apiKey: apiKey,
            SharedSettingsKey.baseURL: baseURL,
            SharedSettingsKey.siteId: siteId
        ]
        
        do {
            try session.updateApplicationContext(context)
            print("⌚ iOS: Sent credentials to Watch via applicationContext (site: \(siteId))")
        } catch {
            print("❌ iOS: Failed to update applicationContext: \(error)")
        }
        
        // Also try immediate message if Watch is reachable (faster delivery)
        if session.isReachable {
            session.sendMessage(context, replyHandler: nil) { error in
                // Non-fatal - applicationContext is the reliable path
                print("⌚ iOS: Immediate message failed (non-fatal): \(error.localizedDescription)")
            }
            print("⌚ iOS: Also sent immediate message (Watch is reachable)")
        }
    }
    
    /// Force resend current credentials (call from Settings if user reports Watch issues)
    func resendCredentials(from api: PowstonAPI) {
        guard let siteId = api.selectedSiteId else {
            print("⌚ iOS: No site selected, cannot resend")
            return
        }
        sendCredentialsToWatch(
            apiKey: api.apiKey,
            baseURL: api.baseURL,
            siteId: siteId
        )
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isActivated = activationState == .activated
            self.isReachable = session.isReachable
        }
        
        if let error = error {
            print("❌ iOS: WCSession activation error: \(error)")
        } else {
            print("⌚ iOS: WCSession activated with state: \(activationState.rawValue) (0=notActivated, 1=inactive, 2=activated)")
            print("⌚ iOS: Watch app installed: \(session.isWatchAppInstalled), paired: \(session.isPaired)")
        }
    }
    
    func sessionDidBecomeInactive(_ session: WCSession) {
        print("⌚ iOS: WCSession became inactive")
    }
    
    func sessionDidDeactivate(_ session: WCSession) {
        print("⌚ iOS: WCSession deactivated, reactivating...")
        // Required for switching between multiple Apple Watches
        session.activate()
    }
    
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
        print("⌚ iOS: Watch reachability changed to: \(session.isReachable)")
    }
    
    // Handle messages from Watch (if Watch ever needs to request credentials)
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        print("⌚ iOS: Received message from Watch: \(message.keys)")
        
        // If Watch requests credentials, we could respond here
        if message["requestCredentials"] != nil {
            print("⌚ iOS: Watch requested credentials refresh")
            // Would need reference to PowstonAPI to resend
        }
    }
}
