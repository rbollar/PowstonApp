//
//  LVMarketContract.swift
//  Powston
//
//  Market-wide P2P contract from LocalVolts ContractTable API
//  Shows all executed P2P trades across the entire platform
//
//  IMPORTANT: Understanding the volume field:
//  - Non-zero volume = pending delivery (future periods, not yet settled)
//  - Zero volume = settled (past periods, energy already delivered)
//  The prices persist regardless of settlement status, making this valuable for market intelligence.
//  The spread between buyPrice and sellPrice shows the LocalVolts matching fee.
//

import Foundation
import GRDB

// MARK: - Market Contract Model

struct LVMarketContract: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lv_market_contracts"

    var id: UUID
    var buyer: String
    var seller: String
    var buyerFacility: String?
    var sellerFacility: String?
    var region: String?           // NEM region (QLD1, NSW1, VIC1, SA1, TAS1)
    var sellPriceCents: Double    // What seller receives (cents/kWh)
    var buyPriceCents: Double     // What buyer pays (cents/kWh)
    var volumeKwh: Double         // Pending volume (0 = settled, >0 = pending)
    var period: Int               // 5-minute period (1-288)
    var tradeDate: Date           // Actual trading date
    var fetchedAt: Date
    var category: String?         // SR (Solar Retailer), SC (Solar Consumer), etc.

    enum CodingKeys: String, CodingKey {
        case id
        case buyer
        case seller
        case buyerFacility = "buyer_facility"
        case sellerFacility = "seller_facility"
        case region
        case sellPriceCents = "sell_price_cents"
        case buyPriceCents = "buy_price_cents"
        case volumeKwh = "volume_kwh"
        case period
        case tradeDate = "trade_date"
        case fetchedAt = "fetched_at"
        case category
    }

    // MARK: - Computed Properties

    /// Whether this contract is settled (period has passed)
    var isSettled: Bool {
        volumeKwh == 0
    }

    /// Whether this contract is pending (future period)
    var isPending: Bool {
        volumeKwh > 0
    }

    /// LocalVolts matching fee (spread between buy and sell price)
    var matchingFeeCents: Double {
        buyPriceCents - sellPriceCents
    }

    /// Matching fee as percentage of sell price
    var matchingFeePercent: Double {
        guard sellPriceCents > 0 else { return 0 }
        return (matchingFeeCents / sellPriceCents) * 100
    }

    /// Legacy compatibility - use sell price as the "contract price"
    var priceCents: Double {
        sellPriceCents
    }

    var revenue: Double {
        volumeKwh * sellPriceCents / 100.0
    }

    /// Calculate the actual time from period number
    /// Period 1 = 00:00, Period 288 = 23:55 (5-minute intervals)
    var periodTime: Date {
        let calendar = Calendar(identifier: .gregorian)
        let minutesOffset = (period - 1) * 5
        return calendar.date(byAdding: .minute, value: minutesOffset, to: tradeDate) ?? tradeDate
    }

    /// Format period as HH:mm string
    var periodTimeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        return formatter.string(from: periodTime)
    }
}

// MARK: - API Parsing

extension LVMarketContract {

    /// Parse a market contract from ContractTable API response
    /// ContractTable format: buyer, seller, buyFacility, sellFacility, buyRegion, sellRegion, sellPrice, buyPrice, volume, period, date, category
    ///
    /// Note: volume=0 means the contract is settled (past period), volume>0 means pending (future period).
    /// Both are valuable for market intelligence - prices persist regardless of settlement status.
    static func parse(
        from dict: [String: Any],
        fetchedAt: Date = Date()
    ) -> LVMarketContract? {
        // Required fields - buyer, seller, period, date
        guard let buyer = dict["buyer"] as? String,
              let seller = dict["seller"] as? String else {
            return nil
        }

        // Both prices are required for proper spread analysis
        // Prices are in dollars, convert to cents
        guard let sellPriceDollars = parseDouble(dict["sellPrice"]),
              let buyPriceDollars = parseDouble(dict["buyPrice"]) else {
            return nil
        }

        // Period number (1-288)
        guard let period = dict["period"] as? Int, period >= 1, period <= 288 else {
            return nil
        }

        // Parse trade date from the date field
        guard let tradeDate = parseTradingDate(from: dict) else {
            return nil
        }

        // Volume can be zero (settled) or positive (pending) - both are valid
        let volume = parseDouble(dict["volume"]) ?? 0

        // Region - use sellRegion as the primary region (where the energy was generated)
        let region = dict["sellRegion"] as? String ?? dict["buyRegion"] as? String ?? dict["region"] as? String

        // Category: SR (Solar Retailer), SC (Solar Consumer), etc.
        let category = dict["category"] as? String

        // Create deterministic ID from unique contract identifiers
        // This allows upsert instead of delete-all + insert-all
        let deterministicId = createDeterministicId(buyer: buyer, seller: seller, period: period, tradeDate: tradeDate)

        return LVMarketContract(
            id: deterministicId,
            buyer: buyer,
            seller: seller,
            buyerFacility: dict["buyFacility"] as? String ?? dict["buyerFacility"] as? String ?? dict["buyer_facility"] as? String,
            sellerFacility: dict["sellFacility"] as? String ?? dict["sellerFacility"] as? String ?? dict["seller_facility"] as? String,
            region: region,
            sellPriceCents: sellPriceDollars * 100.0,
            buyPriceCents: buyPriceDollars * 100.0,
            volumeKwh: volume,
            period: period,
            tradeDate: tradeDate,
            fetchedAt: fetchedAt,
            category: category
        )
    }

