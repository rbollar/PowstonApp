//
//  ScorecardCache.swift
//  Powston
//
//  Manages caching of meter records for scorecard computation
//  Now routes through PowstonAPI.fetchMeterRecords() for SQLite cache-through
//  Finalized data (>7 days old) is served from SQLite without API calls
//

import Foundation
import Combine
import SwiftUI

/// Financial summary from day_rates API (matches History view)
struct ScorecardFinancialSummary {
    let totalEarnings: Double      // Sold (dollars)
    let energyCosts: Double        // Bought (dollars) - rate costs only
    let supplyCosts: Double        // Supply (dollars)
    let totalCosts: Double         // Bought + Supply (dollars)
    let netPosition: Double        // Net profit (dollars) - positive = profit
    let totalImport: Double        // kWh
    let totalExport: Double        // kWh
    let avgBuyRate: Double         // cents/kWh
    let avgSellRate: Double        // cents/kWh
}

@MainActor
class ScorecardCache: ObservableObject {
    static let shared = ScorecardCache()
    
    // In-memory cache for filtered records per period
    private var recordsCache: [Int: [MeterRecord]] = [:]  // siteId -> records
    private var lastFetchDate: [Int: Date] = [:]  // siteId -> last fetch time
    private var oldestCachedDate: [Int: Date] = [:]  // siteId -> oldest record date
    private var newestCachedDate: [Int: Date] = [:]  // siteId -> newest record date
    
    // Computed scorecards cache
    private var scorecardCache: [String: Scorecard] = [:]  // "siteId_period_date" -> scorecard
    
    // Financial summary cache (from day_rates API)
    private var financialCache: [String: ScorecardFinancialSummary] = [:]  // "siteId_period_date" -> summary
    
    @Published var isLoading = false
    @Published var loadingProgress: String = ""
    
    // User's peak hour settings
    @AppStorage("peak_start_hour") private var peakStartHour: Double = 16.0
    @AppStorage("peak_end_hour") private var peakEndHour: Double = 21.0
    
    // MARK: - Public Interface
    
    /// Get or compute scorecard for a site and period
    /// Returns scorecard (for performance analysis) and optionally financial summary (for display)
    func getScorecard(
        siteId: Int,
        period: ScorecardPeriod,
        api: PowstonAPI,
        forceRefresh: Bool = false
    ) async -> Scorecard? {
        let cacheKey = scorecardCacheKey(siteId: siteId, period: period)

        // Return cached scorecard if fresh (within 5 minutes)
        if !forceRefresh,
           let cached = scorecardCache[cacheKey],
           Date().timeIntervalSince(cached.generatedAt) < 300 {
            return cached
        }

        // Check data availability using day_rates canary
        await api.refreshLatestCompleteDataDate()
        let latestCompleteDate = api.latestCompleteDataDate

        // Ensure we have records (uses SQLite cache-through)
        await ensureRecords(siteId: siteId, period: period, api: api, latestCompleteDate: latestCompleteDate)

        guard let records = recordsCache[siteId], !records.isEmpty else {
            return nil
        }

        // Get site timezone
        let siteTimezone: TimeZone
        if let site = api.sites.first(where: { $0.id == siteId }),
           let tzString = site.timezone,
           let tz = TimeZone(identifier: tzString) {
            siteTimezone = tz
        } else {
            siteTimezone = TimeZone(identifier: "Australia/Brisbane")!
        }

        // Filter records for period (using site timezone for date boundaries)
        // Uses latestCompleteDate to avoid requesting data that isn't finalized yet
        let (from, to) = dateRange(for: period, timezone: siteTimezone, latestCompleteDate: latestCompleteDate)
        let filteredRecords = records.filter { record in
            guard let date = record.date else { return false }
            return date >= from && date < to  // Use < for end boundary to avoid including next day's midnight
        }
        
        guard !filteredRecords.isEmpty else { return nil }
        
        // Get inverter capacity from site (watts)
        let inverterCapacity: Double
        if let site = api.sites.first(where: { $0.id == siteId }),
           let power = site.inverterPower {
            inverterCapacity = Double(power)
        } else {
            inverterCapacity = 20000  // Default 20kW
        }
        
        // Get battery capacity from site (kWh)
        let batteryCapacityKWh: Double?
        if let site = api.sites.first(where: { $0.id == siteId }),
           let batteryWh = site.installedBattery {
            batteryCapacityKWh = Double(batteryWh) / 1000.0
        } else {
            batteryCapacityKWh = nil
        }
        
        // Get cohort benchmark and position from leaderboard (fetch if missing)
        let (cohortBestEfficiency, cohortPercentile, cohortRank, cohortSize) = await getCohortData(for: period, api: api)

        // Compute scorecard with site's timezone, user's peak hours, inverter capacity, and benchmark
        let calculator = ScorecardCalculator(
            timezone: siteTimezone,
            peakStartHour: Int(peakStartHour),
            peakEndHour: Int(peakEndHour),
            inverterCapacityWatts: inverterCapacity,
            cohortBestEfficiency: cohortBestEfficiency,
            batteryCapacityKWh: batteryCapacityKWh,
            cohortPercentile: cohortPercentile,
            cohortRank: cohortRank,
            cohortSize: cohortSize
        )
        let scorecard = calculator.calculate(
            records: filteredRecords,
            siteId: siteId,
            from: from,
            to: to
        )
        
        // Cache it
        scorecardCache[cacheKey] = scorecard
        
        // Also fetch and cache financial summary from day_rates API
        await fetchFinancialSummary(siteId: siteId, period: period, from: from, to: to, api: api)
        
        return scorecard
    }
    
