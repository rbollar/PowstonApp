//
//  LeaderboardCard.swift
//  Powston
//
//  Leaderboard card for dashboard showing site ranking among all Powston sites
//

import SwiftUI
import Combine

// MARK: - Data Models

struct RatesSite: Identifiable, Equatable {
    let siteId: Int
    let state: String
    let tariff: String
    let network: String
    let brand: String
    let inverterPower: Int
    let installedSolar: Int
    let installedBattery: Int
    let totalCosts: Double
    let totalEarnings: Double
    let buyRate: Double
    let sellRate: Double
    let expectedBill: Double
    let dailyCosts: Double
    let totalEnergyImported: Double
    let totalEnergyExported: Double
    let startTime: Date
    let endTime: Date
    
    var id: Int { siteId }
    
    func netBenefit(comparisonBuyRate: Double, comparisonSellRate: Double) -> Double {
        let currentCost = totalEarnings - totalCosts
        let comparisonCost = (totalEnergyExported * comparisonSellRate) - (totalEnergyImported * comparisonBuyRate)
        return currentCost - comparisonCost
    }
    
    var formattedBill: String {
        let dollars = expectedBill / 100
        let absDollars = abs(dollars)
        let absCents = abs(expectedBill)
        if absDollars >= 1 {
            return String(format: "$%.2f", absDollars)
        } else {
            return String(format: "%.1f¢", absCents)
        }
    }
    
    var isCredit: Bool { expectedBill < 0 }
    
    func formattedNetBenefit(comparisonBuyRate: Double, comparisonSellRate: Double) -> String {
        let benefit = netBenefit(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate)
        let dollars = benefit / 100
        if abs(dollars) >= 1 {
            return String(format: "$%.2f", dollars)
        } else {
            return String(format: "%.1f¢", benefit)
        }
    }
    
    var batteryKWh: Double { Double(installedBattery) / 1000.0 }
    
    func efficiency(comparisonBuyRate: Double, comparisonSellRate: Double) -> Double? {
        guard batteryKWh >= 5.0 else { return nil }
        let benefit = netBenefit(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate)
        return benefit / batteryKWh
    }
    
    func formattedEfficiency(comparisonBuyRate: Double, comparisonSellRate: Double) -> String {
        guard let eff = efficiency(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate) else { return "–" }
        let dollars = eff / 100
        if abs(dollars) >= 1 {
            return String(format: "$%.2f", dollars)
        } else {
            return String(format: "%.1f¢", eff)
        }
    }
}

// MARK: - Ranking Mode
enum LeaderboardRankingMode: String, CaseIterable {
    case bill = "bill"
    case netBenefit = "netBenefit"
    case efficiency = "efficiency"
    
    var displayName: String {
        switch self {
        case .bill: return "Bill"
        case .netBenefit: return "Net Benefit"
        case .efficiency: return "Efficiency"
        }
    }
}

// MARK: - Leaderboard Period
enum LeaderboardPeriod: String, CaseIterable {
    case yesterday = "yesterday"
    case dayBefore = "dayBefore"
    case week = "week"
    case month = "month"
    
    var displayName: String {
        switch self {
        case .yesterday: return "Yesterday"
        case .dayBefore: return "Day Before"
        case .week: return "7 Days"
        case .month: return "30 Days"
        }
    }
    
    var days: Int {
        switch self {
        case .yesterday: return 1
        case .dayBefore: return 1
        case .week: return 7
        case .month: return 30
        }
    }
    
    var daysAgo: Int {
        switch self {
        case .yesterday: return 1
        case .dayBefore: return 2
        case .week: return 1
        case .month: return 1
        }
    }
}

// MARK: - Leaderboard State

@MainActor
class LeaderboardState: ObservableObject {
    static let shared = LeaderboardState()
    
    @Published var sites: [RatesSite] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var dataDate: Date?
    @Published var hasData = false
    @Published var currentPeriod: LeaderboardPeriod = .yesterday
    @Published var isServerFiltered = false
    @Published var currentTolerance: Int = 20
    @Published var batteryRangeMinKWh: Int?
    @Published var batteryRangeMaxKWh: Int?
    @Published var loadingStatus: String?
    @Published var myPercentile: Int?
    @Published var isUsingFallbackData = false
    
    // MARK: - Pinned Sites
    @AppStorage("pinned_site_ids") private var pinnedSiteIdsStorage: String = ""
    
    var pinnedSiteIds: Set<Int> {
        get {
            Set(pinnedSiteIdsStorage.split(separator: ",").compactMap { Int($0) })
        }
    }
    
    func isPinned(_ siteId: Int) -> Bool {
        pinnedSiteIds.contains(siteId)
    }
    
    func canAddMorePins() -> Bool {
        pinnedSiteIds.count < 3
    }
    
    func togglePin(_ siteId: Int) {
        var current = pinnedSiteIds
        if current.contains(siteId) {
            current.remove(siteId)
        } else if current.count < 3 {
            current.insert(siteId)
        }
        pinnedSiteIdsStorage = current.map { String($0) }.joined(separator: ",")
        objectWillChange.send()
    }
    
    func addPinnedSite(_ siteId: Int) -> Bool {
        guard canAddMorePins(), !isPinned(siteId) else { return false }
        var current = pinnedSiteIds
        current.insert(siteId)
        pinnedSiteIdsStorage = current.map { String($0) }.joined(separator: ",")
        objectWillChange.send()
        return true
    }
    
    func removePinnedSite(_ siteId: Int) {
        var current = pinnedSiteIds
        current.remove(siteId)
        pinnedSiteIdsStorage = current.map { String($0) }.joined(separator: ",")
        objectWillChange.send()
    }
    
