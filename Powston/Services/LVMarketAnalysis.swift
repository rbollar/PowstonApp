//
//  LVMarketAnalysis.swift
//  Powston
//
//  Analysis engine for market-wide P2P contract data
//  Provides aggregations, distributions, and leaderboards
//
//  NOTE: The volume field in contracts is a settlement indicator:
//  - volume = 0: settled (past period, energy delivered)
//  - volume > 0: pending (future period, not yet delivered)
//  For market intelligence, we analyze by contract COUNT and PRICE, not volume.
//

import Foundation
import Combine

// MARK: - Market Analysis Engine

@MainActor
class LVMarketAnalysis: ObservableObject {

    static let shared = LVMarketAnalysis()

    @Published var summary: LVMarketSummary?
    @Published var isAnalyzing = false
    @Published var error: String?

    private init() {}

    // MARK: - Analysis

    /// Analyze market contracts and generate summary
    /// Note: Volume is a settlement indicator, not trade size. We use contract counts for rankings.
    func analyze(contracts: [LVMarketContract], userSeller: String? = nil) -> LVMarketSummary? {
        guard !contracts.isEmpty else { return nil }

        isAnalyzing = true
        defer { isAnalyzing = false }

        let tradeDate = contracts.first?.tradeDate ?? Date()

        // Basic stats - use sell prices as the "contract price"
        let totalTrades = contracts.count
        let totalVolume = contracts.reduce(0) { $0 + $1.volumeKwh }  // For display only
        let sellPrices = contracts.map { $0.sellPriceCents }
        let avgPrice = sellPrices.reduce(0, +) / Double(sellPrices.count)
        let minPrice = sellPrices.min() ?? 0
        let maxPrice = sellPrices.max() ?? 0

        let uniqueBuyers = Set(contracts.map { $0.buyer }).count
        let uniqueSellers = Set(contracts.map { $0.seller }).count

        // Price distribution
        let priceDistribution = calculatePriceDistribution(contracts: contracts)

        // Volume tiers (really price tiers since volume isn't meaningful)
        let volumeTiers = calculateVolumeTiers(contracts: contracts, totalVolume: totalVolume)

        // Seller leaderboard - ranked by contract count, not volume
        let topSellers = calculateSellerLeaderboard(contracts: contracts, limit: 20)

        // Hourly activity - by contract count
        let hourlyActivity = calculateHourlyActivity(contracts: contracts)

        let result = LVMarketSummary(
            tradeDate: tradeDate,
            totalTrades: totalTrades,
            totalVolumeKwh: totalVolume,
            avgPriceCents: avgPrice,
            minPriceCents: minPrice,
            maxPriceCents: maxPrice,
            uniqueBuyers: uniqueBuyers,
            uniqueSellers: uniqueSellers,
            priceDistribution: priceDistribution,
            volumeTiers: volumeTiers,
            topSellers: topSellers,
            hourlyActivity: hourlyActivity
        )

        self.summary = result
        return result
    }

    /// Calculate user's position in the market
    /// Uses simple averages of sell prices (since volume is just a settlement indicator)
    func calculateUserPosition(
        contracts: [LVMarketContract],
        userSeller: String
    ) -> LVMarketUserPosition? {
        guard !contracts.isEmpty else { return nil }

        // User's trades
        let userContracts = contracts.filter { $0.seller == userSeller }
        guard !userContracts.isEmpty else { return nil }

        // Use simple average of sell prices (volume isn't meaningful for weighting)
        let userAvgPrice = userContracts.map { $0.sellPriceCents }.reduce(0, +) / Double(userContracts.count)
        let userVolume = userContracts.reduce(0) { $0 + $1.volumeKwh }  // For display only

        // Market stats - simple average of all sell prices
        let marketAvgPrice = contracts.map { $0.sellPriceCents }.reduce(0, +) / Double(contracts.count)
        let totalVolume = contracts.reduce(0) { $0 + $1.volumeKwh }

        return LVMarketUserPosition(
            userAvgPriceCents: userAvgPrice,
            marketAvgPriceCents: marketAvgPrice,
            userVolumeKwh: userVolume,
            marketTotalVolumeKwh: totalVolume,
            userTradeCount: userContracts.count,
            marketTradeCount: contracts.count
        )
    }

    // MARK: - Price Distribution

    private func calculatePriceDistribution(contracts: [LVMarketContract]) -> LVMarketPriceDistribution {
        // Use sell prices for distribution (what sellers receive)
        let sellPrices = contracts.map { $0.sellPriceCents }.sorted()
        guard !sellPrices.isEmpty else {
            return LVMarketPriceDistribution(
                minPrice: 0, maxPrice: 0, avgPrice: 0,
                volumeWeightedAvgPrice: 0, totalVolume: 0, totalTrades: 0, percentiles: [:]
            )
        }

        let minPrice = sellPrices.first ?? 0
        let maxPrice = sellPrices.last ?? 0
        let avgPrice = sellPrices.reduce(0, +) / Double(sellPrices.count)

        // Note: Volume is a settlement indicator, not trade size
        // Using simple average instead of volume-weighted
        let totalVolume = contracts.reduce(0) { $0 + $1.volumeKwh }

        // Percentiles
        func percentile(_ p: Int) -> Double {
            let index = Int(Double(sellPrices.count - 1) * Double(p) / 100.0)
            return sellPrices[index]
        }

        let percentiles: [Int: Double] = [
            25: percentile(25),
            50: percentile(50),
            75: percentile(75)
        ]

        return LVMarketPriceDistribution(
            minPrice: minPrice,
            maxPrice: maxPrice,
            avgPrice: avgPrice,
            volumeWeightedAvgPrice: avgPrice,  // Same as avg since volume isn't meaningful
            totalVolume: totalVolume,
            totalTrades: contracts.count,
            percentiles: percentiles
        )
    }

