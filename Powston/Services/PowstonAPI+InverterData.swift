//
//  PowstonAPI+InverterData.swift
//  Powston
//
//  Inverter data fetching, demo mode, price alerts, watch integration
//

import Foundation
import SwiftUI

extension PowstonAPI {
    
    // MARK: - Fetch Inverter Data
    
    func fetchData() async {
        print("🔄 fetchData() called")
        if demoModeEnabled {
            await MainActor.run { loadDemoData() }
            return
        }
        
        guard selectedInverterId != 0 else {
            await MainActor.run { error = "No inverter selected" }
            return
        }
        
        await MainActor.run { isLoading = true; error = nil }
        
        let url = URL(string: "\(baseURL)/api/inverter_params/\(selectedInverterId)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse else {
                await MainActor.run { error = "Invalid response"; isLoading = false }
                return
            }
            
            if http.statusCode == 401 {
                await MainActor.run { error = "Unauthorized - check API key"; isLoading = false }
                return
            }
            
            if http.statusCode != 200 {
                await MainActor.run { error = "HTTP \(http.statusCode)"; isLoading = false }
                return
            }
            
            let decoded = try JSONDecoder().decode(InverterResponse.self, from: data)
            await MainActor.run {
                withTransaction(Transaction(animation: nil)) {
                    self.data = decoded
                    self.lastFetchTime = Date()
                    self.isLoading = false
                }
                self.updateStoredSiteTimezone()
                self.updateDetectedLeadInverter()
                self.cacheIdsForBackgroundSync()  // ← Add this line
                if let sellPrice = decoded.sellPrice, let buyPrice = decoded.buyPrice {
                    self.checkPriceAlert(sellPrice, buyPrice)
                }
                #if os(iOS)
                self.pushComplicationDataToWatch(decoded)
                #endif
            }
            
            await refreshActiveOverrides()

            // Trigger daily LV sync if needed (fire-and-forget, non-blocking)
            if let siteId = selectedSite?.id {
                let retailer = selectedSite?.activeRetailer
                Task.detached { [siteId, retailer] in
                    await LocalVoltsService.shared.performDailySyncIfNeeded(siteId: siteId, activeRetailer: retailer)
                }
            }

        } catch {
            await MainActor.run { self.error = error.localizedDescription; isLoading = false }
        }
    }
    
    // MARK: - Fetch Current User Code
    
    func fetchCurrentUserCode(inverterId: Int) async -> String? {
        guard !apiKey.isEmpty else { return nil }
        
        let urlString = "https://app.powston.com/api/current_user_code/\(inverterId)"
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            
            if let codeString = try? JSONDecoder().decode(String.self, from: data) {
                return codeString
            }
            
            return String(data: data, encoding: .utf8)
        } catch {
            print("Error fetching user code: \(error)")
            return nil
        }
    }
    
    // MARK: - Price Alert Check
    
    func checkPriceAlert(_ sellPrice: Double, _ buyPrice: Double) {
        guard UserDefaults.standard.bool(forKey: "price_alerts_enabled") else { return }
        
        if UserDefaults.standard.bool(forKey: "sell_above_enabled") {
            let threshold = UserDefaults.standard.double(forKey: "sell_above_threshold")
            if threshold > 0 && sellPrice >= threshold {
                NotificationManager.shared.sendAlert(
                    type: "sell_above", title: "🚀 High Sell Price Alert!",
                    price: sellPrice, threshold: threshold, priceType: "Sell"
                )
            }
        }
        
        if UserDefaults.standard.bool(forKey: "sell_below_enabled") {
            let threshold = UserDefaults.standard.double(forKey: "sell_below_threshold")
            if threshold > 0 && sellPrice <= threshold {
                NotificationManager.shared.sendAlert(
                    type: "sell_below", title: "⚠️ Low Sell Price Alert",
                    price: sellPrice, threshold: threshold, priceType: "Sell"
                )
            }
        }
        
        if UserDefaults.standard.bool(forKey: "buy_below_enabled") {
            let threshold = UserDefaults.standard.double(forKey: "buy_below_threshold")
            if threshold > 0 && buyPrice <= threshold {
                NotificationManager.shared.sendAlert(
                    type: "buy_below", title: "💰 Low Buy Price Alert!",
                    price: buyPrice, threshold: threshold, priceType: "Buy"
                )
            }
        }
        
        if UserDefaults.standard.bool(forKey: "buy_above_enabled") {
            let threshold = UserDefaults.standard.double(forKey: "buy_above_threshold")
            if threshold > 0 && buyPrice >= threshold {
                NotificationManager.shared.sendAlert(
                    type: "buy_above", title: "⚠️ High Buy Price Alert",
                    price: buyPrice, threshold: threshold, priceType: "Buy"
                )
            }
        }
    }
    
    // MARK: - Watch Complication Push
    
    #if os(iOS)
    internal func pushComplicationDataToWatch(_ data: InverterResponse) {
        let soc = Int((data.batterySoc ?? 0).rounded())
        let batteryKw = abs((data.batteryPower ?? 0) / 1000.0)
        let isCharging = (data.batteryPower ?? 0) < 0
        let buyPrice = data.buyPrice ?? 0
        let sellPrice = data.sellPrice ?? 0
        let action = data.lastAction ?? data.action ?? "auto"
        
        WatchConnectivityManager.shared.pushComplicationUpdate(
            soc: soc,
            batteryKw: batteryKw,
            isCharging: isCharging,
            buyPrice: buyPrice,
            sellPrice: sellPrice,
            action: action
        )
    }
    #endif
    
    // MARK: - Demo Data
    
    static func createDemoSite() -> Site {
        let seQldLocations: [(lat: Double, lng: Double, name: String, postcode: String)] = [
            (-27.4698, 153.0251, "Brisbane CBD", "4000"),
            (-27.9424, 153.3971, "Gold Coast", "4217"),
            (-26.6500, 153.0667, "Sunshine Coast", "4558"),
            (-27.5598, 151.9507, "Toowoomba", "4350"),
            (-27.6144, 152.7609, "Ipswich", "4305"),
            (-27.2424, 152.9854, "Caboolture", "4510"),
            (-27.8951, 153.2830, "Southport", "4215"),
            (-26.4004, 153.0667, "Noosa", "4567"),
            (-27.0344, 153.0690, "Bribie Island", "4507"),
            (-27.5263, 153.0848, "Wynnum", "4178"),
        ]
        let location = seQldLocations.randomElement()!
        
        return Site(
            id: 1,
            name: "demo_site",
            displayName: "Demo Home",
            state: "QLD",
            network: "energex",
            installedSolar: 29920,
            installedBattery: 101880,
            windPower: nil,
            hydroPower: nil,
            primaryInverterId: 1,
            latitude: location.lat,
            longitude: location.lng,
            location: "\(location.name), QLD \(location.postcode)",
            postcode: location.postcode,
            timezone: "Australia/Brisbane",
            brand: "SUNGROW",
            nmi: "3012345678",
            tariff: "6950",
            exportTariff: "9850",
            gridPowerLimit: 9600,
            inverterPower: 20000,
            minSoc: 50,
            controlled: true,
            isCommercial: false,
            readOnly: false,
            haPublish: true,
            mqttUser: "demo",
            mqttPassword: nil,
            pvoutputSiteId: nil,
            pvoutputApiKey: nil,
            vendorId: "12345",
            installerId: 1,
            amberKey: nil,
            amberSiteId: nil,
            localvoltsKey: "demo_key",
            localvoltsPartnerId: nil,
            activeRetailer: "localvolts",
            marketCosts: nil
        )
    }
    
    static func createDemoInverter() -> Inverter {
        Inverter(
            id: 1,
            serialNumber: "DEMO123456",
            manufacturer: "SUNGROW",
            productName: "SH10RT",
            batteryCapacity: 101880,
            siteId: 1,
            siteName: "Demo Home",
            pvCapacity: 29920,
            phases: 1,
            bdcRatedPower: 10000,
            batteryPower: 10000,
            maxDischarging: 10000,
            maxCharging: 10000
        )
    }
    
    static func createDemoData() -> InverterResponse {
        let buyForecast: [Double] = [
            12.5, 11.8, 11.2, 10.9, 10.5, 10.3,
            10.8, 11.5, 13.2, 15.8, 18.5, 20.3,
            22.1, 21.8, 19.5, 17.2, 16.8, 16.5,
            17.2, 18.5, 19.8, 21.2, 22.5, 23.8,
            25.2, 24.8, 23.5, 22.1, 21.8, 22.5,
            28.5, 32.8, 38.5, 42.3, 45.8, 43.2,
            39.5, 35.2, 28.5, 22.8, 19.5, 17.2,
            15.8, 14.5, 13.8, 13.2, 12.8, 12.5
        ]
        
        let sellForecast: [Double] = [
            8.2, 7.5, 6.9, 6.6, 6.2, 6.0,
            6.5, 7.2, 8.9, 11.5, 14.2, 16.0,
            17.8, 17.5, 15.2, 12.9, 12.5, 12.2,
            12.9, 14.2, 15.5, 16.9, 18.2, 19.5,
            20.9, 20.5, 19.2, 17.8, 17.5, 18.2,
            24.2, 28.5, 34.2, 38.0, 41.5, 38.9,
            35.2, 30.9, 24.2, 18.5, 15.2, 12.9,
            11.5, 10.2, 9.5, 8.9, 8.5, 8.2
        ]
        
        let actionPattern = [
            "hold", "hold", "hold", "hold", "hold", "hold",
            "charge", "charge", "hold", "export", "export", "export",
            "export", "export", "hold", "hold", "charge", "charge",
            "export", "export", "export", "hold", "hold", "hold"
        ]
        
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: Date())
        let currentPeriod = min(hour * 2, buyForecast.count - 1)
        
        let startOfDay = calendar.startOfDay(for: Date())
        let sunriseTime = calendar.date(byAdding: .hour, value: 5, to: startOfDay)!
            .addingTimeInterval(30 * 60)
        let sunsetTime = calendar.date(byAdding: .hour, value: 18, to: startOfDay)!
            .addingTimeInterval(45 * 60)
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        
        return InverterResponse(
            batterySocRaw: 75.5,
            batteryPower: -3200,
            action: "export",
            lastAction: "export",
            solarPower: 8500,
            gridPower: 3200,
            housePower: 2100,
            buyPrice: buyForecast[currentPeriod],
            sellPrice: sellForecast[currentPeriod],
            rrp: 85.50,
            reason: "DEMO MODE: High sell price detected. Exporting excess solar to grid for maximum return.",
            userCodeName: "demo_optimizer_v1",
            actionPattern: actionPattern,
            currentHour: hour,
            buyForecast: buyForecast,
            sellForecast: sellForecast,
            sunrise: formatter.string(from: sunriseTime),
            sunset: formatter.string(from: sunsetTime),
            intervalTime: formatter.string(from: startOfDay)
        )
    }
    
    func loadDemoData() {
        isDemoMode = true
        sites = [Self.createDemoSite()]
        inverters = [Self.createDemoInverter()]
        selectedInverterId = 1
        data = Self.createDemoData()
        lastFetchTime = Date()
        error = nil
        controllerHealthStatus = .healthy
    }
    
    func clearDemoData() {
        isDemoMode = false
        sites = []
        inverters = []
        data = nil
        selectedInverterId = 0
        controllerHealthStatus = .unknown
    }
    
    // MARK: - Background Sync Cache

    /// Cache site and inverter IDs for background sync (used by AppDelegate)
    func cacheIdsForBackgroundSync() {
        guard let siteId = selectedSiteId, siteId > 0 else { return }
        
        let inverterIds = inverters.filter { $0.siteId == siteId }.map { $0.id }
        guard !inverterIds.isEmpty else { return }
        
        UserDefaults.standard.set(siteId, forKey: "selected_site_id")
        if let data = try? JSONEncoder().encode(inverterIds) {
            UserDefaults.standard.set(data, forKey: "site_\(siteId)_inverter_ids")
        }
        print("📦 Cached IDs for background sync: site \(siteId), inverters \(inverterIds)")
    }
}
