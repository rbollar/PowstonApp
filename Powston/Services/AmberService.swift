//
//  AmberService.swift
//  Powston
//
//  Client for the Amber Electric public API.
//  Base URL: https://api.amber.com.au/v1, Bearer token auth.
//
//  Key resolution: a manually entered key (stored per Powston site in the app
//  group UserDefaults) takes precedence; otherwise the amber_key that Powston
//  reports on the Site is used. The key is intentionally NOT placed in the
//  Keychain — it lives in the app group store like the Powston API key.
//

import Foundation
import SwiftUI
import Combine

@MainActor
class AmberService: ObservableObject {

    static let shared = AmberService()

    // MARK: - Published State

    @Published var currentPrices: [AmberInterval] = []   // current + forecast, all channels
    @Published var dailyUsage: [AmberDailyUsage] = []
    @Published var sites: [AmberSite] = []
    @Published var isLoadingPrices = false
    @Published var isLoadingUsage = false
    @Published var lastFetchTime: Date?
    @Published var priceError: String?
    @Published var usageError: String?

    // MARK: - Configuration

    private let baseURL = "https://api.amber.com.au/v1"

    /// Which Powston site the published data belongs to (guards against
    /// showing site A's Amber data after switching to site B)
    private var loadedForPowstonSiteId: Int?
    private var lastUsageFetchTime: Date?
    private static let usageTTL: TimeInterval = 15 * 60

    private static func manualKeyKey(_ siteId: Int) -> String { "amber_api_key_\(siteId)" }
    private static func siteIdKey(_ siteId: Int) -> String { "amber_selected_site_id_\(siteId)" }

    /// Manually entered key for a Powston site (overrides the Powston-provided one)
    func manualKey(forPowstonSite siteId: Int) -> String? {
        let key = sharedDefaults?.string(forKey: Self.manualKeyKey(siteId))
        return (key?.isEmpty == false) ? key : nil
    }

    func setManualKey(_ key: String?, forPowstonSite siteId: Int) {
        sharedDefaults?.set(key ?? "", forKey: Self.manualKeyKey(siteId))
    }

    /// Resolve the API key: manual override first, then the site's Powston-provided key
    func apiKey(for site: Site?) -> String? {
        if let siteId = site?.id, let manual = manualKey(forPowstonSite: siteId) {
            return manual
        }
        if let siteKey = site?.amberKey, !siteKey.isEmpty { return siteKey }
        return nil
    }

    /// Resolve the Amber site id: Powston-provided first, then locally discovered
    func amberSiteId(for site: Site?) -> String? {
        if let id = site?.amberSiteId, !id.isEmpty { return id }
        guard let siteId = site?.id else { return nil }
        let stored = sharedDefaults?.string(forKey: Self.siteIdKey(siteId))
        return (stored?.isEmpty == false) ? stored : nil
    }

    /// Whether Amber is configured for this site. When Powston reports a
    /// different active retailer (e.g. localvolts) and there is no manual
    /// override, Amber stays hidden even if a stale amber_key is present.
    func isConfigured(for site: Site?) -> Bool {
        guard apiKey(for: site) != nil else { return false }
        if let siteId = site?.id, manualKey(forPowstonSite: siteId) != nil { return true }
        if let retailer = site?.activeRetailer, retailer != "amber" { return false }
        return true
    }

    // MARK: - Requests

    private func request<T: Decodable>(_ path: String, apiKey: String) async throws -> T {
        guard let url = URL(string: baseURL + path) else {
            throw AmberError.invalidURL
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "accept")
        req.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AmberError.invalidResponse
        }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw AmberError.unauthorized
        case 429: throw AmberError.rateLimited
        default: throw AmberError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Public API

    /// Fetch the user's Amber sites (also validates the key)
    @discardableResult
    func fetchSites(apiKey: String, forPowstonSite siteId: Int? = nil) async throws -> [AmberSite] {
        let result: [AmberSite] = try await request("/sites", apiKey: apiKey)
        sites = result
        // Remember the first active site for later use if Powston has no amber_site_id
        if let siteId, let active = result.first(where: { $0.status == .active }) ?? result.first {
            sharedDefaults?.set(active.id, forKey: Self.siteIdKey(siteId))
        }
        return result
    }

