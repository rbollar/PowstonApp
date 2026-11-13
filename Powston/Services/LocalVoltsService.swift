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
    @Published var isSyncing: Bool = false

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
    private var receivedSettlementCount: Int = 0

    // MARK: - Throttling

    /// Track last action times to prevent hammering
    private var lastActionTime: [ThrottleAction: Date] = [:]

    enum ThrottleAction: String {
        case syncTrades
        case testConnection
    }

    /// Cooldown periods for each action (in seconds)
    private static let cooldowns: [ThrottleAction: TimeInterval] = [
        .syncTrades: 30,       // 30 seconds between settlement syncs
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

    private init() {}

    // MARK: - Public API

    /// Check if credentials are configured for the current site
    var hasCredentials: Bool {
        guard currentSiteId > 0 else { return false }
        return credentialManager.hasCredentials(siteId: currentSiteId)
    }

    /// Check if credentials are configured for a specific site
    func hasCredentials(forSiteId siteId: Int) -> Bool {
        credentialManager.hasCredentials(siteId: siteId)
    }

    /// Get stored username for current site (for display)
    var storedUsername: String? {
        guard currentSiteId > 0 else { return nil }
        return credentialManager.load(siteId: currentSiteId)?.username
    }

    /// Connect to LocalVolts with stored credentials
    func connect(siteId: Int) async throws {
        guard let credentials = credentialManager.load(siteId: siteId) else {
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

    /// Save credentials for the current site after successful test
    func saveCredentials(username: String, password: String) throws {
        guard currentSiteId > 0 else { throw ServiceError.noCredentials }
        try credentialManager.save(username: username, password: password, siteId: currentSiteId)
    }

    /// Save credentials for a specific site
    func saveCredentials(username: String, password: String, siteId: Int) throws {
        try credentialManager.save(username: username, password: password, siteId: siteId)
    }

    /// Delete stored credentials for the current site
    func deleteCredentials() throws {
        guard currentSiteId > 0 else { return }
        try credentialManager.delete(siteId: currentSiteId)
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
            if !Task.isCancelled && connectionStatus.isConnected && !isSyncing {
                print("🔌 Disconnecting idle LocalVolts socket")
                disconnect()
            }
        }
    }

    /// Fetch settlement data for a date range via QtyReport.
    /// The Identity response covers today; historical data requires a QtyReport request.
    func fetchSettlement(siteId: Int, from: Date, to: Date) async throws {
        isSyncing = true
        defer {
            isSyncing = false
            if connectionStatus.isLoading { connectionStatus = .disconnected }
        }

        // Connect if needed - this sends identity request and receives today's settlement
        if !connectionStatus.isConnected {
            connectionStatus = .connecting
            try await connect(siteId: siteId)
        }

        guard socketClient?.isConnected == true else {
            throw ServiceError.notConnected
        }

        connectionStatus = .fetching

        // Wait for identity response to be parsed
        try await Task.sleep(nanoseconds: 2_000_000_000)  // 2s for parsing

        // Check if we need data outside of today (historical)
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
        let todayStart = calendar.startOfDay(for: Date())

        // Identity response only contains today's data; QtyReport is needed for history
        if from < todayStart {
            // Reconnect with userId_sessionId suffix so server can route response back
            print("🔄 Reconnecting with suffix for historical settlement data...")
            try await socketClient?.reconnectWithUserSuffix()

            let settlementBeforeRequest = receivedSettlementCount
            print("📤 Requesting settlement data from \(from) to \(to)")
            socketClient?.requestTradeData(from: from, to: to)

            // Poll for data response (up to 30 seconds, checking every 2 seconds)
            for attempt in 1...15 {
                try await Task.sleep(nanoseconds: 2_000_000_000)  // 2s between checks
                let newSettlement = receivedSettlementCount - settlementBeforeRequest
                if newSettlement > 0 {
                    print("✅ Received \(newSettlement) settlement records after \(attempt * 2)s")
                    break
                }
                if attempt < 15 {
                    print("⏳ Waiting for settlement data... (\(attempt * 2)s)")
                }
            }
        }

        connectionStatus = .connected
        lastSyncTime = Date()

        // Disconnect socket when done - no need to keep connection open
        disconnectWhenIdle()
    }

    // MARK: - Daily Background Sync

    /// Perform daily background sync if needed
    /// Call this periodically (e.g., when Powston API refreshes data)
    /// Backfills settlement data if stale or missing
    func performDailySyncIfNeeded(siteId: Int, activeRetailer: String? = nil) async {
        guard hasCredentials(forSiteId: siteId) else { return }

        // A site that has moved to another retailer has no new LV settlement to fetch
        if let retailer = activeRetailer, !retailer.isEmpty, retailer.lowercased() != "localvolts" {
            return
        }

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

        // Throttle to once per day; backfillSettlementIfNeeded itself returns
        // early when no dates in the 60-day window are missing
        let lastSyncKey = "lv_last_daily_settlement_sync_\(siteId)"
        let lastSync = UserDefaults.standard.object(forKey: lastSyncKey) as? Date
        let daysSinceSync = lastSync.map { Date().timeIntervalSince($0) } ?? .infinity
        guard needsRefresh || daysSinceSync > 24 * 60 * 60 else { return }

        print("📅 Daily LV sync - settlement backfill")
        await backfillSettlementIfNeeded(siteId: siteId, forceRefresh: needsRefresh)
        UserDefaults.standard.set(Date(), forKey: lastSyncKey)
        print("✅ Daily LV sync complete")
    }

    // MARK: - Private

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

        // Recent days (last 3 days) are always re-fetched because settlement data
        // may arrive incomplete on first fetch and fill in over subsequent hours
        let recentCutoff = calendar.date(byAdding: .day, value: -3, to: today) ?? today

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")

        var missingDates: [Date] = []
        var checkDate = effectiveFrom
        while checkDate <= effectiveTo {
            let dateStr = formatter.string(from: checkDate)
            let isRecent = checkDate >= recentCutoff
            if isRecent || !existingDates.contains(dateStr) {
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
                // fetchSettlement triggers QtyReport which returns settlement data via handleReceivedSettlement
                try await fetchSettlement(siteId: siteId, from: chunkFrom, to: chunkTo)
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
                try await fetchSettlement(siteId: siteId, from: from, to: to)
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

        // Save per-interval records before aggregation (upserts accumulate across batches)
        dataStore.saveLVSettlementIntervals(filtered, siteId: currentSiteId)

        // Recompute daily summaries from ALL accumulated intervals in the table,
        // not just this batch. Previous approach computed from the batch only, causing
        // stale/partial cashflow when data arrives in multiple Identity responses.
        let affectedDates = Set(filtered.map { String($0.date.prefix(10)) })
        var summaries: [LVCashflowSummary] = []
        for dateStr in affectedDates {
            let allIntervals = dataStore.getSettlementIntervals(siteId: currentSiteId, date: dateStr)
            if !allIntervals.isEmpty {
                summaries.append(allIntervals.cashflowSummary())
            }
        }

        // Save to database
        if !summaries.isEmpty {
            dataStore.saveLVCashflowSummaries(summaries, siteId: currentSiteId)
        }
        receivedSettlementCount += filtered.count
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