    private var periodCache: [LeaderboardPeriod: [RatesSite]] = [:]
    private var periodCacheDate: [LeaderboardPeriod: Date] = [:]
    private var api: PowstonAPI?
    
    var useDevServer: Bool { api?.useDevServer ?? false }
    
    func configure(api: PowstonAPI) { self.api = api }
    
    var formattedBatteryRange: String? {
        guard let min = batteryRangeMinKWh, let max = batteryRangeMaxKWh else { return nil }
        return "\(min)-\(max) kWh (±\(currentTolerance)%)"
    }
    
    var mySiteIds: [Int] { api?.sites.map { $0.id } ?? [] }
    
    var formattedDataDate: String {
        guard let date = dataDate else { return "" }
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.timeZone = powstonTimezone()
        
        switch currentPeriod {
        case .yesterday:
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        case .dayBefore:
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        case .week:
            formatter.dateFormat = "MMM d"
            let endDate = formatter.string(from: date)
            if let startDate = calendar.date(byAdding: .day, value: -6, to: date) {
                return "\(formatter.string(from: startDate)) – \(endDate)"
            }
            return "7 Days"
        case .month:
            formatter.dateFormat = "MMM d"
            let endDate = formatter.string(from: date)
            if let startDate = calendar.date(byAdding: .day, value: -29, to: date) {
                return "\(formatter.string(from: startDate)) – \(endDate)"
            }
            return "30 Days"
        }
    }
    
    var myRank: Int? {
        guard let mySiteId = api?.selectedSiteId else { return nil }
        let sorted = sites.sorted { $0.expectedBill < $1.expectedBill }
        if let index = sorted.firstIndex(where: { $0.siteId == mySiteId }) { return index + 1 }
        return nil
    }
    
    var myStateRank: Int? {
        guard let mySiteId = api?.selectedSiteId, let myState = mySite?.state else { return nil }
        let stateSites = sites.filter { $0.state == myState }
        let sorted = stateSites.sorted { $0.expectedBill < $1.expectedBill }
        if let index = sorted.firstIndex(where: { $0.siteId == mySiteId }) { return index + 1 }
        return nil
    }
    
    var stateSiteCount: Int {
        guard let myState = mySite?.state else { return 0 }
        return sites.filter { $0.state == myState }.count
    }
    
    var mySite: RatesSite? {
        guard let mySiteId = api?.selectedSiteId else { return nil }
        return sites.first { $0.siteId == mySiteId }
    }
    
    var totalSites: Int { sites.count }
    
    func calculatePercentile(forMode mode: LeaderboardRankingMode) -> Int? {
        guard let mySiteId = api?.selectedSiteId else { return nil }
        let comparisonBuyRate = UserDefaults.standard.double(forKey: "comparison_buy_rate")
        let comparisonSellRate = UserDefaults.standard.double(forKey: "comparison_sell_rate")
        let buyRate = comparisonBuyRate > 0 ? comparisonBuyRate : 33.0
        let sellRate = comparisonSellRate > 0 ? comparisonSellRate : 5.0
        
        let ranked: [RatesSite]
        switch mode {
        case .bill:
            ranked = sites.sorted { $0.expectedBill < $1.expectedBill }
        case .netBenefit:
            ranked = sites.sorted {
                $0.netBenefit(comparisonBuyRate: buyRate, comparisonSellRate: sellRate) >
                $1.netBenefit(comparisonBuyRate: buyRate, comparisonSellRate: sellRate)
            }
        case .efficiency:
            ranked = sites
                .filter { $0.efficiency(comparisonBuyRate: buyRate, comparisonSellRate: sellRate) != nil }
                .sorted {
                    ($0.efficiency(comparisonBuyRate: buyRate, comparisonSellRate: sellRate) ?? 0) >
                    ($1.efficiency(comparisonBuyRate: buyRate, comparisonSellRate: sellRate) ?? 0)
                }
        }
        
        guard !ranked.isEmpty, let myIndex = ranked.firstIndex(where: { $0.siteId == mySiteId }) else { return nil }
        let rank = myIndex + 1
        return Int(ceil(Double(rank) / Double(ranked.count) * 100))
    }
    
    func topEfficiency(for period: LeaderboardPeriod) -> Double? {
        let sitesToUse: [RatesSite]
        if let cached = periodCache[period], let cacheDate = periodCacheDate[period],
           Date().timeIntervalSince(cacheDate) < 600, !cached.isEmpty {
            sitesToUse = cached
        } else if currentPeriod == period && hasData {
            sitesToUse = sites
        } else { return nil }
        
        let comparisonBuyRate = UserDefaults.standard.double(forKey: "comparison_buy_rate")
        let comparisonSellRate = UserDefaults.standard.double(forKey: "comparison_sell_rate")
        let buyRate = comparisonBuyRate > 0 ? comparisonBuyRate : 33.0
        let sellRate = comparisonSellRate > 0 ? comparisonSellRate : 5.0
        
        let efficiencies = sitesToUse.compactMap { $0.efficiency(comparisonBuyRate: buyRate, comparisonSellRate: sellRate) }
        return efficiencies.max()
    }
    
