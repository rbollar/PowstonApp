//
//  LVOrder.swift
//  Powston
//
//  LocalVolts Order/Contract model from TradeList API
//  Represents standing orders (contracts) on the P2P platform
//

import Foundation
import GRDB

// MARK: - LV Order Model

struct LVOrder: Codable, Identifiable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "lv_orders"

    var id: String              // orderId from API (string)
    var siteId: Int
    var customerId: String
    var direction: String       // "Buy" or "Sell"
    var nmi: String?
    var dateFrom: Date
    var dateTo: Date
    var volumeKwh: Double
    var priceCents: Double?     // nil for market-price orders ("N/A")
    var tradeDate: Date         // When order was created
    var status: String?         // "Confirmed", "Cancelled" (from TradeDetail)
    var fetchedAt: Date

    // Time window (parsed from order details if available)
    var startHour: Int?         // e.g., 10 for 10:00
    var endHour: Int?           // e.g., 16 for 16:00

    enum CodingKeys: String, CodingKey {
        case id
        case siteId = "site_id"
        case customerId = "customer_id"
        case direction
        case nmi
        case dateFrom = "date_from"
        case dateTo = "date_to"
        case volumeKwh = "volume_kwh"
        case priceCents = "price_cents"
        case tradeDate = "trade_date"
        case status
        case fetchedAt = "fetched_at"
        case startHour = "start_hour"
        case endHour = "end_hour"
    }

    // MARK: - Computed Properties

    var isActive: Bool {
        let today = Calendar.current.startOfDay(for: Date())
        return dateTo >= today && status != "Cancelled"
    }

    var isBuy: Bool { direction == "Buy" }
    var isSell: Bool { direction == "Sell" }

    var isMarketPrice: Bool { priceCents == nil }

    var durationDays: Int {
        let calendar = Calendar.current
        return (calendar.dateComponents([.day], from: dateFrom, to: dateTo).day ?? 0) + 1
    }

    var dayProgress: Int? {
        guard isActive else { return nil }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayNum = (calendar.dateComponents([.day], from: dateFrom, to: today).day ?? 0) + 1
        return max(1, min(dayNum, durationDays))
    }

    var timeWindowString: String? {
        guard let start = startHour, let end = endHour else { return nil }
        return String(format: "%02d:00–%02d:00 AEST", start, end)
    }

    var priceString: String {
        if let price = priceCents {
            return String(format: "%.1f¢", price)
        }
        return "Market"
    }
}

// MARK: - API Parsing

extension LVOrder {

    /// Parse from TradeList response
    /// Fields: orderId, customerId, direction, NMI, dateFrom, dateTo, volume, price, tradeDate
    static func parse(
        from dict: [String: Any],
        siteId: Int,
        fetchedAt: Date = Date()
    ) -> LVOrder? {
        guard let orderIdRaw = dict["orderId"],
              let direction = dict["direction"] as? String,
              let volumeRaw = dict["volume"] else {
            return nil
        }

        // orderId can be Int or String
        let orderId: String
        if let id = orderIdRaw as? Int {
            orderId = String(id)
        } else if let id = orderIdRaw as? String {
            orderId = id
        } else {
            return nil
        }

        let volume = parseDouble(volumeRaw) ?? 0
        guard volume > 0 else { return nil }

        // Parse dates
        guard let dateFrom = parseDate(dict["dateFrom"]),
              let dateTo = parseDate(dict["dateTo"]) else {
            return nil
        }

        let tradeDate = parseDate(dict["tradeDate"]) ?? fetchedAt

        // Price - can be "N/A" for market orders
        var priceCents: Double? = nil
        if let priceRaw = dict["price"] {
            if let priceStr = priceRaw as? String, priceStr != "N/A" {
                if let p = Double(priceStr) {
                    priceCents = p * 100.0  // Convert dollars to cents
                }
            } else if let p = parseDouble(priceRaw) {
                priceCents = p * 100.0
            }
        }

        let customerId: String
        if let cid = dict["customerId"] as? Int {
            customerId = String(cid)
        } else if let cid = dict["customerId"] as? String {
            customerId = cid
        } else {
            customerId = ""
        }

        return LVOrder(
            id: orderId,
            siteId: siteId,
            customerId: customerId,
            direction: direction,
            nmi: dict["NMI"] as? String,
            dateFrom: dateFrom,
            dateTo: dateTo,
            volumeKwh: volume,
            priceCents: priceCents,
            tradeDate: tradeDate,
            status: dict["status"] as? String,
            fetchedAt: fetchedAt,
            startHour: nil,
            endHour: nil
        )
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        guard let value = value else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ value: Any?) -> Date? {
        guard let value = value else { return nil }

        let aest = TimeZone(identifier: "Australia/Brisbane")!

        if let dateStr = value as? String {
            // Try ISO8601 first
            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.timeZone = aest
            if let date = isoFormatter.date(from: dateStr) {
                return date
            }

            // Try date only format
            let dateFormatter = DateFormatter()
            dateFormatter.timeZone = aest
            dateFormatter.dateFormat = "yyyy-MM-dd"
            if let date = dateFormatter.date(from: String(dateStr.prefix(10))) {
                return date
            }
        }

        return nil
    }
}

