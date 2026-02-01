//
//  PeerPowerResult.swift
//  Powston
//
//  Created by Rick Bollar on 1/28/26.
//


//
//  PeerPowerAnalysis.swift
//  Powston
//
//  Analyzes peak export windows to identify P2P trading opportunities.
//  Compares actual spot sell prices vs what buyers paid to find the spread
//  where a P2P offer would benefit both parties.
//

import Foundation
import SwiftUI
import GRDB
import Combine

// MARK: - Result Types

struct PeerPowerResult: Codable {
    let analysisDate: Date
    let periodDays: Int
    
    // Peak window config
    let peakStartHour: Int
    let peakEndHour: Int
    
    // Export totals during peak
    let totalPeakExportKwh: Double
    let totalPeakExportRevenue: Double    // Dollars - what you actually earned
    let totalPeakIntervals: Int
    let intervalsWithExport: Int
    
    // Spread analysis (aggregate)
    let avgBuyPrice: Double               // What buyers paid (c/kWh)
    let avgSellPrice: Double              // What you received (c/kWh)
    let avgSpread: Double                 // Buyer - Seller gap
    
    // Scenarios at different P2P offer prices
    let scenarios: [P2PPriceScenario]
    
    // Hourly breakdown within peak
    let hourlyBreakdown: [P2PHourlyBreakdown]
    
    // Recommendation
    let recommendedPrice: Double
    let maxOpportunityDollars: Double
    let winWinPercent: Double
}

struct P2PPriceScenario: Codable, Identifiable {
    var id: Double { offerPrice }
    
    let offerPrice: Double                // P2P offer in c/kWh
    let eligibleIntervals: Int            // Where offer > spot AND offer < buyer
    let eligibleKwh: Double
    let additionalRevenue: Double         // Dollars vs actual spot earnings
    let winWinPercent: Double             // % of peak exports eligible
    let avgYourGain: Double               // Avg c/kWh above spot sell
    let avgBuyerSaving: Double            // Avg c/kWh below buyer price
}

struct P2PHourlyBreakdown: Codable, Identifiable, Equatable {
    var id: Int { hour }
    
    let hour: Int                         // 16, 17, 18, etc.
    let intervalCount: Int
    let exportKwh: Double
    let avgBuyPrice: Double
    let avgSellPrice: Double
    let avgSpread: Double
    let bestOfferPrice: Double            // Sweet spot for this hour
    let opportunityDollars: Double        // At best offer price
    let winWinPercent: Double             // % eligible at best offer
}

// Internal working struct
private struct P2PIntervalDetail {
    let timestamp: Date
    let hour: Int
    let exportKwh: Double
    let spotSellPrice: Double
    let buyerPrice: Double
    let spread: Double
    let actualEarnings: Double            // cents
}

// MARK: - Analysis Engine

@MainActor
class PeerPowerAnalysis: ObservableObject {
    @Published var result: PeerPowerResult?
    @Published var isAnalyzing = false
    @Published var progress: String = ""
    @Published var error: String?
    
    private let cacheKey = "peer_power_cache"
    
    // Test prices from 20¢ to 70¢
    private let testPrices: [Double] = [20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70]
    
    // MARK: - Run Analysis