    func myEfficiency(for period: LeaderboardPeriod) -> Double? {
        let sitesToUse: [RatesSite]
        if let cached = periodCache[period], let cacheDate = periodCacheDate[period],
           Date().timeIntervalSince(cacheDate) < 600, !cached.isEmpty {
            sitesToUse = cached
        } else if currentPeriod == period && hasData {
            sitesToUse = sites
        } else { return nil }
        
        guard let mySiteId = api?.selectedSiteId,
              let mySite = sitesToUse.first(where: { $0.siteId == mySiteId }) else { return nil }
        
        let comparisonBuyRate = UserDefaults.standard.double(forKey: "comparison_buy_rate")
        let comparisonSellRate = UserDefaults.standard.double(forKey: "comparison_sell_rate")
        let buyRate = comparisonBuyRate > 0 ? comparisonBuyRate : 33.0
        let sellRate = comparisonSellRate > 0 ? comparisonSellRate : 5.0
        
        return mySite.efficiency(comparisonBuyRate: buyRate, comparisonSellRate: sellRate)
    }
    
    func hasDataForPeriod(_ period: LeaderboardPeriod) -> Bool {
        if currentPeriod == period && hasData { return true }
        if let cached = periodCache[period], let cacheDate = periodCacheDate[period],
           Date().timeIntervalSince(cacheDate) < 600, !cached.isEmpty { return true }
        return false
    }

    func fetchRates(period: LeaderboardPeriod? = nil, attempt: Int = 1) async {
        guard let api = api else { return }
        let targetPeriod = period ?? currentPeriod
        currentPeriod = targetPeriod
        
        let calendar = Calendar.current
        let endDate = calendar.date(byAdding: .day, value: -targetPeriod.daysAgo, to: Date()) ?? Date()
        let startDate: Date
        
        switch targetPeriod {
        case .yesterday, .dayBefore: startDate = endDate
        case .week: startDate = calendar.date(byAdding: .day, value: -6, to: endDate) ?? endDate
        case .month: startDate = calendar.date(byAdding: .day, value: -29, to: endDate) ?? endDate
        }
        
        guard attempt <= 2 else { hasData = false; isLoading = false; return }
        
        isLoading = true
        isServerFiltered = false
        error = nil
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = powstonTimezone()
        let startString = formatter.string(from: startDate)
        let endString = formatter.string(from: endDate)
        
        var seenSiteIds = Set<Int>()
        var allDecoded: [RatesSiteDTO] = []
        
        let directions: [String?] = ["ASC", "DESC", nil]
        let brands = ["AlphaESS", "LG", "SAJ", "SIGENERGY", "SUNGROW", "Sonnen", "mixed"]
        
        for direction in directions {
            var urlString = "\(api.baseURL)/api/rates?start_date=\(startString)&end_date=\(endString)&limit=50"
            if let dir = direction { urlString += "&direction=\(dir)" }
            if let results = await fetchRatesBatch(urlString: urlString, api: api) {
                for site in results where !seenSiteIds.contains(site.site_id) {
                    seenSiteIds.insert(site.site_id)
                    allDecoded.append(site)
                }
            }
        }
        
        for brand in brands {
            let urlString = "\(api.baseURL)/api/rates?start_date=\(startString)&end_date=\(endString)&brand=\(brand)&limit=50"
            if let results = await fetchRatesBatch(urlString: urlString, api: api) {
                for site in results where !seenSiteIds.contains(site.site_id) {
                    seenSiteIds.insert(site.site_id)
                    allDecoded.append(site)
                }
            }
        }
        
        if allDecoded.isEmpty && (targetPeriod == .yesterday || targetPeriod == .dayBefore) {
            isLoading = false
            if let newEnd = calendar.date(byAdding: .day, value: -1, to: endDate) {
                await fetchRatesWithDates(startDate: newEnd, endDate: newEnd, period: targetPeriod, attempt: attempt + 1)
                return
            }
        }
        
        let userSiteIds = api.sites.map { $0.id }
        for siteId in userSiteIds {
            if !seenSiteIds.contains(siteId) {
                if let siteData = await fetchSingleSite(siteId: siteId, startDate: startString, endDate: endString, api: api) {
                    allDecoded.append(siteData)
                }
            }
        }
        
        sites = allDecoded.map { dto in
            RatesSite(siteId: dto.site_id, state: dto.state, tariff: dto.tariff, network: dto.network,
                      brand: dto.brand, inverterPower: dto.inverter_power, installedSolar: dto.installed_solar,
                      installedBattery: dto.installed_battery, totalCosts: dto.total_costs, totalEarnings: dto.total_earnings,
                      buyRate: dto.buy_rate, sellRate: dto.sell_rate, expectedBill: dto.expected_bill,
                      dailyCosts: dto.daily_costs, totalEnergyImported: dto.total_energy_imported,
                      totalEnergyExported: dto.total_energy_exported,
                      startTime: ISO8601DateFormatter().date(from: dto.start_time) ?? Date(),
                      endTime: ISO8601DateFormatter().date(from: dto.end_time) ?? Date())
        }
        
        periodCache[targetPeriod] = sites
        periodCacheDate[targetPeriod] = Date()
        dataDate = endDate
        hasData = !sites.isEmpty
        isLoading = false
    }
    
