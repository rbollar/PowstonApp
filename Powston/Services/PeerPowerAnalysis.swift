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
import Combine
import GRDB

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
    
    // Hourly breakdown within peak (at recommended price)
    let hourlyBreakdown: [P2PHourlyBreakdown]
    
    // Actionable recommendation
    let recommendation: P2PRecommendation

    // 7-day tiered contract recommendation
    let tieredRecommendation: P2PTieredRecommendation?

    // Legacy computed properties (for teaser card compatibility)
    var recommendedPrice: Double { recommendation.offerPrice }
    var maxOpportunityDollars: Double { recommendation.monthlyExtraRevenue }
    var winWinPercent: Double { recommendation.winWinPercent }
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
    
    let hour: Int
    let intervalCount: Int
    let exportKwh: Double
    let avgBuyPrice: Double
    let avgSellPrice: Double
    let avgSpread: Double
    
    // At recommended price
    let dailyKwh: Double                     // avg kWh/day this hour
    let dailyExtraAtRecommended: Double      // $/day at recommended price
    let winWinAtRecommended: Double          // % win-win at recommended price
}

struct P2PRecommendation: Codable {
    let offerPrice: Double           // c/kWh
    let startHour: Int               // e.g., 17 (5pm)
    let endHour: Int                 // e.g., 20 (8pm) - exclusive
    let dailyKwh: Double             // avg kWh/day in that window
    let dailyExtraRevenue: Double    // $/day above spot
    let monthlyExtraRevenue: Double  // $/month projection
    let winWinPercent: Double        // coverage at this price/window
}

// MARK: - Tiered Contract Recommendation

struct P2PTieredRecommendation: Codable {
    let weeklyTotalKwh: Double           // Total kWh for the week
    let weeklyEstimatedRevenue: Double   // Estimated $ for the week
    let startHour: Int
    let endHour: Int
    let tiers: [P2PRecommendedTier]

    // System constraints used
    let batteryCapacityKwh: Double
    let inverterExportKw: Double
    let maxDailyExportKwh: Double        // What system can physically export/day
    let lvContractLimitKwh: Double?      // LocalVolts contract limit from recent history

    // Overnight load and effective exportable capacity
    let overnightLoadKwh: Double         // Avg nightly consumption (9pm-6am)
    let effectiveExportableKwh: Double   // Battery minus overnight load

    // Win-win filtered window
    let filteredStartHour: Int           // Actual start after win-win filtering
    let filteredEndHour: Int             // Actual end after win-win filtering
    let excludedHours: [Int]             // Hours excluded due to low win-win (<50%)
    let winWinThreshold: Double          // Threshold used (default 50%)

    // P2P contract execution requirements
    let requiredExportRateKw: Double     // kW needed to fulfill contract each interval
    let windowHours: Int                 // Number of hours in window
    let systemCanSustain: Bool           // Whether system can sustain required rate
    let effectiveWindowWarning: String?  // Warning if window doesn't match capability

    // Historical contract performance incorporated
    let contractsAnalyzed: Int           // Number of past contracts used
    let hasHistoricalData: Bool          // Whether real P2P data informed this
    let tradesAnalyzed: Int              // Number of actual trades analyzed for pricing
    let forecastTradesIncluded: Int      // Forward contract trades included (weighted 2x)
    let outlierTradesExcluded: Int       // Trades excluded as bad pricing (below spot)

    // Comparison to previous contract
    let previousContract: P2PPreviousContractSummary?
    let recommendationChanged: Bool
    let changeReason: String?

    // Renewal scheduling
    let renewalDueDate: Date?            // When next contract should be scheduled
    let daysUntilRenewal: Int?           // Days until renewal deadline (6+ required)
    let renewalUrgency: RenewalUrgency

    // Validation against win-win analysis
    let singlePriceRecommendation: Double?  // From win-win analysis for comparison
    let recommendationDivergence: String?   // Explanation if tiered differs from single-price

    var blendedPriceCents: Double {
        guard weeklyTotalKwh > 0 else { return 0 }
        return (weeklyEstimatedRevenue / weeklyTotalKwh) * 100
    }

    /// Effective window hours after win-win filtering
    var effectiveWindowHours: Int {
        filteredEndHour - filteredStartHour
    }

    /// Scale weekly values to an arbitrary contract period
    func scaled(toDays days: Int) -> (totalKwh: Double, estimatedRevenue: Double, multiplier: Double) {
        let multiplier = Double(days) / 7.0
        return (
            totalKwh: weeklyTotalKwh * multiplier,
            estimatedRevenue: weeklyEstimatedRevenue * multiplier,
            multiplier: multiplier
        )
    }
}

/// Summary of the previous/current contract for comparison
struct P2PPreviousContractSummary: Codable {
    let tierPrices: [Double]             // Price points from previous contract
    let totalKwh: Double
    let blendedPrice: Double
    let endDate: Date
}

/// How urgent is the renewal scheduling
enum RenewalUrgency: String, Codable {
    case none = "None"                   // No active contract or far out
    case upcoming = "Upcoming"           // 6-14 days out - good time to schedule
    case urgent = "Urgent"               // <6 days - may miss ideal booking window
    case overdue = "Overdue"             // Contract ended, no renewal scheduled
}

struct P2PRecommendedTier: Codable, Identifiable {
    var id: Double { priceCents }

    let priceCents: Double               // Offer price (data-driven from clusters)
    let percentage: Double               // % of total allocation (for LV entry)
    let weeklyKwh: Double                // kWh allocated to this tier
    let weeklyRevenue: Double            // Expected $ from this tier
    let winWinPercent: Double            // Theoretical win-win from spread analysis
    let avgYourGainCents: Double         // Avg gain above spot
    let avgBuyerSavingCents: Double      // Avg buyer saves vs grid
    let confidence: TierConfidence       // Based on historical data
    let historicalFillRate: Double?      // Actual fill rate from past contracts (nil if no data)
    let historicalVolumeKwh: Double      // Total kWh traded at this price cluster
    let basedOnTrades: Int               // Number of actual trades at this price point
}

enum TierConfidence: String, Codable {
    case high = "High"       // >70% historical fill OR win-win
    case medium = "Medium"   // 50-70%
    case low = "Low"         // <50%
    case proven = "Proven"   // Based on actual trade history
}

// MARK: - Buyer Analysis Types

/// Result of buyer-side P2P analysis
struct P2PBuyerResult: Codable {
    let analysisDate: Date
    let periodDays: Int

    // Import window config
    let importStartHour: Int
    let importEndHour: Int

    // Import totals during window
    let totalImportKwh: Double
    let totalImportCost: Double           // Dollars - what you actually paid
    let totalImportIntervals: Int
    let intervalsWithImport: Int

    // Price analysis
    let avgGridPrice: Double              // What you paid to grid (c/kWh)
    let avgSpotPrice: Double              // Spot price during imports (c/kWh)

    // Hedge metrics - protection against price spikes
    let maxSpotPrice: Double              // Worst spike observed (c/kWh)
    let p25SpotPrice: Double              // 25th percentile
    let p50SpotPrice: Double              // Median
    let p75SpotPrice: Double              // 75th percentile
    let spikeIntervals: Int               // Intervals where spot > 15¢
    let spikePercent: Double              // % of intervals with spikes

    // Scenarios at different price caps
    let scenarios: [P2PBuyPriceScenario]

    // Hourly breakdown within window
    let hourlyBreakdown: [P2PBuyHourlyBreakdown]

    // Actionable recommendation
    let recommendation: P2PBuyRecommendation

    // Tiered contract recommendation for hedging
    let tieredRecommendation: P2PBuyTieredRecommendation?
}

/// Scenario for a given buy price cap
struct P2PBuyPriceScenario: Codable, Identifiable {
    var id: Double { priceCap }

    let priceCap: Double                  // Max P2P price willing to pay (c/kWh)
    let expectedFillRate: Double          // % of imports expected from P2P
    let expectedP2PKwh: Double            // kWh expected from P2P at this cap
    let expectedSpotKwh: Double           // kWh expected from spot (unfilled)
    let avgP2PPrice: Double               // Expected avg P2P price at this cap
    let expectedP2PCost: Double           // $ for P2P portion
    let expectedSpotCost: Double          // $ for spot portion
    let totalCost: Double                 // Total $ at this cap
    let effectivePrice: Double            // Blended c/kWh
    let savingsVsGrid: Double             // $ saved vs all-grid baseline
    let savingsVsSpot: Double             // $ saved vs all-spot baseline
}

/// Hourly breakdown of imports
struct P2PBuyHourlyBreakdown: Codable, Identifiable {
    var id: Int { hour }

    let hour: Int
    let intervalCount: Int
    let importKwh: Double
    let avgGridPrice: Double              // What grid would charge
    let avgSpotPrice: Double              // What spot charged
    let dailyKwh: Double                  // avg kWh/day this hour
}

/// Recommended buy strategy
struct P2PBuyRecommendation: Codable {
    let priceCap: Double                  // Recommended max price (c/kWh)
    let startHour: Int                    // e.g., 11 (11am)
    let endHour: Int                      // e.g., 16 (4pm) - exclusive
    let weeklyBudgetKwh: Double           // Recommended weekly buy allocation
    let expectedFillRate: Double          // Expected % from P2P
    let expectedSavings: Double           // $/week vs grid
    let rationale: String                 // Why this recommendation
}

/// Tiered buy contract recommendation for hedging
struct P2PBuyTieredRecommendation: Codable {
    let startHour: Int                    // Contract window start
    let endHour: Int                      // Contract window end (exclusive)
    let windowRationale: String           // Why this window

    let tiers: [P2PBuyTier]               // Price tiers from 0¢ up
    let totalWeeklyKwh: Double            // Total commitment
    let minDailyImportKwh: Double         // Minimum daily import observed (basis for commitment)
    let avgDailyImportKwh: Double         // Average daily import in window

    let expectedFillRate: Double          // Overall expected fill %
    let expectedWeeklyCost: Double        // $ expected to pay
    let hedgeValue: Double                // $ saved if max spike occurs
    let maxSpikeProtection: Double        // Max spike price we're protected against
}

/// Individual tier in buy contract
struct P2PBuyTier: Codable, Identifiable {
    var id: Double { priceCents }

    let priceCents: Double                // Price cap for this tier
    let percentage: Double                // % of total allocation
    let weeklyKwh: Double                 // kWh for this tier
    let expectedFillRate: Double          // Expected fill at this price
    let expectedCost: Double              // $ expected for this tier
}

/// Represents a price cluster derived from actual trade data
private struct PriceCluster {
    let centerPrice: Double              // Cluster center (rounded to nearest cent)
    let minPrice: Double
    let maxPrice: Double
    let totalVolumeKwh: Double
    let tradeCount: Int
    let avgFillRate: Double?             // From contract performance if available
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

// Internal working struct for buyer analysis
private struct P2PImportIntervalDetail {
    let timestamp: Date
    let hour: Int
    let importKwh: Double
    let spotPrice: Double       // What spot charged
    let gridPrice: Double       // What grid would charge (often same as spot for imports)
    let actualCost: Double      // cents paid
}

// MARK: - Analysis Engine

@MainActor
class PeerPowerAnalysis: ObservableObject {
    @Published var result: PeerPowerResult?
    @Published var buyerResult: P2PBuyerResult?
    @Published var isAnalyzing = false
    @Published var isAnalyzingBuyer = false
    @Published var progress: String = ""
    @Published var error: String?
    @Published var buyerError: String?

