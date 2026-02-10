//
//  TVAPI.swift
//  PowstonTV
//
//  API client for tvOS app - uses iCloud for credentials with manual fallback
//

import Foundation
import SwiftUI
import Combine

// MARK: - Data Models

/// Data model for TV display
struct TVData {
    let soc: Double
    let batteryKw: Double
    let isCharging: Bool
    let action: String
    let buyPrice: Double
    let sellPrice: Double
    let gridKw: Double
    let solarKw: Double
    let loadKw: Double
    let inverterCount: Int
    
    // Forecast data
    let buyForecast: [Double]?
    let sellForecast: [Double]?
    let forecastStart: Date?
    
    // Timestamp for change detection
    let intervalTime: String?
    
    // Scorecard summary (computed separately)
    var scorecard: TVScorecardSummary?
}

/// Lightweight scorecard summary for TV display
struct TVScorecardSummary {
    let grade: String
    let score: Double
    let netPosition: Double      // $ (negative = profit)
    let periodLabel: String      // "Yesterday"
    let componentGrades: [String: String]  // name -> grade
}

/// Leaderboard entry for TV
struct TVLeaderboardEntry: Codable, Identifiable {
    var id: Int { odometer }
    
    let odometer: Int
    let siteName: String?
    let billCost: Double?
    let netBenefit: Double?
    let efficiency: Double?
    let batteryCapacity: Double?
    
    enum CodingKeys: String, CodingKey {
        case odometer
        case siteName = "site_name"
        case billCost = "bill_cost"
        case netBenefit = "net_benefit"
        case efficiency
        case batteryCapacity = "battery_capacity"
    }
}

/// Leaderboard response
struct TVLeaderboardResponse: Codable {
    let entries: [TVLeaderboardEntry]
    let userRank: Int?
    let userEntry: TVLeaderboardEntry?
    
    enum CodingKeys: String, CodingKey {
        case entries
        case userRank = "user_rank"
        case userEntry = "user_entry"
    }
}

/// Tracks where credentials came from
enum CredentialSource: String {
    case none
    case iCloud
    case manual
}

// MARK: - TVAPI

@MainActor
class TVAPI: ObservableObject {
    @Published var data: TVData?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var authState: AuthState = .checking
    @Published var siteName: String = "My Site"
    @Published var credentialSource: CredentialSource = .none
    
    // Leaderboard data
    @Published var leaderboard: TVLeaderboardResponse?
    
    private var apiKey = ""
    private var baseURL = "https://app.powston.com"
    private var siteId = 0
    private var inverterId = 0
    
    // Cached meter records for scorecard
    private var cachedMeterRecords: [MeterRecord] = []
    private var meterRecordsFetchDate: Date?
    
    // Cached scorecard
    private var cachedScorecard: TVScorecardSummary?
    private var scorecardComputeDate: Date?
    
    // Site metadata for scorecard calculation and weather
    private var siteTimezone: TimeZone = TimeZone(identifier: "Australia/Brisbane")!
    private var batteryCapacityKWh: Double = 100.0
    private var inverterCapacityWatts: Double = 20000.0
    
    // Site location for weather (public for WeatherService access)
    var siteLatitude: Double = -26.65  // Default to Sunshine Coast
    var siteLongitude: Double = 153.06
    
    // Local storage keys for manual credentials
    private enum LocalKeys {
        static let apiKey = "powston_local_api_key"
        static let baseURL = "powston_local_base_url"
        static let siteId = "powston_local_site_id"
        static let inverterId = "powston_local_inverter_id"
        static let siteName = "powston_local_site_name"
    }
    
    enum AuthState: Equatable {
        case checking
        case notAuthenticated
        case authenticated
    }
    
    init() {
        // Start observing iCloud changes
        CloudCredentialSync.shared.observeChanges { [weak self] credentials in
            Task { @MainActor in
                await self?.handleCredentialChange(credentials)
            }
        }
    }
    
    // MARK: - Credential Management
    
