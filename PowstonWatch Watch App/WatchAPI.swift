//
//  WatchAPI.swift
//  PowstonWatch
//

import Foundation
import SwiftUI
import WidgetKit
import Combine

@MainActor
class WatchAPI: ObservableObject {
    @Published var data: WatchData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var authState: WatchAuthState = .checking
    
    private let credentials = WatchCredentialManager.shared
    
    var debugInfo: String {
        """
        Auth: \(credentials.authSource.rawValue)
        Key: \(credentials.apiKey.isEmpty ? "empty" : "\(credentials.apiKey.prefix(8))...")
        Site: \(credentials.siteId) (\(credentials.siteName))
        Demo: \(credentials.isDemoMode)
        """
    }
    
    var isDemoMode: Bool {
        credentials.isDemoMode
    }
    
    var siteName: String {
        credentials.siteName
    }
    
    init() {
        updateAuthState()
    }
    
    private func updateAuthState() {
        if credentials.isDemoMode {
            authState = .demoMode
        } else if credentials.isConfigured {
            authState = .configured
        } else {
            authState = .notConfigured
        }
    }
    
    func fetchData() async {
        // Update auth state before fetching
        updateAuthState()
        
        // Demo mode
        if credentials.isDemoMode {
            data = Self.createDemoData()
            cacheForComplications(data!)
            reloadComplications()
            errorMessage = nil
            return
        }
        
        guard credentials.isConfigured else {
            errorMessage = nil
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let result = try await fetchAggregateData()
            data = result
            cacheForComplications(result)
            reloadComplications()
        } catch let error as APIError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    private func fetchAggregateData() async throws -> WatchData {
        let apiKey = credentials.apiKey
        let baseURL = credentials.baseURL
        let siteId = credentials.siteId
        
        // Fetch inverters for site
        let invertersURL = URL(string: "\(baseURL)/api/inverters/\(siteId)")!
        var invertersRequest = URLRequest(url: invertersURL)
        invertersRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        invertersRequest.timeoutInterval = 15
        
        let (invertersData, invertersResponse) = try await URLSession.shared.data(for: invertersRequest)
        
        guard let http = invertersResponse as? HTTPURLResponse else {
            throw APIError.noResponse
        }
        
        guard http.statusCode == 200 else {
            throw APIError.httpError(http.statusCode)
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        let inverters = try decoder.decode([WatchInverter].self, from: invertersData)
        
        guard !inverters.isEmpty else {
            throw APIError.noInverters
        }
        
        // Aggregate across all inverters
        var totalCapacity: Double = 0
        var weightedSoc: Double = 0
        var totalBatteryKw: Double = 0
        var latestBuyPrice: Double = 0
        var latestSellPrice: Double = 0
        var latestAction: String = "auto"
        
        for inverter in inverters {
            let paramsURL = URL(string: "\(baseURL)/api/inverter_params/\(inverter.id)")!
            var paramsRequest = URLRequest(url: paramsURL)
            paramsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            paramsRequest.timeoutInterval = 15
            
            guard let (paramsData, paramsResponse) = try? await URLSession.shared.data(for: paramsRequest),
                  let httpParams = paramsResponse as? HTTPURLResponse,
                  httpParams.statusCode == 200 else {
                continue
            }
            
            let params = try decoder.decode(WatchInverterParams.self, from: paramsData)
            
            let capacityKwh = (params.batteryCapacity ?? 10000) / 1000.0
            totalCapacity += capacityKwh
            
            let rawSoc = params.batterySoc ?? 0
            let socPercent = rawSoc > 1.0 ? rawSoc : rawSoc * 100.0
            weightedSoc += socPercent * capacityKwh
            
            let powerKw = (params.batteryPower ?? 0) / 1000.0
            totalBatteryKw += powerKw
            
            latestBuyPrice = params.buyPrice ?? latestBuyPrice
            latestSellPrice = params.sellPrice ?? latestSellPrice
            latestAction = params.currentAction
        }
        
        let aggregateSoc = totalCapacity > 0 ? weightedSoc / totalCapacity : 0
        let isCharging = totalBatteryKw < 0
        
        return WatchData(
            soc: aggregateSoc,
            batteryKw: abs(totalBatteryKw),
            isCharging: isCharging,
            action: latestAction,
            buyPrice: latestBuyPrice,
            sellPrice: latestSellPrice
        )
    }
    
    // MARK: - Complication Support
    
    private let watchAppGroup = "group.com.bollar.powston.watch"

    private func cacheForComplications(_ data: WatchData) {
        let complicationData = WatchComplicationData(
            soc: Int(data.soc.rounded()),
            batteryKw: data.batteryKw,
            isCharging: data.isCharging,
            buyPrice: data.buyPrice,
            sellPrice: data.sellPrice,
            action: data.action,
            timestamp: Date()
        )
        
        if let encoded = try? JSONEncoder().encode(complicationData),
           let sharedDefaults = UserDefaults(suiteName: watchAppGroup) {
            sharedDefaults.set(encoded, forKey: "cached_complication_data")
        }
    }
    
    private func reloadComplications() {
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    static func getCachedComplicationData() -> WatchComplicationData {
        guard let data = UserDefaults.standard.data(forKey: "cached_complication_data"),
              let decoded = try? JSONDecoder().decode(WatchComplicationData.self, from: data) else {
            return .placeholder
        }
        return decoded
    }
    
    // MARK: - Demo Data
    
    static func createDemoData() -> WatchData {
        WatchData(
            soc: 72,
            batteryKw: 3.2,
            isCharging: true,
            action: "charge",
            buyPrice: 12.5,
            sellPrice: 8.2
        )
    }
    
    // MARK: - Errors
    
    enum APIError: LocalizedError {
        case noResponse
        case httpError(Int)
        case noInverters
        
        var errorDescription: String? {
            switch self {
            case .noResponse: return "No response"
            case .httpError(let code): return "HTTP \(code)"
            case .noInverters: return "No inverters"
            }
        }
    }
}
