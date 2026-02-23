//
//  LocalVoltsService.swift
//  Powston
//
//  Main orchestration service for LocalVolts integration
//  Combines authentication, WebSocket, and storage layers
//

import Foundation
import SwiftUI
import Combine

@MainActor
class LocalVoltsService: ObservableObject {

    static let shared = LocalVoltsService()

    // MARK: - Published State

    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var lastSyncTime: Date?
    @Published var error: String?
    @Published var tradeCount: Int = 0
    @Published var isSyncing: Bool = false

    // Market-wide contract data
    @Published var marketContracts: [LVMarketContract] = []
    @Published var isLoadingMarket: Bool = false
    @Published var lastMarketFetchTime: Date?

    // Order/contract data
    @Published var orders: [LVOrder] = []
    @Published var isLoadingOrders: Bool = false
    @Published var lastOrdersFetchTime: Date?

    // MARK: - Connection Status

    enum ConnectionStatus: Equatable {
        case disconnected
        case authenticating
        case connecting
        case fetching
        case connected
        case error(String)

        var displayText: String {
            switch self {
            case .disconnected: return "Not connected"
            case .authenticating: return "Authenticating..."
            case .connecting: return "Connecting..."
            case .fetching: return "Fetching trades..."
            case .connected: return "Connected"
            case .error(let msg): return "Error: \(msg)"
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var isLoading: Bool {
            switch self {
            case .authenticating, .connecting, .fetching:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Dependencies

    private let credentialManager = LocalVoltsCredentialManager.shared
    private let authService = LocalVoltsAuthService.shared
    private var socketClient: LocalVoltsSocketClient?
    private var dataStore: PowstonDataStore { PowstonDataStore.shared }

    // MARK: - State

    private var authToken: LocalVoltsAuthService.TokenResponse?
    private var currentSiteId: Int = 0
    private var receivedTrades: [LVIntervalTrade] = []
    private var receivedMarketContracts: [LVMarketContract] = []
    private var receivedOrders: [LVOrder] = []
    private var receivedSettlementCount: Int = 0

    // MARK: - Throttling

    /// Track last action times to prevent hammering
    private var lastActionTime: [ThrottleAction: Date] = [:]

    enum ThrottleAction: String {
        case syncTrades
        case syncOrders
        case syncMarket
        case testConnection
    }

    /// Cooldown periods for each action (in seconds)
    private static let cooldowns: [ThrottleAction: TimeInterval] = [
        .syncTrades: 30,       // 30 seconds between trade syncs
        .syncOrders: 60,       // 1 minute between order syncs
        .syncMarket: 120,      // 2 minutes between market syncs
        .testConnection: 5     // 5 seconds between connection tests
    ]

    /// Check if an action can proceed (not throttled)
    func canPerform(_ action: ThrottleAction) -> Bool {
        guard let lastTime = lastActionTime[action],
              let cooldown = Self.cooldowns[action] else {
            return true
        }
        return Date().timeIntervalSince(lastTime) >= cooldown
    }

    /// Get remaining cooldown seconds for an action
    func cooldownRemaining(_ action: ThrottleAction) -> Int {
        guard let lastTime = lastActionTime[action],
              let cooldown = Self.cooldowns[action] else {
            return 0
        }
        let remaining = cooldown - Date().timeIntervalSince(lastTime)
        return max(0, Int(remaining.rounded(.up)))
    }

    /// Mark an action as performed (for throttle tracking)
    private func markActionPerformed(_ action: ThrottleAction) {
        lastActionTime[action] = Date()
    }

    /// Reset throttle for an action (e.g., after error)
    func resetThrottle(_ action: ThrottleAction) {
        lastActionTime.removeValue(forKey: action)
    }

    private init() {
        updateTradeCount()
    }

    // MARK: - Public API

    /// Check if credentials are configured
    var hasCredentials: Bool {
        credentialManager.hasCredentials
    }

    /// Get stored username (for display)
    var storedUsername: String? {
        credentialManager.load()?.username
    }

    /// Connect to LocalVolts with stored credentials
    func connect(siteId: Int) async throws {
        guard let credentials = credentialManager.load() else {
            throw ServiceError.noCredentials
        }

        currentSiteId = siteId

        try await connect(
            username: credentials.username,
            password: credentials.password,
            siteId: siteId
        )
    }

    /// Connect with provided credentials (for initial setup/test)
    func connect(username: String, password: String, siteId: Int) async throws {
        currentSiteId = siteId
        error = nil

        // Step 1: Authenticate
        connectionStatus = .authenticating
        do {
            authToken = try await authService.login(username: username, password: password)
            print("✅ LocalVolts authentication successful")
        } catch {
            connectionStatus = .error("Authentication failed")
            self.error = error.localizedDescription
            throw error
        }

        // Step 2: Connect WebSocket
        connectionStatus = .connecting
        guard let token = authToken else {
            throw ServiceError.noAuthToken
        }

        socketClient = LocalVoltsSocketClient()
        socketClient?.onTradesReceived = { [weak self] trades in
            Task { @MainActor in
                self?.handleReceivedTrades(trades)
            }
        }
        socketClient?.onMarketContractsReceived = { [weak self] contracts in
            Task { @MainActor in
                self?.handleReceivedMarketContracts(contracts)
            }
        }
        socketClient?.onOrdersReceived = { [weak self] orders in
            Task { @MainActor in
                self?.handleReceivedOrders(orders)
            }
        }
        socketClient?.onSettlementReceived = { [weak self] records in
            Task { @MainActor in
                self?.handleReceivedSettlement(records)
            }
        }
        socketClient?.onError = { [weak self] error in
            Task { @MainActor in
                self?.error = error.localizedDescription
            }
        }
        socketClient?.onDisconnect = { [weak self] in
            Task { @MainActor in
                self?.connectionStatus = .disconnected
            }
        }

        do {
            let identity = try await socketClient!.connect(
                username: token.strUsername,
                cognitoSub: token.strSub,
                siteId: siteId,
                jwtToken: token.jwtIdToken
            )
            print("✅ LocalVolts WebSocket connected: \(identity.fullName)")
            connectionStatus = .connected
            lastSyncTime = Date()
        } catch {
            connectionStatus = .error("WebSocket connection failed")
            self.error = error.localizedDescription
            print("❌ LocalVolts WebSocket error: \(error)")
            throw error
        }
    }

    /// Test connection with provided credentials (doesn't save)
    func testConnection(username: String, password: String) async throws -> String {
        // Just test authentication
        let token = try await authService.login(username: username, password: password)
        return token.strUsername
    }

    /// Save credentials after successful test
    func saveCredentials(username: String, password: String) throws {
        try credentialManager.save(username: username, password: password)
    }

    /// Delete stored credentials
    func deleteCredentials() throws {
        try credentialManager.delete()
        disconnect()
        authToken = nil
    }

    /// Disconnect from LocalVolts
    func disconnect() {
        socketClient?.disconnect()
        socketClient = nil
        connectionStatus = .disconnected
    }

    /// Disconnect after a short delay if no new requests come in
    /// This allows back-to-back requests to share a connection while
    /// ensuring we don't keep idle connections open
    private var disconnectTask: Task<Void, Never>?

    private func disconnectWhenIdle() {
        // Cancel any pending disconnect
        disconnectTask?.cancel()

        // Schedule disconnect after 5 seconds of idle
        disconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 seconds

            // Only disconnect if still connected and not syncing
            if !Task.isCancelled && connectionStatus.isConnected && !isSyncing && !isLoadingMarket && !isLoadingOrders {
                print("🔌 Disconnecting idle LocalVolts socket")
                disconnect()
            }
        }
    }

    /// Fetch trades for a date range
    /// Identity response contains today's trades; historical data requires separate request
    func fetchTrades(siteId: Int, from: Date, to: Date) async throws -> [LVIntervalTrade] {
        isSyncing = true

        // Connect if needed - this sends identity request and receives trades
        if !connectionStatus.isConnected {
            connectionStatus = .connecting
            receivedTrades = []  // Clear before connecting
            try await connect(siteId: siteId)
        }

        guard socketClient?.isConnected == true else {
            isSyncing = false
            throw ServiceError.notConnected
        }

        connectionStatus = .fetching

        // Wait for identity response trades to be parsed
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2s for parsing

        // Check if we need data outside of today (historical or future/forecast)
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
        let todayStart = calendar.startOfDay(for: Date())
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: todayStart) ?? todayStart

        // Request QtyReport if date range extends beyond today
        // Identity response only contains today's trades, so we need QtyReport for:
        // - Historical: start date is before today
        // - Forecast: end date is tomorrow or later
        let needsHistorical = from < todayStart
        let needsForecast = to >= tomorrowStart
        let needsDataRequest = needsHistorical || needsForecast

        if needsDataRequest {
            // Reconnect with userId_sessionId suffix so server can route response back
            let dataType = needsForecast ? "forecast" : "historical"
            print("🔄 Reconnecting with suffix for \(dataType) data...")
            try await socketClient?.reconnectWithUserSuffix()

            // Request trades for date range
            let tradesBeforeRequest = receivedTrades.count
            let settlementBeforeRequest = receivedSettlementCount
            print("📤 Requesting \(dataType) trades from \(from) to \(to)")
            socketClient?.requestTradeData(from: from, to: to)

            // Poll for data response (up to 30 seconds, checking every 2 seconds)
            // Check for both trade data AND settlement data (some date ranges may have settlement but no P2P trades)
            for attempt in 1...15 {
                try await Task.sleep(nanoseconds: 2_000_000_000)  // 2s between checks
                let newTrades = receivedTrades.count - tradesBeforeRequest
                let newSettlement = receivedSettlementCount - settlementBeforeRequest
                if newTrades > 0 || newSettlement > 0 {
                    print("✅ Received \(newTrades) trades + \(newSettlement) settlement records after \(attempt * 2)s")
                    break
                }
                if attempt < 15 {
                    print("⏳ Waiting for \(dataType) data... (\(attempt * 2)s)")
                }
            }
        }

        isSyncing = false
        connectionStatus = .connected

        // Save received trades (filter to requested date range)
        let filteredTrades = receivedTrades.filter { trade in
            trade.periodStart >= from && trade.periodStart <= to
        }

        if !filteredTrades.isEmpty {
            try dataStore.saveLVIntervalTradesBatch(filteredTrades, siteId: siteId, from: from, to: to)
            dataStore.setLastLVSyncTime(siteId: siteId)
            lastSyncTime = Date()
            updateTradeCount()
            print("💾 Saved \(filteredTrades.count) trades for date range")
        }

        // Disconnect socket when done - no need to keep connection open
        disconnectWhenIdle()

        return filteredTrades
    }

    /// Sync trades for today (quick refresh)
    /// Respects throttle - throws if called too frequently
    func syncToday(siteId: Int, force: Bool = false) async throws {
        guard force || canPerform(.syncTrades) else {
            let remaining = cooldownRemaining(.syncTrades)
            throw ServiceError.throttled(seconds: remaining)
        }

        markActionPerformed(.syncTrades)

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
        let today = calendar.startOfDay(for: Date())

        _ = try await fetchTrades(siteId: siteId, from: today, to: Date())
    }

    /// Sync last 7 days (full refresh)
    /// Respects throttle - throws if called too frequently
    func syncWeek(siteId: Int, force: Bool = false) async throws {
        guard force || canPerform(.syncTrades) else {
            let remaining = cooldownRemaining(.syncTrades)
            throw ServiceError.throttled(seconds: remaining)
        }

        markActionPerformed(.syncTrades)

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current

        let today = Date()
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today)!

        _ = try await fetchTrades(siteId: siteId, from: weekAgo, to: today)
    }

    /// Sync forward-contracted P2P trades out to the furthest active order.
    /// QtyReport returns matched (contracted) volume for future dates, which is needed
    /// for accurate fill tracking on forward orders. Fetches in chunks to avoid timeouts.
    func syncForwardTrades(siteId: Int) async throws {
        let activeOrders = dataStore.getActiveLVOrders(siteId: siteId)
        guard !activeOrders.isEmpty else { return }

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
        let today = calendar.startOfDay(for: Date())

        // Find the furthest active order end date
        let furthestEnd = activeOrders.map { $0.dateTo }.max() ?? today
        let horizon = calendar.date(byAdding: .day, value: 1, to: furthestEnd) ?? furthestEnd

        // Only fetch forward dates (today onward) — historical is handled by syncWeek
        guard horizon > today else { return }

        // Fetch in chunks to avoid QtyReport timeouts (60 days per chunk)
        let chunkSize = 60
        var chunkStart = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        var totalFetched = 0

        while chunkStart < horizon {
            let chunkEnd = min(
                calendar.date(byAdding: .day, value: chunkSize, to: chunkStart) ?? horizon,
                horizon
            )

            do {
                let trades = try await fetchTrades(siteId: siteId, from: chunkStart, to: chunkEnd)
                totalFetched += trades.count
                print("📊 Forward sync chunk: \(trades.count) trades for \(chunkStart) to \(chunkEnd)")
            } catch {
                print("⚠️ Forward sync chunk failed: \(error.localizedDescription)")
            }

            chunkStart = calendar.date(byAdding: .day, value: chunkSize, to: chunkStart) ?? horizon
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1s between chunks
        }

        if totalFetched > 0 {
            print("✅ Forward sync complete: \(totalFetched) trades across \(activeOrders.count) active orders")
        }
    }

    /// Force re-fetch all historical P2P trades (clears existing and re-fetches via QtyReport)
    /// Use when trade data has been lost/corrupted
    func refetchAllTrades(siteId: Int) async -> Int {
        guard hasCredentials else { return 0 }

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
        let today = calendar.startOfDay(for: Date())
        let maxLookback = calendar.date(byAdding: .day, value: -60, to: today) ?? today

        // Clear all existing trade data so INSERT OR IGNORE doesn't skip anything
        dataStore.clearLVTrades(siteId: siteId)
        print("🔄 Refetching all P2P trades from \(maxLookback) to \(today)...")

        var totalFetched = 0
        let chunkSize = 7  // 7 days per chunk to get detailed trade data
        var chunkStart = maxLookback

        while chunkStart < today {
            let chunkEnd = min(calendar.date(byAdding: .day, value: chunkSize, to: chunkStart) ?? today, today)

            do {
                let trades = try await fetchTrades(siteId: siteId, from: chunkStart, to: chunkEnd)
                totalFetched += trades.count
                print("📊 Refetch chunk: \(trades.count) trades for \(chunkStart) to \(chunkEnd)")
            } catch {
                print("⚠️ Refetch chunk failed: \(error.localizedDescription)")
            }

            chunkStart = chunkEnd
            // Brief pause between chunks
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        print("✅ Refetched \(totalFetched) total P2P trades")
        return totalFetched
    }

    // MARK: - Data Access

    /// Get trades from local database
    func getTrades(siteId: Int, from: Date, to: Date) -> [LVIntervalTrade] {
        dataStore.getLVIntervalTrades(siteId: siteId, from: from, to: to)
    }

    /// Get counterparty summary
    func getCounterpartySummary(siteId: Int, from: Date, to: Date) -> [P2PCounterpartySummary] {
        dataStore.getLVCounterpartySummary(siteId: siteId, from: from, to: to)
    }

    /// Check if we need to sync (>4 hours since last sync)
    func needsSync(siteId: Int) -> Bool {
        guard let lastSync = dataStore.getLastLVSyncTime(siteId: siteId) else {
            return true
        }
        return Date().timeIntervalSince(lastSync) > 4 * 60 * 60  // 4 hours
    }

    // MARK: - Market Data (ContractTable)

    /// Fetch market-wide P2P contracts for today
    /// Returns all executed trades across the entire LocalVolts platform
    func fetchMarketContracts(siteId: Int) async throws -> [LVMarketContract] {
        isLoadingMarket = true
        receivedMarketContracts = []

        // Connect with retry - other operations may interfere with connection state
        var connectAttempts = 0
        let maxConnectAttempts = 3
        while socketClient?.isConnected != true && connectAttempts < maxConnectAttempts {
            connectAttempts += 1
            if connectAttempts > 1 {
                print("🔄 Market fetch connection retry \(connectAttempts)/\(maxConnectAttempts)")
                try await Task.sleep(nanoseconds: 1_000_000_000)  // 1s delay between retries
            }
            if !connectionStatus.isConnected {
                try await connect(siteId: siteId)
            }
        }

        guard socketClient?.isConnected == true else {
            isLoadingMarket = false
            throw ServiceError.notConnected
        }

        // Reconnect with suffix if needed for ContractTable requests
        try await socketClient?.reconnectWithUserSuffix()

        // Request ContractTable
        socketClient?.requestContractTable()

        // Poll for data response (up to 30 seconds, checking every 2 seconds)
        for attempt in 1...15 {
            try await Task.sleep(nanoseconds: 2_000_000_000)  // 2s between checks
            if !receivedMarketContracts.isEmpty {
                print("✅ Received \(receivedMarketContracts.count) market contracts after \(attempt * 2)s")
                break
            }
            if attempt < 15 {
                print("⏳ Waiting for ContractTable data... (\(attempt * 2)s)")
            }
        }

        isLoadingMarket = false

        if receivedMarketContracts.isEmpty {
            print("⚠️ No market contracts received from ContractTable")
            return []
        }

        // Save to database
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let today = calendar.startOfDay(for: Date())

        do {
            try dataStore.saveLVMarketContracts(receivedMarketContracts, for: today)
            dataStore.setLastLVMarketContractsFetchTime()
            lastMarketFetchTime = Date()
        } catch {
            print("❌ Failed to save market contracts: \(error)")
        }

        marketContracts = receivedMarketContracts

        // Disconnect socket when done - no need to keep connection open
        disconnectWhenIdle()

        return receivedMarketContracts
    }

    /// Get market contracts from local database for today
    func getMarketContractsForToday() -> [LVMarketContract] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let today = calendar.startOfDay(for: Date())
        return dataStore.getLVMarketContracts(for: today)
    }

    /// Check if market data needs refresh (>5 minutes old)
    func needsMarketRefresh() -> Bool {
        dataStore.isLVMarketContractsStale(maxAge: 300)
    }

    // MARK: - Orders/Contracts (TradeList)

    /// Fetch all orders/contracts for a date range
    /// These are standing orders (contracts) on the P2P platform
    /// Respects throttle - throws if called too frequently
    func fetchOrders(siteId: Int, from: Date? = nil, to: Date? = nil, force: Bool = false) async throws -> [LVOrder] {
        guard force || canPerform(.syncOrders) else {
            let remaining = cooldownRemaining(.syncOrders)
            throw ServiceError.throttled(seconds: remaining)
        }

        markActionPerformed(.syncOrders)
        isLoadingOrders = true
        receivedOrders = []

        // Connect if needed
        if !connectionStatus.isConnected {
            try await connect(siteId: siteId)
        }

        guard socketClient?.isConnected == true else {
            isLoadingOrders = false
            throw ServiceError.notConnected
        }

        // Reconnect with suffix if needed for TradeList requests
        try await socketClient?.reconnectWithUserSuffix()

        // Default date range: last 90 days to 30 days ahead
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let startDate = from ?? calendar.date(byAdding: .day, value: -90, to: Date())!
        let endDate = to ?? calendar.date(byAdding: .day, value: 30, to: Date())!

        // Request both Sell and Buy orders
        socketClient?.requestAllOrders(from: startDate, to: endDate)

        // Poll for data response (up to 30 seconds, checking every 2 seconds)
        // Wait for both directions: after first response, allow extra time for the second
        var firstResponseAt: Int?
        for attempt in 1...15 {
            try await Task.sleep(nanoseconds: 2_000_000_000)  // 2s between checks
            if !receivedOrders.isEmpty {
                if firstResponseAt == nil {
                    firstResponseAt = attempt
                    print("📥 First orders received (\(receivedOrders.count)) after \(attempt * 2)s, waiting for both directions...")
                }
                // Wait at least 4 more seconds after first response for second direction
                if attempt >= (firstResponseAt ?? attempt) + 2 {
                    print("✅ Received \(receivedOrders.count) orders total after \(attempt * 2)s")
                    break
                }
            }
            if attempt < 15 && receivedOrders.isEmpty {
                print("⏳ Waiting for TradeList data... (\(attempt * 2)s)")
            }
        }

        isLoadingOrders = false

        if receivedOrders.isEmpty {
            print("⚠️ No orders received from TradeList")
            return []
        }

        // Save to database and clean up stale orders
        do {
            try dataStore.saveLVOrders(receivedOrders)

            // Remove orders that are no longer in the API response
            // This handles cancelled/expired orders that LocalVolts no longer returns
            let freshIds = Set(receivedOrders.map { $0.id })
            let removed = try dataStore.removeStaleOrders(siteId: siteId, keepIds: freshIds)
            if removed > 0 {
                print("🗑️ Removed \(removed) stale orders no longer in API response")
            }

            dataStore.setLastLVOrdersSyncTime(siteId: siteId)
            lastOrdersFetchTime = Date()

            // Fetch TradeDetail for active/upcoming orders to get commitment data
            // This saves snapshots with fills data, so no need for separate trackContractSubscriptions call
            await fetchTradeDetailsForOrders(receivedOrders, siteId: siteId)
        } catch {
            print("❌ Failed to save orders: \(error)")
        }

        orders = receivedOrders

        // Disconnect socket when done - no need to keep connection open
        disconnectWhenIdle()

        return receivedOrders
    }

    /// Get orders from local database
    func getOrders(siteId: Int) -> [LVOrder] {
        dataStore.getLVOrders(siteId: siteId)
    }

    /// Get active orders (not expired or cancelled)
    func getActiveOrders(siteId: Int, direction: String? = nil) -> [LVOrder] {
        dataStore.getActiveLVOrders(siteId: siteId, direction: direction)
    }

    // MARK: - TradeDetail (Order Fills)

    /// Fetch TradeDetail for active/upcoming orders to get commitment data
    /// This is especially important for buy contracts where forward trades aren't in identity response
    private func fetchTradeDetailsForOrders(_ orders: [LVOrder], siteId: Int) async {
        // Filter to active or upcoming orders (not expired)
        let today = Calendar.current.startOfDay(for: Date())
        let activeOrUpcoming = orders.filter { order in
            order.dateTo >= today && order.status != "Cancelled"
        }

        guard !activeOrUpcoming.isEmpty else { return }

        // Create lookup dictionary for orders by ID (use uniquingKeysWith to handle duplicate IDs)
        let orderDict = Dictionary(activeOrUpcoming.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        let orderIds = Array(orderDict.keys)

        guard !orderIds.isEmpty else { return }

        print("📋 Fetching TradeDetail for \(orderIds.count) active/upcoming orders...")

        // Track received count for logging
        var receivedCount = 0

        // Set up callback to save each snapshot immediately as it arrives
        // This avoids data races by processing on main actor as each response comes in
        socketClient?.onTradeDetailReceived = { [weak self] orderId, fills in
            guard let self = self,
                  let order = orderDict[orderId] else {
                print("⚠️ TradeDetail received for unknown order: \(orderId)")
                return
            }

            // Save snapshot immediately on main actor
            Task { @MainActor in
                let saved = self.dataStore.saveContractSnapshot(order: order, fills: fills, siteId: siteId)
                if saved {
                    print("✅ Saved snapshot for order \(orderId): \(fills.count) counterparties")
                }
            }
            receivedCount += 1
        }

        // Request details for each order (staggered)
        socketClient?.requestTradeDetails(orderIds: orderIds, delay: 0.3)

        // Wait for responses (with timeout)
        // Allow 0.5s per order plus 3s buffer
        let waitTime = Double(orderIds.count) * 0.5 + 3.0
        try? await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))

        print("📋 TradeDetail complete: received \(receivedCount) of \(orderIds.count) responses")

        // Update tracker count
        ContractSubscriptionTracker.shared.trackedContracts = dataStore.getActiveTrackedOrderIds(siteId: siteId).count
    }