    /// Get financial summary from day_rates API (matches History view values)
    func getFinancialSummary(siteId: Int, period: ScorecardPeriod) -> ScorecardFinancialSummary? {
        let cacheKey = scorecardCacheKey(siteId: siteId, period: period)
        return financialCache[cacheKey]
    }
    
    /// Fetch financial summary from day_rates API
    private func fetchFinancialSummary(siteId: Int, period: ScorecardPeriod, from: Date, to: Date, api: PowstonAPI) async {
        let cacheKey = scorecardCacheKey(siteId: siteId, period: period)
        
        // Calculate the end date for the API call
        // The 'to' date is exclusive (start of today), so we need day before for inclusive end
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: to) ?? to
        
        // Use fetchCustomRangeSummary for all periods (freshest data approach)
        guard let summary = await api.fetchCustomRangeSummary(startDate: from, endDate: inclusiveEnd) else {
            print("⚠️ Failed to fetch financial summary for scorecard")
            return
        }
        
        // Calculate supply costs: Total Costs - Rate Costs (energy only)
        // This ensures: Sold - Bought - Supply = Net always reconciles
        let supplyCosts = summary.earningsDollars - summary.rateCostsDollars - summary.netProfitDollars
        
        let financialSummary = ScorecardFinancialSummary(
            totalEarnings: summary.earningsDollars,
            energyCosts: summary.rateCostsDollars,
            supplyCosts: supplyCosts,
            totalCosts: summary.rateCostsDollars + supplyCosts,
            netPosition: summary.netProfitDollars,
            totalImport: summary.totalEnergyImported,
            totalExport: summary.totalEnergyExported,
            avgBuyRate: summary.buyRate,
            avgSellRate: summary.sellRate
        )
        