    /// Parse trading date from dict
    /// Note: ContractTable API uses the actual trading date directly (not settlement date T+1)
    private static func parseTradingDate(from dict: [String: Any]) -> Date? {
        guard let dateStr = dict["date"] as? String else { return nil }

        // AEST timezone (no DST - same as Brisbane)
        let aest = TimeZone(identifier: "Australia/Brisbane")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = aest

        // Extract just the date portion (YYYY-MM-DD) from the ISO string
        let dateOnly = String(dateStr.prefix(10))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = aest

        guard let baseDate = formatter.date(from: dateOnly) else {
            return nil
        }

        // Return start of day
        return calendar.startOfDay(for: baseDate)
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        guard let value = value else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// Create a deterministic UUID from contract identifiers
    /// This ensures the same contract always gets the same ID, enabling upsert
    private static func createDeterministicId(buyer: String, seller: String, period: Int, tradeDate: Date) -> UUID {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd"
        dateFormatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        let dateStr = dateFormatter.string(from: tradeDate)

        // Create a unique string from the contract identifiers
        let idString = "\(buyer)|\(seller)|\(period)|\(dateStr)"

        // Use SHA256-like approach: create a stable hash and format as UUID
        var hash: UInt64 = 5381
        for char in idString.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }

        // Create a second hash for more bits
        var hash2: UInt64 = 0
        for char in idString.utf8.reversed() {
            hash2 = ((hash2 << 5) &+ hash2) &+ UInt64(char)
        }

        // Format as UUID string (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
        let hex1 = String(format: "%08x", UInt32(truncatingIfNeeded: hash))
        let hex2 = String(format: "%04x", UInt16(truncatingIfNeeded: hash >> 32))
        let hex3 = String(format: "%04x", UInt16(truncatingIfNeeded: hash >> 48))
        let hex4 = String(format: "%04x", UInt16(truncatingIfNeeded: hash2))
        let hex5 = String(format: "%012llx", hash2 >> 16)

        let uuidString = "\(hex1)-\(hex2)-\(hex3)-\(hex4)-\(hex5.prefix(12))"
        return UUID(uuidString: uuidString) ?? UUID()
    }
}

// MARK: - Aggregation Results

struct LVMarketPriceDistribution: Identifiable {
    let id = UUID()
    let minPrice: Double
    let maxPrice: Double
    let avgPrice: Double
    let volumeWeightedAvgPrice: Double
    let totalVolume: Double
    let totalTrades: Int
    let percentiles: [Int: Double]  // P25, P50, P75
}

struct LVMarketVolumeTier: Identifiable {
    let id = UUID()
    let tierName: String           // e.g., "0-10c", "10-20c"
    let minPriceCents: Double
    let maxPriceCents: Double
    let volumeKwh: Double
    let tradeCount: Int
    let percentageOfTotal: Double
}

struct LVMarketSellerRank: Identifiable {
    let id = UUID()
    let seller: String
    let volumeKwh: Double
    let avgPriceCents: Double
    let tradeCount: Int
    let marketSharePercent: Double
    let rank: Int
}

struct LVMarketHourlyActivity: Identifiable {
    let id = UUID()
    let hour: Int
    let volumeKwh: Double
    let avgPriceCents: Double
    let tradeCount: Int
}

struct LVMarketSummary: Identifiable {
    let id = UUID()
    let tradeDate: Date
    let totalTrades: Int
    let totalVolumeKwh: Double
    let avgPriceCents: Double
    let minPriceCents: Double
    let maxPriceCents: Double
    let uniqueBuyers: Int
    let uniqueSellers: Int
    let priceDistribution: LVMarketPriceDistribution?
    let volumeTiers: [LVMarketVolumeTier]
    let topSellers: [LVMarketSellerRank]
    let hourlyActivity: [LVMarketHourlyActivity]
}

// MARK: - User Position Comparison

struct LVMarketUserPosition: Identifiable {
    let id = UUID()
    let userAvgPriceCents: Double
    let marketAvgPriceCents: Double
    let userVolumeKwh: Double
    let marketTotalVolumeKwh: Double
    let userTradeCount: Int
    let marketTradeCount: Int

    var pricePositionPercent: Double {
        guard marketAvgPriceCents > 0 else { return 0 }
        return ((userAvgPriceCents - marketAvgPriceCents) / marketAvgPriceCents) * 100
    }

    var pricePositionDescription: String {
        let diff = pricePositionPercent
        if abs(diff) < 1 {
            return "At market average"
        } else if diff > 0 {
            return String(format: "%.0f%% above market", diff)
        } else {
            return String(format: "%.0f%% below market", abs(diff))
        }
    }

    var marketSharePercent: Double {
        guard marketTotalVolumeKwh > 0 else { return 0 }
        return (userVolumeKwh / marketTotalVolumeKwh) * 100
    }
}
