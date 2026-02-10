//
//  PowstonAPI+DayRates.swift
//  Powston
//
//  Day rate summary fetching, period summaries, breakdowns
//  Includes hourly_rates for accurate single-day data
//  Uses cumulative subtraction for accurate daily breakdowns (workaround for day_rates 2-day minimum bug)
//
//  SQLite Integration:
//  - Uses PowstonDataStore for persistent caching of daily summaries
//  - Finalized days (>7 days old) are served from cache without API calls
//  - Recent days are refreshed from API and cached
//

import Foundation
import GRDB

// MARK: - Day Rate Summary Model

/// Response from /api/day_rates/{site_id} endpoint
/// Aggregates all data within the requested date range into a single summary
/// NOTE: This endpoint has a bug where single-day queries return 2 days minimum
struct DayRateSummary: Codable, Identifiable {
    var id: String { "\(siteId)_\(startTime)_\(endTime)" }
    
    let siteId: Int
    let installerId: Int
    let state: String
    let tariff: String
    let network: String
    let brand: String
    let inverterPower: Int
    let recordCount: Int
    
    // Financial (in cents)
    let expectedBill: Double      // Net P&L: negative = credit, positive = cost
    let dailyCosts: Double
    let totalCosts: Double
    let totalEarnings: Double
    let rateCosts: Double
    let rateEarnings: Double
    
    // Energy (kWh)
    let totalEnergyImported: Double
    let totalEnergyExported: Double
    let totalBatteryKwh: Double
    
    // Rates (cents/kWh averages)
    let buyRate: Double
    let sellRate: Double
    
    // System info
    let installedSolar: Int
    let installedBattery: Int
    let windPower: Double
    let hydroPower: Double
    
    // Time range
    let startTime: String
    let endTime: String
    
    enum CodingKeys: String, CodingKey {
        case siteId = "site_id"
        case installerId = "installer_id"
        case state, tariff, network, brand
        case inverterPower = "inverter_power"
        case recordCount = "record_count"
        case expectedBill = "expected_bill"
        case dailyCosts = "daily_costs"
        case totalCosts = "total_costs"
        case totalEnergyImported = "total_energy_imported"
        case buyRate = "buy_rate"
        case totalBatteryKwh = "total_battery_kwh"
        case totalEnergyExported = "total_energy_exported"
        case totalEarnings = "total_earnings"
        case rateCosts = "rate_costs"
        case rateEarnings = "rate_earnings"
        case sellRate = "sell_rate"
        case installedSolar = "installed_solar"
        case installedBattery = "installed_battery"
        case windPower = "wind_power"
        case hydroPower = "hydro_power"
        case startTime = "start_time"
        case endTime = "end_time"
    }
    
    // MARK: - Computed Properties (Dollars)
    
    /// Net result: negative = credit, positive = cost (use -netDollars for display where positive = profit)
    var netDollars: Double {
        expectedBill / 100.0
    }
    
    /// Earnings from selling energy
    var earningsDollars: Double {
        totalEarnings / 100.0
    }
    
    /// Total costs including supply charges
    var costsDollars: Double {
        totalCosts / 100.0
    }
    
    /// Energy costs only - matches web "Bought" value (excludes supply charges)
    var rateCostsDollars: Double {
        rateCosts / 100.0
    }
    
    /// Net profit in dollars (positive = profit, negative = loss) - matches web display
    var netProfitDollars: Double {
        -expectedBill / 100.0
    }
    
    var isCredit: Bool {
        expectedBill < 0
    }
    
    var formattedNet: String {
        let absVal = abs(netDollars)
        return isCredit ? String(format: "-$%.2f", absVal) : String(format: "+$%.2f", absVal)
    }
    
    var formattedNetWithLabel: String {
        let absVal = abs(netDollars)
        return isCredit ? String(format: "$%.2f (credit)", absVal) : String(format: "$%.2f (cost)", absVal)
    }
    
    var formattedEarnings: String {
        String(format: "$%.2f", earningsDollars)
    }
    
    var formattedCosts: String {
        String(format: "$%.2f", costsDollars)
    }
    
    var formattedBuyRate: String {
        String(format: "%.1f¢", buyRate)
    }
    
    var formattedSellRate: String {
        String(format: "%.1f¢", sellRate)
    }
    