        financialCache[cacheKey] = financialSummary
        print("✅ Fetched financial summary: Sold $\(String(format: "%.2f", financialSummary.totalEarnings)), Bought $\(String(format: "%.2f", financialSummary.energyCosts)), Net $\(String(format: "%.2f", financialSummary.netPosition))")
    }
    
    /// Get cohort data from leaderboard (fetches if missing)
    /// Returns: (bestEfficiency, userPercentile, userRank, cohortSize)
    private func getCohortData(for period: ScorecardPeriod, api: PowstonAPI) async -> (Double?, Int?, Int?, Int?) {
        let leaderboardPeriod = period.leaderboardPeriod
        let leaderboard = LeaderboardState.shared

        // Ensure leaderboard is configured
        leaderboard.configure(api: api)

        // Fetch leaderboard data if not available for this period
        if !leaderboard.hasDataForPeriod(leaderboardPeriod) {
            print("📊 Fetching leaderboard data for \(leaderboardPeriod.displayName)...")
            await leaderboard.fetchRatesAdaptive(state: api.selectedSite?.state, period: leaderboardPeriod)

            // Re-check after fetch
            guard leaderboard.hasDataForPeriod(leaderboardPeriod) else {
                print("📊 Still no leaderboard data for \(leaderboardPeriod.displayName) after fetch")
                return (nil, nil, nil, nil)
            }
        }

        // Get top performer's efficiency
        let topEfficiency = leaderboard.topEfficiency(for: leaderboardPeriod)

        // Get user's percentile
        let percentile = leaderboard.calculatePercentile(forMode: .efficiency)

        // Get user's rank and cohort size
        let cohortSize = leaderboard.totalSites
        let rank = leaderboard.myRank

        if let topEff = topEfficiency {
            print("📊 Cohort for \(leaderboardPeriod.displayName): best=\(topEff)¢/kWh, rank=\(rank ?? 0)/\(cohortSize), percentile=\(percentile ?? 0)%")
        }

        return (topEfficiency, percentile, rank, cohortSize > 0 ? cohortSize : nil)
    }
    
    /// Refresh records from API
    func refreshRecords(siteId: Int, api: PowstonAPI) async {
        await fetchRecords(siteId: siteId, api: api, fullRefresh: true)
    }
    
    /// Clear all cached data
    func clearCache() {
        recordsCache.removeAll()
        lastFetchDate.removeAll()
        oldestCachedDate.removeAll()
        newestCachedDate.removeAll()
        scorecardCache.removeAll()
        financialCache.removeAll()
    }
    
    /// Clear cache for specific site
    func clearCache(siteId: Int) {
        recordsCache.removeValue(forKey: siteId)
        lastFetchDate.removeValue(forKey: siteId)
        oldestCachedDate.removeValue(forKey: siteId)
        newestCachedDate.removeValue(forKey: siteId)
        
        // Clear scorecard and financial cache entries for this site
        scorecardCache = scorecardCache.filter { !$0.key.hasPrefix("\(siteId)_") }
        financialCache = financialCache.filter { !$0.key.hasPrefix("\(siteId)_") }
    }
    
    // MARK: - Private Methods
    
    private func ensureRecords(siteId: Int, period: ScorecardPeriod, api: PowstonAPI, latestCompleteDate: Date? = nil) async {
        let (from, _) = dateRange(for: period, latestCompleteDate: latestCompleteDate)

        // Check if we need to fetch
        if let oldest = oldestCachedDate[siteId], oldest <= from {
            // We have data going back far enough
            // Check if we need fresh data (last fetch > 5 min ago)
            if let lastFetch = lastFetchDate[siteId],
               Date().timeIntervalSince(lastFetch) < 300 {
                return  // Cache is fresh enough
            }

            // Fetch only new records
            await fetchNewRecords(siteId: siteId, api: api)
        } else {
            // Need to fetch more historical data
            await fetchRecords(siteId: siteId, api: api, from: from)
        }
    }
    
    private func fetchRecords(siteId: Int, api: PowstonAPI, from: Date? = nil, fullRefresh: Bool = false) async {
        isLoading = true
        loadingProgress = "Fetching meter records..."
        
        defer {
            isLoading = false
            loadingProgress = ""
        }
        
        let toDate = Date()
        let fromDate = from ?? Calendar.current.date(byAdding: .day, value: -35, to: toDate)!  // 35 days for month + buffer
        
        // Use PowstonAPI.fetchMeterRecords which has SQLite cache-through
        // Finalized data (>7 days old) will be served from SQLite without API calls
        let records = await api.fetchMeterRecords(
            siteId: siteId,
            fromDate: fromDate,
            toDate: toDate,
            forceRefresh: fullRefresh
        )
        
        if records.isEmpty {
            print("⚠️ No meter records returned for scorecard")
            return
        }
        
        if fullRefresh {
            recordsCache[siteId] = records
        } else {
            // Merge with existing
            var existing = recordsCache[siteId] ?? []
            let existingIds = Set(existing.map { $0.id })
            let newRecords = records.filter { !existingIds.contains($0.id) }
            existing.append(contentsOf: newRecords)
            existing.sort { $0.intervalTime < $1.intervalTime }
            recordsCache[siteId] = existing
        }
        
        // Update metadata
        lastFetchDate[siteId] = Date()
        
        if let cached = recordsCache[siteId] {
            if let oldest = cached.compactMap({ $0.date }).min() {
                oldestCachedDate[siteId] = oldest
            }
            if let newest = cached.compactMap({ $0.date }).max() {
                newestCachedDate[siteId] = newest
            }
        }
        
        // Invalidate scorecard and financial cache for this site
        scorecardCache = scorecardCache.filter { !$0.key.hasPrefix("\(siteId)_") }
        financialCache = financialCache.filter { !$0.key.hasPrefix("\(siteId)_") }
        
        loadingProgress = "Loaded \(records.count) records"
        print("📊 ScorecardCache: loaded \(records.count) meter records via cache-through")
    }
    
    private func fetchNewRecords(siteId: Int, api: PowstonAPI) async {
        guard let newest = newestCachedDate[siteId] else {
            await fetchRecords(siteId: siteId, api: api)
            return
        }
        
        // Fetch from newest cached date to now
        let fromDate = newest.addingTimeInterval(-3600)  // Overlap by 1 hour for safety
        await fetchRecords(siteId: siteId, api: api, from: fromDate)
    }
    
    private func dateRange(for period: ScorecardPeriod, timezone: TimeZone? = nil, latestCompleteDate: Date? = nil) -> (from: Date, to: Date) {
        var calendar = Calendar.current
        let tz = timezone ?? TimeZone(identifier: "Australia/Brisbane")!
        calendar.timeZone = tz
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)

        // Use latestCompleteDate if available, otherwise default to yesterday
        let effectiveEndDay: Date
        if let latestDate = latestCompleteDate {
            // End at the day AFTER latestCompleteDate (exclusive end boundary)
            effectiveEndDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: latestDate)) ?? todayStart
        } else {
            effectiveEndDay = todayStart
        }

        let from: Date
        let to: Date

        switch period {
        case .day:
            // Most recent complete day (latestCompleteDate or yesterday)
            let dayStart = calendar.date(byAdding: .day, value: -1, to: effectiveEndDay)!
            from = dayStart
            to = effectiveEndDay

        case .week:
            // Last 7 complete days ending at latestCompleteDate
            from = calendar.date(byAdding: .day, value: -7, to: effectiveEndDay)!
            to = effectiveEndDay

        case .month:
            // Last 30 complete days ending at latestCompleteDate
            from = calendar.date(byAdding: .day, value: -30, to: effectiveEndDay)!
            to = effectiveEndDay
        }

        return (from, to)
    }
    
    private func scorecardCacheKey(siteId: Int, period: ScorecardPeriod) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: Date())
        return "\(siteId)_\(period.rawValue)_\(dateStr)"
    }
}
