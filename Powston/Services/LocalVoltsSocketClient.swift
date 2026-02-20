//
//  LocalVoltsSocketClient.swift
//  Powston
//
//  Socket.IO v2 client for LocalVolts WebSocket communication
//  Uses EIO=3 protocol for compatibility with LocalVolts server
//

import Foundation
import SocketIO

// MARK: - LV Identity Response

struct LVIdentityResponse {
    let userId: Int
    let session: String
    let fullName: String
    let reportConfig: LVReportConfig?
}

struct LVReportConfig {
    let period: String
    let basis: String
}

// MARK: - Socket Client

class LocalVoltsSocketClient {

    private var manager: SocketManager?
    private var socket: SocketIOClient?

    private let baseURL = URL(string: "https://market.localvolts.com")!

    // Callbacks
    var onTradesReceived: (([LVIntervalTrade]) -> Void)?
    var onMarketContractsReceived: (([LVMarketContract]) -> Void)?
    var onOrdersReceived: (([LVOrder]) -> Void)?
    var onSettlementReceived: (([LVSettlementRecord]) -> Void)?
    var onError: ((Error) -> Void)?
    var onDisconnect: (() -> Void)?

    // Connection state
    private(set) var isConnected = false
    private var cognitoSub: String?
    private var username: String?
    private var siteId: Int = 0
    private var jwtToken: String?
    private var userId: Int = 0
    private var sessionId: Int = 0
    private var nmi: String?

    // MARK: - Connection