    /// Load credentials from iCloud first, then fall back to local storage
    func loadCredentialsAndFetch() async {
        authState = .checking
        
        // Force sync from iCloud
        NSUbiquitousKeyValueStore.default.synchronize()
        
        // Try iCloud first
        if let creds = CloudCredentialSync.shared.getCredentials() {
            apiKey = creds.apiKey
            baseURL = creds.baseURL
            siteId = creds.siteId
            inverterId = creds.inverterId
            siteName = creds.siteName
            credentialSource = .iCloud
            
            print("📺 Loaded credentials from iCloud (site: \(siteName), id: \(siteId))")
            authState = .authenticated
            
            await fetchData()
            return
        }
        
        // Fall back to local storage
        if let localApiKey = UserDefaults.standard.string(forKey: LocalKeys.apiKey),
           !localApiKey.isEmpty {
            apiKey = localApiKey
            baseURL = UserDefaults.standard.string(forKey: LocalKeys.baseURL) ?? "https://app.powston.com"
            siteId = UserDefaults.standard.integer(forKey: LocalKeys.siteId)
            inverterId = UserDefaults.standard.integer(forKey: LocalKeys.inverterId)
            siteName = UserDefaults.standard.string(forKey: LocalKeys.siteName) ?? "My Site"
            credentialSource = .manual
            
            print("📺 Loaded credentials from local storage (site: \(siteName), id: \(siteId))")
            authState = .authenticated
            
            await fetchData()
            return
        }
        
        print("📺 No credentials found in iCloud or local storage")
        authState = .notAuthenticated
    }
    
    /// Handle credential changes from iCloud observer
    private func handleCredentialChange(_ credentials: CloudCredentialSync.CloudCredentials?) async {
        if let creds = credentials {
            apiKey = creds.apiKey
            baseURL = creds.baseURL
            siteId = creds.siteId
            inverterId = creds.inverterId
            siteName = creds.siteName
            credentialSource = .iCloud
            authState = .authenticated
            
            // Clear cached data for new site
            cachedMeterRecords = []
            meterRecordsFetchDate = nil
            cachedScorecard = nil
            scorecardComputeDate = nil
            
            print("📺 Credentials updated from iCloud (site: \(siteName))")
            await fetchData()
        } else if credentialSource == .iCloud {
            // Only clear if we were using iCloud credentials
            // Keep manual credentials intact
            authState = .notAuthenticated
            data = nil
            credentialSource = .none
            print("📺 iCloud credentials cleared")
        }
    }
    
    // MARK: - Manual Credential Entry
    
    /// Set credentials manually (validates and discovers site info)
    /// Returns nil on success, or error message on failure
    func setManualCredentials(apiKey: String) async -> String? {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !trimmedKey.isEmpty else {
            return "API key cannot be empty"
        }
        
        // Validate key by fetching sites
        do {
            let siteInfo = try await discoverSite(apiKey: trimmedKey)
            
            // Save to local storage
            UserDefaults.standard.set(trimmedKey, forKey: LocalKeys.apiKey)
            UserDefaults.standard.set(baseURL, forKey: LocalKeys.baseURL)
            UserDefaults.standard.set(siteInfo.siteId, forKey: LocalKeys.siteId)
            UserDefaults.standard.set(siteInfo.inverterId, forKey: LocalKeys.inverterId)
            UserDefaults.standard.set(siteInfo.siteName, forKey: LocalKeys.siteName)
            
            // Apply credentials
            self.apiKey = trimmedKey
            self.siteId = siteInfo.siteId
            self.inverterId = siteInfo.inverterId
            self.siteName = siteInfo.siteName
            self.credentialSource = .manual
            self.authState = .authenticated
            
            print("📺 Manual credentials saved (site: \(siteName), id: \(siteId))")
            
            await fetchData()
            return nil // Success
            
        } catch {
            print("📺 Manual credential validation failed: \(error)")
            return error.localizedDescription
        }
    }
    