    /// Check if orders data needs refresh (>1 hour old)
    func needsOrdersRefresh(siteId: Int) -> Bool {
        guard let lastSync = dataStore.getLastLVOrdersSyncTime(siteId: siteId) else {
            return true
        }
        return Date().timeIntervalSince(lastSync) > 60 * 60  // 1 hour
    }

    // MARK: - Daily Background Sync

    /// Check if a daily orders sync is needed (>24 hours since last sync)
    /// Returns true if we have credentials and haven't synced in over 24 hours
    func needsDailyOrdersSync(siteId: Int) -> Bool {
        guard hasCredentials else { return false }

        guard let lastSync = dataStore.getLastLVOrdersSyncTime(siteId: siteId) else {
            // Never synced orders - check if we have any contracts
            let hasContracts = dataStore.hasLVOrders(siteId: siteId)
            // Only trigger daily sync if we know about contracts (from previous import)
            return hasContracts
        }

        // 24 hours since last sync
        return Date().timeIntervalSince(lastSync) > 24 * 60 * 60
    }

    /// Check if a daily trades sync is needed (>24 hours since last sync)
    /// Returns true if we have credentials and haven't synced in over 24 hours
    func needsDailyTradesSync(siteId: Int) -> Bool {
        guard hasCredentials else { return false }

        guard let lastSync = dataStore.getLastLVSyncTime(siteId: siteId) else {
            // Never synced trades - check if we have any
            let hasTrades = tradeCount > 0
            return hasTrades
        }

        // 24 hours since last sync
        return Date().timeIntervalSince(lastSync) > 24 * 60 * 60
    }