    // MARK: - Price Tiers

    /// Group contracts by price tier and count contracts in each tier
    /// Note: Uses contract count for percentages since volume is a settlement indicator
    private func calculateVolumeTiers(contracts: [LVMarketContract], totalVolume: Double) -> [LVMarketVolumeTier] {
        // Define price tiers (in cents) based on sell price
        let tiers: [(name: String, min: Double, max: Double)] = [
            ("0-5c", 0, 5),
            ("5-10c", 5, 10),
            ("10-15c", 10, 15),
            ("15-20c", 15, 20),
            ("20-25c", 20, 25),
            ("25-30c", 25, 30),
            ("30-40c", 30, 40),
            ("40c+", 40, 1000)
        ]

        let totalContracts = contracts.count

        return tiers.map { tier in
            let tierContracts = contracts.filter { $0.sellPriceCents >= tier.min && $0.sellPriceCents < tier.max }
            let tierVolume = tierContracts.reduce(0) { $0 + $1.volumeKwh }  // For display only
            // Use contract count for percentage (volume isn't meaningful)
            let percentage = totalContracts > 0 ? (Double(tierContracts.count) / Double(totalContracts)) * 100 : 0

            return LVMarketVolumeTier(
                tierName: tier.name,
                minPriceCents: tier.min,
                maxPriceCents: tier.max,
                volumeKwh: tierVolume,
                tradeCount: tierContracts.count,
                percentageOfTotal: percentage
            )
        }.filter { $0.tradeCount > 0 }  // Only include tiers with contracts
    }

    // MARK: - Seller Leaderboard

    /// Rank sellers by contract count (not volume, since volume is a settlement indicator)
    private func calculateSellerLeaderboard(contracts: [LVMarketContract], limit: Int) -> [LVMarketSellerRank] {
        // Group by seller
        let grouped = Dictionary(grouping: contracts) { $0.seller }
        let totalContracts = contracts.count

        var sellers: [(seller: String, count: Int, totalSellPrice: Double, volume: Double)] = []

        for (seller, sellerContracts) in grouped {
            let count = sellerContracts.count
            let totalSellPrice = sellerContracts.map { $0.sellPriceCents }.reduce(0, +)
            let volume = sellerContracts.reduce(0) { $0 + $1.volumeKwh }  // For display only
            sellers.append((seller, count, totalSellPrice, volume))
        }

        // Sort by contract count descending (not volume)
        sellers.sort { $0.count > $1.count }

        // Take top N and assign ranks
        return sellers.prefix(limit).enumerated().map { index, seller in
            let avgPrice = seller.count > 0 ? seller.totalSellPrice / Double(seller.count) : 0
            let marketShare = totalContracts > 0 ? (Double(seller.count) / Double(totalContracts)) * 100 : 0

            return LVMarketSellerRank(
                seller: seller.seller,
                volumeKwh: seller.volume,  // For display only
                avgPriceCents: avgPrice,
                tradeCount: seller.count,
                marketSharePercent: marketShare,
                rank: index + 1
            )
        }
    }

    // MARK: - Hourly Activity

    /// Calculate contract count and average price by hour
    /// Note: volumeKwh is kept for display compatibility but isn't meaningful
    private func calculateHourlyActivity(contracts: [LVMarketContract]) -> [LVMarketHourlyActivity] {
        // Group by hour
        var hourlyData: [Int: (volume: Double, totalSellPrice: Double, count: Int)] = [:]

        for contract in contracts {
            let hour = (contract.period - 1) * 5 / 60  // Convert period to hour
            let existing = hourlyData[hour] ?? (0, 0, 0)
            hourlyData[hour] = (
                existing.volume + contract.volumeKwh,
                existing.totalSellPrice + contract.sellPriceCents,
                existing.count + 1
            )
        }

        return (0..<24).compactMap { hour in
            guard let data = hourlyData[hour], data.count > 0 else { return nil }
            let avgPrice = data.totalSellPrice / Double(data.count)

            return LVMarketHourlyActivity(
                hour: hour,
                volumeKwh: data.volume,  // For display compatibility
                avgPriceCents: avgPrice,
                tradeCount: data.count
            )
        }
    }

    // MARK: - Region Filtering

    /// Get contracts for a specific region
    func filterByRegion(_ contracts: [LVMarketContract], region: String?) -> [LVMarketContract] {
        guard let region = region else { return contracts }
        return contracts.filter { $0.region == region }
    }