    var formattedImport: String {
        String(format: "%.1f kWh", totalEnergyImported)
    }
    
    var formattedExport: String {
        String(format: "%.1f kWh", totalEnergyExported)
    }
}

// MARK: - Daily Rate (for availability check)

struct DailyRate: Codable {
    let siteId: Int
    let installerId: Int
    let state: String
    let tariff: String
    let network: String
    let brand: String
    let inverterPower: Int
    let recordCount: Int
    let expectedBill: Double
    let dailyCosts: Double
    let totalCosts: Double
    let totalEnergyImported: Double
    let buyRate: Double
    let totalBatteryKwh: Double
    let totalEnergyExported: Double
    let totalEarnings: Double
    let rateCosts: Double
    let rateEarnings: Double
    let sellRate: Double
    let installedSolar: Int
    let installedBattery: Int
    let windPower: Double
    let hydroPower: Double
    let startTime: String
    let endTime: String
    
    enum CodingKeys: String, CodingKey {
        case siteId = "site_id"
        case installerId = "installer_id"
        case state, tariff, network, brand
        case inverterPower = "inverter_power"
        case recordCount = "record_count"
        case expectedBill = "expected_bill"
        case dailyCosts = "daily_costs"
        case totalCosts = "total_costs"
        case totalEnergyImported = "total_energy_imported"
        case buyRate = "buy_rate"
        case totalBatteryKwh = "total_battery_kwh"
        case totalEnergyExported = "total_energy_exported"
        case totalEarnings = "total_earnings"
        case rateCosts = "rate_costs"
        case rateEarnings = "rate_earnings"
        case sellRate = "sell_rate"
        case installedSolar = "installed_solar"
        case installedBattery = "installed_battery"
        case windPower = "wind_power"
        case hydroPower = "hydro_power"
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

// MARK: - Hourly Rate Model

/// Response from /api/hourly_rates/{site_id} endpoint
/// Returns 24 records (one per hour) for a single day
struct HourlyRate: Codable {
    let hour: Int
    let expectedBill: Double      // Net P&L for this hour (cents)
    let hourlyCosts: Double       // Fixed hourly costs (cents)
    let totalCosts: Double        // Energy costs (cents)
    let totalEnergyImported: Double
    let buyRate: Double
    let totalEnergyExported: Double
    let totalEarnings: Double
    let sellRate: Double
    
    enum CodingKeys: String, CodingKey {
        case hour
        case expectedBill = "expected_bill"
        case hourlyCosts = "hourly_costs"
        case totalCosts = "total_costs"
        case totalEnergyImported = "total_energy_imported"
        case buyRate = "buy_rate"
        case totalEnergyExported = "total_energy_exported"
        case totalEarnings = "total_earnings"
        case sellRate = "sell_rate"
    }
}

/// Summary of a single day derived from hourly_rates API
struct HourlyDaySummary {
    let date: Date
    let totalImport: Double       // kWh
    let totalExport: Double       // kWh
    let totalEarnings: Double     // Dollars (Sold)
    let totalCosts: Double        // Dollars (Bought - energy costs)
    let fixedCosts: Double        // Dollars (Supply - hourly fixed charges)
    let netProfit: Double         // Dollars (positive = profit)
    
    /// Convert to DailySummary for use in heatmaps and charts
        func toDailySummary() -> DailySummary {
            DailySummary(
                date: date,
                totalImport: totalImport,
                totalExport: totalExport,
                totalEarnings: totalEarnings,
                totalCosts: totalCosts + fixedCosts,
                avgSoc: 0,
                recordCount: 24,
                netProfit: netProfit  // Use authoritative value from expectedBill
            )
        }
}

/// Summary values extracted from cumulative day_rates for subtraction
struct CumulativeDayValues {
    let expectedBill: Double      // cents
    let totalCosts: Double        // cents
    let rateCosts: Double         // cents
    let totalEarnings: Double     // cents
    let totalEnergyImported: Double
    let totalEnergyExported: Double
    
    static let zero = CumulativeDayValues(
        expectedBill: 0, totalCosts: 0, rateCosts: 0,
        totalEarnings: 0, totalEnergyImported: 0, totalEnergyExported: 0
    )
    