    private func fetchRatesBatch(urlString: String, api: PowstonAPI) async -> [RatesSiteDTO]? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(api.apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            return try JSONDecoder().decode([RatesSiteDTO].self, from: data)
        } catch { return nil }
    }
    
    private func fetchRatesWithDates(startDate: Date, endDate: Date, period: LeaderboardPeriod, attempt: Int) async {
        guard let api = api, attempt <= 2 else { hasData = false; isLoading = false; return }
        isLoading = true
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = powstonTimezone()
        let startString = formatter.string(from: startDate)
        let endString = formatter.string(from: endDate)
        
        var seenSiteIds = Set<Int>()
        var allDecoded: [RatesSiteDTO] = []
        
        let directions: [String?] = ["ASC", "DESC", nil]
        let brands = ["AlphaESS", "LG", "SAJ", "SIGENERGY", "SUNGROW", "Sonnen", "mixed"]
        
        for direction in directions {
            var urlString = "\(api.baseURL)/api/rates?start_date=\(startString)&end_date=\(endString)&limit=50"
            if let dir = direction { urlString += "&direction=\(dir)" }
            if let results = await fetchRatesBatch(urlString: urlString, api: api) {
                for site in results where !seenSiteIds.contains(site.site_id) {
                    seenSiteIds.insert(site.site_id)
                    allDecoded.append(site)
                }
            }
        }
        
        for brand in brands {
            let urlString = "\(api.baseURL)/api/rates?start_date=\(startString)&end_date=\(endString)&brand=\(brand)&limit=50"
            if let results = await fetchRatesBatch(urlString: urlString, api: api) {
                for site in results where !seenSiteIds.contains(site.site_id) {
                    seenSiteIds.insert(site.site_id)
                    allDecoded.append(site)
                }
            }
        }
        
        if allDecoded.isEmpty {
            if let newEnd = Calendar.current.date(byAdding: .day, value: -1, to: endDate) {
                isLoading = false
                await fetchRatesWithDates(startDate: newEnd, endDate: newEnd, period: period, attempt: attempt + 1)
                return
            }
        }
        
        let userSiteIds = api.sites.map { $0.id }
        for siteId in userSiteIds {
            if !seenSiteIds.contains(siteId) {
                if let siteData = await fetchSingleSite(siteId: siteId, startDate: startString, endDate: endString, api: api) {
                    allDecoded.append(siteData)
                }
            }
        }
        
        sites = allDecoded.map { dto in
            RatesSite(siteId: dto.site_id, state: dto.state, tariff: dto.tariff, network: dto.network,
                      brand: dto.brand, inverterPower: dto.inverter_power, installedSolar: dto.installed_solar,
                      installedBattery: dto.installed_battery, totalCosts: dto.total_costs, totalEarnings: dto.total_earnings,
                      buyRate: dto.buy_rate, sellRate: dto.sell_rate, expectedBill: dto.expected_bill,
                      dailyCosts: dto.daily_costs, totalEnergyImported: dto.total_energy_imported,
                      totalEnergyExported: dto.total_energy_exported,
                      startTime: ISO8601DateFormatter().date(from: dto.start_time) ?? Date(),
                      endTime: ISO8601DateFormatter().date(from: dto.end_time) ?? Date())
        }
        
        periodCache[period] = sites
        periodCacheDate[period] = Date()
        dataDate = endDate
        hasData = !sites.isEmpty
        isLoading = false
    }
    
    private func fetchSingleSite(siteId: Int, startDate: String, endDate: String, api: PowstonAPI) async -> RatesSiteDTO? {
        let urlString = "\(api.baseURL)/api/rates?start_date=\(startDate)&end_date=\(endDate)&site_id=\(siteId)&limit=1"
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(api.apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode([RatesSiteDTO].self, from: data)
            return decoded.first
        } catch { return nil }
    }
    
    private func calculateBatteryRange(batteryKWh: Int, tolerance: Int) -> (min: Int, max: Int) {
        let factor = Double(tolerance) / 100.0
        return (Int(Double(batteryKWh) * (1.0 - factor)), Int(Double(batteryKWh) * (1.0 + factor)))
    }
    
    private func fetchBatteryRangeBatch(minKWh: Int, maxKWh: Int, state: String?, startDate: String, endDate: String, api: PowstonAPI) async -> [RatesSiteDTO]? {
        var urlString = "\(api.baseURL)/api/rates?start_date=\(startDate)&end_date=\(endDate)&direction=ASC&limit=50"
        urlString += "&battery_size=\(minKWh * 1000)-\(maxKWh * 1000)"
        if let state = state { urlString += "&state=\(state)" }
        return await fetchRatesBatch(urlString: urlString, api: api)
    }

    func fetchRatesAdaptive(state: String? = nil, period: LeaderboardPeriod? = nil, allowFallback: Bool = true) async {
        guard let api = api else { return }
        guard let mySiteId = api.selectedSiteId, let mySite = api.selectedSite,
              let myBatteryWh = mySite.installedBattery else {
            await fetchRates(period: period)
            return
        }

        let myBatteryKWh = myBatteryWh / 1000
        let targetPeriod = period ?? currentPeriod
        currentPeriod = targetPeriod

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        // Pre-check data availability using day_rates as a reliable canary
        // This avoids unnecessary API calls when we know data isn't ready yet
        var endDate = calendar.date(byAdding: .day, value: -targetPeriod.daysAgo, to: Date()) ?? Date()

        if targetPeriod == .yesterday && allowFallback {
            loadingStatus = "Checking data availability..."
            let yesterdayFinalized = await api.isDayDataFinalized(date: endDate)

            if !yesterdayFinalized {
                // Yesterday's data not ready, proactively use day-before
                print("📊 Leaderboard: Yesterday's data not finalized, using day-before")
                endDate = calendar.date(byAdding: .day, value: -2, to: Date()) ?? endDate
                isUsingFallbackData = true
            }
        }

        let startDate: Date
        switch targetPeriod {
        case .yesterday, .dayBefore: startDate = endDate
        case .week: startDate = calendar.date(byAdding: .day, value: -6, to: endDate) ?? endDate
        case .month: startDate = calendar.date(byAdding: .day, value: -29, to: endDate) ?? endDate
        }

        isLoading = true
        isServerFiltered = true
        if !isUsingFallbackData { isUsingFallbackData = false }
        error = nil
        myPercentile = nil
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = powstonTimezone()
        let startString = formatter.string(from: startDate)
        let endString = formatter.string(from: endDate)
        
        var tolerance = 20
        var results: [RatesSiteDTO] = []
        var userIncluded = false
        
        loadingStatus = "Finding your peers..."
        
        while tolerance >= 5 {
            let (minKWh, maxKWh) = calculateBatteryRange(batteryKWh: myBatteryKWh, tolerance: tolerance)
            if let batch = await fetchBatteryRangeBatch(minKWh: minKWh, maxKWh: maxKWh, state: state, startDate: startString, endDate: endString, api: api) {
                results = batch
                userIncluded = batch.contains { $0.site_id == mySiteId }
                if userIncluded {
                    if batch.count < 20 && tolerance < 50 { break }
                    currentTolerance = tolerance
                    batteryRangeMinKWh = minKWh
                    batteryRangeMaxKWh = maxKWh
                    break
                }
            }
            tolerance -= 5
            loadingStatus = "Narrowing search (±\(tolerance)%)..."
        }
        
        if results.count < 20 && tolerance < 50 {
            loadingStatus = "Finding more peers..."
            tolerance = max(tolerance, 20)
            while results.count < 20 && tolerance <= 50 {
                tolerance += 10
                let (minKWh, maxKWh) = calculateBatteryRange(batteryKWh: myBatteryKWh, tolerance: tolerance)
                if let batch = await fetchBatteryRangeBatch(minKWh: minKWh, maxKWh: maxKWh, state: state, startDate: startString, endDate: endString, api: api) {
                    results = batch
                    userIncluded = batch.contains { $0.site_id == mySiteId }
                    currentTolerance = tolerance
                    batteryRangeMinKWh = minKWh
                    batteryRangeMaxKWh = maxKWh
                    if batch.count >= 20 || tolerance >= 50 { break }
                }
            }
        }
        
        var userSiteFound = userIncluded
        if !userIncluded {
            if let siteData = await fetchSingleSite(siteId: mySiteId, startDate: startString, endDate: endString, api: api) {
                results.append(siteData)
                userSiteFound = true
            }
        }
        
        // NOTE: Pinned sites fetch disabled - API now restricts site_id lookups to own sites only
        // Uncomment when API support is available
        // let pinnedIds = pinnedSiteIds
        // for pinnedId in pinnedIds {
        //     if !results.contains(where: { $0.site_id == pinnedId }) {
        //         if let pinnedData = await fetchSingleSite(siteId: pinnedId, startDate: startString, endDate: endString, api: api) {
        //             results.append(pinnedData)
        //         }
        //     }
        // }
        
        // Fallback to prior day if user's site still not found (only for yesterday period)
        if !userSiteFound && targetPeriod == .yesterday && allowFallback {
            loadingStatus = "Checking prior day..."
            if let priorEndDate = calendar.date(byAdding: .day, value: -2, to: Date()) {
                isLoading = false
                await fetchRatesAdaptiveWithDate(endDate: priorEndDate, state: state, period: targetPeriod, isFallback: true)
                return
            }
        }
        
        sites = results.map { dto in
            RatesSite(siteId: dto.site_id, state: dto.state, tariff: dto.tariff, network: dto.network,
                      brand: dto.brand, inverterPower: dto.inverter_power, installedSolar: dto.installed_solar,
                      installedBattery: dto.installed_battery, totalCosts: dto.total_costs, totalEarnings: dto.total_earnings,
                      buyRate: dto.buy_rate, sellRate: dto.sell_rate, expectedBill: dto.expected_bill,
                      dailyCosts: dto.daily_costs, totalEnergyImported: dto.total_energy_imported,
                      totalEnergyExported: dto.total_energy_exported,
                      startTime: ISO8601DateFormatter().date(from: dto.start_time) ?? Date(),
                      endTime: ISO8601DateFormatter().date(from: dto.end_time) ?? Date())
        }
        
        periodCache[targetPeriod] = sites
        periodCacheDate[targetPeriod] = Date()
        calculateLegacyPercentile(mySiteId: mySiteId)
        dataDate = endDate
        hasData = !sites.isEmpty
        loadingStatus = nil
        isLoading = false
        
        if let topEff = topEfficiency(for: targetPeriod) {
            let key = "leaderboard_top_efficiency_\(targetPeriod.rawValue)"
            NSUbiquitousKeyValueStore.default.set(topEff, forKey: key)
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }
    
    private func fetchRatesAdaptiveWithDate(endDate: Date, state: String?, period: LeaderboardPeriod, isFallback: Bool) async {
        guard let api = api, let mySiteId = api.selectedSiteId, let mySite = api.selectedSite,
              let myBatteryWh = mySite.installedBattery else { return }
        
        let myBatteryKWh = myBatteryWh / 1000
        isLoading = true
        isServerFiltered = true
        isUsingFallbackData = isFallback
        error = nil
        myPercentile = nil
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = powstonTimezone()
        let dateString = formatter.string(from: endDate)
        
        var results: [RatesSiteDTO] = []
        loadingStatus = isFallback ? "Loading prior day..." : "Finding your peers..."
        
        let (minKWh, maxKWh) = calculateBatteryRange(batteryKWh: myBatteryKWh, tolerance: 20)
        if let batch = await fetchBatteryRangeBatch(minKWh: minKWh, maxKWh: maxKWh, state: state, startDate: dateString, endDate: dateString, api: api) {
            results = batch
            currentTolerance = 20
            batteryRangeMinKWh = minKWh
            batteryRangeMaxKWh = maxKWh
        }
        
        if !results.contains(where: { $0.site_id == mySiteId }) {
            if let siteData = await fetchSingleSite(siteId: mySiteId, startDate: dateString, endDate: dateString, api: api) {
                results.append(siteData)
            }
        }
        
        // NOTE: Pinned sites fetch disabled - API now restricts site_id lookups to own sites only
        // Uncomment when API support is available
        // let pinnedIds = pinnedSiteIds
        // for pinnedId in pinnedIds {
        //     if !results.contains(where: { $0.site_id == pinnedId }) {
        //         if let pinnedData = await fetchSingleSite(siteId: pinnedId, startDate: dateString, endDate: dateString, api: api) {
        //             results.append(pinnedData)
        //         }
        //     }
        // }
        
        sites = results.map { dto in
            RatesSite(siteId: dto.site_id, state: dto.state, tariff: dto.tariff, network: dto.network,
                      brand: dto.brand, inverterPower: dto.inverter_power, installedSolar: dto.installed_solar,
                      installedBattery: dto.installed_battery, totalCosts: dto.total_costs, totalEarnings: dto.total_earnings,
                      buyRate: dto.buy_rate, sellRate: dto.sell_rate, expectedBill: dto.expected_bill,
                      dailyCosts: dto.daily_costs, totalEnergyImported: dto.total_energy_imported,
                      totalEnergyExported: dto.total_energy_exported,
                      startTime: ISO8601DateFormatter().date(from: dto.start_time) ?? Date(),
                      endTime: ISO8601DateFormatter().date(from: dto.end_time) ?? Date())
        }
        
        periodCache[period] = sites
        periodCacheDate[period] = Date()
        calculateLegacyPercentile(mySiteId: mySiteId)
        dataDate = endDate
        hasData = !sites.isEmpty
        loadingStatus = nil
        isLoading = false
    }
    
    private func calculateLegacyPercentile(mySiteId: Int) {
        myPercentile = calculatePercentile(forMode: .efficiency)
    }
    
    func fetchRatesFiltered(batteryMinKWh: Int?, batteryMaxKWh: Int?, state: String? = nil, period: LeaderboardPeriod? = nil) async {
        await fetchRatesAdaptive(state: state, period: period)
    }
}