    /// Get available regions from contracts
    func getAvailableRegions(_ contracts: [LVMarketContract]) -> [String] {
        Array(Set(contracts.compactMap { $0.region })).sorted()
    }
}

// MARK: - Price Histogram Support

extension LVMarketAnalysis {

    struct PriceHistogramBin: Identifiable {
        let id = UUID()
        let minPrice: Double
        let maxPrice: Double
        let count: Int
        let totalVolume: Double  // Actual kWh volume for display

        var label: String {
            String(format: "%.0f-%.0f¢", minPrice, maxPrice)
        }
    }

    // Type alias for view compatibility
    typealias PriceBin = PriceHistogramBin

    /// Generate histogram bins for price distribution chart
    /// Uses sell prices (what sellers receive)
    func generatePriceHistogram(contracts: [LVMarketContract], binCount: Int = 20) -> [PriceHistogramBin] {
        guard !contracts.isEmpty else { return [] }

        let prices = contracts.map { $0.sellPriceCents }
        let minPrice = prices.min() ?? 0
        let maxPrice = prices.max() ?? 0
        let range = maxPrice - minPrice

        guard range > 0 else {
            let totalVol = contracts.reduce(0) { $0 + $1.volumeKwh }
            return [PriceHistogramBin(minPrice: minPrice, maxPrice: maxPrice, count: contracts.count,
                                      totalVolume: totalVol)]
        }

        let binWidth = range / Double(binCount)

        var bins: [PriceHistogramBin] = []
        for i in 0..<binCount {
            let binMin = minPrice + Double(i) * binWidth
            let binMax = minPrice + Double(i + 1) * binWidth
            let binContracts = contracts.filter { $0.sellPriceCents >= binMin && $0.sellPriceCents < binMax }

            if binContracts.count > 0 {
                let binVolume = binContracts.reduce(0) { $0 + $1.volumeKwh }
                bins.append(PriceHistogramBin(
                    minPrice: binMin,
                    maxPrice: binMax,
                    count: binContracts.count,
                    totalVolume: binVolume
                ))
            }
        }

        return bins
    }
}

// MARK: - Hourly Price Stats (Buy/Sell with Percentiles)

extension LVMarketAnalysis {

    /// Hourly price statistics with buy/sell spread and percentiles
    /// Uses settled contracts only for accurate historical pricing
    struct HourlyPriceStats: Identifiable {
        let id = UUID()
        let hour: Int
        let avgSellPrice: Double
        let avgBuyPrice: Double
        let p25SellPrice: Double  // 25th percentile (low)
        let p50SellPrice: Double  // Median
        let p75SellPrice: Double  // 75th percentile (high)
        let matchingFee: Double   // Average buy - sell spread
        let contractCount: Int
        let totalVolume: Double   // Total kWh for this hour

        // Aliases for view compatibility
        var tradeCount: Int { contractCount }

        var hourLabel: String {
            String(format: "%02d:00", hour)
        }

        /// For candlestick-style display: low/mid/high
        var priceRange: (low: Double, mid: Double, high: Double) {
            (p25SellPrice, p50SellPrice, p75SellPrice)
        }
    }

    // Type alias for view compatibility
    typealias LVHourlyPriceStat = HourlyPriceStats

    /// Calculate hourly price stats with buy/sell spread and percentiles
    /// Focuses on settled contracts (volume=0) for accurate historical data
    func calculateHourlyPriceStats(contracts: [LVMarketContract], settledOnly: Bool = true) -> [HourlyPriceStats] {
        // Filter to settled contracts if requested
        let filtered = settledOnly ? contracts.filter { $0.isSettled } : contracts

        // Group by hour
        var hourlyContracts: [Int: [LVMarketContract]] = [:]
        for contract in filtered {
            let hour = (contract.period - 1) * 5 / 60
            hourlyContracts[hour, default: []].append(contract)
        }

        return (0..<24).compactMap { hour -> HourlyPriceStats? in
            guard let contracts = hourlyContracts[hour], !contracts.isEmpty else { return nil }

            let sellPrices = contracts.map { $0.sellPriceCents }.sorted()
            let buyPrices = contracts.map { $0.buyPriceCents }
            let totalVol = contracts.reduce(0) { $0 + $1.volumeKwh }

            let avgSell = sellPrices.reduce(0, +) / Double(sellPrices.count)
            let avgBuy = buyPrices.reduce(0, +) / Double(buyPrices.count)

            // Percentiles
            func percentile(_ prices: [Double], _ p: Double) -> Double {
                guard !prices.isEmpty else { return 0 }
                let index = Int(Double(prices.count - 1) * p)
                return prices[min(index, prices.count - 1)]
            }

            return HourlyPriceStats(
                hour: hour,
                avgSellPrice: avgSell,
                avgBuyPrice: avgBuy,
                p25SellPrice: percentile(sellPrices, 0.25),
                p50SellPrice: percentile(sellPrices, 0.50),
                p75SellPrice: percentile(sellPrices, 0.75),
                matchingFee: avgBuy - avgSell,
                contractCount: contracts.count,
                totalVolume: totalVol
            )
        }
    }
}
