//
//  PowstonAPI.swift
//  Powston
//
//  Core class definition with shared state and authentication
//

import Foundation
import SwiftUI
import Combine

class PowstonAPI: ObservableObject {
    // MARK: - Published Properties
    @Published var data: InverterResponse?
    @Published var sites: [Site] = []
    @Published var inverters: [Inverter] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var lastFetchTime: Date?
    @Published var isDemoMode = false
    @Published var earliestRecordDate: Date?
    
    // Controller health monitoring
    @Published var controllerHealthStatus: ControllerHealthStatus = .unknown
    @Published var unhealthyControllers: [String] = []  // MAC addresses of offline controllers
    @Published var lastControllerHealthCheck: Date?
    // Powston service health
    @Published var powstonServiceOnline: Bool = true
    @Published var powstonServiceLastCheck: Date?
    
    // Manual override tracking
    @Published var pendingOverrides: [PendingOverride] = []
    @Published var currentOverrides: [ManualAction] = []   // Currently executing (grouped)
    @Published var scheduledOverrides: [ManualAction] = [] // Future start time (grouped)
    internal var allOverrideActions: [ManualAction] = []   // Full list for cancellation/verification
    internal var actionParamsMetadataCache: [String: ActionParamsMetadata] = [:]  // keyed by brand
    
    // Day Rate Summary Properties
    @Published var latestCompleteDataDate: Date?
    internal var dayRateSummaryCache: [String: DayRateCacheEntry] = [:]
    internal let dayRateSummaryCacheMinutes: Double = 30
    internal var lastDataAvailabilityCheck: Date?
    internal let dataAvailabilityCheckInterval: TimeInterval = 30 * 60
    
    // MARK: - Caches
    internal var meterRecordsCache: [String: (records: [MeterRecord], fetchTime: Date)] = [:]
    internal let meterRecordsCacheMinutes: Double = 60
    
    internal var actionsCache: [String: (actions: [InverterAction], fetchTime: Date)] = [:]
    internal let actionsCacheMinutes: Double = 5
    
    // MARK: - Session
    internal lazy var persistentSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()
    
    // MARK: - App Storage
    @AppStorage("api_key") var apiKey = "" {
        didSet {
            sharedDefaults?.set(apiKey, forKey: SharedSettingsKey.apiKey)
        }
    }
    
    @AppStorage("selected_inverter_id") var selectedInverterId: Int = 0 {
        didSet {
            sharedDefaults?.set(selectedInverterId, forKey: SharedSettingsKey.selectedInverterId)
        }
    }
    
    @AppStorage("demo_mode_enabled") var demoModeEnabled: Bool = false
    @AppStorage("use_dev_server") var useDevServer: Bool = false
    @AppStorage("single_site_mode") var singleSiteMode: Bool = false
    
    @AppStorage("selected_site_id") internal var persistedSiteId: Int = 0 {
        didSet {
            sharedDefaults?.set(persistedSiteId, forKey: SharedSettingsKey.siteId)
        }
    }
    
    // MARK: - Lead Inverter Storage Keys
    internal let leadInverterOverridesKey = "lead_inverter_overrides"
    internal let detectedLeadInvertersKey = "detected_lead_inverters"
    
    // MARK: - Init
    init() {
        syncSettingsToAppGroup()
    }
    
    // MARK: - Computed Properties
    
    var selectedSiteId: Int? {
        if let inverter = inverters.first(where: { $0.id == selectedInverterId }) {
            if persistedSiteId != inverter.siteId {
                persistedSiteId = inverter.siteId
            }
            return inverter.siteId
        }
        if persistedSiteId != 0 {
            return persistedSiteId
        }
        return sites.first?.id
    }
    
    var selectedSite: Site? {
        guard let siteId = selectedSiteId else { return nil }
        return sites.first(where: { $0.id == siteId })
    }
    
    var effectiveSites: [Site] {
        if singleSiteMode {
            if let site = selectedSite {
                sharedDefaults?.set(site.timezone ?? "", forKey: SharedSettingsKey.siteTimezone)
                sharedDefaults?.set(site.state ?? "", forKey: SharedSettingsKey.siteState)
                return [site]
            }
            return Array(sites.prefix(1))
        }
        return sites
    }
    
    var baseURL: String {
        let url = useDevServer ? "https://dev.inverterintelligence.com" : "https://app.powston.com"
        sharedDefaults?.set(url, forKey: SharedSettingsKey.baseURL)
        return url
    }
    
    // Legacy computed property for compatibility
    var activeOverrides: [ManualAction] {
        currentOverrides + scheduledOverrides
    }
    
    // MARK: - Override Status Properties
    
    var hasActiveOverride: Bool {
        !currentOverrides.isEmpty
    }
    
    var hasScheduledOverride: Bool {
        !scheduledOverrides.isEmpty
    }
    
    var hasPendingOverride: Bool {
        !pendingOverrides.isEmpty
    }
    