    /// Discover site info from API key
    private func discoverSite(apiKey: String) async throws -> (siteId: Int, inverterId: Int, siteName: String) {
        // Fetch sites for this API key
        let sitesURL = URL(string: "\(baseURL)/api/sites")!
        var request = URLRequest(url: sitesURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let http = response as? HTTPURLResponse else {
            throw ManualEntryError.invalidResponse
        }
        
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw ManualEntryError.invalidApiKey
        default:
            throw ManualEntryError.serverError(http.statusCode)
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        let sites = try decoder.decode([TVSite].self, from: data)
        
        guard let site = sites.first else {
            throw ManualEntryError.noSitesFound
        }
        
        // Store site metadata
        if let tzString = site.timezone, let tz = TimeZone(identifier: tzString) {
            self.siteTimezone = tz
        }
        if let batteryWh = site.installedBattery {
            self.batteryCapacityKWh = Double(batteryWh) / 1000.0
        }
        if let inverterW = site.inverterPower {
            self.inverterCapacityWatts = Double(inverterW)
        }
        if let lat = site.latitude {
            self.siteLatitude = lat
        }
        if let lon = site.longitude {
            self.siteLongitude = lon
        }
        
        // Fetch inverters for this site
        let invertersURL = URL(string: "\(baseURL)/api/inverters/\(site.id)")!
        var invertersRequest = URLRequest(url: invertersURL)
        invertersRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let (invertersData, invertersResponse) = try await URLSession.shared.data(for: invertersRequest)
        
        guard let httpInverters = invertersResponse as? HTTPURLResponse, httpInverters.statusCode == 200 else {
            throw ManualEntryError.noInvertersFound
        }
        
        let inverters = try decoder.decode([TVInverter].self, from: invertersData)
        
        guard let inverter = inverters.first else {
            throw ManualEntryError.noInvertersFound
        }
        
        return (siteId: site.id, inverterId: inverter.id, siteName: site.name ?? "My Site")
    }
    
    /// Clear manually stored credentials
    func clearManualCredentials() {
        UserDefaults.standard.removeObject(forKey: LocalKeys.apiKey)
        UserDefaults.standard.removeObject(forKey: LocalKeys.baseURL)
        UserDefaults.standard.removeObject(forKey: LocalKeys.siteId)
        UserDefaults.standard.removeObject(forKey: LocalKeys.inverterId)
        UserDefaults.standard.removeObject(forKey: LocalKeys.siteName)
        
        if credentialSource == .manual {
            authState = .notAuthenticated
            data = nil
            credentialSource = .none
        }
        
        print("📺 Manual credentials cleared")
    }
    
    // MARK: - Data Fetching
    
    func fetchData() async {
        guard !apiKey.isEmpty, siteId > 0 else {
            errorMessage = "Not configured"
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let tvData = try await fetchAggregateData()
            
            // Attach cached scorecard if available and fresh
            var dataWithScorecard = tvData
            if let cached = cachedScorecard,
               let computeDate = scorecardComputeDate,
               Calendar.current.isDateInToday(computeDate) {
                dataWithScorecard.scorecard = cached
            }
            
            data = dataWithScorecard
        } catch {
            errorMessage = error.localizedDescription
            print("📺 Fetch error: \(error)")
        }
        
        isLoading = false
    }
    
    private func fetchAggregateData() async throws -> TVData {
        // Fetch inverters for this site
        let invertersURL = URL(string: "\(baseURL)/api/inverters/\(siteId)")!
        var invertersRequest = URLRequest(url: invertersURL)
        invertersRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let (invertersData, invertersResponse) = try await URLSession.shared.data(for: invertersRequest)
        
        guard let http = invertersResponse as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.requestFailed
        }
        
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        
        let inverters = try decoder.decode([TVInverter].self, from: invertersData)
        
        print("📺 Found \(inverters.count) inverters for site \(siteId): \(inverters.map { $0.id })")
        
        guard !inverters.isEmpty else {
            throw APIError.noInverters
        }
        
        // Aggregate across all inverters
        var totalCapacity: Double = 0
        var weightedSoc: Double = 0
        var totalBatteryKw: Double = 0
        var totalGridKw: Double = 0
        var totalSolarKw: Double = 0
        var totalLoadKw: Double = 0
        var latestBuyPrice: Double = 0
        var latestSellPrice: Double = 0
        var latestAction: String = "auto"
        
        // Forecast data (from first inverter that has it)
        var buyForecast: [Double]?
        var sellForecast: [Double]?
        var forecastStart: Date?
        var latestIntervalTime: String?
        
        for inverter in inverters {
            let paramsURL = URL(string: "\(baseURL)/api/inverter_params/\(inverter.id)")!
            var paramsRequest = URLRequest(url: paramsURL)
            paramsRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            
            let (paramsData, paramsResponse) = try await URLSession.shared.data(for: paramsRequest)
            
            guard let httpParams = paramsResponse as? HTTPURLResponse, httpParams.statusCode == 200 else {
                print("📺 Inverter \(inverter.id): FAILED to fetch params")
                continue // Skip failed inverters
            }
            
            let params = try decoder.decode(TVInverterParams.self, from: paramsData)
            
            // Capture site name from first inverter
            if let name = params.siteName, self.siteName == "My Site" {
                self.siteName = name
            }
            
            // Debug: show raw values
            print("📺 Inverter \(inverter.id): soc=\(params.batterySoc ?? 0), batteryW=\(params.batteryPower ?? 0), solarW=\(params.solarPower ?? 0), gridW=\(params.gridPower ?? 0), houseW=\(params.housePower ?? 0)")
            
            // Capacity in Wh → kWh
            let capacityKwh = (params.batteryCapacity ?? 10000) / 1000.0
            totalCapacity += capacityKwh
            
            // SOC normalization (0-1 or 0-100)
            let rawSoc = params.batterySoc ?? 0
            let socPercent = rawSoc > 1.0 ? rawSoc : rawSoc * 100.0
            weightedSoc += socPercent * capacityKwh
            
            // Power values (W → kW)
            totalBatteryKw += (params.batteryPower ?? 0) / 1000.0
            totalGridKw += (params.gridPower ?? 0) / 1000.0
            totalSolarKw += (params.solarPower ?? 0) / 1000.0
            totalLoadKw += (params.housePower ?? 0) / 1000.0
            
            // Prices (cents)
            latestBuyPrice = params.buyPrice ?? latestBuyPrice
            latestSellPrice = params.sellPrice ?? latestSellPrice
            latestAction = params.currentAction
            
            // Capture interval time for change detection
            if latestIntervalTime == nil, let interval = params.intervalTime {
                latestIntervalTime = interval
            }
            
            // Capture forecast from first inverter that has it
            if buyForecast == nil, let forecast = params.buyForecast, !forecast.isEmpty {
                buyForecast = forecast
                sellForecast = params.sellForecast
                forecastStart = params.forecastStartDate
                print("📺 Forecast: \(forecast.count) periods starting \(forecastStart?.description ?? "unknown")")
            }
        }
        
        // Update battery capacity from actual data
        if totalCapacity > 0 {
            batteryCapacityKWh = totalCapacity
        }
        
        print("📺 Totals: capacity=\(totalCapacity)kWh, soc=\(totalCapacity > 0 ? weightedSoc/totalCapacity : 0)%, battery=\(totalBatteryKw)kW, solar=\(totalSolarKw)kW, grid=\(totalGridKw)kW, load=\(totalLoadKw)kW")
        
        let aggregateSoc = totalCapacity > 0 ? weightedSoc / totalCapacity : 0
        let isCharging = totalBatteryKw < 0  // Negative = charging
        
        return TVData(
            soc: aggregateSoc,
            batteryKw: abs(totalBatteryKw),
            isCharging: isCharging,
            action: latestAction,
            buyPrice: latestBuyPrice,
            sellPrice: latestSellPrice,
            gridKw: totalGridKw,
            solarKw: totalSolarKw,
            loadKw: totalLoadKw,
            inverterCount: inverters.count,
            buyForecast: buyForecast,
            sellForecast: sellForecast,
            forecastStart: forecastStart,
            intervalTime: latestIntervalTime,
            scorecard: nil
        )
    }
    