    /// Fetch current price + forecasts for all channels.
    func fetchCurrentPrices(site: Site?, next: Int = 24, resolution: Int = 30) async {
        guard let key = apiKey(for: site) else { return }

        // Site switch: drop the previous site's data and skip the throttle
        let siteChanged = loadedForPowstonSiteId != site?.id
        if siteChanged {
            currentPrices = []
            dailyUsage = []
            lastFetchTime = nil
            lastUsageFetchTime = nil
        }

        // Throttle: current prices barely change inside a 5-minute dispatch interval
        if let last = lastFetchTime, Date().timeIntervalSince(last) < 60, !currentPrices.isEmpty {
            return
        }

        isLoadingPrices = true
        priceError = nil
        do {
            let siteId = try await resolveSiteId(site: site, apiKey: key)
            let prices: [AmberInterval] = try await request(
                "/sites/\(siteId)/prices/current?next=\(next)&previous=0&resolution=\(resolution)",
                apiKey: key
            )
            currentPrices = prices
            lastFetchTime = Date()
            loadedForPowstonSiteId = site?.id
        } catch is CancellationError {
            // View disappeared — not an error
        } catch {
            priceError = (error as? AmberError)?.errorDescription ?? error.localizedDescription
        }
        isLoadingPrices = false
    }

    /// Price forecast for Ask, without touching the published state the Prices tab shows.
    /// Amber forecasts to about 4 AM the next day; asking for more just returns what it has.
    func forecastIntervals(site: Site?, next: Int = 96) async -> [AmberInterval] {
        guard let key = apiKey(for: site) else { return [] }
        do {
            let siteId = try await resolveSiteId(site: site, apiKey: key)
            return try await request(
                "/sites/\(siteId)/prices/current?next=\(next)&previous=0&resolution=30",
                apiKey: key
            )
        } catch {
            return []
        }
    }

    /// Fetch usage for a date range (Amber finalizes usage ~T+1)
    func fetchUsage(site: Site?, from: Date, to: Date) async {
        guard let key = apiKey(for: site) else { return }

        // Usage is finalized data — a 15-minute TTL is plenty
        if let last = lastUsageFetchTime,
           Date().timeIntervalSince(last) < Self.usageTTL,
           loadedForPowstonSiteId == site?.id,
           !dailyUsage.isEmpty {
            return
        }

        isLoadingUsage = true
        usageError = nil
        do {
            let siteId = try await resolveSiteId(site: site, apiKey: key)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = powstonTimezone()
            let start = formatter.string(from: from)
            let end = formatter.string(from: to)
            let usage: [AmberUsageRecord] = try await request(
                "/sites/\(siteId)/usage?startDate=\(start)&endDate=\(end)&resolution=30",
                apiKey: key
            )
            dailyUsage = AmberDailyUsage.aggregate(usage)
            lastUsageFetchTime = Date()
            loadedForPowstonSiteId = site?.id
        } catch is CancellationError {
            // View disappeared — not an error
        } catch {
            usageError = (error as? AmberError)?.errorDescription ?? error.localizedDescription
        }
        isLoadingUsage = false
    }

    /// Test a key without saving it. Returns the active site description.
    func testKey(_ key: String, forPowstonSite siteId: Int? = nil) async throws -> String {
        let sites = try await fetchSites(apiKey: key, forPowstonSite: siteId)
        guard let site = sites.first(where: { $0.status == .active }) ?? sites.first else {
            throw AmberError.noSites
        }
        return "NMI \(site.nmi) on \(site.network) (\(site.intervalLength)-min intervals)"
    }

    // MARK: - Helpers

    private func resolveSiteId(site: Site?, apiKey: String) async throws -> String {
        if let id = amberSiteId(for: site) { return id }
        let sites = try await fetchSites(apiKey: apiKey, forPowstonSite: site?.id)
        guard let active = sites.first(where: { $0.status == .active }) ?? sites.first else {
            throw AmberError.noSites
        }
        return active.id
    }

    /// Current general (buy) interval
    var currentGeneral: AmberInterval? {
        currentPrices.first { $0.isCurrent && $0.channelType == .general }
    }

    /// Current feed-in (sell) interval
    var currentFeedIn: AmberInterval? {
        currentPrices.first { $0.isCurrent && $0.channelType == .feedIn }
    }

    /// Forecast intervals for a channel, in time order
    func forecast(for channel: AmberChannelType) -> [AmberInterval] {
        currentPrices.filter { $0.isForecast && $0.channelType == channel }
    }

    // MARK: - Errors

    enum AmberError: LocalizedError {
        case invalidURL
        case invalidResponse
        case unauthorized
        case rateLimited
        case noSites
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid Amber API URL"
            case .invalidResponse: return "Invalid response from Amber"
            case .unauthorized: return "Amber API key rejected (401)"
            case .rateLimited: return "Amber API rate limit reached — try again shortly"
            case .noSites: return "No Amber sites found for this API key"
            case .httpError(let code): return "Amber API error (HTTP \(code))"
            }
        }
    }
}