    private let cacheKey = "peer_power_cache"
    private let buyerCacheKey = "peer_power_buyer_cache"

    // Test prices from 15¢ to 50¢ in 1¢ increments (displayed in UI)
    private let testPrices: [Double] = Array(stride(from: 15.0, through: 50.0, by: 1.0))

    // Fine-grained prices for internal analysis (1¢ increments)
    private let fineGrainedPrices: [Double] = Array(stride(from: 15.0, through: 50.0, by: 1.0))
    
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
        let avgBuy = totalExportKwh > 0
            ? intervals.reduce(0) { $0 + $1.buyerPrice * $1.exportKwh } / totalExportKwh
            : intervals.reduce(0) { $0 + $1.buyerPrice } / Double(max(1, intervals.count))
        let avgSell = totalExportKwh > 0
            ? intervals.reduce(0) { $0 + $1.spotSellPrice * $1.exportKwh } / totalExportKwh
            : intervals.reduce(0) { $0 + $1.spotSellPrice } / Double(max(1, intervals.count))
        let avgSpread = avgBuy - avgSell

        let periodDays = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 60

        // Calculate scenarios for each test price
        let scenarios = calculateScenarios(intervals: intervals)
        
        progress = "Finding best trade window..."
        
        // Calculate actionable recommendation (needs to come before hourly so we have the price)
        let recommendation = calculateRecommendation(
            intervals: intervals,
            peakStartHour: peakStartHour,
            peakEndHour: peakEndHour,
            periodDays: periodDays
        )
        
        progress = "Analyzing hourly patterns..."
        
        // Calculate hourly breakdown at the recommended price
        let hourlyBreakdown = calculateHourlyBreakdown(
            intervals: intervals,
            peakStartHour: peakStartHour,
            peakEndHour: peakEndHour,
            periodDays: periodDays,
            recommendedPrice: recommendation.offerPrice
        )
        
        // Count total peak intervals
        let totalPeakIntervals = meterRecords.filter { record in
            guard let recordDate = record.date else { return false }
            let hour = calendar.component(.hour, from: recordDate)
            return hour >= peakStartHour && hour < peakEndHour
        }.count

        progress = "Building tiered recommendation...\nAnalyzing overnight load & trade history"

        // Calculate 7-day tiered contract recommendation
        let tieredRecommendation = calculateTieredRecommendation(
            scenarios: scenarios,
            intervals: intervals,
            periodDays: periodDays,
            peakStartHour: peakStartHour,
            peakEndHour: peakEndHour,
            config: config,
            hourlyBreakdown: hourlyBreakdown
        )

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
            recommendation: recommendation,
            tieredRecommendation: tieredRecommendation
        )

