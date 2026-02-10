//
//  WatchConnectivityManager.swift
//  Powston
//
//  Handles WatchConnectivity to send credentials to Apple Watch
//

import Foundation
import WatchConnectivity
import Combine

class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()
    
    private var session: WCSession?
    @Published var isReachable = false
    @Published var isActivated = false
    
    // Cache credentials for sending after activation
    private var pendingCredentials: (apiKey: String, baseURL: String, siteId: Int, demoMode: Bool)?
    
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
    func sendCredentialsToWatch(apiKey: String, baseURL: String, siteId: Int, demoMode: Bool = false) {
        // Always cache the latest credentials
        pendingCredentials = (apiKey, baseURL, siteId, demoMode)
        
        guard let session = session else {
            print("⌚ iOS: No WCSession, credentials cached for later")
            return
        }
        
        guard session.activationState == .activated else {
            print("⌚ iOS: WCSession not yet activated, credentials cached for later")
            return
        }
        
        sendCredentialsNow(apiKey: apiKey, baseURL: baseURL, siteId: siteId, demoMode: demoMode)
    }
    
    /// Actually send credentials (only call when session is activated)
    private func sendCredentialsNow(apiKey: String, baseURL: String, siteId: Int, demoMode: Bool) {
        guard let session = session, session.activationState == .activated else {
            print("⌚ iOS: Cannot send - session not activated")
            return
        }
        
        let context: [String: Any] = [
            SharedSettingsKey.apiKey: apiKey,
            SharedSettingsKey.baseURL: baseURL,
            SharedSettingsKey.siteId: siteId,
            SharedSettingsKey.demoMode: demoMode
        ]
        
        do {
            try session.updateApplicationContext(context)
            print("⌚ iOS: Sent credentials to Watch via applicationContext (site: \(siteId), demo: \(demoMode))")
        } catch {
            print("❌ iOS: Failed to update applicationContext: \(error)")
        }
        
        // Also try immediate message if Watch is reachable (faster delivery)
        if session.isReachable {
            session.sendMessage(context, replyHandler: nil) { error in
                print("⌚ iOS: Immediate message failed (non-fatal): \(error.localizedDescription)")
            }
            print("⌚ iOS: Also sent immediate message (Watch is reachable)")
        }
    }
    
    /// Send cached credentials after activation
    private func sendPendingCredentials() {
        guard let pending = pendingCredentials else {
            print("⌚ iOS: No pending credentials to send")
            return
        }
        
        print("⌚ iOS: Sending cached credentials after activation...")
        sendCredentialsNow(apiKey: pending.apiKey, baseURL: pending.baseURL, siteId: pending.siteId, demoMode: pending.demoMode)
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
            siteId: siteId,
            demoMode: api.demoModeEnabled
        )
    }
    
    // MARK: - Complication Updates
    
    /// Push complication data to Watch (call after successful data fetch)
    /// Uses transferCurrentComplicationUserInfo for higher priority delivery
    func pushComplicationUpdate(
        soc: Int,
        batteryKw: Double,
        isCharging: Bool,
        buyPrice: Double,
        sellPrice: Double,
        action: String
    ) {
        guard let session = session, session.activationState == .activated else {
            print("⌚ iOS: Cannot push complication - session not activated")
            return
        }
        
        guard session.isWatchAppInstalled else {
            print("⌚ iOS: Watch app not installed, skipping complication push")
            return
        }
        
        let data: [String: Any] = [
            "complication_update": true,
            "soc": soc,
            "batteryKw": batteryKw,
            "isCharging": isCharging,
            "buyPrice": buyPrice,
            "sellPrice": sellPrice,
            "action": action,
            "timestamp": Date().timeIntervalSince1970
        ]
        
        // Use transferCurrentComplicationUserInfo for high-priority complication updates
        // This has a budget of ~50 transfers per day, which is plenty for our use case
        if session.isComplicationEnabled {
            // remainingComplicationUserInfoTransfers tells us how many we have left today
            let remaining = session.remainingComplicationUserInfoTransfers
            print("⌚ iOS: Complication transfers remaining today: \(remaining)")
            
            if remaining > 0 {
                session.transferCurrentComplicationUserInfo(data)
                print("⌚ iOS: Pushed complication update via transferCurrentComplicationUserInfo (SOC: \(soc)%)")
                return
            } else {
                print("⌚ iOS: Complication transfer budget exhausted, falling back to userInfo")
            }
        }
        
        // Fallback: regular userInfo transfer (lower priority but no daily limit)
        session.transferUserInfo(data)
        print("⌚ iOS: Pushed complication update via transferUserInfo (SOC: \(soc)%)")
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
            if session.isWatchAppInstalled {
                print("⌚ iOS: Complication enabled: \(session.isComplicationEnabled), transfers remaining: \(session.remainingComplicationUserInfoTransfers)")
            }
            
            // Send any pending credentials now that we're activated
            if activationState == .activated {
                sendPendingCredentials()
            }
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
        
        // When Watch becomes reachable, try sending credentials immediately
        if session.isReachable, let pending = pendingCredentials {
            let context: [String: Any] = [
                SharedSettingsKey.apiKey: pending.apiKey,
                SharedSettingsKey.baseURL: pending.baseURL,
                SharedSettingsKey.siteId: pending.siteId,
                SharedSettingsKey.demoMode: pending.demoMode
            ]
            session.sendMessage(context, replyHandler: nil) { error in
                print("⌚ iOS: Reachability message failed: \(error.localizedDescription)")
            }
            print("⌚ iOS: Sent credentials on reachability change")
        }
    }
    
    /// Send just demo mode state (call when demo mode toggles)
    func sendDemoModeToWatch(enabled: Bool, from api: PowstonAPI) {
        let siteId = api.selectedSiteId ?? 0
        sendCredentialsToWatch(
            apiKey: enabled ? "" : api.apiKey,
            baseURL: api.baseURL,
            siteId: siteId,
            demoMode: enabled
        )
    }
    
    // Handle messages from Watch (if Watch ever needs to request credentials)
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        print("⌚ iOS: Received message from Watch: \(message.keys)")
        
        // If Watch requests credentials, resend them
        if message["requestCredentials"] != nil {
            print("⌚ iOS: Watch requested credentials refresh")
            sendPendingCredentials()
        }
    }
}