    /// Subtract another cumulative value to isolate a single day
    func subtracting(_ other: CumulativeDayValues) -> CumulativeDayValues {
        CumulativeDayValues(
            expectedBill: expectedBill - other.expectedBill,
            totalCosts: totalCosts - other.totalCosts,
            rateCosts: rateCosts - other.rateCosts,
            totalEarnings: totalEarnings - other.totalEarnings,
            totalEnergyImported: totalEnergyImported - other.totalEnergyImported,
            totalEnergyExported: totalEnergyExported - other.totalEnergyExported
        )
    }
    
    /// Convert to DailySummary
    /// Convert to DailySummary
        func toDailySummary(date: Date) -> DailySummary {
            return DailySummary(
                date: date,
                totalImport: totalEnergyImported,
                totalExport: totalEnergyExported,
                totalEarnings: totalEarnings / 100.0,
                totalCosts: totalCosts / 100.0,
                avgSoc: 0,
                recordCount: 1,
                netProfit: -expectedBill / 100.0  // Use authoritative value from expectedBill
            )
        }
    
    /// Convert to DaySummaryRecord for SQLite storage
    func toDaySummaryRecord(siteId: Int, date: Date) -> DaySummaryRecord {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()
        let dateStr = dateFormatter.string(from: date)
        
        return DaySummaryRecord(
            siteId: siteId,
            date: dateStr,
            expectedBill: expectedBill,
            totalCosts: totalCosts,
            totalEarnings: totalEarnings,
            rateCosts: rateCosts,
            rateEarnings: nil,
            dailyCosts: nil,
            energyImported: totalEnergyImported,
            energyExported: totalEnergyExported,
            batteryKwh: nil,
            buyRate: nil,
            sellRate: nil,
            recordCount: 1,
            isFinalized: false
        )
    }
}

// MARK: - PowstonAPI Extension

extension PowstonAPI {
    
    // MARK: - Finalization Configuration
    
    /// Days older than this are considered finalized and won't be re-fetched
    private var finalizationDays: Int { 7 }
    
    // MARK: - Core Fetch Method
    
    func fetchDayRateSummary(
        siteId: Int? = nil,
        startDate: Date,
        endDate: Date,
        forceRefresh: Bool = false
    ) async -> DayRateSummary? {
        let id = siteId ?? selectedSiteId ?? 0
        guard id != 0, !apiKey.isEmpty else {
            print("❌ day_rates: No site or API key")
            return nil
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()
        
        let startStr = dateFormatter.string(from: startDate)
        let endStr = dateFormatter.string(from: endDate)
        let cacheKey = "\(id)_\(startStr)_\(endStr)"
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let includesIncompleteData = calendar.isDateInToday(endDate)
        
        if !forceRefresh && !includesIncompleteData,
           let cached = dayRateSummaryCache[cacheKey],
           Date().timeIntervalSince(cached.fetchTime) < dayRateSummaryCacheMinutes * 60 {
            print("📦 Using cached day_rates for \(cacheKey)")
            return cached.summary
        }
        
        let urlString = "\(baseURL)/api/day_rates/\(id)?start_date=\(startStr)&end_date=\(endStr)"
        guard let url = URL(string: urlString) else {
            print("❌ day_rates: Invalid URL")
            return nil
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        print("📊 Fetching day_rates: \(startStr) to \(endStr)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse else {
                print("❌ day_rates: No HTTP response")
                return nil
            }
            
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                print("❌ day_rates HTTP \(http.statusCode): \(body)")
                return nil
            }
            
            let decoded = try JSONDecoder().decode([DayRateSummary].self, from: data)
            guard let summary = decoded.first else {
                print("⚠️ day_rates: Empty response for \(cacheKey)")
                return nil
            }
            
            print("✅ day_rates: \(summary.recordCount) records, net \(summary.formattedNet)")
            
            if !includesIncompleteData {
                dayRateSummaryCache[cacheKey] = DayRateCacheEntry(summary: summary, fetchTime: Date())
            }
            
            return summary
            
        } catch {
            print("❌ day_rates error: \(error)")
            return nil
        }
    }
    
    // MARK: - Hourly Rates (Single Day)
    