        cacheResult(result!, config: config)
        progress = "Complete"
    }

    // MARK: - Buyer Analysis

    /// Run buyer-side P2P analysis to find optimal buy price cap
    func runBuyerAnalysis(api: PowstonAPI, config: AnalysisConfig) async {
        guard !isAnalyzingBuyer else { return }
        isAnalyzingBuyer = true
        buyerError = nil
        progress = "Loading import data..."

        defer { isAnalyzingBuyer = false }

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        // Date range: 60 days ending at last complete day
        let todayStart = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let latestComplete = api.latestCompleteDataDate ?? yesterday
        let endDate = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: latestComplete) ?? latestComplete)

        guard let startDate = calendar.date(byAdding: .day, value: -60, to: endDate) else {
            buyerError = "Failed to calculate date range"
            return
        }

        let siteId = config.siteId
        let dataStore = PowstonDataStore.shared

        // Get import hours from settings (default to solar hours 10am-4pm)
        let importStart = UserDefaults.standard.integer(forKey: "import_start_hour")
        let importEnd = UserDefaults.standard.integer(forKey: "import_end_hour")
        let importStartHour = importStart > 0 ? importStart : 10
        let importEndHour = importEnd > 0 ? importEnd : 16

        progress = "Loading meter records..."

        // Load meter records
        let dbRecords = dataStore.getMeterRecordsLocal(siteId: siteId, from: startDate, to: endDate)
        let meterRecords = dbRecords.map { $0.toMeterRecord() }

        progress = "Loading price data..."

        // Load action records for buy prices
        let actions = dataStore.fetchActions(siteId: siteId, from: startDate, to: endDate)

        // Build price lookup by interval time
        var pricesByInterval: [Date: (buy: Double, sell: Double)] = [:]
        for action in actions {
            if let buy = action.buyPrice, let sell = action.sellPrice {
                pricesByInterval[action.intervalTime] = (buy: buy, sell: sell)
            }
        }

        progress = "Analyzing imports..."

        // Filter to import hours with imports and prices
        var intervals: [P2PImportIntervalDetail] = []

        for record in meterRecords {
            guard let recordDate = record.date else { continue }

            let hour = calendar.component(.hour, from: recordDate)

            guard hour >= importStartHour && hour < importEndHour else { continue }

            // Use effectiveImport for correct kWh value
            let importKwh = record.effectiveImport
            guard importKwh > 0.001 else { continue }

            // Get prices for this interval
            guard let prices = pricesByInterval[recordDate] else { continue }

            // For imports, grid price = buy price (what you pay)
            // Spot price approximated by sell price (market clearing price)
            let gridPrice = prices.buy
            let spotPrice = prices.sell  // Use sell as proxy for spot
            let actualCost = importKwh * gridPrice

            intervals.append(P2PImportIntervalDetail(
                timestamp: recordDate,
                hour: hour,
                importKwh: importKwh,
                spotPrice: spotPrice,
                gridPrice: gridPrice,
                actualCost: actualCost
            ))
        }

        guard !intervals.isEmpty else {
            buyerError = "No import data with pricing found in window"
            return
        }

        progress = "Calculating buy scenarios..."

        // Aggregate totals
        let totalImportKwh = intervals.reduce(0) { $0 + $1.importKwh }
        let totalCost = intervals.reduce(0) { $0 + $1.actualCost }
        let avgGridPrice = totalImportKwh > 0
            ? intervals.reduce(0) { $0 + $1.gridPrice * $1.importKwh } / totalImportKwh
            : intervals.reduce(0) { $0 + $1.gridPrice } / Double(max(1, intervals.count))
        let avgSpotPrice = totalImportKwh > 0
            ? intervals.reduce(0) { $0 + $1.spotPrice * $1.importKwh } / totalImportKwh
            : intervals.reduce(0) { $0 + $1.spotPrice } / Double(max(1, intervals.count))

        let periodDays = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 60

        // Calculate scenarios for different price caps
        let scenarios = calculateBuyerScenarios(
            intervals: intervals,
            avgSpotPrice: avgSpotPrice,
            avgGridPrice: avgGridPrice
        )

        progress = "Analyzing hourly patterns..."

        // Calculate hourly breakdown
        let hourlyBreakdown = calculateBuyerHourlyBreakdown(
            intervals: intervals,
            importStartHour: importStartHour,
            importEndHour: importEndHour,
            periodDays: periodDays
        )

        progress = "Building recommendation..."

        // Calculate recommendation
        let recommendation = calculateBuyerRecommendation(
            scenarios: scenarios,
            intervals: intervals,
            avgSpotPrice: avgSpotPrice,
            avgGridPrice: avgGridPrice,
            importStartHour: importStartHour,
            importEndHour: importEndHour,
            periodDays: periodDays
        )

        // Count total import intervals
        let totalImportIntervals = meterRecords.filter { record in
            guard let recordDate = record.date else { return false }
            let hour = calendar.component(.hour, from: recordDate)
            return hour >= importStartHour && hour < importEndHour
        }.count

        // Calculate hedge metrics - price distribution and spike analysis
        let sortedSpotPrices = intervals.map { $0.spotPrice }.sorted()
        let maxSpotPrice = sortedSpotPrices.last ?? 0
        let p25SpotPrice = sortedSpotPrices[max(0, sortedSpotPrices.count / 4)]
        let p50SpotPrice = sortedSpotPrices[max(0, sortedSpotPrices.count / 2)]
        let p75SpotPrice = sortedSpotPrices[max(0, sortedSpotPrices.count * 3 / 4)]

        // Count spike intervals (spot > 15¢ is considered a spike during solar hours)
        let spikeThreshold = 15.0
        let spikeIntervals = intervals.filter { $0.spotPrice > spikeThreshold }.count
        let spikePercent = Double(spikeIntervals) / Double(max(1, intervals.count)) * 100

        progress = "Building tiered contract..."

        // Calculate tiered buy recommendation for hedging
        let tieredRecommendation = calculateBuyTieredRecommendation(
            intervals: intervals,
            hourlyBreakdown: hourlyBreakdown,
            scenarios: scenarios,
            periodDays: periodDays,
            maxSpotPrice: maxSpotPrice,
            importStartHour: importStartHour,
            importEndHour: importEndHour
        )

        buyerResult = P2PBuyerResult(
            analysisDate: Date(),
            periodDays: periodDays,
            importStartHour: importStartHour,
            importEndHour: importEndHour,
            totalImportKwh: totalImportKwh,
            totalImportCost: totalCost / 100,  // Convert to dollars
            totalImportIntervals: totalImportIntervals,
            intervalsWithImport: intervals.count,
            avgGridPrice: avgGridPrice,
            avgSpotPrice: avgSpotPrice,
            maxSpotPrice: maxSpotPrice,
            p25SpotPrice: p25SpotPrice,
            p50SpotPrice: p50SpotPrice,
            p75SpotPrice: p75SpotPrice,
            spikeIntervals: spikeIntervals,
            spikePercent: spikePercent,
            scenarios: scenarios,
            hourlyBreakdown: hourlyBreakdown,
            recommendation: recommendation,
            tieredRecommendation: tieredRecommendation
        )

        cacheBuyerResult(buyerResult!, config: config)
        progress = "Complete"
    }

    // MARK: - Buyer Scenario Calculation

    private func calculateBuyerScenarios(
        intervals: [P2PImportIntervalDetail],
        avgSpotPrice: Double,
        avgGridPrice: Double
    ) -> [P2PBuyPriceScenario] {
        var scenarios: [P2PBuyPriceScenario] = []

        // Find the price range from actual data
        let minSpotPrice = intervals.map { $0.spotPrice }.min() ?? 0

        // Test price caps in 1¢ increments
        // Start from 0¢ (some sellers have negative FiT and need to offload)
        // End at first multiple of 5 above min spot, capped at 15¢
        let endCap = min(ceil(minSpotPrice / 5) * 5 + 5, 15.0)  // First 5¢ multiple above floor, max 15¢

        let testCaps = Array(stride(from: 0.0, through: endCap, by: 1.0))

        for cap in testCaps {
            // For each interval, determine if P2P would fill at this cap
            // P2P fills when: seller offers <= your cap AND seller offers above their spot
            // Since we don't know seller offers, use spot price as proxy
            // If spot <= cap, assume P2P could match at spot (or slightly above)
            var intervalsAtOrBelowCap = 0
            var p2pKwh: Double = 0
            var spotKwh: Double = 0
            var p2pCostCents: Double = 0
            var spotCostCents: Double = 0

            for interval in intervals {
                // P2P fills when spot is at or below your cap
                // Actual P2P price would be between spot and cap
                if interval.spotPrice <= cap {
                    intervalsAtOrBelowCap += 1
                    p2pKwh += interval.importKwh
                    // Expected P2P price: sellers want above spot, you want below cap
                    // Model as weighted average - sellers have more leverage when spot is low
                    let spotWeight = max(0.3, min(0.7, 1.0 - (cap - interval.spotPrice) / 20.0))
                    let expectedP2PPrice = interval.spotPrice * spotWeight + cap * (1 - spotWeight)
                    p2pCostCents += interval.importKwh * expectedP2PPrice
                } else {
                    // Cap too low - no P2P, buy at spot
                    spotKwh += interval.importKwh
                    spotCostCents += interval.importKwh * interval.spotPrice
                }
            }

            let totalKwh = p2pKwh + spotKwh
            let fillRate = totalKwh > 0 ? (p2pKwh / totalKwh) * 100 : 0
            let totalCostCents = p2pCostCents + spotCostCents
            let effectivePrice = totalKwh > 0 ? totalCostCents / totalKwh : avgSpotPrice

            // Calculate savings vs baselines
            let gridBaselineCents = intervals.reduce(0) { $0 + $1.importKwh * $1.gridPrice }
            let spotBaselineCents = intervals.reduce(0) { $0 + $1.importKwh * $1.spotPrice }
            let savingsVsGridCents = gridBaselineCents - totalCostCents
            let savingsVsSpotCents = spotBaselineCents - totalCostCents

            let avgP2PPrice = p2pKwh > 0 ? p2pCostCents / p2pKwh : cap

            scenarios.append(P2PBuyPriceScenario(
                priceCap: cap,
                expectedFillRate: fillRate,
                expectedP2PKwh: p2pKwh,
                expectedSpotKwh: spotKwh,
                avgP2PPrice: avgP2PPrice,
                expectedP2PCost: p2pCostCents / 100,
                expectedSpotCost: spotCostCents / 100,
                totalCost: totalCostCents / 100,
                effectivePrice: effectivePrice,
                savingsVsGrid: savingsVsGridCents / 100,
                savingsVsSpot: savingsVsSpotCents / 100
            ))
        }

        return scenarios
    }

    // MARK: - Buyer Hourly Breakdown

    private func calculateBuyerHourlyBreakdown(
        intervals: [P2PImportIntervalDetail],
        importStartHour: Int,
        importEndHour: Int,
        periodDays: Int
    ) -> [P2PBuyHourlyBreakdown] {
        var breakdown: [P2PBuyHourlyBreakdown] = []

        for hour in importStartHour..<importEndHour {
            let hourIntervals = intervals.filter { $0.hour == hour }

            guard !hourIntervals.isEmpty else {
                breakdown.append(P2PBuyHourlyBreakdown(
                    hour: hour,
                    intervalCount: 0,
                    importKwh: 0,
                    avgGridPrice: 0,
                    avgSpotPrice: 0,
                    dailyKwh: 0
                ))
                continue
            }

            let totalImportKwh = hourIntervals.reduce(0) { $0 + $1.importKwh }
            let avgGrid = totalImportKwh > 0
                ? hourIntervals.reduce(0) { $0 + $1.gridPrice * $1.importKwh } / totalImportKwh
                : hourIntervals.reduce(0) { $0 + $1.gridPrice } / Double(hourIntervals.count)
            let avgSpot = totalImportKwh > 0
                ? hourIntervals.reduce(0) { $0 + $1.spotPrice * $1.importKwh } / totalImportKwh
                : hourIntervals.reduce(0) { $0 + $1.spotPrice } / Double(hourIntervals.count)
            let dailyKwh = totalImportKwh / Double(max(1, periodDays))

            breakdown.append(P2PBuyHourlyBreakdown(
                hour: hour,
                intervalCount: hourIntervals.count,
                importKwh: totalImportKwh,
                avgGridPrice: avgGrid,
                avgSpotPrice: avgSpot,
                dailyKwh: dailyKwh
            ))
        }

        return breakdown
    }

    // MARK: - Buyer Recommendation

    private func calculateBuyerRecommendation(
        scenarios: [P2PBuyPriceScenario],
        intervals: [P2PImportIntervalDetail],
        avgSpotPrice: Double,
        avgGridPrice: Double,
        importStartHour: Int,
        importEndHour: Int,
        periodDays: Int
    ) -> P2PBuyRecommendation {
        // Find optimal price cap
        // Key insight: during solar hours, spot is often very low or negative
        // Optimal buyer strategy: set cap just above typical spot to catch cheap P2P
        // but not so high that you overpay vs just buying spot

        // Calculate percentiles of actual spot prices
        let sortedSpotPrices = intervals.map { $0.spotPrice }.sorted()
        let p25 = sortedSpotPrices[max(0, sortedSpotPrices.count / 4)]
        let p50 = sortedSpotPrices[max(0, sortedSpotPrices.count / 2)]
        let p75 = sortedSpotPrices[max(0, sortedSpotPrices.count * 3 / 4)]

        var bestCap: Double = p50
        var bestScore: Double = -Double.infinity
        var bestSavings: Double = 0
        var bestFillRate: Double = 0

        for scenario in scenarios {
            // Score = savings vs spot (the realistic baseline during solar hours)
            // Penalize very low fill rates, but don't require high fill since
            // unfilled P2P just falls back to spot (no loss)
            let fillBonus = scenario.expectedFillRate >= 10 ? 1.0 : 0.5

            // Primary metric: does this cap result in lower cost than pure spot?
            // If P2P price > spot, we're overpaying
            let score = scenario.savingsVsSpot * fillBonus

            // Also consider: at very low caps, we get few P2P fills but pay spot anyway
            // At very high caps, we might overpay on P2P vs spot
            // Sweet spot: cap just above typical spot prices

            if score > bestScore {
                bestScore = score
                bestCap = scenario.priceCap
                bestSavings = scenario.savingsVsSpot
                bestFillRate = scenario.expectedFillRate
            }
        }

        // If no scenario beats spot, recommend lowest reasonable cap
        // (just get spot prices, don't overpay for P2P)
        if bestSavings <= 0 && !scenarios.isEmpty {
            // Find cap that gives ~50% fill without costing more than spot
            for scenario in scenarios.sorted(by: { $0.priceCap < $1.priceCap }) {
                if scenario.expectedFillRate >= 50 && scenario.savingsVsSpot >= 0 {
                    bestCap = scenario.priceCap
                    bestFillRate = scenario.expectedFillRate
                    bestSavings = scenario.savingsVsSpot
                    break
                }
            }
        }

        // Calculate weekly budget based on historical imports
        let totalImportKwh = intervals.reduce(0) { $0 + $1.importKwh }
        let dailyImportKwh = totalImportKwh / Double(max(1, periodDays))
        let weeklyImportKwh = dailyImportKwh * 7

        // Recommend budget based on expected fill rate
        let weeklyBudgetKwh = weeklyImportKwh * (bestFillRate / 100.0)

        // Build rationale based on price analysis
        let rationale: String
        if bestCap <= 0 {
            rationale = "During solar hours, spot often goes negative. Cap at \(String(format: "%.0f", bestCap))¢ only accepts P2P when sellers are desperate to offload."
        } else if bestCap < p25 {
            rationale = "Very conservative cap (\(String(format: "%.0f", bestCap))¢) below 25th percentile spot (\(String(format: "%.0f", p25))¢). Only \(String(format: "%.0f", bestFillRate))% fills expected - rest at spot."
        } else if bestCap < p50 {
            rationale = "Cap at \(String(format: "%.0f", bestCap))¢ is below median spot (\(String(format: "%.0f", p50))¢). Captures cheap solar-glut P2P offers."
        } else if bestCap < p75 {
            rationale = "Cap at \(String(format: "%.0f", bestCap))¢ captures most solar-hour P2P (\(String(format: "%.0f", bestFillRate))% fill expected)."
        } else {
            rationale = "Higher cap (\(String(format: "%.0f", bestCap))¢) maximizes P2P fill. Consider lowering if spot is typically cheaper."
        }

        return P2PBuyRecommendation(
            priceCap: bestCap,
            startHour: importStartHour,
            endHour: importEndHour,
            weeklyBudgetKwh: weeklyBudgetKwh,
            expectedFillRate: bestFillRate,
            expectedSavings: bestSavings * 7 / Double(max(1, periodDays)),  // Weekly savings
            rationale: rationale
        )
    }

    // MARK: - Tiered Buy Contract Recommendation

    private func calculateBuyTieredRecommendation(
        intervals: [P2PImportIntervalDetail],
        hourlyBreakdown: [P2PBuyHourlyBreakdown],
        scenarios: [P2PBuyPriceScenario],
        periodDays: Int,
        maxSpotPrice: Double,
        importStartHour: Int,
        importEndHour: Int
    ) -> P2PBuyTieredRecommendation? {
        guard !intervals.isEmpty, !hourlyBreakdown.isEmpty else { return nil }

        // STEP 1: Find best contiguous window for hedging
        // Criteria: hours with imports AND price volatility (hedge value)

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        // Calculate per-hour metrics
        struct HourMetrics {
            let hour: Int
            var totalImportKwh: Double = 0
            var intervalCount: Int = 0
            var maxSpot: Double = 0
            var avgSpot: Double = 0
            var spikeCount: Int = 0  // intervals > 15¢
        }

        var hourMetrics: [Int: HourMetrics] = [:]
        for hour in importStartHour..<importEndHour {
            hourMetrics[hour] = HourMetrics(hour: hour)
        }

        for interval in intervals {
            guard var metrics = hourMetrics[interval.hour] else { continue }
            metrics.totalImportKwh += interval.importKwh
            metrics.intervalCount += 1
            metrics.maxSpot = max(metrics.maxSpot, interval.spotPrice)
            if interval.spotPrice > 15 {
                metrics.spikeCount += 1
            }
            hourMetrics[interval.hour] = metrics
        }

        // Calculate average spot per hour
        for (hour, var metrics) in hourMetrics {
            if metrics.intervalCount > 0 {
                let hourIntervals = intervals.filter { $0.hour == hour }
                metrics.avgSpot = hourIntervals.reduce(0) { $0 + $1.spotPrice } / Double(hourIntervals.count)
                hourMetrics[hour] = metrics
            }
        }

        // Find best contiguous window (2-6 hours)
        // Score: import volume * hedge value (max spike - avg spot)
        var bestWindow: (start: Int, end: Int, score: Double, rationale: String) = (importStartHour, importEndHour, 0, "")

        for windowStart in importStartHour..<importEndHour {
            let maxWindowSize = importEndHour - windowStart
            guard maxWindowSize >= 2 else { continue }  // Need at least 2 hours

            for windowSize in 2...min(6, maxWindowSize) {
                let windowEnd = windowStart + windowSize

                var windowImport: Double = 0
                var windowMaxSpike: Double = 0
                var windowAvgSpot: Double = 0
                var windowHoursWithData = 0

                for hour in windowStart..<windowEnd {
                    if let metrics = hourMetrics[hour], metrics.intervalCount > 0 {
                        windowImport += metrics.totalImportKwh
                        windowMaxSpike = max(windowMaxSpike, metrics.maxSpot)
                        windowAvgSpot += metrics.avgSpot
                        windowHoursWithData += 1
                    }
                }

                guard windowHoursWithData > 0 else { continue }
                windowAvgSpot /= Double(windowHoursWithData)

                // Hedge value = potential savings during spikes
                let hedgeValue = windowMaxSpike - windowAvgSpot
                let score = windowImport * hedgeValue

                if score > bestWindow.score {
                    let rationale = "Peak import + highest spike potential (\(String(format: "%.0f", windowMaxSpike))¢ max)"
                    bestWindow = (windowStart, windowEnd, score, rationale)
                }
            }
        }

        // STEP 2: Calculate min/avg daily import in the window
        // Group imports by day to find minimum

        var importByDay: [String: Double] = [:]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()

        for interval in intervals {
            guard interval.hour >= bestWindow.start && interval.hour < bestWindow.end else { continue }
            let dayKey = dateFormatter.string(from: interval.timestamp)
            importByDay[dayKey, default: 0] += interval.importKwh
        }

        let dailyImports = Array(importByDay.values)
        let minDailyImport = dailyImports.min() ?? 0
        let avgDailyImport = dailyImports.isEmpty ? 0 : dailyImports.reduce(0, +) / Double(dailyImports.count)

        // Use minimum as conservative basis (you'll definitely import at least this much)
        let weeklyBudget = minDailyImport * 7

        guard weeklyBudget > 0.5 else { return nil }  // Need meaningful volume

        // STEP 3: Create tiered prices from 0¢ up
        // Find the price range where we get meaningful fills

        let maxTierPrice = scenarios.first { $0.expectedFillRate >= 95 }?.priceCap ?? 10
        let tierCount = min(Int(maxTierPrice) + 1, 11)  // 0¢ to 10¢ max, or less

        var tiers: [P2PBuyTier] = []
        var remainingKwh = weeklyBudget
        var totalExpectedCost: Double = 0
        var weightedFillRate: Double = 0

        // Allocate more to lower prices (better hedge), tapering up
        // Pattern: 0¢ gets most, each higher price gets less
        for i in 0..<tierCount {
            let priceCents = Double(i)

            // Find scenario for this price
            let scenario = scenarios.first { abs($0.priceCap - priceCents) < 0.5 }
            let fillRate = scenario?.expectedFillRate ?? 0

            // Allocation: more at lower prices
            // e.g., 0¢: 20%, 1¢: 18%, 2¢: 16%... tapering
            let basePercent = max(5, 20 - i * 2)
            let tierKwh = min(remainingKwh, weeklyBudget * Double(basePercent) / 100)

            guard tierKwh > 0.1 else { continue }

            let expectedCost = tierKwh * priceCents / 100  // $ for this tier
            totalExpectedCost += expectedCost
            weightedFillRate += fillRate * tierKwh

            tiers.append(P2PBuyTier(
                priceCents: priceCents,
                percentage: Double(basePercent),
                weeklyKwh: tierKwh,
                expectedFillRate: fillRate,
                expectedCost: expectedCost
            ))

            remainingKwh -= tierKwh
            if remainingKwh < 0.1 { break }
        }

        guard !tiers.isEmpty else { return nil }

        // Recalculate percentages based on actual allocation
        let actualTotal = tiers.reduce(0) { $0 + $1.weeklyKwh }
        tiers = tiers.map { tier in
            P2PBuyTier(
                priceCents: tier.priceCents,
                percentage: round(tier.weeklyKwh / actualTotal * 100),
                weeklyKwh: tier.weeklyKwh,
                expectedFillRate: tier.expectedFillRate,
                expectedCost: tier.expectedCost
            )
        }

        let overallFillRate = actualTotal > 0 ? weightedFillRate / actualTotal : 0

        // Calculate hedge value: savings if max spike occurs on all imports
        let hedgeValue = actualTotal * (maxSpotPrice - (totalExpectedCost / actualTotal * 100)) / 100

        return P2PBuyTieredRecommendation(
            startHour: bestWindow.start,
            endHour: bestWindow.end,
            windowRationale: bestWindow.rationale,
            tiers: tiers,
            totalWeeklyKwh: actualTotal,
            minDailyImportKwh: minDailyImport,
            avgDailyImportKwh: avgDailyImport,
            expectedFillRate: overallFillRate,
            expectedWeeklyCost: totalExpectedCost,
            hedgeValue: hedgeValue,
            maxSpikeProtection: maxSpotPrice
        )
    }

    // MARK: - Buyer Caching

    func getCachedBuyerResult(config: AnalysisConfig) -> P2PBuyerResult? {
        let key = "\(buyerCacheKey)_\(config.siteId)"
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(P2PBuyerResult.self, from: data) else {
            return nil
        }

        let age = Date().timeIntervalSince(cached.analysisDate)
        guard age < 24 * 3600 else { return nil }

        return cached
    }

    private func cacheBuyerResult(_ result: P2PBuyerResult, config: AnalysisConfig) {
        let key = "\(buyerCacheKey)_\(config.siteId)"
        if let data = try? JSONEncoder().encode(result) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func clearBuyerCache(config: AnalysisConfig) {
        let key = "\(buyerCacheKey)_\(config.siteId)"
        UserDefaults.standard.removeObject(forKey: key)
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
    
    // MARK: - Fine-Grained Price Analysis

    /// Analyze at 1¢ granularity to find true optimal price and detect anomalies
    private func findOptimalPrice(intervals: [P2PIntervalDetail]) -> (optimalPrice: Double, anomalies: [String]) {
        var priceResults: [(price: Double, revenue: Double, winWin: Double)] = []
        var anomalies: [String] = []

        for price in fineGrainedPrices {
            var eligibleCount = 0
            var additionalRevenue: Double = 0

            for interval in intervals {
                let yourGain = price - interval.spotSellPrice
                let buyerSaving = interval.buyerPrice - price

                if yourGain > 0 && buyerSaving > 0 {
                    eligibleCount += 1
                    additionalRevenue += interval.exportKwh * yourGain
                }
            }

            let winWinPct = Double(eligibleCount) / Double(max(1, intervals.count)) * 100
            priceResults.append((price: price, revenue: additionalRevenue / 100, winWin: winWinPct))
        }

        // Find optimal price (max revenue, prefer higher price if within 5%)
        var optimalPrice: Double = 25
        var optimalRevenue: Double = 0

        for result in priceResults {
            if result.revenue > optimalRevenue {
                optimalPrice = result.price
                optimalRevenue = result.revenue
            } else if result.revenue >= optimalRevenue * 0.95 && result.price > optimalPrice {
                optimalPrice = result.price
            }
        }

        // Detect anomalies - sudden drops in win-win or revenue between increments
        for i in 1..<priceResults.count {
            let prev = priceResults[i - 1]
            let curr = priceResults[i]

            // Win-win dropped by more than 10% in a single cent
            if prev.winWin - curr.winWin > 10 {
                anomalies.append("Win-win drops sharply at \(Int(curr.price))¢ (\(Int(prev.winWin))% → \(Int(curr.winWin))%)")
            }

            // Revenue dropped significantly
            if prev.revenue > 0 && (prev.revenue - curr.revenue) / prev.revenue > 0.15 {
                anomalies.append("Revenue drops \(Int(((prev.revenue - curr.revenue) / prev.revenue) * 100))% at \(Int(curr.price))¢")
            }
        }

        return (optimalPrice, anomalies)
    }

    // MARK: - Best Window Recommendation

    private func calculateRecommendation(
        intervals: [P2PIntervalDetail],
        peakStartHour: Int,
        peakEndHour: Int,
        periodDays: Int
    ) -> P2PRecommendation {

        // Find optimal price at 1¢ granularity
        let (optimalFinePrice, _) = findOptimalPrice(intervals: intervals)

        // Use fine-grained optimal directly (LV supports any price, not just 5¢ increments)
        var bestPrice: Double = optimalFinePrice
        var bestRevenue: Double = 0

        for price in testPrices {
            var eligible = 0
            var revenue: Double = 0
            
            for interval in intervals {
                let yourGain = price - interval.spotSellPrice
                let buyerSaving = interval.buyerPrice - price
                
                if yourGain > 0 && buyerSaving > 0 {
                    eligible += 1
                    revenue += interval.exportKwh * yourGain
                }
            }
            
            // Prefer higher price if revenue is within 5% of best
            // This captures "same return with less volume committed"
            if revenue > bestRevenue {
                bestPrice = price
                bestRevenue = revenue
            } else if revenue >= bestRevenue * 0.95 && price > bestPrice {
                // Similar revenue but higher price = better efficiency
                bestPrice = price
                bestRevenue = revenue
            }
        }
        
        // Step 2: Calculate per-hour stats at the best price
        struct HourStats {
            let hour: Int
            var totalKwh: Double = 0
            var extraRevenueCents: Double = 0
            var eligibleIntervals: Int = 0
            var totalIntervals: Int = 0
        }
        
        var hourlyStats: [Int: HourStats] = [:]
        for hour in peakStartHour..<peakEndHour {
            hourlyStats[hour] = HourStats(hour: hour)
        }
        
        for interval in intervals {
            guard var stats = hourlyStats[interval.hour] else { continue }
            
            stats.totalIntervals += 1
            
            let yourGain = bestPrice - interval.spotSellPrice
            let buyerSaving = interval.buyerPrice - bestPrice
            
            if yourGain > 0 && buyerSaving > 0 {
                stats.totalKwh += interval.exportKwh
                stats.extraRevenueCents += interval.exportKwh * yourGain
                stats.eligibleIntervals += 1
            }
            
            hourlyStats[interval.hour] = stats
        }
        
        // Step 3: Find best contiguous window
        // Try all possible contiguous ranges and pick the one with best daily yield
        var bestWindow: (start: Int, end: Int, dailyKwh: Double, dailyExtra: Double, winWin: Double) = (peakStartHour, peakStartHour + 1, 0, 0, 0)
        
        for windowStart in peakStartHour..<peakEndHour {
            for windowEnd in (windowStart + 1)...peakEndHour {
                var windowKwh: Double = 0
                var windowExtraCents: Double = 0
                var windowEligible: Int = 0
                var windowTotal: Int = 0
                
                for hour in windowStart..<windowEnd {
                    if let stats = hourlyStats[hour] {
                        windowKwh += stats.totalKwh
                        windowExtraCents += stats.extraRevenueCents
                        windowEligible += stats.eligibleIntervals
                        windowTotal += stats.totalIntervals
                    }
                }
                
                let dailyKwh = windowKwh / Double(max(1, periodDays))
                let dailyExtraDollars = (windowExtraCents / 100.0) / Double(max(1, periodDays))
                let winWin = windowTotal > 0 ? Double(windowEligible) / Double(windowTotal) * 100 : 0
                
                // Score: prioritize daily yield but require reasonable coverage
                let score = dailyExtraDollars * (winWin / 100.0)
                let currentScore = bestWindow.dailyExtra * (bestWindow.winWin / 100.0)
                
                if score > currentScore && winWin >= 50 {
                    bestWindow = (windowStart, windowEnd, dailyKwh, dailyExtraDollars, winWin)
                }
            }
        }
        
        // Fallback: if no window with 50%+ coverage, take the best regardless
        if bestWindow.dailyExtra == 0 {
            for windowStart in peakStartHour..<peakEndHour {
                for windowEnd in (windowStart + 1)...peakEndHour {
                    var windowKwh: Double = 0
                    var windowExtraCents: Double = 0
                    var windowEligible: Int = 0
                    var windowTotal: Int = 0
                    
                    for hour in windowStart..<windowEnd {
                        if let stats = hourlyStats[hour] {
                            windowKwh += stats.totalKwh
                            windowExtraCents += stats.extraRevenueCents
                            windowEligible += stats.eligibleIntervals
                            windowTotal += stats.totalIntervals
                        }
                    }
                    
                    let dailyKwh = windowKwh / Double(max(1, periodDays))
                    let dailyExtraDollars = (windowExtraCents / 100.0) / Double(max(1, periodDays))
                    let winWin = windowTotal > 0 ? Double(windowEligible) / Double(windowTotal) * 100 : 0
                    
                    if dailyExtraDollars > bestWindow.dailyExtra {
                        bestWindow = (windowStart, windowEnd, dailyKwh, dailyExtraDollars, winWin)
                    }
                }
            }
        }
        
        return P2PRecommendation(
            offerPrice: bestPrice,
            startHour: bestWindow.start,
            endHour: bestWindow.end,
            dailyKwh: bestWindow.dailyKwh,
            dailyExtraRevenue: bestWindow.dailyExtra,
            monthlyExtraRevenue: bestWindow.dailyExtra * 30,
            winWinPercent: bestWindow.winWin
        )
    }
    
    // MARK: - Hourly Breakdown
    
    private func calculateHourlyBreakdown(
        intervals: [P2PIntervalDetail],
        peakStartHour: Int,
        peakEndHour: Int,
        periodDays: Int,
        recommendedPrice: Double
    ) -> [P2PHourlyBreakdown] {
        
        var breakdown: [P2PHourlyBreakdown] = []
        
        for hour in peakStartHour..<peakEndHour {
            let hourIntervals = intervals.filter { $0.hour == hour }
            
            guard !hourIntervals.isEmpty else {
                breakdown.append(P2PHourlyBreakdown(
                    hour: hour,
                    intervalCount: 0,
                    exportKwh: 0,
                    avgBuyPrice: 0,
                    avgSellPrice: 0,
                    avgSpread: 0,
                    dailyKwh: 0,
                    dailyExtraAtRecommended: 0,
                    winWinAtRecommended: 0
                ))
                continue
            }
            
            let totalExportKwh = hourIntervals.reduce(0) { $0 + $1.exportKwh }
            let avgBuy = totalExportKwh > 0
                ? hourIntervals.reduce(0) { $0 + $1.buyerPrice * $1.exportKwh } / totalExportKwh
                : hourIntervals.reduce(0) { $0 + $1.buyerPrice } / Double(hourIntervals.count)
            let avgSell = totalExportKwh > 0
                ? hourIntervals.reduce(0) { $0 + $1.spotSellPrice * $1.exportKwh } / totalExportKwh
                : hourIntervals.reduce(0) { $0 + $1.spotSellPrice } / Double(hourIntervals.count)
            let avgSpread = avgBuy - avgSell
            
            // Calculate at recommended price
            var eligibleKwh: Double = 0
            var extraRevenueCents: Double = 0
            var eligibleCount: Int = 0
            
            for interval in hourIntervals {
                let yourGain = recommendedPrice - interval.spotSellPrice
                let buyerSaving = interval.buyerPrice - recommendedPrice
                
                if yourGain > 0 && buyerSaving > 0 {
                    eligibleKwh += interval.exportKwh
                    extraRevenueCents += interval.exportKwh * yourGain
                    eligibleCount += 1
                }
            }
            
            let dailyKwh = eligibleKwh / Double(max(1, periodDays))
            let dailyExtra = (extraRevenueCents / 100.0) / Double(max(1, periodDays))
            let winWin = Double(eligibleCount) / Double(hourIntervals.count) * 100
            
            breakdown.append(P2PHourlyBreakdown(
                hour: hour,
                intervalCount: hourIntervals.count,
                exportKwh: totalExportKwh,
                avgBuyPrice: avgBuy,
                avgSellPrice: avgSell,
                avgSpread: avgSpread,
                dailyKwh: dailyKwh,
                dailyExtraAtRecommended: dailyExtra,
                winWinAtRecommended: winWin
            ))
        }
        
        return breakdown
    }

    // MARK: - Tiered Contract Recommendation

    /// Historical performance data for a price point
    private struct HistoricalTierPerformance {
        let priceCents: Double
        let totalOfferedKwh: Double
        let totalFilledKwh: Double
        let contractCount: Int

        var fillRate: Double {
            guard totalOfferedKwh > 0 else { return 0 }
            return (totalFilledKwh / totalOfferedKwh) * 100
        }
    }

    /// Calculate average overnight load from meter records (9pm-6am)
    /// This represents power consumed while battery is typically not charging from solar
    /// Returns average kWh per night
    private func calculateOvernightLoad(siteId: Int, days: Int = 7) -> Double {
        let dataStore = PowstonDataStore.shared
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -days, to: today) else { return 0 }

        let records = dataStore.getMeterRecordsLocal(siteId: siteId, from: startDate, to: today)

        // Filter to overnight hours (9pm-6am = hours 21, 22, 23, 0, 1, 2, 3, 4, 5)
        let overnightHours: Set<Int> = [21, 22, 23, 0, 1, 2, 3, 4, 5]
        var totalConsumptionKwh: Double = 0
        var intervalCount = 0

        // Track consumption per night
        var consumptionByNight: [String: Double] = [:]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()

        for record in records {
            let meterRecord = record.toMeterRecord()
            guard let recordDate = meterRecord.date else { continue }

            let hour = calendar.component(.hour, from: recordDate)
            guard overnightHours.contains(hour) else { continue }

            intervalCount += 1

            // Use houseConsumption which captures total load from all sources
            // houseConsumption is in Watts (instantaneous power)
            // Convert to kWh for 5-min interval: W * (5/60) / 1000 = W / 12000
            let consumption: Double
            if let houseLoad = meterRecord.houseConsumption, houseLoad > 0 {
                consumption = houseLoad / 12000.0  // Watts to kWh for 5-min interval
            } else {
                // Fallback: use effectiveImport (already in kWh per interval)
                consumption = meterRecord.effectiveImport
            }

            // Track which night this belongs to (use previous day's date for hours 0-5)
            var nightDate = recordDate
            if hour < 6 {
                nightDate = calendar.date(byAdding: .day, value: -1, to: recordDate) ?? recordDate
            }
            let nightKey = dateFormatter.string(from: nightDate)
            consumptionByNight[nightKey, default: 0] += max(0, consumption)
            totalConsumptionKwh += max(0, consumption)
        }

        // Use actual number of nights with data, or fall back to requested days
        let nightCount = max(1, consumptionByNight.count > 0 ? consumptionByNight.count : days)
        let avgPerNight = totalConsumptionKwh / Double(nightCount)

        // Debug: show per-night breakdown
        let nightTotals = consumptionByNight.sorted { $0.key < $1.key }.map { "\($0.key): \(String(format: "%.1f", $0.value))" }.joined(separator: ", ")
        print("🌙 Overnight load: \(intervalCount) intervals, \(nightCount) nights")
        print("   Per night: \(nightTotals)")
        print("   Total: \(String(format: "%.1f", totalConsumptionKwh)) kWh, Avg: \(String(format: "%.1f", avgPerNight)) kWh/night")

        return avgPerNight
    }

    /// Filter peak hours to only include those with win-win >= threshold
    private func filterHoursByWinWin(
        hourlyBreakdown: [P2PHourlyBreakdown],
        peakStartHour: Int,
        peakEndHour: Int,
        threshold: Double = 50.0
    ) -> (filteredStart: Int, filteredEnd: Int, excludedHours: [Int]) {
        // Get hours that meet the win-win threshold
        let eligibleHours = hourlyBreakdown
            .filter { $0.hour >= peakStartHour && $0.hour < peakEndHour }
            .filter { $0.winWinAtRecommended >= threshold }
            .map { $0.hour }
            .sorted()

        guard !eligibleHours.isEmpty else {
            // No hours meet threshold - fall back to original window
            return (peakStartHour, peakEndHour, [])
        }

        // Find the best contiguous block
        var bestStart = eligibleHours.first!
        var bestEnd = eligibleHours.first! + 1
        var bestLength = 1

        var currentStart = eligibleHours.first!
        var currentEnd = eligibleHours.first! + 1

        for i in 1..<eligibleHours.count {
            if eligibleHours[i] == eligibleHours[i-1] + 1 {
                // Contiguous
                currentEnd = eligibleHours[i] + 1
            } else {
                // Gap - check if current block is best
                if currentEnd - currentStart > bestLength {
                    bestStart = currentStart
                    bestEnd = currentEnd
                    bestLength = currentEnd - currentStart
                }
                // Start new block
                currentStart = eligibleHours[i]
                currentEnd = eligibleHours[i] + 1
            }
        }

        // Check final block
        if currentEnd - currentStart > bestLength {
            bestStart = currentStart
            bestEnd = currentEnd
        }

        // Find excluded hours (within original window but not in filtered)
        let allPeakHours = Set(peakStartHour..<peakEndHour)
        let includedHours = Set(bestStart..<bestEnd)
        let excludedHours = allPeakHours.subtracting(includedHours).sorted()

        return (bestStart, bestEnd, excludedHours)
    }

    /// Calculate a 7-day tiered contract recommendation using data-driven pricing
    /// Clusters actual trade prices to find natural tier points
    private func calculateTieredRecommendation(
        scenarios: [P2PPriceScenario],
        intervals: [P2PIntervalDetail],
        periodDays: Int,
        peakStartHour: Int,
        peakEndHour: Int,
        config: AnalysisConfig,
        hourlyBreakdown: [P2PHourlyBreakdown]? = nil
    ) -> P2PTieredRecommendation? {
        guard !scenarios.isEmpty else { return nil }

        let dataStore = PowstonDataStore.shared
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let today = calendar.startOfDay(for: Date())

        // System constraints
        let batteryCapacityKwh = config.batteryCapacityKWh
        let inverterExportKw = config.inverterExportCapacityKw

        // MARK: - Calculate Overnight Load
        let overnightLoadKwh = calculateOvernightLoad(siteId: config.siteId, days: 7)
        let effectiveExportableKwh = max(0, batteryCapacityKwh * 0.8 - overnightLoadKwh)

        // Calculate max daily export based on system
        let peakHours = Double(peakEndHour - peakStartHour)
        let batteryDailyMax = effectiveExportableKwh  // Use effective capacity after overnight load
        let inverterDailyMax = inverterExportKw * peakHours
        let maxDailyExportKwh = min(batteryDailyMax, inverterDailyMax)

        // Get daily average from historical meter data
        let dailyAvgExportKwh = intervals.reduce(0) { $0 + $1.exportKwh } / Double(max(1, periodDays))

        // MARK: - Get Win-Win Analysis Reference

        // Find the single-price recommendation from win-win analysis for cross-validation
        let bestScenario = scenarios.max(by: { $0.additionalRevenue < $1.additionalRevenue })
        let singlePriceRecommendation = bestScenario?.offerPrice

        // Calculate minimum viable price (average spot sell price - don't go below this)
        let avgSpotSellPrice = intervals.reduce(0) { $0 + $1.spotSellPrice } / Double(max(1, intervals.count))
        let minViablePrice = max(avgSpotSellPrice, 15.0)  // At least spot price or 15¢

        // MARK: - Load Actual Trade Data for Clustering

        // Get all counterparty trades (actual P2P trades with real prices)
        let allTrades = dataStore.getP2PCounterpartyTrades(siteId: config.siteId)

        // Get trade records to identify provisional (forecast) trades
        let tradeRecords = dataStore.getP2PTradeRecords(siteId: config.siteId)
        let provisionalRecordIds = Set(tradeRecords.filter { $0.isProvisional }.map { $0.id })

        // Separate trades into actual vs provisional (forward contracts)
        let actualTrades = allTrades.filter { !provisionalRecordIds.contains($0.tradeRecordId) }
        let provisionalTrades = allTrades.filter { provisionalRecordIds.contains($0.tradeRecordId) }

        // Filter out outlier trades (prices below spot = losing trades)
        let validActualTrades = actualTrades.filter { $0.priceCents >= minViablePrice }
        let validProvisionalTrades = provisionalTrades.filter { $0.priceCents >= minViablePrice }

        // Combine - provisional trades represent current forward contracts, weight them 2x
        // by duplicating them in the analysis (they're more relevant than old historical data)
        let weightedTrades = validActualTrades + validProvisionalTrades + validProvisionalTrades
        let validTrades = weightedTrades

        let outlierTradesExcluded = allTrades.count - (validActualTrades.count + validProvisionalTrades.count)
        let tradesAnalyzed = validActualTrades.count + validProvisionalTrades.count
        let forecastTradesIncluded = validProvisionalTrades.count

        // MARK: - Load Contract Performance Data

        // Filter to SELL contracts only - this is the sell analysis
        let allContracts = dataStore.getP2PContracts(siteId: config.siteId)
            .filter { $0.direction == .sell }
        let completedContracts = allContracts.filter { contract in
            calendar.startOfDay(for: contract.endDate) < today
        }

        // Get LocalVolts contract limit - prefer upcoming sell contract, then most recent sell
        let upcomingContract = allContracts
            .filter { calendar.startOfDay(for: $0.startDate) > today }
            .sorted { $0.startDate < $1.startDate }
            .first

        let mostRecentContract = allContracts
            .sorted { $0.createdAt > $1.createdAt }
            .first

        let lvContractLimitKwh: Double?
        if let upcoming = upcomingContract {
            // Use upcoming contract's volume as the limit (LV has already set this)
            lvContractLimitKwh = upcoming.totalVolumeKwh
        } else if let recent = mostRecentContract {
            // Fall back to most recent contract
            lvContractLimitKwh = recent.totalVolumeKwh
        } else {
            lvContractLimitKwh = nil
        }

        // Apply LV export budget limit to weekly max
        // Priority: 1) User-configured LV budget, 2) Contract-derived limit, 3) Physical capacity
        let maxWeeklyKwh: Double
        if let lvBudget = config.lvExportBudgetKwh {
            // User has set their LV export budget - use it
            maxWeeklyKwh = lvBudget
        } else if let lvLimit = lvContractLimitKwh {
            // Fall back to contract-derived limit
            maxWeeklyKwh = lvLimit
        } else {
            // No LV limit - use physical capacity
            maxWeeklyKwh = min(maxDailyExportKwh * 7, dailyAvgExportKwh * 7)
        }

        // Build price -> performance map from P2PContract records (if any)
        var historicalPerformance: [Int: HistoricalTierPerformance] = [:]

        for contract in allContracts {
            let perf = dataStore.getP2PContractPerformance(contract)

            for tierPerf in perf.tierPerformance {
                let priceKey = Int(tierPerf.tier.priceCents)
                guard Double(priceKey) >= minViablePrice else { continue }

                let existing = historicalPerformance[priceKey]

                historicalPerformance[priceKey] = HistoricalTierPerformance(
                    priceCents: tierPerf.tier.priceCents,
                    totalOfferedKwh: (existing?.totalOfferedKwh ?? 0) + tierPerf.tier.volumeKwh,
                    totalFilledKwh: (existing?.totalFilledKwh ?? 0) + tierPerf.matchedKwh,
                    contractCount: (existing?.contractCount ?? 0) + 1
                )
            }
        }

        // Fallback: if no P2PContract records, build from LV order groups (actual API orders)
        if historicalPerformance.isEmpty {
            let sellOrders = dataStore.getActiveLVOrders(siteId: config.siteId, direction: "Sell")
            let sellGroups = LVOrder.groupByContract(sellOrders)
            let sellPerfs = dataStore.getLVOrderGroupPerformances(sellGroups)

            for (_, perf) in zip(sellGroups, sellGroups.map({ sellPerfs[$0.id] })) {
                guard let perf = perf else { continue }
                for tierPerf in perf.tierPerformance {
                    let priceKey = Int(tierPerf.tier.priceCents)
                    guard Double(priceKey) >= minViablePrice else { continue }

                    let existing = historicalPerformance[priceKey]

                    historicalPerformance[priceKey] = HistoricalTierPerformance(
                        priceCents: tierPerf.tier.priceCents,
                        totalOfferedKwh: (existing?.totalOfferedKwh ?? 0) + tierPerf.tier.volumeKwh,
                        totalFilledKwh: (existing?.totalFilledKwh ?? 0) + tierPerf.matchedKwh,
                        contractCount: (existing?.contractCount ?? 0) + 1
                    )
                }
            }
        }

        let contractsAnalyzed = completedContracts.count

        // MARK: - Cluster Actual Trade Prices

        // Extract price points from actual trades and cluster them (using filtered trades)
        let priceClusters = clusterTradePrices(validTrades, historicalPerformance: historicalPerformance)
        let hasHistoricalData = !priceClusters.isEmpty

        // MARK: - Get Previous Contract for Comparison

        let activeContract = allContracts.first { contract in
            let start = calendar.startOfDay(for: contract.startDate)
            let end = calendar.startOfDay(for: contract.endDate)
            return start <= today && end >= today
        }

        // upcomingContract already defined above for LV limit

        let previousContract: P2PPreviousContractSummary?
        let latestContract = activeContract ?? allContracts.sorted(by: { $0.endDate > $1.endDate }).first

        if let contract = latestContract {
            previousContract = P2PPreviousContractSummary(
                tierPrices: contract.tiers.map { $0.priceCents }.sorted(by: >),
                totalKwh: contract.totalVolumeKwh,
                blendedPrice: contract.blendedPriceCents,
                endDate: contract.endDate
            )
        } else {
            previousContract = nil
        }

        // MARK: - Calculate Renewal Timing

        let renewalInfo = calculateRenewalTiming(
            activeContract: activeContract,
            upcomingContract: upcomingContract,
            today: today,
            calendar: calendar
        )

        // MARK: - Build Tier Recommendations from Clusters

        // If we have trade data, use clusters; otherwise fall back to theoretical scenarios
        var candidateTiers: [(price: Double, score: Double, volume: Double, trades: Int, fillRate: Double?, isWinWin: Bool)] = []

        if !priceClusters.isEmpty {
            // Data-driven approach: use actual trade price clusters
            for cluster in priceClusters {
                // Get theoretical win-win for this price
                let scenario = scenarios.min(by: { abs($0.offerPrice - cluster.centerPrice) < abs($1.offerPrice - cluster.centerPrice) })
                let theoreticalWinWin = scenario?.winWinPercent ?? 0

                // Check if this price is actually a win-win (above spot, below buyer)
                let isWinWin = theoreticalWinWin >= 30

                // Calculate combined score - penalize non-win-win prices heavily
                let fillRateScore = cluster.avgFillRate ?? theoreticalWinWin
                let volumeScore = min(100, (cluster.totalVolumeKwh / 50.0) * 100)
                let tradeScore = min(100, Double(cluster.tradeCount) * 10)
                let winWinBonus = isWinWin ? 1.0 : 0.3  // Heavily penalize non-win-win

                // Weight: 40% fill rate, 30% theoretical win-win, 20% trade count, 10% volume
                let baseScore = (fillRateScore * 0.4) + (theoreticalWinWin * 0.3) + (tradeScore * 0.2) + (volumeScore * 0.1)
                let combinedScore = baseScore * winWinBonus

                candidateTiers.append((
                    price: cluster.centerPrice,
                    score: combinedScore,
                    volume: cluster.totalVolumeKwh,
                    trades: cluster.tradeCount,
                    fillRate: cluster.avgFillRate,
                    isWinWin: isWinWin
                ))
            }
        }

        // Always include win-win scenarios from theoretical analysis
        for scenario in scenarios where scenario.winWinPercent >= 40 {
            // Skip if we already have a similar price from clusters
            let existingSimilar = candidateTiers.first { abs($0.price - scenario.offerPrice) < 3 }
            if existingSimilar != nil { continue }

            let histPerf = historicalPerformance[Int(scenario.offerPrice)]
            let fillRate = histPerf?.fillRate

            candidateTiers.append((
                price: scenario.offerPrice,
                score: scenario.winWinPercent,
                volume: scenario.eligibleKwh,
                trades: 0,
                fillRate: fillRate,
                isWinWin: true
            ))
        }

        guard !candidateTiers.isEmpty else { return nil }

        // Filter to only win-win tiers (or fall back to best available)
        var winWinCandidates = candidateTiers.filter { $0.isWinWin }
        if winWinCandidates.isEmpty {
            // No win-win options - take best scoring non-losers
            winWinCandidates = candidateTiers.filter { $0.price >= minViablePrice }
        }

        guard !winWinCandidates.isEmpty else { return nil }

        // Sort by score descending
        let sortedCandidates = winWinCandidates.sorted { $0.score > $1.score }

        // MARK: - Select Variable Number of Tiers

        // Determine optimal tier count based on data spread
        let priceRange = (sortedCandidates.map { $0.price }.max() ?? 0) - (sortedCandidates.map { $0.price }.min() ?? 0)
        let optimalTierCount: Int
        if priceRange < 5 {
            optimalTierCount = 1  // Prices too close, use single tier
        } else if priceRange < 10 {
            optimalTierCount = 2
        } else if priceRange < 20 {
            optimalTierCount = 3
        } else {
            optimalTierCount = min(4, sortedCandidates.count)  // Wide spread, up to 4 tiers
        }

        // Select tiers spread across price range with good scores
        var selectedTiers: [(price: Double, score: Double, volume: Double, trades: Int, fillRate: Double?, isWinWin: Bool)] = []

        // First, pick the highest-scoring tier
        if let best = sortedCandidates.first {
            selectedTiers.append(best)
        }

        // Then add tiers that are well-spaced from existing selections
        for candidate in sortedCandidates.dropFirst() {
            if selectedTiers.count >= optimalTierCount { break }

            // Check if this price is sufficiently different from selected tiers
            let minGap = selectedTiers.map { abs($0.price - candidate.price) }.min() ?? Double.infinity
            if minGap >= 5.0 && candidate.score >= 30 {  // At least 5¢ gap for meaningful tiers
                selectedTiers.append(candidate)
            }
        }

        guard !selectedTiers.isEmpty else { return nil }

        // MARK: - Adjust Prices Toward Win-Win Optimal

        // If historical prices diverge significantly from win-win optimal, adjust toward optimal
        var adjustedTiers = selectedTiers.map { tier -> (price: Double, score: Double, volume: Double, trades: Int, fillRate: Double?, isWinWin: Bool) in
            guard let optimalPrice = singlePriceRecommendation else { return tier }

            // If tier price is more than 5¢ below optimal and doesn't have strong historical backing
            if tier.price < optimalPrice - 5 && tier.trades < 10 {
                // Nudge price toward optimal (blend 60% original, 40% toward optimal)
                let adjustedPrice = round(tier.price * 0.6 + optimalPrice * 0.4)
                return (price: adjustedPrice, score: tier.score, volume: tier.volume, trades: tier.trades, fillRate: tier.fillRate, isWinWin: tier.isWinWin)
            }
            return tier
        }

        // Ensure we still have at least 5¢ gaps after adjustment
        adjustedTiers = adjustedTiers.sorted { $0.price > $1.price }
        var finalTiers: [(price: Double, score: Double, volume: Double, trades: Int, fillRate: Double?, isWinWin: Bool)] = []
        for tier in adjustedTiers {
            let minGap = finalTiers.map { abs($0.price - tier.price) }.min() ?? Double.infinity
            if finalTiers.isEmpty || minGap >= 5 {
                finalTiers.append(tier)
            }
        }

        guard !finalTiers.isEmpty else { return nil }

        // MARK: - Add Probe Tier (Test Market Ceiling)

        // Always add a probe tier ~5¢ above the best-performing tier to test higher prices
        // This helps discover if premium pricing is viable without risking core volume
        let bestPerformingTier = finalTiers.max(by: { ($0.fillRate ?? $0.score) < ($1.fillRate ?? $1.score) })
        let highestPrice = finalTiers.map { $0.price }.max() ?? 0

        var tiersWithProbe = finalTiers

        if let bestTier = bestPerformingTier {
            // Probe price: 5¢ above highest existing tier, or 5¢ above best performer if that's higher
            let probePrice = max(highestPrice + 5, bestTier.price + 5)

            // Only add probe if it's meaningfully above existing tiers and within reasonable range
            let maxReasonablePrice = (singlePriceRecommendation ?? 30) + 10  // Don't probe more than 10¢ above optimal
            let minGapFromExisting = finalTiers.map { abs($0.price - probePrice) }.min() ?? Double.infinity

            if probePrice <= maxReasonablePrice && minGapFromExisting >= 4 {
                // Add probe tier with estimated score (lower than proven tiers)
                let probeScore = max(20, (bestTier.score * 0.5))  // Conservative score for unproven price
                tiersWithProbe.append((
                    price: probePrice,
                    score: probeScore,
                    volume: 0,  // No historical volume
                    trades: 0,  // No trades at this price yet
                    fillRate: nil,  // Unknown fill rate - that's why we're probing
                    isWinWin: true  // Assume win-win if within reasonable range
                ))
            }
        }

        // MARK: - Allocate kWh to Tiers

        var tiers: [P2PRecommendedTier] = []
        var totalAllocated: Double = 0

        // Reserve 15-20% for probe tier before allocating to proven tiers
        let probeAllocation = maxWeeklyKwh * 0.18  // 18% for probe
        let remainingForProvenTiers = maxWeeklyKwh - probeAllocation

        // Sort by fill rate descending for allocation (best performers first)
        // This ensures high-fill tiers get priority allocation
        let sortedByFillRate = tiersWithProbe.sorted { t1, t2 in
            let fill1 = t1.fillRate ?? t1.score
            let fill2 = t2.fillRate ?? t2.score
            return fill1 > fill2
        }

        // Identify the probe tier (highest price with no historical data)
        let probeTierPrice = sortedByFillRate.filter { $0.fillRate == nil && $0.trades == 0 }
            .map { $0.price }.max()

        var remainingWeeklyKwh = maxWeeklyKwh

        for tierData in sortedByFillRate {
            guard remainingWeeklyKwh > 0.5 else { break }

            let scenario = scenarios.min(by: { abs($0.offerPrice - tierData.price) < abs($1.offerPrice - tierData.price) })

            // Check if this is the probe tier (no historical data, highest unproven price)
            let isProbe = tierData.fillRate == nil && tierData.trades == 0 && tierData.price == probeTierPrice

            let weeklyKwhForTier: Double

            if isProbe {
                // Probe tier: fixed 18% allocation to test market ceiling
                weeklyKwhForTier = probeAllocation
            } else if let actualFillRate = tierData.fillRate {
                // Proven tier: allocate based on actual fill rate performance
                let fillRateWeight = actualFillRate / 100.0

                if actualFillRate >= 60 {
                    // High performers (sweet spot) get majority of remaining budget
                    weeklyKwhForTier = min(remainingWeeklyKwh * 0.65, remainingForProvenTiers * 0.7)
                } else if actualFillRate >= 40 {
                    // Medium performers get proportional allocation
                    let remainingTiers = tiersWithProbe.count - tiers.count
                    let baseAllocation = remainingWeeklyKwh / Double(max(1, remainingTiers))
                    weeklyKwhForTier = min(remainingWeeklyKwh, baseAllocation * fillRateWeight * 1.2)
                } else {
                    // Low performers (<40% fill) - keep as small base/floor tier
                    weeklyKwhForTier = min(maxWeeklyKwh * 0.15, remainingWeeklyKwh * 0.25)
                }
            } else {
                // No historical data but not the probe - conservative allocation
                let scoreWeight = tierData.score / 100.0
                let remainingTiers = tiersWithProbe.count - tiers.count
                let baseAllocation = remainingWeeklyKwh / Double(max(1, remainingTiers))
                weeklyKwhForTier = min(remainingWeeklyKwh, baseAllocation * scoreWeight)
            }

            guard weeklyKwhForTier > 0.5 else { continue }

            let weeklyRevenue = weeklyKwhForTier * tierData.price / 100.0

            // Determine confidence based on data backing
            let confidence: TierConfidence
            if tierData.trades >= 5 {
                if let fillRate = tierData.fillRate, fillRate >= 70 {
                    confidence = .proven
                } else if let fillRate = tierData.fillRate, fillRate >= 50 {
                    confidence = .high
                } else {
                    confidence = .medium
                }
            } else if tierData.trades >= 2 {
                confidence = .medium
            } else if tierData.score >= 70 {
                confidence = .high
            } else if tierData.score >= 50 {
                confidence = .medium
            } else {
                confidence = .low
            }

            // Percentage will be calculated after we know total
            tiers.append(P2PRecommendedTier(
                priceCents: tierData.price,
                percentage: 0,  // Placeholder - calculated below
                weeklyKwh: weeklyKwhForTier,
                weeklyRevenue: weeklyRevenue,
                winWinPercent: scenario?.winWinPercent ?? tierData.score,
                avgYourGainCents: scenario?.avgYourGain ?? 0,
                avgBuyerSavingCents: scenario?.avgBuyerSaving ?? 0,
                confidence: confidence,
                historicalFillRate: tierData.fillRate,
                historicalVolumeKwh: tierData.volume,
                basedOnTrades: tierData.trades
            ))

            totalAllocated += weeklyKwhForTier
            remainingWeeklyKwh -= weeklyKwhForTier
        }

        guard !tiers.isEmpty else { return nil }

        // Recalculate with percentages
        tiers = tiers.map { tier in
            let percentage = totalAllocated > 0 ? round((tier.weeklyKwh / totalAllocated) * 100) : 0
            return P2PRecommendedTier(
                priceCents: tier.priceCents,
                percentage: percentage,
                weeklyKwh: tier.weeklyKwh,
                weeklyRevenue: tier.weeklyRevenue,
                winWinPercent: tier.winWinPercent,
                avgYourGainCents: tier.avgYourGainCents,
                avgBuyerSavingCents: tier.avgBuyerSavingCents,
                confidence: tier.confidence,
                historicalFillRate: tier.historicalFillRate,
                historicalVolumeKwh: tier.historicalVolumeKwh,
                basedOnTrades: tier.basedOnTrades
            )
        }

        // Calculate totals
        let weeklyTotalKwh = tiers.reduce(0) { $0 + $1.weeklyKwh }
        let weeklyEstimatedRevenue = tiers.reduce(0) { $0 + $1.weeklyRevenue }

        // MARK: - Detect Recommendation Changes

        let (recommendationChanged, changeReason) = detectRecommendationChanges(
            newTiers: tiers,
            previousContract: previousContract
        )

        // MARK: - Detect Divergence from Win-Win Analysis

        let recommendationDivergence = detectDivergence(
            tieredPrices: tiers.map { $0.priceCents },
            singlePriceRecommendation: singlePriceRecommendation,
            avgSpotSellPrice: avgSpotSellPrice
        )

        // MARK: - Win-Win Hour Filtering

        // Filter hours by win-win threshold (exclude hours where forced export at low spot would hurt)
        let winWinThreshold = 50.0  // Require at least 50% win-win
        let filteredWindow: (filteredStart: Int, filteredEnd: Int, excludedHours: [Int])

        if let breakdown = hourlyBreakdown {
            filteredWindow = filterHoursByWinWin(
                hourlyBreakdown: breakdown,
                peakStartHour: peakStartHour,
                peakEndHour: peakEndHour,
                threshold: winWinThreshold
            )
        } else {
            // Calculate hourly win-win inline if breakdown not provided
            let bestPrice = singlePriceRecommendation ?? 30.0
            var hourWinWin: [(hour: Int, winWin: Double)] = []

            for hour in peakStartHour..<peakEndHour {
                let hourIntervals = intervals.filter { $0.hour == hour }
                guard !hourIntervals.isEmpty else { continue }

                var eligibleCount = 0
                for interval in hourIntervals {
                    let yourGain = bestPrice - interval.spotSellPrice
                    let buyerSaving = interval.buyerPrice - bestPrice
                    if yourGain > 0 && buyerSaving > 0 {
                        eligibleCount += 1
                    }
                }
                let winWin = Double(eligibleCount) / Double(hourIntervals.count) * 100
                hourWinWin.append((hour: hour, winWin: winWin))
            }

            // Build a mock breakdown for filtering
            let mockBreakdown = hourWinWin.map { hw in
                P2PHourlyBreakdown(
                    hour: hw.hour,
                    intervalCount: 1,
                    exportKwh: 0,
                    avgBuyPrice: 0,
                    avgSellPrice: 0,
                    avgSpread: 0,
                    dailyKwh: 0,
                    dailyExtraAtRecommended: 0,
                    winWinAtRecommended: hw.winWin
                )
            }
            filteredWindow = filterHoursByWinWin(
                hourlyBreakdown: mockBreakdown,
                peakStartHour: peakStartHour,
                peakEndHour: peakEndHour,
                threshold: winWinThreshold
            )
        }

        // MARK: - P2P Contract Execution Requirements

        // Use filtered window for rate calculation
        let effectiveWindowHours = filteredWindow.filteredEnd - filteredWindow.filteredStart
        let windowHours = effectiveWindowHours > 0 ? effectiveWindowHours : (peakEndHour - peakStartHour)
        let requiredExportRateKw = weeklyTotalKwh / (Double(windowHours) * 7.0)

        // Check if system can sustain this rate
        let systemCanSustain = requiredExportRateKw <= inverterExportKw

        // Check battery capacity vs window - use effective exportable capacity
        let maxWindowExportKwh = effectiveExportableKwh  // Per day, from battery minus overnight load
        let requiredDailyExportKwh = weeklyTotalKwh / 7.0

        var effectiveWindowWarning: String? = nil
        if !filteredWindow.excludedHours.isEmpty {
            let excludedStr = filteredWindow.excludedHours.map { "\($0 % 12 == 0 ? 12 : $0 % 12)\($0 < 12 ? "am" : "pm")" }.joined(separator: ", ")
            effectiveWindowWarning = "Hours \(excludedStr) excluded (win-win <\(Int(winWinThreshold))%)"
        }
        if !systemCanSustain {
            let rateWarning = "Required rate \(String(format: "%.1f", requiredExportRateKw)) kW exceeds inverter capacity \(String(format: "%.0f", inverterExportKw)) kW"
            effectiveWindowWarning = effectiveWindowWarning.map { $0 + ". " + rateWarning } ?? rateWarning
        } else if requiredDailyExportKwh > maxWindowExportKwh {
            let battWarning = "Daily \(String(format: "%.0f", requiredDailyExportKwh)) kWh may exceed available battery (~\(String(format: "%.0f", maxWindowExportKwh)) kWh after \(String(format: "%.0f", overnightLoadKwh)) kWh overnight load)"
            effectiveWindowWarning = effectiveWindowWarning.map { $0 + ". " + battWarning } ?? battWarning
        }

        // Supply/demand insight: after 7pm, seller supply drops dramatically while buyer demand stays steady
        // This creates a premium window opportunity for those with sufficient battery reserves
        let supplyDemandNote: String?
        if filteredWindow.filteredEnd >= 19 && effectiveExportableKwh >= 20 {
            // Battery can potentially reach the premium window
            supplyDemandNote = "7pm+ is a premium window — supply drops 65% while demand stays steady. Consider extending to capture undersupply pricing."
        } else if filteredWindow.filteredEnd < 19 && effectiveExportableKwh >= 30 {
            // Battery could reach premium but window doesn't include it
            supplyDemandNote = "Your battery may support extending to 7-9pm where seller supply is scarce."
        } else if filteredWindow.filteredEnd >= 19 && effectiveExportableKwh < 20 {
            // Window includes premium but battery may not sustain
            supplyDemandNote = "7pm+ has premium pricing but ensure battery reserves can sustain exports into evening."
        } else {
            supplyDemandNote = nil
        }

        // Append supply/demand note to warning if present
        if let note = supplyDemandNote {
            effectiveWindowWarning = effectiveWindowWarning.map { $0 + ". " + note } ?? note
        }

        return P2PTieredRecommendation(
            weeklyTotalKwh: weeklyTotalKwh,
            weeklyEstimatedRevenue: weeklyEstimatedRevenue,
            startHour: peakStartHour,
            endHour: peakEndHour,
            tiers: tiers,
            batteryCapacityKwh: batteryCapacityKwh,
            inverterExportKw: inverterExportKw,
            maxDailyExportKwh: maxDailyExportKwh,
            lvContractLimitKwh: config.lvExportBudgetKwh ?? lvContractLimitKwh,  // Use config budget if set
            overnightLoadKwh: overnightLoadKwh,
            effectiveExportableKwh: effectiveExportableKwh,
            filteredStartHour: filteredWindow.filteredStart,
            filteredEndHour: filteredWindow.filteredEnd,
            excludedHours: filteredWindow.excludedHours,
            winWinThreshold: winWinThreshold,
            requiredExportRateKw: requiredExportRateKw,
            windowHours: windowHours,
            systemCanSustain: systemCanSustain,
            effectiveWindowWarning: effectiveWindowWarning,
            contractsAnalyzed: contractsAnalyzed,
            hasHistoricalData: hasHistoricalData,
            tradesAnalyzed: tradesAnalyzed,
            forecastTradesIncluded: forecastTradesIncluded,
            outlierTradesExcluded: outlierTradesExcluded,
            previousContract: previousContract,
            recommendationChanged: recommendationChanged,
            changeReason: changeReason,
            renewalDueDate: renewalInfo.dueDate,
            daysUntilRenewal: renewalInfo.daysUntil,
            renewalUrgency: renewalInfo.urgency,
            singlePriceRecommendation: singlePriceRecommendation,
            recommendationDivergence: recommendationDivergence
        )
    }

    // MARK: - Divergence Detection

    private func detectDivergence(
        tieredPrices: [Double],
        singlePriceRecommendation: Double?,
        avgSpotSellPrice: Double
    ) -> String? {
        guard let singlePrice = singlePriceRecommendation else { return nil }

        var issues: [String] = []

        // Check if tiered prices align with win-win recommendation
        let avgTieredPrice = tieredPrices.reduce(0, +) / Double(max(1, tieredPrices.count))

        // Flag if tiered average is significantly different from single-price recommendation
        if abs(avgTieredPrice - singlePrice) > 5 {
            if avgTieredPrice < singlePrice {
                issues.append("Tiered prices (\(Int(avgTieredPrice))¢ avg) are below the optimal \(Int(singlePrice))¢ — consider raising")
            } else {
                issues.append("Tiered prices (\(Int(avgTieredPrice))¢ avg) exceed optimal \(Int(singlePrice))¢ — may reduce fill rate")
            }
        }

        // Flag any tier below spot price
        let belowSpot = tieredPrices.filter { $0 < avgSpotSellPrice }
        if !belowSpot.isEmpty {
            issues.append("Warning: \(belowSpot.map { "\(Int($0))¢" }.joined(separator: ", ")) below avg spot (\(Int(avgSpotSellPrice))¢)")
        }

        // Flag if no tier near the recommended price
        let nearRecommended = tieredPrices.filter { abs($0 - singlePrice) <= 5 }
        if nearRecommended.isEmpty && tieredPrices.count > 1 {
            issues.append("No tier near optimal \(Int(singlePrice))¢ — consider adding")
        }

        return issues.isEmpty ? nil : issues.joined(separator: ". ")
    }

    // MARK: - Price Clustering

    /// Cluster actual trade prices to find natural tier points
    private func clusterTradePrices(
        _ trades: [P2PCounterpartyTrade],
        historicalPerformance: [Int: HistoricalTierPerformance]
    ) -> [PriceCluster] {
        guard !trades.isEmpty else { return [] }

        // Round prices to nearest cent and aggregate
        var priceAggregates: [Int: (volume: Double, count: Int)] = [:]

        for trade in trades {
            let roundedPrice = Int(round(trade.priceCents))
            let existing = priceAggregates[roundedPrice] ?? (volume: 0, count: 0)
            priceAggregates[roundedPrice] = (
                volume: existing.volume + trade.volumeKwh,
                count: existing.count + 1
            )
        }

        // Merge adjacent prices into clusters (within 2¢ of each other)
        var clusters: [PriceCluster] = []
        let sortedPrices = priceAggregates.keys.sorted()

        var currentClusterPrices: [Int] = []
        var currentClusterVolume: Double = 0
        var currentClusterCount: Int = 0

        for price in sortedPrices {
            let aggregate = priceAggregates[price]!

            if currentClusterPrices.isEmpty {
                currentClusterPrices = [price]
                currentClusterVolume = aggregate.volume
                currentClusterCount = aggregate.count
            } else if let lastPrice = currentClusterPrices.last, price - lastPrice <= 2 {
                // Merge into current cluster
                currentClusterPrices.append(price)
                currentClusterVolume += aggregate.volume
                currentClusterCount += aggregate.count
            } else {
                // Finalize current cluster and start new one
                if let cluster = finalizeCluster(
                    prices: currentClusterPrices,
                    volume: currentClusterVolume,
                    count: currentClusterCount,
                    historicalPerformance: historicalPerformance
                ) {
                    clusters.append(cluster)
                }

                currentClusterPrices = [price]
                currentClusterVolume = aggregate.volume
                currentClusterCount = aggregate.count
            }
        }

        // Finalize last cluster
        if let cluster = finalizeCluster(
            prices: currentClusterPrices,
            volume: currentClusterVolume,
            count: currentClusterCount,
            historicalPerformance: historicalPerformance
        ) {
            clusters.append(cluster)
        }

        // Filter to clusters with meaningful volume (at least 1 kWh or 2+ trades)
        return clusters.filter { $0.totalVolumeKwh >= 1.0 || $0.tradeCount >= 2 }
            .sorted { $0.totalVolumeKwh > $1.totalVolumeKwh }
    }

    private func finalizeCluster(
        prices: [Int],
        volume: Double,
        count: Int,
        historicalPerformance: [Int: HistoricalTierPerformance]
    ) -> PriceCluster? {
        guard !prices.isEmpty else { return nil }

        // Calculate weighted center price
        let centerPrice = Double(prices.reduce(0, +)) / Double(prices.count)

        // Get fill rate from historical performance if available
        let avgFillRate: Double?
        let matchingPerf = prices.compactMap { historicalPerformance[$0] }
        if !matchingPerf.isEmpty {
            let totalOffered = matchingPerf.reduce(0) { $0 + $1.totalOfferedKwh }
            let totalFilled = matchingPerf.reduce(0) { $0 + $1.totalFilledKwh }
            avgFillRate = totalOffered > 0 ? (totalFilled / totalOffered) * 100 : nil
        } else {
            avgFillRate = nil
        }

        return PriceCluster(
            centerPrice: round(centerPrice),
            minPrice: Double(prices.min() ?? Int(centerPrice)),
            maxPrice: Double(prices.max() ?? Int(centerPrice)),
            totalVolumeKwh: volume,
            tradeCount: count,
            avgFillRate: avgFillRate
        )
    }

    // MARK: - Renewal Timing

    private func calculateRenewalTiming(
        activeContract: P2PContract?,
        upcomingContract: P2PContract?,
        today: Date,
        calendar: Calendar
    ) -> (dueDate: Date?, daysUntil: Int?, urgency: RenewalUrgency) {

        // If there's an upcoming contract already scheduled, no urgency
        if upcomingContract != nil {
            return (nil, nil, .none)
        }

        guard let active = activeContract else {
            // No active contract - check if we had one recently
            return (nil, nil, .none)
        }

        // Calculate when renewal should be scheduled (6+ days before contract ends)
        let contractEndDate = calendar.startOfDay(for: active.endDate)
        let renewalDueDate = calendar.date(byAdding: .day, value: -6, to: contractEndDate)!

        let daysUntilEnd = calendar.dateComponents([.day], from: today, to: contractEndDate).day ?? 0
        let daysUntilRenewal = calendar.dateComponents([.day], from: today, to: renewalDueDate).day ?? 0

        let urgency: RenewalUrgency
        if daysUntilEnd < 0 {
            urgency = .overdue
        } else if daysUntilRenewal < 0 {
            urgency = .urgent  // Less than 6 days until contract ends
        } else if daysUntilRenewal <= 8 {
            urgency = .upcoming  // 6-14 days out - good time to schedule
        } else {
            urgency = .none
        }

        return (renewalDueDate, daysUntilRenewal, urgency)
    }

    // MARK: - Change Detection

    private func detectRecommendationChanges(
        newTiers: [P2PRecommendedTier],
        previousContract: P2PPreviousContractSummary?
    ) -> (changed: Bool, reason: String?) {
        guard let previous = previousContract else {
            return (false, nil)
        }

        let newPrices = newTiers.map { $0.priceCents }.sorted(by: >)
        let oldPrices = previous.tierPrices.sorted(by: >)

        // Check for tier count change
        if newPrices.count != oldPrices.count {
            let direction = newPrices.count > oldPrices.count ? "more" : "fewer"
            return (true, "Recommending \(direction) tiers based on recent trade patterns")
        }

        // Check for significant price changes (>2¢ difference in any tier)
        var significantChanges: [String] = []

        for (i, newPrice) in newPrices.enumerated() {
            if i < oldPrices.count {
                let diff = newPrice - oldPrices[i]
                if abs(diff) > 2 {
                    let direction = diff > 0 ? "higher" : "lower"
                    significantChanges.append("\(Int(newPrice))¢ (\(direction) than \(Int(oldPrices[i]))¢)")
                }
            }
        }

        if !significantChanges.isEmpty {
            return (true, "Price adjustment: \(significantChanges.joined(separator: ", "))")
        }

        // Check for significant volume change
        let newTotalKwh = newTiers.reduce(0) { $0 + $1.weeklyKwh }
        let volumeDiff = abs(newTotalKwh - previous.totalKwh) / previous.totalKwh
        if volumeDiff > 0.2 {
            let direction = newTotalKwh > previous.totalKwh ? "increased" : "decreased"
            return (true, "Weekly volume \(direction) based on recent export patterns")
        }

        return (false, nil)
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