// MARK: - Order Fill Summary (from TradeDetail)

struct LVOrderFill: Identifiable {
    let id = UUID()
    let orderId: String
    let counterpartyName: String
    let dealtKwh: Double        // Volume dealt/matched
    let settledKwh: Double      // Volume settled
    let priceCents: Double?     // Price in cents/kWh
    let matchTime: Date?
}

extension LVOrderFill {
    /// Parse from TradeDetail array[2] - counterparty summary
    /// Fields: counterparty, dealt, settled, sellPrice/buyPrice (in dollars), matchTime
    static func parse(from dict: [String: Any], orderId: String) -> LVOrderFill? {
        guard let counterparty = dict["counterparty"] as? String else {
            return nil
        }

        let dealt = parseDouble(dict["dealt"]) ?? 0
        let settled = parseDouble(dict["settled"]) ?? 0

        // Price - can be sellPrice or buyPrice depending on contract direction
        // Prices are in dollars, convert to cents
        var priceCents: Double? = nil
        if let sellPrice = parseDouble(dict["sellPrice"]) {
            priceCents = sellPrice * 100.0
        } else if let buyPrice = parseDouble(dict["buyPrice"]) {
            priceCents = buyPrice * 100.0
        }

        // Parse match time
        var matchTime: Date? = nil
        if let matchTimeStr = dict["matchTime"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
            matchTime = formatter.date(from: matchTimeStr)
        }

        // Skip fills with 0 volume
        guard dealt > 0 || settled > 0 else { return nil }

        return LVOrderFill(
            orderId: orderId,
            counterpartyName: counterparty,
            dealtKwh: dealt,
            settledKwh: settled,
            priceCents: priceCents,
            matchTime: matchTime
        )
    }

    private static func parseDouble(_ value: Any?) -> Double? {
        guard let value = value else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }
}

// MARK: - Grouped Orders

/// Represents multiple LV orders with the same date range, merged into tiers
/// Orders placed within a short time window (e.g., 10 minutes) are considered
/// part of the same contract session
struct LVOrderGroup: Identifiable {
    let id: UUID = UUID()
    let orders: [LVOrder]

    /// The first order in the group (used for common properties)
    var primaryOrder: LVOrder { orders.first! }

    // Common properties from the grouped orders
    var siteId: Int { primaryOrder.siteId }
    var direction: String { primaryOrder.direction }
    var dateFrom: Date { primaryOrder.dateFrom }
    var dateTo: Date { primaryOrder.dateTo }
    var status: String? {
        // If any order is cancelled, show cancelled
        orders.contains { $0.status == "Cancelled" } ? "Cancelled" : orders.first?.status
    }

    // Simple sum of all order volumes
    var sumVolume: Double {
        orders.reduce(0.0) { $0 + $1.volumeKwh }
    }

    // Aggregated values
    // NOTE: In LocalVolts, when a contract has a "Market" fallback tier:
    // - The Market order (priceCents == nil) represents the TOTAL contract volume
    // - The priced orders are tiers WITHIN that total, not additional volume
    // Example: Market=129.6kWh + Tier@4¢=118.4kWh means total is 129.6, with 118.4 at fixed price
    var totalVolumeKwh: Double {
        guard orders.count > 1 else { return orders.first?.volumeKwh ?? 0 }

        // Check if there's a "Market" order (nil price) - this represents the total
        let marketOrders = orders.filter { $0.priceCents == nil }
        let pricedOrders = orders.filter { $0.priceCents != nil }

        if let marketOrder = marketOrders.first, !pricedOrders.isEmpty {
            // Market order exists alongside priced tiers
            // The Market order's volume IS the total contract volume
            return marketOrder.volumeKwh
        }

        // No market order - check for identical volumes (all tiers showing total)
        let volumes = orders.map { $0.volumeKwh }
        let maxVolume = volumes.max() ?? 0
        let minVolume = volumes.min() ?? 0

        // If all volumes are within 2% of each other, they likely all represent the same total
        if maxVolume > 0 && (maxVolume - minVolume) / maxVolume < 0.02 {
            return maxVolume
        }

        // Volumes differ significantly and no market order - sum the tier volumes
        return sumVolume
    }
    var orderIds: [String] { orders.map { $0.id } }
    var tradeDate: Date { orders.map { $0.tradeDate }.min() ?? Date() }