    /// Fetch hourly rates for a single day - returns 24 records (one per hour)
    /// This endpoint works correctly for single days (no 2-day minimum bug)
    func fetchHourlyRates(date: Date) async -> [HourlyRate]? {
        guard let siteId = selectedSiteId, siteId > 0, !apiKey.isEmpty else {
            print("❌ hourly_rates: No site or API key")
            return nil
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()
        let dateStr = dateFormatter.string(from: date)
        
        let urlString = "\(baseURL)/api/hourly_rates/\(siteId)?start_date=\(dateStr)&end_date=\(dateStr)"
        guard let url = URL(string: urlString) else {
            print("❌ hourly_rates: Invalid URL")
            return nil
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        print("📊 Fetching hourly_rates: \(dateStr)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("❌ hourly_rates: Bad response")
                return nil
            }
            
            let decoded = try JSONDecoder().decode([HourlyRate].self, from: data)
            print("✅ hourly_rates: \(decoded.count) hours")
            return decoded
            
        } catch {
            print("❌ hourly_rates error: \(error)")
            return nil
        }
    }
    
    /// Fetch single-day summary using hourly_rates (accurate, no 2-day bug)
    func fetchHourlyDaySummary(date: Date) async -> HourlyDaySummary? {
        guard let hours = await fetchHourlyRates(date: date), !hours.isEmpty else {
            return nil
        }
        
        let totalImport = hours.reduce(0) { $0 + $1.totalEnergyImported }
        let totalExport = hours.reduce(0) { $0 + $1.totalEnergyExported }
        let totalEarnings = hours.reduce(0) { $0 + $1.totalEarnings } / 100.0
        let totalCosts = hours.reduce(0) { $0 + $1.totalCosts } / 100.0
        let fixedCosts = hours.reduce(0) { $0 + $1.hourlyCosts } / 100.0
        let netBill = hours.reduce(0) { $0 + $1.expectedBill } / 100.0
        let netProfit = -netBill  // Negate: positive expectedBill = cost
        
        return HourlyDaySummary(
            date: date,
            totalImport: totalImport,
            totalExport: totalExport,
            totalEarnings: totalEarnings,
            totalCosts: totalCosts,
            fixedCosts: fixedCosts,
            netProfit: netProfit
        )
    }
    
    // MARK: - Cumulative Subtraction for Daily Breakdown (with SQLite Cache)
    
    /// Fetch accurate daily breakdown using cumulative subtraction
    /// Now integrated with PowstonDataStore for persistent caching
    ///
    /// Cache strategy:
    /// - Check SQLite for each day first
    /// - Finalized days (>7 days old) are served from cache without API calls
    /// - Recent days are fetched from API and cached
    /// - For N missing days, requires N+1 API calls
    @MainActor
    func fetchDailyBreakdownCumulative(startDate: Date, endDate: Date) async -> [DailySummary] {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        guard let siteId = selectedSiteId, siteId > 0 else {
            print("❌ fetchDailyBreakdownCumulative: No site selected")
            return []
        }
        
        // Clamp to latest complete data for current/future dates
        let today = Date()
        let effectiveEnd: Date
        if endDate < calendar.startOfDay(for: today) {
            effectiveEnd = endDate
        } else {
            await refreshLatestCompleteDataDate()
            let maxDate = latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -1, to: today)!
            effectiveEnd = min(endDate, maxDate)
        }
        
        guard effectiveEnd >= startDate else { return [] }
        
        let daysInRange = calendar.dateComponents([.day], from: startDate, to: effectiveEnd).day! + 1
        guard daysInRange > 0 else { return [] }
        
        // Build list of all dates in range
        var allDates: [Date] = []
        for dayOffset in 0..<daysInRange {
            if let date = calendar.date(byAdding: .day, value: dayOffset, to: startDate) {
                allDates.append(date)
            }
        }
        
        // Check SQLite cache for existing data
        let dataStore = PowstonDataStore.shared
        var cachedSummaries: [Date: DailySummary] = [:]
        var missingDates: [Date] = []
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()
        
        for date in allDates {
            let dateStr = dateFormatter.string(from: date)
            let dayAge = calendar.dateComponents([.day], from: date, to: today).day ?? 0
            let isFinalized = dayAge > finalizationDays
            
            // Check if we have this day cached
            if let cached = dataStore.getDaySummaryLocal(siteId: siteId, date: dateStr) {
                // Use cached if finalized OR if it's recent but we have data
                if isFinalized || cached.isFinalized {
                    if let dailySummary = cached.toDailySummary() {
                        cachedSummaries[date] = dailySummary
                        continue
                    }
                }
            }
            
            // Need to fetch this day
            missingDates.append(date)
        }
        
        print("📊 Daily breakdown: \(cachedSummaries.count) cached, \(missingDates.count) to fetch")
        
        // If we have all data cached, return it
        if missingDates.isEmpty {
            return allDates.compactMap { cachedSummaries[$0] }
        }
        
        // Fetch missing days using cumulative subtraction
        let fetchedSummaries = await fetchMissingDaysViaCumulative(
            missingDates: missingDates,
            siteId: siteId,
            calendar: calendar
        )
        
        // Merge cached and fetched
        var allSummaries = cachedSummaries
        for (date, summary) in fetchedSummaries {
            allSummaries[date] = summary
        }
        
        // Return in date order
        return allDates.compactMap { allSummaries[$0] }
    }
    