    // MARK: - Meter Records (for Scorecard)
    
    /// Fetch meter records for the most recent complete day (used for scorecard calculation)
    /// Falls back to day-before-yesterday if yesterday has insufficient data
    func fetchMeterRecords() async throws -> [MeterRecord] {
        // Return cached if fresh (within 5 minutes)
        if let fetchDate = meterRecordsFetchDate,
           Date().timeIntervalSince(fetchDate) < 300,
           !cachedMeterRecords.isEmpty {
            return cachedMeterRecords
        }

        var calendar = Calendar.current
        calendar.timeZone = siteTimezone

        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let dayBeforeYesterday = calendar.date(byAdding: .day, value: -2, to: today)!

        // Try yesterday first
        var records = try await fetchMeterRecordsForDate(yesterday)

        // If yesterday has insufficient data (< 280 records for a complete day), try day before
        if records.count < 280 {
            print("📺 Yesterday has only \(records.count) records, trying day before")
            records = try await fetchMeterRecordsForDate(dayBeforeYesterday)
        }

        cachedMeterRecords = records
        meterRecordsFetchDate = Date()

        return records
    }

    /// Fetch meter records for a specific date
    private func fetchMeterRecordsForDate(_ date: Date) async throws -> [MeterRecord] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = siteTimezone