private struct RatesSiteDTO: Codable {
    let site_id: Int
    let state: String
    let tariff: String
    let network: String
    let brand: String
    let inverter_power: Int
    let installed_solar: Int
    let installed_battery: Int
    let total_costs: Double
    let total_earnings: Double
    let buy_rate: Double
    let sell_rate: Double
    let expected_bill: Double
    let daily_costs: Double
    let total_energy_imported: Double
    let total_energy_exported: Double
    let start_time: String
    let end_time: String
}

// MARK: - Dashboard Card

struct LeaderboardCard: View {
    @EnvironmentObject var api: PowstonAPI
    @ObservedObject private var leaderboard = LeaderboardState.shared
    @State private var showFullLeaderboard = false
    @AppStorage("leaderboard_enabled") private var leaderboardEnabled: Bool = true
    @AppStorage("leaderboard_default_sort") private var defaultSort: String = "efficiency"
    @AppStorage("comparison_buy_rate") private var comparisonBuyRate: Double = 33.0
    @AppStorage("comparison_sell_rate") private var comparisonSellRate: Double = 5.0
    
    private var rankingMode: LeaderboardRankingMode {
        LeaderboardRankingMode(rawValue: defaultSort) ?? .efficiency
    }
    
    private var myPercentile: Int? {
        leaderboard.calculatePercentile(forMode: rankingMode)
    }
    
