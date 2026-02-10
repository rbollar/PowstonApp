//
//  PushNotificationService.swift
//  Powston
//
//  Handles registration with push notification server
//

import Foundation

class PushNotificationService {
    static let shared = PushNotificationService()
    
    // MARK: - Configuration
    
    private let serverURL = "https://push.bollar.com"
    private let sharedSecret = "RU2j*XV9FDYHvvHZXU-ZhWg!i-dwwqM2"
    
    private var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
    
    // MARK: - Registration
    
    /// Register device for push notifications
    func register(
        deviceToken: String,
        state: String,
        network: String,
        tariff: String,
        exportTariff: String,
        marketCosts: Double?,
        sellAbove: Double?,
        sellBelow: Double?,
        buyAbove: Double?,
        buyBelow: Double?,
        spikeThreshold: Double?
    ) async -> Bool {
        guard let url = URL(string: "\(serverURL)/api/push/register") else {
            print("❌ Push registration: Invalid URL")
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sharedSecret, forHTTPHeaderField: "X-Push-Secret")
        
        let payload: [String: Any] = [
            "device_token": deviceToken,
            "state": state,
            "network": network,
            "tariff": tariff,
            "export_tariff": exportTariff,
            "market_costs": marketCosts ?? 2,
            "apns_environment": apnsEnvironment,
            "thresholds": [
                "sell_above": sellAbove as Any,
                "sell_below": sellBelow as Any,
                "buy_above": buyAbove as Any,
                "buy_below": buyBelow as Any,
                "spike_threshold": spikeThreshold as Any,
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Push registration: Invalid response")
                return false
            }
            
            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let action = json["action"] as? String {
                    print("✅ Push registration (\(apnsEnvironment)): \(action)")
                }
                return true
            } else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                print("❌ Push registration failed: \(httpResponse.statusCode) - \(body)")
                return false
            }
        } catch {
            print("❌ Push registration error: \(error)")
            return false
        }
    }
    
    /// Unregister device from push notifications
    func unregister(deviceToken: String) async -> Bool {
        guard let url = URL(string: "\(serverURL)/api/push/register") else {
            print("❌ Push unregister: Invalid URL")
            return false
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sharedSecret, forHTTPHeaderField: "X-Push-Secret")
        
        let payload: [String: Any] = [
            "device_token": deviceToken
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Push unregister: Invalid response")
                return false
            }
            
            if httpResponse.statusCode == 200 {
                print("✅ Push unregistered")
                return true
            } else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                print("❌ Push unregister failed: \(httpResponse.statusCode) - \(body)")
                return false
            }
        } catch {
            print("❌ Push unregister error: \(error)")
            return false
        }
    }
    
    /// Convenience method using current settings
    func registerWithCurrentSettings(api: PowstonAPI) async -> Bool {
        guard let token = NotificationManager.shared.getDeviceToken() else {
            print("❌ Push registration: No device token")
            return false
        }
        
        guard let site = api.selectedSite else {
            print("❌ Push registration: No site selected")
            return false
        }
        
        // Need state, network, and tariff
        guard let state = site.state, !state.isEmpty,
              let network = site.network, !network.isEmpty,
              let tariff = site.tariff, !tariff.isEmpty else {
            print("❌ Push registration: Missing site info (state/network/tariff)")
            return false
        }
        
        // Export tariff - same as tariff in QLD, may differ elsewhere
        let exportTariff = site.exportTariff ?? tariff
        
        // Market costs - null means 2 (standard), higher for Amber
        let marketCosts = site.marketCosts
        
        // Get thresholds from UserDefaults
        let priceAlertsEnabled = UserDefaults.standard.bool(forKey: "price_alerts_enabled")
        guard priceAlertsEnabled else {
            return await unregister(deviceToken: token)
        }
        
        let sellAbove: Double? = UserDefaults.standard.bool(forKey: "sell_above_enabled")
            ? UserDefaults.standard.double(forKey: "sell_above_threshold") : nil
        let sellBelow: Double? = UserDefaults.standard.bool(forKey: "sell_below_enabled")
            ? UserDefaults.standard.double(forKey: "sell_below_threshold") : nil
        let buyAbove: Double? = UserDefaults.standard.bool(forKey: "buy_above_enabled")
            ? UserDefaults.standard.double(forKey: "buy_above_threshold") : nil
        let buyBelow: Double? = UserDefaults.standard.bool(forKey: "buy_below_enabled")
            ? UserDefaults.standard.double(forKey: "buy_below_threshold") : nil
        let spikeThreshold: Double? = UserDefaults.standard.bool(forKey: "spike_alerts_enabled")
            ? UserDefaults.standard.double(forKey: "spike_threshold") * 10  // ¢/kWh → $/MWh
            : nil
        
        let hasAnyThreshold = sellAbove != nil || sellBelow != nil || buyAbove != nil || buyBelow != nil || spikeThreshold != nil
        guard hasAnyThreshold else {
            return await unregister(deviceToken: token)
        }
        
        return await register(
            deviceToken: token,
            state: state,
            network: network,
            tariff: tariff,
            exportTariff: exportTariff,
            marketCosts: marketCosts,
            sellAbove: sellAbove,
            sellBelow: sellBelow,
            buyAbove: buyAbove,
            buyBelow: buyBelow,
            spikeThreshold: spikeThreshold
        )
    }
}