    /// Fetch missing days via cumulative subtraction and save to SQLite
    @MainActor
    private func fetchMissingDaysViaCumulative(
        missingDates: [Date],
        siteId: Int,
        calendar: Calendar
    ) async -> [Date: DailySummary] {
        guard !missingDates.isEmpty else { return [:] }
        
        let sortedDates = missingDates.sorted()
        guard let firstDate = sortedDates.first,
              let anchorDate = calendar.date(byAdding: .day, value: -1, to: firstDate),
              let preAnchorDate = calendar.date(byAdding: .day, value: -1, to: anchorDate) else {
            return [:]
        }
        
        print("📊 Fetching \(sortedDates.count) days via cumulative subtraction...")
        
        let dataStore = PowstonDataStore.shared
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()
        
        // For efficiency, we'll fetch cumulative values for the entire range
        // This is (N+1) API calls for N days when fetching day-by-day
        // But we can optimize by checking if dates are contiguous
        
        // Fetch baseline (anchor cumulative)
        var baselineValue = CumulativeDayValues.zero
        if let baselineSummary = await fetchDayRateSummary(startDate: preAnchorDate, endDate: anchorDate) {
            baselineValue = CumulativeDayValues(
                expectedBill: baselineSummary.expectedBill,
                totalCosts: baselineSummary.totalCosts,
                rateCosts: baselineSummary.rateCosts,
                totalEarnings: baselineSummary.totalEarnings,
                totalEnergyImported: baselineSummary.totalEnergyImported,
                totalEnergyExported: baselineSummary.totalEnergyExported
            )
        }
        
        var results: [Date: DailySummary] = [:]
        var previousCumulative = baselineValue
        let today = Date()
        
        // Fetch each day's cumulative and subtract
        for date in sortedDates {
            guard let summary = await fetchDayRateSummary(startDate: anchorDate, endDate: date) else {
                continue
            }
            
            let cumulative = CumulativeDayValues(
                expectedBill: summary.expectedBill,
                totalCosts: summary.totalCosts,
                rateCosts: summary.rateCosts,
                totalEarnings: summary.totalEarnings,
                totalEnergyImported: summary.totalEnergyImported,
                totalEnergyExported: summary.totalEnergyExported
            )
            
            let dayValues = cumulative.subtracting(previousCumulative)
            let dailySummary = dayValues.toDailySummary(date: date)
            results[date] = dailySummary
            
            // Save to SQLite
            let dayAge = calendar.dateComponents([.day], from: date, to: today).day ?? 0
            let isFinalized = dayAge > finalizationDays
            
            let record = DaySummaryRecord(
                siteId: siteId,
                date: dateFormatter.string(from: date),
                expectedBill: dayValues.expectedBill,
                totalCosts: dayValues.totalCosts,
                totalEarnings: dayValues.totalEarnings,
                rateCosts: dayValues.rateCosts,
                rateEarnings: nil,
                dailyCosts: nil,
                energyImported: dayValues.totalEnergyImported,
                energyExported: dayValues.totalEnergyExported,
                batteryKwh: nil,
                buyRate: nil,
                sellRate: nil,
                recordCount: 1,
                isFinalized: isFinalized
            )
            
            dataStore.saveDaySummaryRecord(record)
            
            previousCumulative = cumulative
        }
        
        print("📊 Fetched and cached \(results.count) daily summaries")
        return results
    }
    