    var body: some View {
        if !leaderboardEnabled {
            EmptyView()
        } else {
            leaderboardContent
        }
    }
    
    @ViewBuilder
    var leaderboardContent: some View {
        Button(action: { showFullLeaderboard = true }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "trophy.fill").foregroundColor(.yellow)
                    Text("Leaderboard").font(.subheadline).fontWeight(.semibold)
                    if leaderboard.hasData {
                        Text("• \(leaderboard.formattedDataDate)").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
                
                if leaderboard.isLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(leaderboard.loadingStatus ?? "Loading rankings...").font(.caption).foregroundColor(.secondary)
                    }.padding(.vertical, 4)
                } else if !leaderboard.hasData {
                    HStack(spacing: 6) {
                        Image(systemName: "clock").foregroundColor(.secondary)
                        Text("Waiting for meter data").font(.caption).foregroundColor(.secondary)
                    }.padding(.vertical, 4)
                } else if let percentile = myPercentile, let mySite = leaderboard.mySite {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if percentile <= 10 { Text("🥇").font(.title2) }
                        else if percentile <= 20 { Text("🥈").font(.title2) }
                        else if percentile <= 30 { Text("🥉").font(.title2) }
                        
                        Text("Top \(percentile)%").font(.title).fontWeight(.bold).foregroundColor(percentileColor(percentile))
                        Text("• \(rankingMode.displayName)").font(.subheadline).foregroundColor(.secondary)
                        Spacer()
                        
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(displayValue(for: mySite)).font(.headline).fontWeight(.bold).foregroundColor(valueColor(for: mySite))
                            Text(valueLabel).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("Site not ranked today").font(.caption).foregroundColor(.secondary).padding(.vertical, 4)
                }
            }
            .padding()
            .background(Color.yellow.opacity(0.08))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.yellow.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showFullLeaderboard) {
            LeaderboardSheet(leaderboard: leaderboard, defaultState: api.selectedSite?.state?.uppercased())
        }
        .task {
            leaderboard.configure(api: api)
            await leaderboard.fetchRatesAdaptive(state: api.selectedSite?.state)
        }
    }
    
    private func displayValue(for site: RatesSite) -> String {
        switch rankingMode {
        case .bill: return site.formattedBill
        case .netBenefit: return site.formattedNetBenefit(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate)
        case .efficiency: return site.formattedEfficiency(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate)
        }
    }
    
    private func valueColor(for site: RatesSite) -> Color {
        switch rankingMode {
        case .bill: return site.isCredit ? .green : .red
        case .netBenefit: return site.netBenefit(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate) >= 0 ? .green : .red
        case .efficiency: return (site.efficiency(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate) ?? 0) >= 0 ? .green : .red
        }
    }
    
    private var valueLabel: String {
        switch rankingMode {
        case .bill: return "bill"
        case .netBenefit: return "benefit"
        case .efficiency: return "per kWh"
        }
    }
    
    func percentileColor(_ percentile: Int) -> Color {
        switch percentile {
        case 1...10: return .yellow
        case 11...25: return .green
        case 26...50: return .blue
        default: return .primary
        }
    }
}