    func connect(
        username: String,
        cognitoSub: String,
        siteId: Int,
        jwtToken: String? = nil
    ) async throws -> LVIdentityResponse {
        self.username = username
        self.cognitoSub = cognitoSub
        self.siteId = siteId
        self.jwtToken = jwtToken

        return try await withCheckedThrowingContinuation { continuation in
            setupSocket()

            var didResume = false
            var readyReceived = false
            var wsUpgradeComplete = false

            func sendIdentityIfReady() {
                if readyReceived && wsUpgradeComplete {
                    Task { @MainActor in
                        self.sendIdentityRequest()
                    }
                }
            }

            socket?.on("ready") { [weak self] _, _ in
                guard self != nil else { return }
                readyReceived = true
                sendIdentityIfReady()
            }

            socket?.on(clientEvent: .websocketUpgrade) { _, _ in
                wsUpgradeComplete = true
                sendIdentityIfReady()
            }

            socket?.on("message") { [weak self] data, _ in
                guard let self = self else { return }
                guard let dict = data.first as? [String: Any] else { return }

                let routingKey = dict["routingKey"] as? String ?? ""
                let isIdentityResponse = routingKey.contains("Id.Client.Result") || routingKey.contains("RDBMS.Get.Id")

                if isIdentityResponse {
                    if let identity = self.parseIdentityResponse(dict) {
                        self.userId = identity.userId
                        self.sessionId = Int(identity.session) ?? 0
                        if !didResume {
                            didResume = true
                            continuation.resume(returning: identity)
                        }
                    } else {
                        print("❌ Failed to parse LV identity response")
                    }
                }

                // Parse trade data from identity response
                if let content = dict["content"] as? [String: Any],
                   let resultsRaw = content["aobjResults"] as? [Any] {

                    // Find the reportList mapping from result[1]
                    if isIdentityResponse {
                        self.parseIdentityResultSets(resultsRaw)
                    }

                    // Extract NMI from settlement data
                    if isIdentityResponse {
                        let settlementIndex = self.findSettlementIndex(resultsRaw)
                        if let idx = settlementIndex,
                           let arr = resultsRaw[idx] as? [Any],
                           let first = arr.first as? [String: Any],
                           let nmiValue = first["NMI"] as? String {
                            self.nmi = nmiValue
                        } else if resultsRaw.count > 2,
                           let meterArray = resultsRaw[2] as? [Any],
                           let firstMeter = meterArray.first as? [String: Any],
                           let nmiValue = firstMeter["NMI"] as? String {
                            self.nmi = nmiValue
                        }
                    }
                    self.parseAndEmitTrades(resultsRaw)
                }
            }

            socket?.on(clientEvent: .error) { data, _ in
                print("❌ LV socket error: \(data)")
                if !didResume {
                    didResume = true
                    continuation.resume(throwing: SocketError.connectionFailed(message: "\(data.first ?? "Unknown")"))
                }
            }

            socket?.on(clientEvent: .disconnect) { [weak self] _, _ in
                self?.isConnected = false
                self?.onDisconnect?()
            }

            socket?.on(clientEvent: .connect) { [weak self] _, _ in
                self?.isConnected = true

                // Fallback timeout for identity response
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    if !didResume {
                        didResume = true
                        let identity = LVIdentityResponse(
                            userId: 0,
                            session: "connected",
                            fullName: self?.username ?? "User",
                            reportConfig: nil
                        )
                        continuation.resume(returning: identity)
                    }
                }
            }

            socket?.connect()

            // Total timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                if !didResume {
                    didResume = true
                    print("❌ LV connection timeout")
                    continuation.resume(throwing: SocketError.timeout)
                }
            }
        }
    }

    private func setupSocket(suffix: String = "") {
        var connectParams: [String: Any] = ["suffix": suffix]
        if userId > 0 {
            connectParams["userId"] = userId
        }

        let config: SocketIOClientConfiguration = [
            .version(.two),
            .forcePolling(false),
            .reconnects(true),
            .reconnectAttempts(3),
            .reconnectWait(5),
            .log(false),  // Disable verbose socket logging
            .secure(true),
            .path("/socket.io/"),
            .extraHeaders(["Origin": "https://market.localvolts.com"]),
            .connectParams(connectParams)
        ]

        manager = SocketManager(socketURL: baseURL, config: config)
        socket = manager?.defaultSocket
    }

    // MARK: - Identity Request

    private func sendIdentityRequest() {
        guard let sub = cognitoSub, let user = username else { return }

        let message: [String: Any] = [
            "from": "Client",
            "key": "Client.Get.Id.RDBMS.Initial.",
            "message": [
                "sub": sub,
                "user": user,
                "offsetTZ": 600
            ]
        ]

        socket?.emit("message", message)
    }

    // MARK: - Response Parsing

    private func parseIdentityResponse(_ dict: [String: Any]) -> LVIdentityResponse? {
        guard let content = dict["content"] as? [String: Any],
              let resultsRaw = content["aobjResults"],
              let results = resultsRaw as? [Any],
              results.count >= 2,
              let identityArray = results[0] as? [Any],
              let identityDict = identityArray.first as? [String: Any],
              let userId = identityDict["userId"] as? Int else {
            return nil
        }

        let session: String
        if let sessionInt = identityDict["session"] as? Int {
            session = String(sessionInt)
        } else if let sessionStr = identityDict["session"] as? String {
            session = sessionStr
        } else {
            session = "unknown"
        }

        let fullName = identityDict["fullName"] as? String ?? ""

        var reportConfig: LVReportConfig?
        if results.count > 1,
           let configArray = results[1] as? [Any],
           let config = configArray.first as? [String: Any] {
            let periodVal = config["period"] as? Int ?? 0
            let basisVal = config["basis"] as? Int ?? 0
            reportConfig = LVReportConfig(period: String(periodVal), basis: String(basisVal))
        }

        return LVIdentityResponse(userId: userId, session: session, fullName: fullName, reportConfig: reportConfig)
    }

    private func parseAndEmitTrades(_ results: [Any]) {
        var trades: [LVIntervalTrade] = []
        let fetchedAt = Date()

        for resultRaw in results {
            guard let resultSet = resultRaw as? [Any], !resultSet.isEmpty,
                  let firstDict = resultSet.first as? [String: Any] else { continue }

            // P2P trades have: counterparty, direction, sellPrice/buyPrice
            let isP2PArray = firstDict["counterparty"] != nil &&
                             firstDict["direction"] != nil &&
                             (firstDict["sellPrice"] != nil || firstDict["buyPrice"] != nil)

            if isP2PArray {
                for item in resultSet {
                    guard let tradeDict = item as? [String: Any] else { continue }
                    let periodStart = parsePeriodTimestamp(from: tradeDict)

                    if let trade = LVIntervalTrade.parse(
                        from: tradeDict,
                        siteId: siteId,
                        periodStart: periodStart ?? Date(),
                        fetchedAt: fetchedAt
                    ) {
                        trades.append(trade)
                    }
                }
            }
        }

        if !trades.isEmpty {
            onTradesReceived?(trades)
        }
    }

    /// Parse identity response result sets and extract settlement data
    private func parseIdentityResultSets(_ results: [Any]) {
        print("📊 Identity: \(results.count) result sets")

        // result[1] contains the reportList mapping
        if results.count > 1,
           let configArray = results[1] as? [Any],
           let config = configArray.first as? [String: Any],
           let reportList = config["reportList"] as? String {
            print("📊 Identity reportList: \(reportList)")
        }

        // Find and parse settlement data (has "settle" + "volume" + "profile" fields)
        if let idx = findSettlementIndex(results) {
            let arr = results[idx] as! [Any]
            let records = arr.compactMap { ($0 as? [String: Any]).flatMap(LVSettlementRecord.parse) }
            if !records.isEmpty {
                let summary = records.cashflowSummary()
                logCashflowSummary(summary, label: "Identity (today)")
                onSettlementReceived?(records)
            }
        }
    }

    /// Find the index of the LARGEST settlement data result set (has settle + volume + profile)
    /// Identity responses can contain multiple settlement-like sets at different resolutions;
    /// the largest one (basis=288, 5-min) has the complete financial breakdown.
    private func findSettlementIndex(_ results: [Any]) -> Int? {
        var bestIdx: Int?
        var bestCount = 0
        for (idx, raw) in results.enumerated() {
            guard let arr = raw as? [Any], arr.count > 10,
                  let first = arr.first as? [String: Any] else { continue }
            if first["settle"] != nil && first["volume"] != nil && first["profile"] != nil {
                print("📊 Settlement candidate: index=\(idx), count=\(arr.count)")
                if arr.count > bestCount {
                    bestCount = arr.count
                    bestIdx = idx
                }
            }
        }
        if let idx = bestIdx {
            print("📊 Selected settlement index=\(idx), count=\(bestCount)")
        }
        return bestIdx
    }

    /// Log a cashflow summary matching the LV dashboard format
    private func logCashflowSummary(_ s: LVCashflowSummary, label: String) {
        print("💰 LV Cashflow Breakdown (\(label)):")
        print("💰   Net Costs: $\(String(format: "%.2f", s.netCosts))")
        print("💰   All Purchases: $\(String(format: "%.2f", s.totalPurchases))")
        print("💰     Spot Energy: $\(String(format: "%.2f", s.spotEnergyCost))")
        print("💰     Network Energy: $\(String(format: "%.2f", s.networkEnergyCost))")
        print("💰     Network Access: $\(String(format: "%.2f", s.networkAccessCost))")
        print("💰     Certificates: $\(String(format: "%.2f", s.certificatesCost))")
        print("💰     LocalVolts Fee: $\(String(format: "%.2f", s.localvoltsFee))")
        print("💰   All Sales: $\(String(format: "%.2f", s.totalSales))")
        print("💰     Spot Energy: $\(String(format: "%.2f", s.spotEnergyRevenue))")
        print("💰     P2P Matched: $\(String(format: "%.2f", s.p2pMatchedRevenue))")
        print("💰   Energy Purchased: \(String(format: "%.2f", s.energyPurchasedKwh)) kWh")
        print("💰   Energy Sold: \(String(format: "%.2f", s.energySoldTotalKwh)) kWh (Spot \(String(format: "%.2f", s.energySoldSpotKwh)), P2P \(String(format: "%.2f", s.energySoldP2PKwh)))")
        print("💰   Emissions: \(String(format: "%.2f", s.emissions)) kgCO2e")
        print("💰   Records: \(s.records)")
    }

    private func parsePeriodTimestamp(from dict: [String: Any]) -> Date? {
        guard let periodNum = dict["period"] as? Int,
              let dateStr = dict["date"] as? String else { return nil }

        let basis = dict["basis"] as? Int ?? 288
        let minutesPerPeriod: Int
        switch basis {
        case 48: minutesPerPeriod = 30
        case 96: minutesPerPeriod = 15
        case 288: minutesPerPeriod = 5
        default: minutesPerPeriod = 1440 / basis
        }

        let aest = TimeZone(identifier: "Australia/Brisbane")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = aest

        let dateOnly = String(dateStr.prefix(10))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = aest

        guard let baseDate = formatter.date(from: dateOnly) else { return nil }

        let minutesOffset = (periodNum - 1) * minutesPerPeriod
        return calendar.date(byAdding: .minute, value: minutesOffset, to: baseDate)
    }

    // MARK: - Reconnect with User Suffix

    func reconnectWithUserSuffix() async throws {
        guard userId > 0, sessionId > 0 else {
            throw SocketError.invalidResponse
        }

        let suffix = "\(userId)_\(sessionId)"

        socket?.disconnect()
        socket = nil
        manager = nil
        isConnected = false

        try await Task.sleep(nanoseconds: 500_000_000)

        setupSocket(suffix: suffix)

        return try await withCheckedThrowingContinuation { continuation in
            var didResume = false

            socket?.on("ready") { [weak self] _, _ in
                self?.isConnected = true
                if !didResume {
                    didResume = true
                    continuation.resume()
                }
            }

            socket?.on("message") { [weak self] data, _ in
                guard let self = self,
                      let dict = data.first as? [String: Any] else { return }

                let routingKey = dict["routingKey"] as? String ?? ""

                if let content = dict["content"] as? [String: Any],
                   let resultsRaw = content["aobjResults"] as? [Any] {

                    if routingKey.contains("QtyReport") {
                        // Log reportList mapping (index → data type)
                        if let reportList = content["reportList"] as? String {
                            print("📊 QtyReport reportList: \(reportList)")
                        }
                        self.parseQtyReportTrades(resultsRaw)
                    } else if routingKey.contains("ContractTable") {
                        self.parseContractTableResponse(resultsRaw)
                    } else if routingKey.contains("TradeDetail") {
                        print("📥 Received TradeDetail response")
                        self.parseTradeDetailResponse(resultsRaw)
                    } else if routingKey.contains("TradeList") {
                        self.parseTradeListResponse(resultsRaw)
                    }
                }
            }

            socket?.on(clientEvent: .error) { data, _ in
                print("❌ LV reconnect error: \(data)")
                if !didResume {
                    didResume = true
                    continuation.resume(throwing: SocketError.connectionFailed(message: "\(data)"))
                }
            }

            socket?.connect()

            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                if !didResume {
                    didResume = true
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - QtyReport Parsing

    private func parseQtyReportTrades(_ results: [Any]) {
        var trades: [LVIntervalTrade] = []
        let fetchedAt = Date()

        print("📊 QtyReport: parsing \(results.count) result sets")

        // Extract P2P trades from all result sets that have counterparty data
        for (index, resultRaw) in results.enumerated() {
            guard let resultSet = resultRaw as? [Any], !resultSet.isEmpty,
                  let firstDict = resultSet.first as? [String: Any] else {
                continue
            }

            let isIdentityP2P = firstDict["counterparty"] != nil &&
                                firstDict["direction"] != nil &&
                                (firstDict["sellPrice"] != nil || firstDict["buyPrice"] != nil)

            if isIdentityP2P {
                for item in resultSet {
                    guard let tradeDict = item as? [String: Any] else { continue }
                    let periodStart = parsePeriodTimestamp(from: tradeDict)

                    if let trade = LVIntervalTrade.parse(
                        from: tradeDict,
                        siteId: siteId,
                        periodStart: periodStart ?? Date(),
                        fetchedAt: fetchedAt
                    ) {
                        trades.append(trade)
                    }
                }
                print("📊 QtyReport result[\(index)]: \(trades.count) P2P trades")
            }
        }

        // Use findSettlementIndex to pick the LARGEST settlement result set
        // (avoids double-counting from multiple settlement sets at different resolutions)
        if let idx = findSettlementIndex(results),
           let arr = results[idx] as? [Any] {
            let allSettlement = arr.compactMap { ($0 as? [String: Any]).flatMap(LVSettlementRecord.parse) }
            if !allSettlement.isEmpty {
                let byDate = Dictionary(grouping: allSettlement) { $0.date }
                for (date, records) in byDate.sorted(by: { $0.key < $1.key }) {
                    let summary = records.cashflowSummary()
                    logCashflowSummary(summary, label: "QtyReport \(String(date.prefix(10)))")
                }
                onSettlementReceived?(allSettlement)
                print("📊 QtyReport: \(trades.count) trades, \(allSettlement.count) settlement records")
            }
        }

        if !trades.isEmpty {
            onTradesReceived?(trades)
        }
    }

    // MARK: - TradeDetail Parsing

    /// Parse TradeDetail response to extract counterparty fills
    /// Response structure: aobjResults[0] = order info, aobjResults[2] = counterparty fills
    private func parseTradeDetailResponse(_ results: [Any]) {
        // Extract orderId from the first result set (order info)
        var orderId: String?
        if let firstSet = results.first as? [Any],
           let orderInfo = firstSet.first as? [String: Any] {
            if let id = orderInfo["orderId"] as? Int {
                orderId = String(id)
            } else if let id = orderInfo["orderId"] as? String {
                orderId = id
            }
        }

        guard let orderId = orderId else {
            print("⚠️ TradeDetail: Could not extract orderId from response")
            return
        }

        // Extract counterparty fills from the third result set (index 2)
        var fills: [LVOrderFill] = []

        if results.count > 2, let fillsArray = results[2] as? [Any] {
            for item in fillsArray {
                guard let fillDict = item as? [String: Any] else { continue }

                // Parse counterparty fill
                if let fill = LVOrderFill.parse(from: fillDict, orderId: orderId) {
                    fills.append(fill)
                }
            }
        }

        // Calculate totals for logging
        let totalDealt = fills.reduce(0) { $0 + $1.dealtKwh }
        let totalSettled = fills.reduce(0) { $0 + $1.settledKwh }
        print("📋 TradeDetail for order \(orderId): \(fills.count) counterparties, \(String(format: "%.2f", totalDealt)) kWh dealt, \(String(format: "%.2f", totalSettled)) kWh settled")

        // Notify callback
        onTradeDetailReceived?(orderId, fills)
    }

    private func parseDouble(_ value: Any?) -> Double? {
        guard let value = value else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    // MARK: - Request Trade Data

    func requestTradeData(from startDate: Date, to endDate: Date) {
        guard isConnected else {
            onError?(SocketError.notConnected)
            return
        }

        guard userId > 0, sessionId > 0 else {
            onError?(SocketError.invalidResponse)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")

        let suffix = "\(userId)_\(sessionId)"

        let message: [String: Any] = [
            "from": "Client",
            "key": "Client.Get.QtyReport.RDBMS.Initial.\(suffix)",
            "message": [
                "userId": userId,
                "NMI": "*",
                "from": formatter.string(from: startDate),
                "to": formatter.string(from: endDate),
                "offsetTZ": -600
            ]
        ]

        socket?.emit("message", message)
    }

    // MARK: - Request ContractTable (Market-Wide Contracts)

    func requestContractTable() {
        guard isConnected else {
            onError?(SocketError.notConnected)
            return
        }

        guard userId > 0, sessionId > 0 else {
            onError?(SocketError.invalidResponse)
            return
        }

        let suffix = "\(userId)_\(sessionId)"

        let message: [String: Any] = [
            "from": "Client",
            "key": "Client.Get.ContractTable.RDBMS.Initial.\(suffix)",
            "message": ["userId": userId]
        ]

        socket?.emit("message", message)
    }

    // MARK: - Request TradeList (Orders)

    func requestTradeList(from startDate: Date, to endDate: Date, direction: String) {
        guard isConnected else {
            onError?(SocketError.notConnected)
            return
        }

        guard userId > 0, sessionId > 0 else {
            onError?(SocketError.invalidResponse)
            return
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")

        let suffix = "\(userId)_\(sessionId)"

        let message: [String: Any] = [
            "from": "Client",
            "key": "Client.Get.TradeList.RDBMS.Initial.\(suffix)",
            "message": [
                "userId": userId,
                "from": formatter.string(from: startDate),
                "to": formatter.string(from: endDate),
                "offsetTZ": -600,
                "direction": direction
            ]
        ]

        socket?.emit("message", message)
    }

    func requestAllOrders(from startDate: Date, to endDate: Date) {
        requestTradeList(from: startDate, to: endDate, direction: "Sell")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.requestTradeList(from: startDate, to: endDate, direction: "Buy")
        }
    }

    // MARK: - Request TradeDetail (Order Fills/Commitments)

    /// Callback for trade detail (fills) received
    var onTradeDetailReceived: ((String, [LVOrderFill]) -> Void)?

    /// Request detail for a specific order including counterparty fills
    func requestTradeDetail(orderId: String) {
        guard isConnected else {
            print("⚠️ TradeDetail request failed: not connected")
            onError?(SocketError.notConnected)
            return
        }

        guard userId > 0, sessionId > 0 else {
            print("⚠️ TradeDetail request failed: invalid userId/sessionId")
            onError?(SocketError.invalidResponse)
            return
        }

        let suffix = "\(userId)_\(sessionId)"

        let message: [String: Any] = [
            "from": "Client",
            "key": "Client.Get.TradeDetail.RDBMS.Initial.\(suffix)",
            "message": [
                "orderId": orderId
            ]
        ]

        print("📤 Requesting TradeDetail for order \(orderId)")
        socket?.emit("message", message)
    }

    /// Request details for multiple orders (staggered to avoid overwhelming the API)
    func requestTradeDetails(orderIds: [String], delay: TimeInterval = 0.3) {
        for (index, orderId) in orderIds.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * Double(index)) { [weak self] in
                self?.requestTradeDetail(orderId: orderId)
            }
        }
    }

    // MARK: - ContractTable Parsing

    private func parseContractTableResponse(_ results: [Any]) {
        var contracts: [LVMarketContract] = []
        let fetchedAt = Date()

        for resultRaw in results {
            guard let resultSet = resultRaw as? [Any], !resultSet.isEmpty,
                  let firstDict = resultSet.first as? [String: Any] else { continue }

            // ContractTable: buyer, seller, sellPrice/buyPrice, period
            let isContractTable = firstDict["buyer"] != nil &&
                                  firstDict["seller"] != nil &&
                                  (firstDict["sellPrice"] != nil || firstDict["buyPrice"] != nil) &&
                                  firstDict["period"] != nil

            if isContractTable {
                for item in resultSet {
                    guard let contractDict = item as? [String: Any] else { continue }
                    if let contract = LVMarketContract.parse(from: contractDict, fetchedAt: fetchedAt) {
                        contracts.append(contract)
                    }
                }
            }
        }

        if !contracts.isEmpty {
            onMarketContractsReceived?(contracts)
        }
    }

    // MARK: - TradeList Parsing

    private func parseTradeListResponse(_ results: [Any]) {
        var orders: [LVOrder] = []
        let fetchedAt = Date()

        guard let firstResult = results.first as? [Any], !firstResult.isEmpty else { return }

        // Debug: Log first few orders to understand structure
        var debugCount = 0
        for item in firstResult {
            guard let orderDict = item as? [String: Any] else { continue }

            // Log first 5 orders for debugging (includes dateFrom/dateTo for short contract support)
            if debugCount < 5 {
                print("📋 TradeList order \(debugCount + 1): orderId=\(orderDict["orderId"] ?? "?"), direction=\(orderDict["direction"] ?? "?"), volume=\(orderDict["volume"] ?? "?"), price=\(orderDict["price"] ?? "?"), dateFrom=\(orderDict["dateFrom"] ?? "?"), dateTo=\(orderDict["dateTo"] ?? "?")")
                debugCount += 1
            }

            if let order = LVOrder.parse(from: orderDict, siteId: siteId, fetchedAt: fetchedAt) {
                orders.append(order)
            }
        }

        if !orders.isEmpty {
            onOrdersReceived?(orders)
        }
    }

    // MARK: - Disconnect

    func disconnect() {
        socket?.disconnect()
        socket = nil
        manager = nil
        isConnected = false
    }

    // MARK: - Errors

    enum SocketError: LocalizedError {
        case connectionFailed(message: String)
        case timeout
        case notConnected
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let message): return "Connection failed: \(message)"
            case .timeout: return "Connection timed out"
            case .notConnected: return "Not connected to LocalVolts"
            case .invalidResponse: return "Invalid response from server"
            }
        }
    }
}