    /// Perform daily background sync if needed
    /// Call this periodically (e.g., when Powston API refreshes data)
    /// Syncs trades (today + 7 days forecast) and orders if stale
    func performDailySyncIfNeeded(siteId: Int) async {
        guard hasCredentials else { return }

        // Settlement schema migrations — clear cached summaries to force re-fetch with corrected logic
        // v14: include export network energy credits in cashflow calculation
        // v15: (broken) recomputed from incomplete intervals table — reverted
        // v16: clear and re-fetch to fix v15 damage
        let settlementVersion = UserDefaults.standard.integer(forKey: "lv_settlement_schema_version")
        let needsRefresh = settlementVersion < 16

        if needsRefresh {
            dataStore.clearAllSettlementData(siteId: siteId)
            UserDefaults.standard.removeObject(forKey: "lv_earliest_settlement_date_\(siteId)")
            UserDefaults.standard.set(16, forKey: "lv_settlement_schema_version")
            print("📊 Settlement v16 migration: cleared cashflow cache for clean re-fetch")
        }

        let needsOrdersSync = needsDailyOrdersSync(siteId: siteId)
        let needsTradesSync = needsDailyTradesSync(siteId: siteId)
        let needsSettlementBackfill = needsRefresh || dataStore.getSettlementDates(siteId: siteId).count < 55

        guard needsOrdersSync || needsTradesSync || needsSettlementBackfill else {
            return
        }

        print("📅 Daily LV sync needed - orders: \(needsOrdersSync), trades: \(needsTradesSync), settlement: \(needsSettlementBackfill)")

        do {
            // Sync orders (contracts) if needed
            if needsOrdersSync {
                print("📦 Daily sync: fetching LV orders...")
                _ = try await fetchOrders(siteId: siteId, force: true)
            }

            // Sync trades (backfill missed days + 7 day forecast) if needed
            if needsTradesSync {
                print("📊 Daily sync: fetching LV trades...")
                var calendar = Calendar.current
                calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
                let today = calendar.startOfDay(for: Date())
                let weekAhead = calendar.date(byAdding: .day, value: 7, to: today) ?? today

                // Backfill from last sync date (or 60 days ago if never synced)
                // Always go back at least 3 days to catch trades that may have been
                // incomplete on prior syncs (LV only returns today's trades via WebSocket)
                let maxLookback = calendar.date(byAdding: .day, value: -60, to: today) ?? today
                let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: today) ?? today
                let lastSync = dataStore.getLastLVSyncTime(siteId: siteId)
                let lastSyncDay = calendar.startOfDay(for: lastSync ?? maxLookback)
                let catchUpDate = max(maxLookback, min(threeDaysAgo, lastSyncDay))
                print("📊 Trade backfill from \(catchUpDate) to \(weekAhead)")

                _ = try await fetchTrades(siteId: siteId, from: catchUpDate, to: weekAhead)
            }

            // Sync forward-contracted trades for active orders (QtyReport for future dates)
            if needsTradesSync || needsOrdersSync {
                print("📊 Daily sync: fetching forward-contracted trades...")
                try await syncForwardTrades(siteId: siteId)
            }

            // Backfill settlement data if we have gaps or v5 cleared data
            if needsSettlementBackfill {
                await backfillSettlementIfNeeded(siteId: siteId, forceRefresh: needsRefresh)
            }

            print("✅ Daily LV sync complete")
        } catch {
            print("⚠️ Daily LV sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func handleReceivedTrades(_ trades: [LVIntervalTrade]) {
        receivedTrades.append(contentsOf: trades)
        print("📥 LocalVolts: received \(trades.count) trades (total: \(receivedTrades.count))")
    }

    private func handleReceivedMarketContracts(_ contracts: [LVMarketContract]) {
        receivedMarketContracts.append(contentsOf: contracts)
        print("📥 LocalVolts: received \(contracts.count) market contracts (total: \(receivedMarketContracts.count))")
    }

    private func handleReceivedOrders(_ orders: [LVOrder]) {
        receivedOrders.append(contentsOf: orders)
        print("📥 LocalVolts: received \(orders.count) orders (total: \(receivedOrders.count))")
    }

    /// Fetch historical settlement data on demand for a date range.
    /// Checks lv_daily_cashflow cache first, only fetches missing dates via QtyReport.
    /// Returns the count of new days fetched (0 if all cached).
    func fetchSettlementOnDemand(siteId: Int, from: Date, to: Date) async -> Int {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
        let today = calendar.startOfDay(for: Date())

        // Clamp 'to' to yesterday (don't fetch today — Identity handles it)
        let effectiveTo = min(to, calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        let effectiveFrom = calendar.startOfDay(for: from)

        guard effectiveFrom <= effectiveTo else { return 0 }

        // Check which dates we already have
        let existingDates = dataStore.getSettlementDates(siteId: siteId)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")

        var missingDates: [Date] = []
        var checkDate = effectiveFrom
        while checkDate <= effectiveTo {
            let dateStr = formatter.string(from: checkDate)
            if !existingDates.contains(dateStr) {
                missingDates.append(checkDate)
            }
            checkDate = calendar.date(byAdding: .day, value: 1, to: checkDate) ?? effectiveTo
        }

        guard !missingDates.isEmpty else { return 0 }

        var newDaysFetched = 0

        // Request in chunks of 30 days
        let chunkSize = 30
        for chunkStart in stride(from: 0, to: missingDates.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, missingDates.count)
            let chunkFrom = missingDates[chunkStart]
            let chunkTo = missingDates[chunkEnd - 1]

            do {
                // fetchTrades triggers QtyReport which returns settlement data via handleReceivedSettlement
                _ = try await fetchTrades(siteId: siteId, from: chunkFrom, to: chunkTo)
                let daysInChunk = chunkEnd - chunkStart
                newDaysFetched += daysInChunk
            } catch {
                print("⚠️ Settlement on-demand failed for chunk: \(error.localizedDescription)")
                break  // Don't hammer the server
            }
        }

        return newDaysFetched
    }

    /// Backfill settlement data for dates we're missing (one-time catch-up per gap)
    /// Settlement data piggybacks on QtyReport responses, so we request historical ranges.
    /// When forceRefresh is true, re-fetch ALL dates (used for v3 migration to correct standing charges).
    private func backfillSettlementIfNeeded(siteId: Int, forceRefresh: Bool = false) async {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
        let today = calendar.startOfDay(for: Date())

        // Clean up any forecast data that was inadvertently stored
        dataStore.purgeFutureSettlementData(siteId: siteId)
        dataStore.purgeFutureSettlementIntervals(siteId: siteId)

        // Go back 60 days max
        let maxLookback = calendar.date(byAdding: .day, value: -60, to: today) ?? today
        let existingDates = forceRefresh ? Set<String>() : dataStore.getSettlementDates(siteId: siteId)

        // Build list of missing dates (or all dates when forceRefresh)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")

        var missingDates: [Date] = []
        var checkDate = maxLookback
        while checkDate < today {  // Don't include today — Identity handles it
            let dateStr = formatter.string(from: checkDate)
            if !existingDates.contains(dateStr) {
                missingDates.append(checkDate)
            }
            checkDate = calendar.date(byAdding: .day, value: 1, to: checkDate) ?? today
        }

        guard !missingDates.isEmpty else { return }

        // Request in chunks of 30 days to avoid huge responses
        let chunkSize = 30
        for chunkStart in stride(from: 0, to: missingDates.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, missingDates.count)
            let from = missingDates[chunkStart]
            let to = missingDates[chunkEnd - 1]

            do {
                _ = try await fetchTrades(siteId: siteId, from: from, to: to)
            } catch {
                print("⚠️ Settlement backfill failed for chunk: \(error.localizedDescription)")
                break  // Don't hammer the server if something's wrong
            }
        }
    }