    /// Fetch weekly daily breakdown using cumulative subtraction (with SQLite cache)
    @MainActor
    func fetchWeekDailyBreakdownCumulative(containing date: Date) async -> [DailySummary] {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))!
        let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart)!
        
        return await fetchDailyBreakdownCumulative(startDate: weekStart, endDate: weekEnd)
    }
    
    /// Fetch monthly daily breakdown using cumulative subtraction (with SQLite cache)
    @MainActor
    func fetchMonthDailyBreakdownCumulative(year: Int, month: Int) async -> [DailySummary] {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonth) else {
            return []
        }
        
        return await fetchDailyBreakdownCumulative(startDate: monthStart, endDate: monthEnd)
    }
    
    // MARK: - Data Availability

    /// Check if a specific date has finalized data using day_rates as a reliable canary.
    /// The day_rates endpoint returns empty when data isn't ready, making it a reliable
    /// indicator of data finalization status.
    ///
    /// - Parameter date: The date to check
    /// - Returns: true if day_rates returns data for this date, false otherwise
    func isDayDataFinalized(date: Date) async -> Bool {
        guard let siteId = selectedSiteId, siteId > 0, !apiKey.isEmpty else {
            return false
        }

        // Use day_rates as the canary - it returns empty when data isn't finalized
        if let summary = await fetchDayRateSummary(siteId: siteId, startDate: date, endDate: date) {
            let hasData = summary.recordCount > 0
            print("📅 isDayDataFinalized(\(formatDateForLog(date))): \(hasData ? "✅ YES" : "❌ NO") - \(summary.recordCount) records")
            return hasData
        }

        print("📅 isDayDataFinalized(\(formatDateForLog(date))): ❌ NO - no response")
        return false
    }

    /// Format date for logging purposes
    private func formatDateForLog(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }

    /// Determine the latest date with finalized data.
    /// Checks yesterday first, falls back to day-before if needed.
    /// Uses day_rates as a reliable canary for data availability.
    func refreshLatestCompleteDataDate() async {
        if let lastCheck = lastDataAvailabilityCheck,
           Date().timeIntervalSince(lastCheck) < dataAvailabilityCheckInterval,
           latestCompleteDataDate != nil {
            return
        }

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        let dayBefore = calendar.date(byAdding: .day, value: -2, to: Date())!

        // Use day_rates as canary - it reliably returns empty when data isn't ready
        if await isDayDataFinalized(date: yesterday) {
            await MainActor.run {
                latestCompleteDataDate = yesterday
                lastDataAvailabilityCheck = Date()
            }
            print("📅 Latest complete data: yesterday")
            return
        }

        if await isDayDataFinalized(date: dayBefore) {
            await MainActor.run {
                latestCompleteDataDate = dayBefore
                lastDataAvailabilityCheck = Date()
            }
            print("📅 Latest complete data: day before yesterday")
            return
        }

        await MainActor.run {
            latestCompleteDataDate = dayBefore
            lastDataAvailabilityCheck = Date()
        }
        print("📅 Latest complete data: defaulting to day before yesterday")
    }

    /// Get the number of days ago that data is finalized for.
    /// Returns 1 for yesterday, 2 for day-before, etc.
    /// Uses cached latestCompleteDataDate if available, otherwise performs fresh check.
    func getDataLagDays() async -> Int {
        await refreshLatestCompleteDataDate()

        guard let completeDate = latestCompleteDataDate else {
            return 2  // Default to 2 days if unknown
        }

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let today = calendar.startOfDay(for: Date())
        let dataDay = calendar.startOfDay(for: completeDate)

        let components = calendar.dateComponents([.day], from: dataDay, to: today)
        return components.day ?? 2
    }
    
    func fetchDailyRates(siteId: Int, date: Date) async -> [DailyRate] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()
        let dateStr = dateFormatter.string(from: date)
        
        let urlString = "\(baseURL)/api/rates?start_date=\(dateStr)&end_date=\(dateStr)&direction=ASC&installer_id=0&site_id=\(siteId)&limit=100"
        
        guard let url = URL(string: urlString) else {
            print("❌ Invalid rates URL")
            return []
        }
        
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let rates = try JSONDecoder().decode([DailyRate].self, from: data)
            print("📊 Rates for \(dateStr): \(rates.count) records")
            return rates
        } catch {
            print("❌ Rates fetch error: \(error)")
            return []
        }
    }
    
    func hasMeterData(siteId: Int, date: Date) async -> Bool {
        let rates = await fetchDailyRates(siteId: siteId, date: date)
        return !rates.isEmpty
    }
    
    // MARK: - Convenience Methods: Single Periods
    
    func fetchLatestDaySummary() async -> DayRateSummary? {
        await refreshLatestCompleteDataDate()
        guard let date = latestCompleteDataDate else { return nil }
        return await fetchDayRateSummary(startDate: date, endDate: date)
    }
    
    func fetchDaySummary(date: Date) async -> DayRateSummary? {
        return await fetchDayRateSummary(startDate: date, endDate: date)
    }
    
    func fetchLastCompleteWeekSummary() async -> DayRateSummary? {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        let today = Date()
        let currentWeekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: today))!
        
        let lastWeekStart = calendar.date(byAdding: .day, value: -7, to: currentWeekStart)!
        let lastWeekEnd = calendar.date(byAdding: .day, value: 6, to: lastWeekStart)!
        
        return await fetchDayRateSummary(startDate: lastWeekStart, endDate: lastWeekEnd)
    }
    
    func fetchWeekSummary(containing date: Date) async -> DayRateSummary? {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))!
        let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart)!
        
        // Only clamp to latestCompleteDataDate for current week
        let today = Date()
        let effectiveEnd: Date
        if weekEnd < calendar.startOfDay(for: today) {
            // Historical week - use full range
            effectiveEnd = weekEnd
        } else {
            // Current week - clamp to latest complete data
            await refreshLatestCompleteDataDate()
            let maxDate = latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -1, to: today)!
            effectiveEnd = min(weekEnd, maxDate)
        }
        
        guard effectiveEnd >= weekStart else { return nil }
        
        return await fetchDayRateSummary(startDate: weekStart, endDate: effectiveEnd)
    }
    
    func fetchMonthSummary(year: Int, month: Int) async -> DayRateSummary? {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonth) else {
            return nil
        }
        
        let today = Date()
        let effectiveEnd: Date
        if calendar.isDate(monthStart, equalTo: today, toGranularity: .month) {
            await refreshLatestCompleteDataDate()
            effectiveEnd = latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -1, to: today)!
        } else {
            effectiveEnd = monthEnd
        }
        
        guard effectiveEnd >= monthStart else { return nil }
        
        return await fetchDayRateSummary(startDate: monthStart, endDate: effectiveEnd)
    }
    
    func fetchCurrentMonthSummary() async -> DayRateSummary? {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        let today = Date()
        let year = calendar.component(.year, from: today)
        let month = calendar.component(.month, from: today)
        
        return await fetchMonthSummary(year: year, month: month)
    }
    
    func fetchYearSummary(year: Int) async -> DayRateSummary? {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let yearEnd = calendar.date(from: DateComponents(year: year, month: 12, day: 31)) else {
            return nil
        }
        
        let today = Date()
        let effectiveEnd: Date
        if calendar.component(.year, from: today) == year {
            await refreshLatestCompleteDataDate()
            effectiveEnd = latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -1, to: today)!
        } else {
            effectiveEnd = yearEnd
        }
        
        guard effectiveEnd >= yearStart else { return nil }
        
        return await fetchDayRateSummary(startDate: yearStart, endDate: effectiveEnd)
    }
    
    // MARK: - Convenience Methods: Breakdowns (Legacy - uses buggy single-day queries)
    
    func fetchYearMonthlyBreakdown(year: Int) async -> [DayRateSummary] {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        let currentYear = calendar.component(.year, from: Date())
        let currentMonth = calendar.component(.month, from: Date())
        let maxMonth = (year == currentYear) ? currentMonth : 12
        
        var summaries: [DayRateSummary] = []
        
        for month in 1...maxMonth {
            if let summary = await fetchMonthSummary(year: year, month: month) {
                summaries.append(summary)
            }
        }
        
        return summaries
    }
    
    func fetchMonthDailyBreakdown(year: Int, month: Int) async -> [DayRateSummary] {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let monthEnd = calendar.date(byAdding: .day, value: -1, to: nextMonth) else {
            return []
        }
        
        // Only clamp to latestCompleteDataDate for current month
        let today = Date()
        let effectiveEnd: Date
        if monthEnd < calendar.startOfDay(for: today) {
            // Historical month - use full range
            effectiveEnd = monthEnd
        } else {
            // Current month - clamp to latest complete data
            await refreshLatestCompleteDataDate()
            effectiveEnd = latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -1, to: today)!
        }
        
        guard effectiveEnd >= monthStart else { return [] }
        
        let daysInRange = calendar.dateComponents([.day], from: monthStart, to: effectiveEnd).day! + 1
        var summaries: [DayRateSummary] = []
        
        for dayOffset in 0..<daysInRange {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: monthStart) else { continue }
            if let summary = await fetchDaySummary(date: date) {
                summaries.append(summary)
            }
        }
        
        return summaries
    }
    
    func fetchWeekDailyBreakdown(containing date: Date) async -> [DayRateSummary] {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date))!
        let weekEnd = calendar.date(byAdding: .day, value: 6, to: weekStart)!
        
        // Only clamp to latestCompleteDataDate for current week
        let today = Date()
        let effectiveEnd: Date
        if weekEnd < calendar.startOfDay(for: today) {
            // Historical week - use full range
            effectiveEnd = weekEnd
        } else {
            // Current week - clamp to latest complete data
            await refreshLatestCompleteDataDate()
            let maxDate = latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -1, to: today)!
            effectiveEnd = min(weekEnd, maxDate)
        }
        
        guard effectiveEnd >= weekStart else { return [] }
        
        let daysInRange = calendar.dateComponents([.day], from: weekStart, to: effectiveEnd).day! + 1
        var summaries: [DayRateSummary] = []
        
        for dayOffset in 0..<daysInRange {
            guard let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else { continue }
            if let summary = await fetchDaySummary(date: date) {
                summaries.append(summary)
            }
        }
        
        return summaries
    }
    
    // MARK: - Custom Range
    
    func fetchCustomRangeSummary(startDate: Date, endDate: Date) async -> DayRateSummary? {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        // Only clamp to latestCompleteDataDate if range extends to today or future
        let today = Date()
        let effectiveEnd: Date
        if endDate < calendar.startOfDay(for: today) {
            // Historical range - use full range
            effectiveEnd = endDate
        } else {
            // Range includes today - clamp to latest complete data
            await refreshLatestCompleteDataDate()
            let maxDate = latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -1, to: today)!
            effectiveEnd = min(endDate, maxDate)
        }
        
        guard effectiveEnd >= startDate else {
            print("⚠️ Custom range: end date before start date")
            return nil
        }
        
        return await fetchDayRateSummary(startDate: startDate, endDate: effectiveEnd)
    }
}

// MARK: - PowstonDataStore Extension for Local Queries

extension PowstonDataStore {
    /// Get a single day summary from local SQLite (no API call)
    /// Used by PowstonAPI to check cache before fetching
    func getDaySummaryLocal(siteId: Int, date: String) -> DaySummaryRecord? {
        guard let db = dbQueue else { return nil }
        
        do {
            return try db.read { db in
                try DaySummaryRecord.fetchOne(
                    db,
                    sql: "SELECT * FROM day_summaries WHERE site_id = ? AND date = ?",
                    arguments: [siteId, date]
                )
            }
        } catch {
            print("❌ getDaySummaryLocal failed: \(error)")
            return nil
        }
    }
    
    /// Save a day summary record to SQLite
    /// Called by PowstonAPI after fetching from network
    func saveDaySummaryRecord(_ record: DaySummaryRecord) {
        guard let db = dbQueue else { return }
        
        var mutableRecord = record
        mutableRecord.updatedAt = Date()
        
        do {
            try db.write { db in
                try mutableRecord.save(db, onConflict: .replace)
            }
            print("💾 Saved day summary: \(record.date)")
        } catch {
            print("❌ saveDaySummaryRecord failed: \(error)")
        }
    }
}