// MARK: - Full Leaderboard Sheet

struct LeaderboardSheet: View {
    @ObservedObject var leaderboard: LeaderboardState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("leaderboard_default_sort") private var defaultSort: String = "efficiency"
    @AppStorage("comparison_buy_rate") private var comparisonBuyRate: Double = 33.0
    @AppStorage("comparison_sell_rate") private var comparisonSellRate: Double = 5.0
    let defaultState: String?
    
    @State private var selectedBrand: String? = nil
    @State private var rankingMode: LeaderboardRankingMode = .efficiency
    
    init(leaderboard: LeaderboardState, defaultState: String? = nil) {
        self.leaderboard = leaderboard
        self.defaultState = defaultState
    }
    
    var availableBrands: [String] { Array(Set(leaderboard.sites.map { $0.brand })).sorted() }
    
    var filteredSites: [RatesSite] {
        var result = leaderboard.sites
        if let brand = selectedBrand { result = result.filter { $0.brand == brand } }
        
        switch rankingMode {
        case .bill: return result.sorted { $0.expectedBill < $1.expectedBill }
        case .netBenefit:
            return result.sorted {
                $0.netBenefit(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate) >
                $1.netBenefit(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate)
            }
        case .efficiency:
            return result
                .filter { $0.efficiency(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate) != nil }
                .sorted {
                    ($0.efficiency(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate) ?? 0) >
                    ($1.efficiency(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate) ?? 0)
                }
        }
    }
    
    var myRankInFiltered: Int? {
        guard let mySiteId = leaderboard.mySite?.siteId else { return nil }
        if let index = filteredSites.firstIndex(where: { $0.siteId == mySiteId }) { return index + 1 }
        return nil
    }
    
    var myPercentileInFiltered: Int? {
        guard let rank = myRankInFiltered else { return nil }
        let total = filteredSites.count
        guard total > 0 else { return nil }
        return Int(ceil(Double(rank) / Double(total) * 100))
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                
                if leaderboard.isLoading {
                    Spacer()
                    ProgressView("Loading leaderboard...")
                    Spacer()
                } else if filteredSites.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "trophy").font(.largeTitle).foregroundColor(.secondary)
                        Text("No sites match filters").foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    HStack {
                        Text("Rank").frame(width: 50, alignment: .leading)
                        Text("Site").frame(maxWidth: .infinity, alignment: .leading)
                        Menu {
                            ForEach(LeaderboardRankingMode.allCases, id: \.self) { mode in
                                Button {
                                    rankingMode = mode
                                    defaultSort = mode.rawValue
                                } label: {
                                    HStack {
                                        Text(mode.displayName)
                                        if rankingMode == mode { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Text(rankingMode.displayName)
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            }.frame(width: 80, alignment: .trailing)
                        }
                    }
                    .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                    .padding(.horizontal).padding(.vertical, 8)
                    .background(Color.gray.opacity(0.1))
                    
                    ScrollViewReader { proxy in
                        List {
                            ForEach(Array(filteredSites.enumerated()), id: \.element.id) { index, site in
                                LeaderboardRow(rank: index + 1, site: site, isMysite: leaderboard.mySiteIds.contains(site.siteId),
                                               isPinned: leaderboard.isPinned(site.siteId),
                                               rankingMode: rankingMode, comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate)
                                    .id(site.siteId)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            }
                        }
                        .listStyle(.plain)
                        .onAppear {
                            if let mySite = leaderboard.mySite {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                    withAnimation { proxy.scrollTo(mySite.siteId, anchor: .center) }
                                }
                            }
                        }
                    }
                    
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("**Bill** is the estimated daily electricity cost. Lower is better. Negative values (green) are credits.")
                                .font(.caption2).foregroundColor(.secondary)
                            Text("**Net Benefit** compares your costs against a flat-rate tariff of \(Int(comparisonBuyRate))¢/\(Int(comparisonSellRate))¢. Higher is better.")
                                .font(.caption2).foregroundColor(.secondary)
                            Text("**Efficiency** is Net Benefit per kWh of battery. Sites <5 kWh excluded. Higher is better.")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                    } label: {
                        Text("How rankings work").font(.caption).foregroundColor(.secondary)
                    }.padding()
                }
            }
            .navigationTitle("Leaderboard • \(leaderboard.formattedDataDate)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let percentile = myPercentileInFiltered {
                        Text("Top \(percentile)%").font(.caption).fontWeight(.medium)
                            .foregroundColor(percentile <= 25 ? .green : .secondary)
                    } else if let rank = myRankInFiltered {
                        Text("#\(rank) of \(filteredSites.count)").font(.caption).foregroundColor(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .onAppear { rankingMode = LeaderboardRankingMode(rawValue: defaultSort) ?? .efficiency }
        }
    }
    
    @ViewBuilder
    var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(LeaderboardPeriod.allCases, id: \.self) { period in
                        Button(period.displayName) {
                            Task { await leaderboard.fetchRatesAdaptive(state: defaultState, period: period) }
                        }
                    }
                } label: {
                    FilterChip(label: leaderboard.currentPeriod.displayName, isActive: true, isStale: leaderboard.isUsingFallbackData)
                }
                
                Divider().frame(height: 20)
                
                if let rangeStr = leaderboard.formattedBatteryRange {
                    HStack(spacing: 4) {
                        Image(systemName: "battery.100").font(.caption).foregroundColor(.green)
                        Text(rangeStr).font(.caption).fontWeight(.medium)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.green.opacity(0.15)).cornerRadius(8)
                    Divider().frame(height: 20)
                }
                
                if let state = defaultState {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin.circle.fill").font(.caption).foregroundColor(.blue)
                        Text(state).font(.caption).fontWeight(.medium)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.blue.opacity(0.15)).cornerRadius(8)
                    Divider().frame(height: 20)
                }
                
                Menu {
                    Button("All Brands") { selectedBrand = nil }
                    Divider()
                    ForEach(availableBrands, id: \.self) { brand in Button(brand) { selectedBrand = brand } }
                } label: {
                    FilterChip(label: selectedBrand ?? "Brand", isActive: selectedBrand != nil)
                }
                
                if selectedBrand != nil {
                    Button { selectedBrand = nil } label: { Text("Clear").font(.caption).foregroundColor(.red) }
                }
            }
            .padding(.horizontal).padding(.vertical, 8)
        }
        .background(Color.gray.opacity(0.05))
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let label: String
    let isActive: Bool
    var isStale: Bool = false
    
    private var chipColor: Color {
        if isStale { return .orange }
        else if isActive { return .blue }
        else { return .gray }
    }
    
    var body: some View {
        HStack(spacing: 4) {
            if isStale { Image(systemName: "clock.arrow.circlepath").font(.caption2) }
            Text(label).font(.caption)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(chipColor.opacity(0.15))
        .foregroundColor(chipColor)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(chipColor, lineWidth: isStale ? 1.5 : (isActive ? 1 : 0)))
    }
}