    private func handleReceivedSettlement(_ records: [LVSettlementRecord]) {
        guard currentSiteId > 0 else { return }

        // Filter out future dates — QtyReport returns forecast data we don't want to store
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        let todayStr = formatter.string(from: Date())
        let filtered = records.filter { String($0.date.prefix(10)) <= todayStr }

        guard !filtered.isEmpty else { return }

        // Save per-interval records before aggregation
        dataStore.saveLVSettlementIntervals(filtered, siteId: currentSiteId)

        // Compute daily summaries from the callback's full record set.
        // This preserves multi-NMI data that the intervals table PK may deduplicate.
        let byDate = Dictionary(grouping: filtered) { String($0.date.prefix(10)) }
        let summaries = byDate.values.map { $0.cashflowSummary() }

        // Save to database
        dataStore.saveLVCashflowSummaries(summaries, siteId: currentSiteId)
        receivedSettlementCount += filtered.count
    }

    private func updateTradeCount() {
        // Get count from current site if we have one
        if currentSiteId > 0 {
            tradeCount = dataStore.countLVTrades(siteId: currentSiteId)
        }
    }

    // MARK: - Errors

    enum ServiceError: LocalizedError {
        case noCredentials
        case noAuthToken
        case notConnected
        case syncFailed(underlying: Error)
        case throttled(seconds: Int)

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "No LocalVolts credentials configured"
            case .noAuthToken:
                return "Not authenticated with LocalVolts"
            case .notConnected:
                return "Not connected to LocalVolts"
            case .syncFailed(let error):
                return "Sync failed: \(error.localizedDescription)"
            case .throttled(let seconds):
                return "Please wait \(seconds) seconds before syncing again"
            }
        }
    }
}

// MARK: - Convenience Extensions

extension LocalVoltsService {

    /// Status badge text for SettingsView
    var statusBadge: String {
        if connectionStatus.isConnected {
            return "Connected"
        } else if hasCredentials {
            return "Configured"
        } else {
            return "Not configured"
        }
    }

    /// Formatted last sync time
    var lastSyncDescription: String? {
        guard let time = lastSyncTime else { return nil }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: time, relativeTo: Date())
    }
}