    func runAnalysis(api: PowstonAPI, config: AnalysisConfig) async {
        guard !isAnalyzing else { return }
        isAnalyzing = true
        error = nil
        progress = "Loading data..."
        
        defer { isAnalyzing = false }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        // Date range: 60 days ending at last complete day
        let todayStart = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let latestComplete = api.latestCompleteDataDate ?? yesterday
        let endDate = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: latestComplete) ?? latestComplete)
        
        guard let startDate = calendar.date(byAdding: .day, value: -60, to: endDate) else {
            error = "Failed to calculate date range"
            return
        }
        
        let siteId = config.siteId
        let dataStore = PowstonDataStore.shared
        
        // Get peak hours from settings
        let peakStart = UserDefaults.standard.integer(forKey: "peak_start_hour")
        let peakEnd = UserDefaults.standard.integer(forKey: "peak_end_hour")
        let peakStartHour = peakStart > 0 ? peakStart : 16
        let peakEndHour = peakEnd > 0 ? peakEnd : 21
        
        progress = "Loading meter records..."
        
        // Load meter records and convert to MeterRecord for effectiveExport
        let dbRecords = dataStore.getMeterRecordsLocal(siteId: siteId, from: startDate, to: endDate)
        let meterRecords = dbRecords.map { $0.toMeterRecord() }
        
        progress = "Loading price data..."
        
        // Load action records for buy/sell prices
        let actions = dataStore.fetchActions(siteId: siteId, from: startDate, to: endDate)
        
        // Build price lookup by interval time (using Date key)
        var pricesByInterval: [Date: (buy: Double, sell: Double)] = [:]
        for action in actions {
            if let buy = action.buyPrice, let sell = action.sellPrice {
                pricesByInterval[action.intervalTime] = (buy: buy, sell: sell)
            }
        }
        
        progress = "Analyzing peak exports..."
        
        // Filter to peak hours with exports and prices
        var intervals: [P2PIntervalDetail] = []
        
        for record in meterRecords {
            guard let recordDate = record.date else { continue }
            
            let hour = calendar.component(.hour, from: recordDate)
            
            guard hour >= peakStartHour && hour < peakEndHour else { continue }
            
            // Use effectiveExport for correct kWh value
            let exportKwh = record.effectiveExport
            guard exportKwh > 0.001 else { continue }
            
            // Get prices for this interval
            guard let prices = pricesByInterval[recordDate] else { continue }
            
            let spread = prices.buy - prices.sell
            let actualEarnings = exportKwh * prices.sell
            
            intervals.append(P2PIntervalDetail(
                timestamp: recordDate,
                hour: hour,
                exportKwh: exportKwh,
                spotSellPrice: prices.sell,
                buyerPrice: prices.buy,
                spread: spread,
                actualEarnings: actualEarnings
            ))
        }
        
        guard !intervals.isEmpty else {
            error = "No peak export data with pricing found"
            return
        }
        
        progress = "Calculating scenarios..."
        
        // Aggregate totals
        let totalExportKwh = intervals.reduce(0) { $0 + $1.exportKwh }
        let totalEarnings = intervals.reduce(0) { $0 + $1.actualEarnings }
        let avgBuy = intervals.reduce(0) { $0 + $1.buyerPrice } / Double(intervals.count)
        let avgSell = intervals.reduce(0) { $0 + $1.spotSellPrice } / Double(intervals.count)
        let avgSpread = avgBuy - avgSell
        
        // Calculate scenarios for each test price
        let scenarios = calculateScenarios(intervals: intervals)
        
        progress = "Analyzing hourly patterns..."
        
        // Calculate hourly breakdown
        let hourlyBreakdown = calculateHourlyBreakdown(
            intervals: intervals,
            peakStartHour: peakStartHour,
            peakEndHour: peakEndHour
        )
        
        // Find recommended price
        let recommended = scenarios.max(by: {
            ($0.additionalRevenue * $0.winWinPercent) < ($1.additionalRevenue * $1.winWinPercent)
        })
        
        let periodDays = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 60
        
        // Count total peak intervals (including those without export)
        let totalPeakIntervals = meterRecords.filter { record in
            guard let recordDate = record.date else { return false }
            let hour = calendar.component(.hour, from: recordDate)
            return hour >= peakStartHour && hour < peakEndHour
        }.count
        
        result = PeerPowerResult(
            analysisDate: Date(),
            periodDays: periodDays,
            peakStartHour: peakStartHour,
            peakEndHour: peakEndHour,
            totalPeakExportKwh: totalExportKwh,
            totalPeakExportRevenue: totalEarnings / 100,
            totalPeakIntervals: totalPeakIntervals,
            intervalsWithExport: intervals.count,
            avgBuyPrice: avgBuy,
            avgSellPrice: avgSell,
            avgSpread: avgSpread,
            scenarios: scenarios,
            hourlyBreakdown: hourlyBreakdown,
            recommendedPrice: recommended?.offerPrice ?? 45,
            maxOpportunityDollars: scenarios.map { $0.additionalRevenue }.max() ?? 0,
            winWinPercent: recommended?.winWinPercent ?? 0
        )
        
        cacheResult(result!, config: config)
        progress = "Complete"
    }
    
    // MARK: - Scenario Calculation
    
    private func calculateScenarios(intervals: [P2PIntervalDetail]) -> [P2PPriceScenario] {
        var scenarios: [P2PPriceScenario] = []
        
        for offerPrice in testPrices {
            var eligibleCount = 0
            var eligibleKwh: Double = 0
            var additionalRevenue: Double = 0
            var totalYourGain: Double = 0
            var totalBuyerSaving: Double = 0
            
            for interval in intervals {
                let yourGain = offerPrice - interval.spotSellPrice
                let buyerSaving = interval.buyerPrice - offerPrice
                
                // Win-win: you beat spot, buyer beats grid
                if yourGain > 0 && buyerSaving > 0 {
                    eligibleCount += 1
                    eligibleKwh += interval.exportKwh
                    additionalRevenue += interval.exportKwh * yourGain
                    totalYourGain += yourGain
                    totalBuyerSaving += buyerSaving
                }
            }
            
            let winWinPct = Double(eligibleCount) / Double(intervals.count) * 100
            let avgGain = eligibleCount > 0 ? totalYourGain / Double(eligibleCount) : 0
            let avgSaving = eligibleCount > 0 ? totalBuyerSaving / Double(eligibleCount) : 0
            
            scenarios.append(P2PPriceScenario(
                offerPrice: offerPrice,
                eligibleIntervals: eligibleCount,
                eligibleKwh: eligibleKwh,
                additionalRevenue: additionalRevenue / 100,
                winWinPercent: winWinPct,
                avgYourGain: avgGain,
                avgBuyerSaving: avgSaving
            ))
        }
        
        return scenarios
    }
    
    // MARK: - Hourly Breakdown
    
    private func calculateHourlyBreakdown(
        intervals: [P2PIntervalDetail],
        peakStartHour: Int,
        peakEndHour: Int
    ) -> [P2PHourlyBreakdown] {
        
        var breakdown: [P2PHourlyBreakdown] = []
        
        for hour in peakStartHour..<peakEndHour {
            let hourIntervals = intervals.filter { $0.hour == hour }
            
            guard !hourIntervals.isEmpty else {
                // Include empty hours for completeness
                breakdown.append(P2PHourlyBreakdown(
                    hour: hour,
                    intervalCount: 0,
                    exportKwh: 0,
                    avgBuyPrice: 0,
                    avgSellPrice: 0,
                    avgSpread: 0,
                    bestOfferPrice: 0,
                    opportunityDollars: 0,
                    winWinPercent: 0
                ))
                continue
            }
            
            let exportKwh = hourIntervals.reduce(0) { $0 + $1.exportKwh }
            let avgBuy = hourIntervals.reduce(0) { $0 + $1.buyerPrice } / Double(hourIntervals.count)
            let avgSell = hourIntervals.reduce(0) { $0 + $1.spotSellPrice } / Double(hourIntervals.count)
            let avgSpread = avgBuy - avgSell
            
            // Find best offer price for this hour
            var bestPrice: Double = 0
            var bestRevenue: Double = 0
            var bestWinWin: Double = 0
            
            for offerPrice in testPrices {
                var revenue: Double = 0
                var eligible = 0
                
                for interval in hourIntervals {
                    let yourGain = offerPrice - interval.spotSellPrice
                    let buyerSaving = interval.buyerPrice - offerPrice
                    
                    if yourGain > 0 && buyerSaving > 0 {
                        revenue += interval.exportKwh * yourGain
                        eligible += 1
                    }
                }
                
                let winWin = Double(eligible) / Double(hourIntervals.count) * 100
                let score = revenue * winWin
                
                if score > bestRevenue * bestWinWin {
                    bestPrice = offerPrice
                    bestRevenue = revenue / 100
                    bestWinWin = winWin
                }
            }
            
            breakdown.append(P2PHourlyBreakdown(
                hour: hour,
                intervalCount: hourIntervals.count,
                exportKwh: exportKwh,
                avgBuyPrice: avgBuy,
                avgSellPrice: avgSell,
                avgSpread: avgSpread,
                bestOfferPrice: bestPrice,
                opportunityDollars: bestRevenue,
                winWinPercent: bestWinWin
            ))
        }
        
        return breakdown
    }
    
    // MARK: - Caching
    
    func getCachedResult(config: AnalysisConfig) -> PeerPowerResult? {
        let key = "\(cacheKey)_\(config.siteId)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(PeerPowerResult.self, from: data) else {
            return nil
        }
        
        let age = Date().timeIntervalSince(cached.analysisDate)
        guard age < 24 * 3600 else { return nil }
        
        return cached
    }
    
    private func cacheResult(_ result: PeerPowerResult, config: AnalysisConfig) {
        let key = "\(cacheKey)_\(config.siteId)"
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
    
    func clearCache(config: AnalysisConfig) {
        let key = "\(cacheKey)_\(config.siteId)"
        UserDefaults.standard.removeObject(forKey: key)
    }
}
