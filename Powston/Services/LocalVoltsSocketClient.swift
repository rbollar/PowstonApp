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

    /// Parse identity response result sets and extract settlement data
    private func parseIdentityResultSets(_ results: [Any]) {
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

    /// Log a one-line cashflow summary
    private func logCashflowSummary(_ s: LVCashflowSummary, label: String) {
        print("💰 LV \(label): net=$\(String(format: "%.2f", -s.netCosts)), sold=$\(String(format: "%.2f", s.totalSales)), bought=$\(String(format: "%.2f", s.totalPurchases)), \(s.records) records")
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
                        self.parseQtyReportSettlement(resultsRaw)
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

    private func parseQtyReportSettlement(_ results: [Any]) {
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
            }
        }
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