        let dateStr = dateFormatter.string(from: date)

        let urlString = "\(baseURL)/api/meter_records/\(siteId)?from=\(dateStr)&to=\(dateStr)"
        guard let url = URL(string: urlString) else {
            throw APIError.requestFailed
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.requestFailed
        }

        let decoded = try JSONDecoder().decode(MeterRecordsResponse.self, from: data)

        print("📺 Fetched \(decoded.records.count) meter records for \(dateStr)")

        return decoded.records
    }
    
 
    /// Get top performer's efficiency from leaderboard (for cohort benchmark)
    func getTopEfficiency() -> Double? {
        guard let entries = leaderboard?.entries, !entries.isEmpty else {
            return nil
        }
        
        // Find entry with best efficiency (most negative = most profit per kWh)
        let sorted = entries.compactMap { $0.efficiency }.sorted()
        return sorted.first
    }
    
    // MARK: - Scorecard Computation
    
    /// Compute yesterday's scorecard using shared ScorecardCalculator
    func computeScorecard() async -> TVScorecardSummary? {
        // Return cached if computed today
        if let cached = cachedScorecard,
           let computeDate = scorecardComputeDate,
           Calendar.current.isDateInToday(computeDate) {
            return cached
        }
        
        do {
            // Fetch meter records
            let records = try await fetchMeterRecords()
            
            guard !records.isEmpty else {
                print("📺 No meter records for scorecard")
                return nil
            }
            
            // Get cohort benchmark from iCloud (synced by iOS)
            let cohortEfficiency: Double?
            NSUbiquitousKeyValueStore.default.synchronize()
            let storedEfficiency = NSUbiquitousKeyValueStore.default.double(forKey: "leaderboard_top_efficiency_yesterday")
            if storedEfficiency != 0 {
                cohortEfficiency = storedEfficiency
                print("📺 Cohort benchmark from iCloud: \(storedEfficiency)¢/kWh")
            } else {
                cohortEfficiency = nil
                print("📺 No cohort benchmark in iCloud, using theoretical")
            }

            // Derive date range from actual records (may be yesterday or day-before)
            var calendar = Calendar.current
            calendar.timeZone = siteTimezone

            // Get the date from the first record
            let recordDates = records.compactMap { $0.date }
            guard let minDate = recordDates.min() else {
                print("📺 No valid dates in meter records")
                return nil
            }

            let dataDay = calendar.startOfDay(for: minDate)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: dataDay) ?? dataDay

            // Create calculator with site parameters
            let calculator = ScorecardCalculator(
                timezone: siteTimezone,
                peakStartHour: 16,  // Default peak hours
                peakEndHour: 21,
                inverterCapacityWatts: inverterCapacityWatts,
                cohortBestEfficiency: cohortEfficiency,
                batteryCapacityKWh: batteryCapacityKWh
            )

            // Compute scorecard using the actual data day
            let scorecard = calculator.calculate(
                records: records,
                siteId: siteId,
                from: dataDay,
                to: nextDay
            )
            
            // Build summary for TV
            var componentGrades: [String: String] = [:]
            for component in scorecard.components {
                componentGrades[component.name] = component.grade
            }
            
            let summary = TVScorecardSummary(
                grade: scorecard.overallGrade,
                score: scorecard.overallScore,
                netPosition: scorecard.netPosition,
                periodLabel: "Yesterday",
                componentGrades: componentGrades
            )
            
            print("📺 Scorecard computed: \(summary.grade) (\(summary.score)) net: $\(summary.netPosition)")
            
            // Cache it
            cachedScorecard = summary
            scorecardComputeDate = Date()
            
            // Update data with scorecard
            if var currentData = data {
                currentData.scorecard = summary
                data = currentData
            }
            print("📺 Scorecard: totalCost=\(scorecard.totalCost), earnings=\(scorecard.earnings), net=\(scorecard.netPosition)")
            print("📺 Records fetched: \(records.count)")
            return summary
                        
        } catch {
            print("📺 Scorecard computation failed: \(error)")
            return nil
        }
        
    }
    
    // MARK: - Errors
    
    enum APIError: LocalizedError {
        case requestFailed
        case noInverters
        
        var errorDescription: String? {
            switch self {
            case .requestFailed: return "Request failed"
            case .noInverters: return "No inverters found"
            }
        }
    }
    
    enum ManualEntryError: LocalizedError {
        case invalidApiKey
        case invalidResponse
        case serverError(Int)
        case noSitesFound
        case noInvertersFound
        
        var errorDescription: String? {
            switch self {
            case .invalidApiKey: return "Invalid API key"
            case .invalidResponse: return "Invalid server response"
            case .serverError(let code): return "Server error (\(code))"
            case .noSitesFound: return "No sites found for this API key"
            case .noInvertersFound: return "No inverters found"
            }
        }
    }
}