    // Time window from any order that has it
    var startHour: Int? { orders.compactMap { $0.startHour }.first }
    var endHour: Int? { orders.compactMap { $0.endHour }.first }
    var timeWindowString: String? {
        guard let start = startHour, let end = endHour else { return nil }
        return String(format: "%02d:00–%02d:00 AEST", start, end)
    }

    // Build tiers from individual orders (sorted by price ascending)
    // For contracts with market-price components, include a "market" tier at 0¢
    // This allows all trades to be matched, with market trades going to the 0¢ tier
    var tiers: [P2PContractTier] {
        var result = orders
            .filter { $0.priceCents != nil }
            .sorted { ($0.priceCents ?? 0) < ($1.priceCents ?? 0) }
            .map { order in
                P2PContractTier(
                    id: UUID(),
                    percentage: (order.volumeKwh / totalVolumeKwh) * 100,
                    priceCents: order.priceCents ?? 0,
                    volumeKwh: order.volumeKwh
                )
            }

        // Add a "market" tier if there's market volume
        // This tier captures trades that happen at market price
        if hasMarketComponent && marketVolumeKwh > 0 {
            let marketTier = P2PContractTier(
                id: UUID(),
                percentage: (marketVolumeKwh / totalVolumeKwh) * 100,
                priceCents: 0,  // Use 0 as marker for "market price"
                volumeKwh: marketVolumeKwh
            )
            // Insert at beginning since it's the lowest "price"
            result.insert(marketTier, at: 0)
        }

        return result
    }

    // Blended price across priced tiers (excludes market-price portion)
    var blendedPriceCents: Double {
        let pricedOrders = orders.filter { $0.priceCents != nil }
        guard !pricedOrders.isEmpty else { return 0 }

        let pricedVolume = pricedOrders.reduce(0.0) { $0 + $1.volumeKwh }
        guard pricedVolume > 0 else { return 0 }

        let totalRevenue = pricedOrders.reduce(0.0) { $0 + ($1.volumeKwh * ($1.priceCents ?? 0)) }
        return totalRevenue / pricedVolume
    }

    // Whether this contract has a market-price fallback component
    var hasMarketComponent: Bool {
        orders.contains { $0.priceCents == nil }
    }

    // Volume at market price (if any)
    var marketVolumeKwh: Double {
        guard hasMarketComponent else { return 0 }
        let pricedVolume = orders.filter { $0.priceCents != nil }.reduce(0.0) { $0 + $1.volumeKwh }
        return max(0, totalVolumeKwh - pricedVolume)
    }

    var priceRangeString: String {
        let prices = orders.compactMap { $0.priceCents }.sorted()
        let marketSuffix = hasMarketComponent ? " + Market" : ""

        guard let minPrice = prices.first, let maxPrice = prices.last else {
            return "Market"
        }
        if minPrice == maxPrice {
            return String(format: "%.0f¢%@", minPrice, marketSuffix)
        }
        return String(format: "%.0f–%.0f¢%@", minPrice, maxPrice, marketSuffix)
    }

    var isActive: Bool { primaryOrder.isActive }
    var isSell: Bool { primaryOrder.isSell }
    var isBuy: Bool { primaryOrder.isBuy }

    var durationDays: Int { primaryOrder.durationDays }

    var dayProgress: Int? { primaryOrder.dayProgress }

    /// Convert to P2PContract with multiple tiers for performance tracking
    func toP2PContract() -> P2PContract {
        let contractTiers = tiers
        let contractDirection: P2PTradeDirection = isSell ? .sell : .buy
        let hours = (startHour ?? 10, endHour ?? 16)

        return P2PContract(
            id: id,
            siteId: siteId,
            direction: contractDirection,
            startDate: dateFrom,
            endDate: dateTo,
            startHour: hours.0,
            endHour: hours.1,
            tiers: contractTiers,
            totalVolumeKwh: totalVolumeKwh,
            renewalDays: nil,
            isActive: isActive,
            createdAt: tradeDate,
            notes: "Imported from LocalVolts (Orders: \(orderIds.joined(separator: ", ")))"
        )
    }
}

