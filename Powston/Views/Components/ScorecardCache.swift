//
//  ScorecardCache.swift
//  Powston
//
//  Manages persistent caching of meter records for scorecard computation
//  Uses UserDefaults for simplicity - could migrate to Core Data for larger datasets
//

import Foundation

class ScorecardCache: ObservableObject {
    static let shared = ScorecardCache()
    
    // In-memory cache
    private var recordsCache: [Int: [MeterRecord]] = [:]  // siteId -> records
    private var lastFetchDate: [Int: Date] = [:]  // siteId -> last fetch time
    private var oldestCachedDate: [Int: Date] = [:]  // siteId -> oldest record date
    private var newestCachedDate: [Int: Date] = [:]  // siteId -> newest record date
    
    // Computed scorecards cache
    private var scorecardCache: [String: Scorecard] = [:]  // "siteId_period_date" -> scorecard
    
    @Published var isLoading = false
    @Published var loadingProgress: String = ""
    
    private let calculator = ScorecardCalculator()
    
    // MARK: - Public Interface
    
    /// Get or compute scorecard for a site and period
    func getScorecard(
        siteId: Int,
        period: ScorecardPeriod,
        api: PowstonAPI,
        forceRefresh: Bool = false
    ) async -> Scorecard? {
        let cacheKey = scorecardCacheKey(siteId: siteId, period: period)
        
        // Return cached scorecard if fresh (within 5 minutes)
        if !forceRefresh,
           let cached = scorecardCache[cacheKey],
           Date().timeIntervalSince(cached.generatedAt) < 300 {
            return cached
        }
        
        // Ensure we have records
        await ensureRecords(siteId: siteId, period: period, api: api)
        
        guard let records = recordsCache[siteId], !records.isEmpty else {
            return nil
        }
        
        // Filter records for period
        let (from, to) = dateRange(for: period)
        let filteredRecords = records.filter { record in
            guard let date = record.date else { return false }
            return date >= from && date <= to
        }
        
        guard !filteredRecords.isEmpty else { return nil }
        
        // Compute scorecard
        let scorecard = calculator.calculate(
            records: filteredRecords,
            siteId: siteId,
            from: from,
            to: to
        )
        
        // Cache it
        scorecardCache[cacheKey] = scorecard
        
        return scorecard
    }
    
    /// Refresh records from API
    func refreshRecords(siteId: Int, api: PowstonAPI) async {
        await fetchRecords(siteId: siteId, api: api, fullRefresh: true)
    }
    
    /// Clear all cached data
    func clearCache() {
        recordsCache.removeAll()
        lastFetchDate.removeAll()
        oldestCachedDate.removeAll()
        newestCachedDate.removeAll()
        scorecardCache.removeAll()
    }
    
    /// Clear cache for specific site
    func clearCache(siteId: Int) {
        recordsCache.removeValue(forKey: siteId)
        lastFetchDate.removeValue(forKey: siteId)
        oldestCachedDate.removeValue(forKey: siteId)
        newestCachedDate.removeValue(forKey: siteId)
        
        // Clear scorecard cache entries for this site
        scorecardCache = scorecardCache.filter { !$0.key.hasPrefix("\(siteId)_") }
    }
    
    // MARK: - Private Methods
    
    private func ensureRecords(siteId: Int, period: ScorecardPeriod, api: PowstonAPI) async {
        let (from, _) = dateRange(for: period)
        
        // Check if we need to fetch
        if let oldest = oldestCachedDate[siteId], oldest <= from {
            // We have data going back far enough
            // Check if we need fresh data (last fetch > 5 min ago)
            if let lastFetch = lastFetchDate[siteId],
               Date().timeIntervalSince(lastFetch) < 300 {
                return  // Cache is fresh enough
            }
            
            // Fetch only new records
            await fetchNewRecords(siteId: siteId, api: api)
        } else {
            // Need to fetch more historical data
            await fetchRecords(siteId: siteId, api: api, from: from)
        }
    }
    
    private func fetchRecords(siteId: Int, api: PowstonAPI, from: Date? = nil, fullRefresh: Bool = false) async {
        await MainActor.run {
            isLoading = true
            loadingProgress = "Fetching meter records..."
        }
        
        defer {
            Task { @MainActor in
                isLoading = false
                loadingProgress = ""
            }
        }
        
        let toDate = Date()
        let fromDate = from ?? Calendar.current.date(byAdding: .day, value: -180, to: toDate)!
        
        do {
            let records = try await fetchMeterRecords(
                siteId: siteId,
                from: fromDate,
                to: toDate,
                api: api
            )
            
            if fullRefresh {
                recordsCache[siteId] = records
            } else {
                // Merge with existing
                var existing = recordsCache[siteId] ?? []
                let existingIds = Set(existing.map { $0.id })
                let newRecords = records.filter { !existingIds.contains($0.id) }
                existing.append(contentsOf: newRecords)
                existing.sort { $0.intervalTime < $1.intervalTime }
                recordsCache[siteId] = existing
            }
            
            // Update metadata
            lastFetchDate[siteId] = Date()
            
            if let cached = recordsCache[siteId] {
                if let oldest = cached.compactMap({ $0.date }).min() {
                    oldestCachedDate[siteId] = oldest
                }
                if let newest = cached.compactMap({ $0.date }).max() {
                    newestCachedDate[siteId] = newest
                }
            }
            
            // Invalidate scorecard cache for this site
            scorecardCache = scorecardCache.filter { !$0.key.hasPrefix("\(siteId)_") }
            
            await MainActor.run {
                loadingProgress = "Loaded \(records.count) records"
            }
            
        } catch {
            print("❌ Failed to fetch meter records: \(error)")
        }
    }
    
    private func fetchNewRecords(siteId: Int, api: PowstonAPI) async {
        guard let newest = newestCachedDate[siteId] else {
            await fetchRecords(siteId: siteId, api: api)
            return
        }
        
        // Fetch from newest cached date to now
        let fromDate = newest.addingTimeInterval(-3600)  // Overlap by 1 hour for safety
        await fetchRecords(siteId: siteId, api: api, from: fromDate)
    }
    
    private func fetchMeterRecords(siteId: Int, from: Date, to: Date, api: PowstonAPI) async throws -> [MeterRecord] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        
        let fromStr = dateFormatter.string(from: from)
        let toStr = dateFormatter.string(from: to)
        
        let urlString = "\(api.baseURL)/api/meter_records/\(siteId)?from=\(fromStr)&to=\(toStr)"
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(api.apiKey)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        let decoded = try JSONDecoder().decode(MeterRecordsResponse.self, from: data)
        return decoded.records
    }
    
    private func dateRange(for period: ScorecardPeriod) -> (from: Date, to: Date) {
        let calendar = Calendar.current
        let now = Date()
        
        let from: Date
        switch period {
        case .day:
            from = calendar.startOfDay(for: now)
        case .week:
            from = calendar.date(byAdding: .day, value: -7, to: now)!
        case .month:
            from = calendar.date(byAdding: .day, value: -30, to: now)!
        case .all:
            from = calendar.date(byAdding: .day, value: -180, to: now)!
        }
        
        return (from, now)
    }
    
    private func scorecardCacheKey(siteId: Int, period: ScorecardPeriod) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateStr = dateFormatter.string(from: Date())
        return "\(siteId)_\(period.rawValue)_\(dateStr)"
    }
}