// MARK: - Response Models

struct TVInverterParams: Codable {
    let batterySoc: Double?
    let batteryPower: Double?
    let batteryCapacity: Double?
    let gridPower: Double?
    let solarPower: Double?
    let housePower: Double?
    let action: String?
    let lastAction: String?
    let buyPrice: Double?
    let sellPrice: Double?
    let siteName: String?
    
    // Forecast data
    let buyForecast: [Double]?
    let sellForecast: [Double]?
    let intervalTime: String?
    
    var currentAction: String {
        lastAction ?? action ?? "auto"
    }
    
    /// Parse forecast start time from intervalTime
    var forecastStartDate: Date? {
        guard let intervalTime = intervalTime else { return nil }
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: intervalTime) {
            return date
        }
        
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: intervalTime)
    }
}

struct TVInverter: Codable {
    let id: Int
}

struct TVSite: Codable {
    let id: Int
    let name: String?
    let timezone: String?
    let installedBattery: Int?
    let inverterPower: Int?
    let latitude: Double?
    let longitude: Double?
    
    enum CodingKeys: String, CodingKey {
        case id
        case name
        case timezone
        case installedBattery = "installed_battery"
        case inverterPower = "inverter_power"
        case latitude
        case longitude
    }
}

// MARK: - RefreshableAPI Conformance

extension TVAPI: RefreshableAPI {
    var currentIntervalTime: String? {
        return data?.intervalTime
    }
    
    var isReadyToPoll: Bool {
        return authState == .authenticated
    }
}