// MARK: - Leaderboard Row

struct LeaderboardRow: View {
    let rank: Int
    let site: RatesSite
    let isMysite: Bool
    let isPinned: Bool
    let rankingMode: LeaderboardRankingMode
    let comparisonBuyRate: Double
    let comparisonSellRate: Double
    
    private var netBenefit: Double {
        site.netBenefit(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate)
    }
    
    private var efficiency: Double? {
        site.efficiency(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate)
    }
    
    private var displayValue: String {
        switch rankingMode {
        case .bill: return site.formattedBill
        case .netBenefit: return site.formattedNetBenefit(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate)
        case .efficiency: return site.formattedEfficiency(comparisonBuyRate: comparisonBuyRate, comparisonSellRate: comparisonSellRate)
        }
    }
    
    private var valueColor: Color {
        switch rankingMode {
        case .bill: return site.isCredit ? .green : .red
        case .netBenefit: return netBenefit >= 0 ? .green : .red
        case .efficiency: return (efficiency ?? 0) >= 0 ? .green : .red
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                if rank <= 3 { Text(medalEmoji(for: rank)).font(.body) }
                Text("#\(rank)").font(.subheadline).fontWeight(isMysite ? .bold : .regular).foregroundColor(rankColor)
            }.frame(width: 50, alignment: .leading)
            
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(site.siteId)").font(.subheadline).fontWeight(isMysite || isPinned ? .bold : .medium)
                    Text(site.state).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.gray.opacity(0.15)).cornerRadius(4)
                    if isMysite { Image(systemName: "star.fill").font(.caption2).foregroundColor(.yellow) }
                    if isPinned && !isMysite { Image(systemName: "pin.fill").font(.caption2).foregroundColor(.blue) }
                }
                HStack(spacing: 8) {
                    Text(site.brand).font(.caption2).foregroundColor(.secondary)
                    Text("•").font(.caption2).foregroundColor(.secondary)
                    Text("\(site.installedBattery / 1000) kWh").font(.caption2).foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Text(displayValue).font(.subheadline).fontWeight(.semibold).foregroundColor(valueColor).frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .background(isMysite ? Color.yellow.opacity(0.1) : (isPinned ? Color.blue.opacity(0.08) : Color.clear))
        .cornerRadius(8)
    }
    
    func medalEmoji(for rank: Int) -> String {
        switch rank {
        case 1: return "🥇"
        case 2: return "🥈"
        case 3: return "🥉"
        default: return ""
        }
    }
    
    var rankColor: Color {
        if isMysite { return .primary }
        switch rank {
        case 1: return .yellow
        case 2: return .gray
        case 3: return .orange
        default: return .primary
        }
    }
}

// MARK: - Preview

#Preview("Leaderboard Card") {
    VStack {
        LeaderboardCard().padding()
    }.environmentObject(PowstonAPI())
}

#Preview("Leaderboard Sheet") {
    LeaderboardSheet(leaderboard: LeaderboardState.shared)
}