    var overrideStatusText: String? {
        if let firstActive = currentOverrides.first {
            if let reason = firstActive.reason, !reason.isEmpty {
                return reason
            }
            return "Manual \(firstActive.action.capitalized)"
        }
        if let firstScheduled = scheduledOverrides.first {
            return "Scheduled: \(firstScheduled.action.capitalized) \(firstScheduled.formattedStartsIn)"
        }
        if let firstPending = pendingOverrides.first {
            return "Pending: \(firstPending.mode.capitalized)"
        }
        return nil
    }
    
    // MARK: - Sync Methods
    
    func syncSettingsToAppGroup() {
        print("📱 Syncing to App Group: \(appGroupID)")
        print("📱 sharedDefaults exists: \(sharedDefaults != nil)")
        sharedDefaults?.set(apiKey, forKey: SharedSettingsKey.apiKey)
        sharedDefaults?.set(baseURL, forKey: SharedSettingsKey.baseURL)
        sharedDefaults?.set(selectedInverterId, forKey: SharedSettingsKey.selectedInverterId)
        sharedDefaults?.set(selectedSiteId ?? 0, forKey: SharedSettingsKey.siteId)
        sharedDefaults?.synchronize()
        print("📱 Synced API Key: '\(apiKey.prefix(10))...'")
        print("📱 Synced Base URL: '\(baseURL)'")
        print("📱 Synced Inverter ID: \(selectedInverterId)")
        print("📱 Synced Site ID: \(selectedSiteId ?? 0)")
        print("☁️ KVS identifier: \(NSUbiquitousKeyValueStore.default.dictionaryRepresentation.keys)")
        
        // iCloud KVS sync for tvOS app
        if !apiKey.isEmpty, let siteId = selectedSiteId, siteId > 0 {
            let siteName = selectedSite?.displayName ?? selectedSite?.name ?? "My Site"
            CloudCredentialSync.shared.saveCredentials(
                apiKey: apiKey,
                baseURL: baseURL,
                siteId: siteId,
                inverterId: selectedInverterId,
                siteName: siteName
            )
        }
        
        // Sync timezone for widgets
        if let site = selectedSite {
            sharedDefaults?.set(site.timezone ?? "", forKey: SharedSettingsKey.siteTimezone)
            sharedDefaults?.set(site.state ?? "", forKey: SharedSettingsKey.siteState)
            print("🌏 Synced Timezone: '\(site.timezone ?? "nil")' State: '\(site.state ?? "nil")'")
        }
        
        #if os(iOS)
        WatchConnectivityManager.shared.sendCredentialsToWatch(
            apiKey: apiKey,
            baseURL: baseURL,
            siteId: selectedSiteId ?? 0,
            demoMode: demoModeEnabled
        )
        #endif
    }
    
    func updateStoredSiteTimezone() {
        if let site = selectedSite {
            // Standard UserDefaults for main app
            UserDefaults.standard.set(site.state, forKey: "selected_site_state")
            UserDefaults.standard.set(site.timezone, forKey: "selected_site_timezone")
            // Shared defaults for widgets
            sharedDefaults?.set(site.timezone ?? "", forKey: SharedSettingsKey.siteTimezone)
            sharedDefaults?.set(site.state ?? "", forKey: SharedSettingsKey.siteState)
        }
    }
    
    // MARK: - Cache Helpers
    
    internal func cacheKey(from: Date?, to: Date?) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = powstonTimezone()
        
        let sitePrefix = selectedSiteId.map { "site\($0)_" } ?? ""
        let fromStr = from.map { formatter.string(from: $0) } ?? "nil"
        let toStr = to.map { formatter.string(from: $0) } ?? "nil"
        return "\(sitePrefix)\(fromStr)_\(toStr)"
    }
    
    func clearMeterRecordsCache() {
        meterRecordsCache.removeAll()
    }
    
    func clearDayRateSummaryCache() {
        dayRateSummaryCache.removeAll()
        latestCompleteDataDate = nil
        lastDataAvailabilityCheck = nil
    }
    
    // MARK: - Helper to get inverter IDs for current site
    internal func getCurrentSiteInverterIds() -> [Int] {
        guard let selectedInverter = inverters.first(where: { $0.id == selectedInverterId }) else {
            return inverters.map { $0.id }
        }
        let ids = inverters.filter { $0.siteId == selectedInverter.siteId }.map { $0.id }
        print("🔍 getCurrentSiteInverterIds: \(ids)")
        return ids
    }
}

// MARK: - Supporting Types

struct PendingOverride: Identifiable {
    let id = UUID()
    let mode: String
    let inverterIds: [Int]
    let startedAt: Date
    
    var elapsedTime: String {
        let elapsed = Int(Date().timeIntervalSince(startedAt))
        if elapsed < 60 {
            return "Submitted \(elapsed)s ago"
        } else {
            return "Submitted \(elapsed / 60)m ago"
        }
    }
}

internal struct DayRateCacheEntry {
    let summary: DayRateSummary
    let fetchTime: Date
}

// MARK: - RefreshableAPI Conformance

extension PowstonAPI: RefreshableAPI {
    var currentIntervalTime: String? {
        return data?.intervalTime
    }
    
    var isReadyToPoll: Bool {
        return selectedInverterId != 0
    }
}