extension LVOrder {
    /// Group orders by date range and trade session
    /// Orders with same dateFrom/dateTo and tradeDates within threshold are merged
    /// - Parameters:
    ///   - orders: Array of LVOrder to group
    ///   - sessionThreshold: Maximum seconds between tradeDates to be considered same session (default 10 minutes)
    /// - Returns: Array of LVOrderGroup, each representing one or more merged orders
    static func groupByContract(_ orders: [LVOrder], sessionThreshold: TimeInterval = 600) -> [LVOrderGroup] {
        // First group by (direction, dateFrom, dateTo)
        var dateGroups: [String: [LVOrder]] = [:]

        let calendar = Calendar.current
        for order in orders {
            let fromDay = calendar.startOfDay(for: order.dateFrom)
            let toDay = calendar.startOfDay(for: order.dateTo)
            let key = "\(order.direction)_\(fromDay.timeIntervalSince1970)_\(toDay.timeIntervalSince1970)"
            dateGroups[key, default: []].append(order)
        }

        var result: [LVOrderGroup] = []

        // Within each date group, further split by trade session timing
        for (_, groupOrders) in dateGroups {
            // Sort by tradeDate
            let sorted = groupOrders.sorted { $0.tradeDate < $1.tradeDate }

            var currentSession: [LVOrder] = []
            var lastTradeDate: Date?

            for order in sorted {
                if let last = lastTradeDate {
                    let gap = order.tradeDate.timeIntervalSince(last)
                    if gap > sessionThreshold {
                        // New session - save current and start fresh
                        if !currentSession.isEmpty {
                            result.append(LVOrderGroup(orders: currentSession))
                        }
                        currentSession = [order]
                    } else {
                        // Same session
                        currentSession.append(order)
                    }
                } else {
                    currentSession = [order]
                }
                lastTradeDate = order.tradeDate
            }

            // Don't forget the last session
            if !currentSession.isEmpty {
                result.append(LVOrderGroup(orders: currentSession))
            }
        }

        // Sort groups by dateFrom descending
        let sorted = result.sorted { $0.dateFrom > $1.dateFrom }

        // Debug: Log grouping results
        for group in sorted.prefix(3) {
            print("📦 Order Group: \(group.orders.count) orders, direction=\(group.direction), total=\(String(format: "%.1f", group.totalVolumeKwh)) kWh")
            for order in group.orders.prefix(5) {
                print("   └─ Order \(order.id): \(String(format: "%.1f", order.volumeKwh)) kWh @ \(order.priceString)")
            }
        }

        return sorted
    }
}

// MARK: - Convert to P2PContract

extension LVOrder {
    /// Convert this LV order to a P2PContract for performance tracking
    /// Creates a single-tier contract matching the order's terms
    func toP2PContract() -> P2PContract {
        // Create a single tier with the order's price and volume
        let tier = P2PContractTier(
            id: UUID(),
            percentage: 100.0,
            priceCents: priceCents ?? 0,  // Market orders default to 0
            volumeKwh: volumeKwh
        )

        // Determine direction
        let direction: P2PTradeDirection = isSell ? .sell : .buy

        // Default hours if not specified
        let hours = (startHour ?? 10, endHour ?? 16)

        return P2PContract(
            id: UUID(uuidString: id) ?? UUID(),  // Try to preserve original ID
            siteId: siteId,
            direction: direction,
            startDate: dateFrom,
            endDate: dateTo,
            startHour: hours.0,
            endHour: hours.1,
            tiers: [tier],
            totalVolumeKwh: volumeKwh,
            renewalDays: nil,
            isActive: isActive,
            createdAt: tradeDate,
            notes: "Imported from LocalVolts (Order #\(id))"
        )
    }

    /// Check if this order matches an existing P2PContract
    func matchesContract(_ contract: P2PContract) -> Bool {
        // Match by date range and direction
        let calendar = Calendar.current
        let sameStart = calendar.isDate(dateFrom, inSameDayAs: contract.startDate)
        let sameEnd = calendar.isDate(dateTo, inSameDayAs: contract.endDate)
        let sameDirection = (isSell && contract.direction == .sell) || (isBuy && contract.direction == .buy)

        return sameStart && sameEnd && sameDirection
    }
}
