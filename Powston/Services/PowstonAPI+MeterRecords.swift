//
//  PowstonAPI+MeterRecords.swift
//  Powston
//
//  Meter record fetching with SQLite cache-through
//  Finalized records (>7 days old) are served from cache without API calls
//
//  Daily Backfill: Once per day after 8am Brisbane, fetches last 7 days
//  to catch any corrections. All callers benefit automatically.
//

import Foundation

extension PowstonAPI {
    
    // MARK: - Finalization Configuration
    
    /// Days older than this are considered finalized and won't be re-fetched
    private var meterRecordFinalizationDays: Int { 7 }
    
    // MARK: - Daily Backfill Coordination
    
    /// Check if we need to perform daily backfill (once per day after 8am Brisbane)
    /// This catches any corrections to recent data that the API might have updated
    private func performDailyBackfillIfNeeded(siteId: Int) async {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        let now = Date()
        let hour = calendar.component(.hour, from: now)
        
        // Only run after 8am Brisbane time (when API has updated)
        guard hour >= 8 else {
            return
        }
        
        // Check if we've already done today's backfill for this site
        let key = "meter_records_last_backfill_\(siteId)"
        let lastBackfillTimestamp = UserDefaults.standard.double(forKey: key)
        
        if lastBackfillTimestamp > 0 {
            let lastBackfill = Date(timeIntervalSince1970: lastBackfillTimestamp)
            if calendar.isDateInToday(lastBackfill) {
                // Already did backfill today
                return
            }
        }
        
        print("📊 Performing daily backfill for site \(siteId)...")
        
        // Fetch days 1-7 ago (the non-finalized window)
        let endDate = calendar.date(byAdding: .day, value: -1, to: now)!  // Yesterday
        let startDate = calendar.date(byAdding: .day, value: -7, to: now)!  // 7 days ago
        
        // Fetch directly from API to catch any corrections
        let records = await fetchMeterRecordsFromAPI(siteId: siteId, fromDate: startDate, toDate: endDate)
        
        if !records.isEmpty {
            let dataStore = PowstonDataStore.shared
            dataStore.saveMeterRecords(records, siteId: siteId)
            print("✅ Daily backfill complete: \(records.count) records for days 1-7")
        } else {
            print("⚠️ Daily backfill returned no records")
        }
        
        // Mark backfill complete for today
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: key)
    }
    
    // MARK: - Update Earliest Date
    
    internal func updateEarliestDate(from records: [MeterRecord]) {
        guard let oldestInBatch = records.compactMap({ $0.date }).min() else { return }
        print("📅 Checking earliest date: batch oldest = \(oldestInBatch), current = \(String(describing: earliestRecordDate))")
        if let current = earliestRecordDate {
            if oldestInBatch < current {
                print("📅 Updating earliest date from \(current) to \(oldestInBatch)")
                earliestRecordDate = oldestInBatch
                UserDefaults.standard.set(oldestInBatch.timeIntervalSince1970, forKey: "earliest_record_date")
            }
        } else {
            print("📅 Setting initial earliest date to \(oldestInBatch)")
            earliestRecordDate = oldestInBatch
            UserDefaults.standard.set(oldestInBatch.timeIntervalSince1970, forKey: "earliest_record_date")
        }
    }
    
    func loadEarliestRecordDate() {
        print("📅 loadEarliestRecordDate called")
        let timestamp = UserDefaults.standard.double(forKey: "earliest_record_date")
        if timestamp > 0 {
            earliestRecordDate = Date(timeIntervalSince1970: timestamp)
            print("📅 Loaded persisted earliest date: \(earliestRecordDate!)")
        } else {
            print("📅 No persisted date found")
        }
        print("📅 Starting discovery task...")
        Task {
            await discoverEarliestRecordDate()
        }
    }
    
    func resetEarliestRecordDate() {
        earliestRecordDate = nil
        UserDefaults.standard.removeObject(forKey: "earliest_record_date")
        print("📅 Reset earliest record date")
    }
    
    func discoverEarliestRecordDate() async {
        print("📅 discoverEarliestRecordDate starting, sites.count = \(sites.count)")
        guard let siteId = selectedSiteId else {
            print("📅 No site available for discovery")
            return
        }
        
        print("📅 Discovering with siteId = \(siteId)")
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let oldDate = calendar.date(from: DateComponents(year: 2020, month: 1, day: 1))!
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()
        
        let today = Date()
        let urlString = "\(baseURL)/api/meter_records/\(siteId)?from=\(dateFormatter.string(from: oldDate))&to=\(dateFormatter.string(from: today))&limit=1"
        
        print("📅 Discovery URL: \(urlString)")
        
        guard let url = URL(string: urlString) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            
            let decoded = try JSONDecoder().decode(MeterRecordsResponse.self, from: data)
            
            if let apiOldest = decoded.records.compactMap({ $0.date }).min() {
                await MainActor.run {
                    if let current = earliestRecordDate {
                        if apiOldest < current {
                            earliestRecordDate = apiOldest
                            UserDefaults.standard.set(apiOldest.timeIntervalSince1970, forKey: "earliest_record_date")
                            print("📅 API has older data: \(apiOldest)")
                        } else {
                            print("📅 Keeping cached earliest: \(current) (API oldest: \(apiOldest))")
                        }
                    } else {
                        earliestRecordDate = apiOldest
                        UserDefaults.standard.set(apiOldest.timeIntervalSince1970, forKey: "earliest_record_date")
                        print("📅 Discovered earliest date: \(apiOldest)")
                    }
                }
            } else {
                print("📅 No records from discovery query")
            }
        } catch {
            print("📅 Discovery error: \(error)")
        }
    }
    
    // MARK: - Fetch Meter Records (with SQLite Cache-Through)
    
    @MainActor
    func fetchMeterRecords(
        siteId: Int? = nil,
        fromDate: Date? = nil,
        toDate: Date? = nil,
        limit: Int = 288,
        forceRefresh: Bool = false
    ) async -> [MeterRecord] {
        let id: Int
        if let siteId = siteId {
            id = siteId
        } else if let currentSiteId = selectedSiteId {
            id = currentSiteId
        } else {
            print("❌ No site available for meter records")
            return []
        }
        
        // Perform daily backfill if needed (once per day after 8am)
        await performDailyBackfillIfNeeded(siteId: id)
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        // Default date range: last 3 days
        let today = Date()
        let effectiveFrom = fromDate ?? calendar.date(byAdding: .day, value: -3, to: today)!
        let effectiveTo = toDate ?? today
        
        let dataStore = PowstonDataStore.shared
        
        // Check if this is a single-day query for finalized data
        let isSingleDay = calendar.isDate(effectiveFrom, inSameDayAs: effectiveTo)
        let dayAge = calendar.dateComponents([.day], from: effectiveFrom, to: today).day ?? 0
        let isFinalized = dayAge > meterRecordFinalizationDays
        
        // For finalized single-day queries, check SQLite first
        if isSingleDay && isFinalized && !forceRefresh {
            if dataStore.hasMeterRecordsForDate(siteId: id, date: effectiveFrom) {
                let cached = dataStore.getMeterRecordsLocal(siteId: id, from: effectiveFrom, to: effectiveTo)
                if !cached.isEmpty {
                    print("📦 Using \(cached.count) cached meter records for finalized date")
                    let records = cached.map { $0.toMeterRecord() }
                    updateEarliestDate(from: records)
                    return records
                }
            }
        }
        
        // For multi-day queries, check if ALL days are finalized and cached
        if !isSingleDay && !forceRefresh {
            let allDaysFinalized = isEntireRangeFinalized(from: effectiveFrom, to: effectiveTo, calendar: calendar)
            if allDaysFinalized {
                let cached = dataStore.getMeterRecordsLocal(siteId: id, from: effectiveFrom, to: effectiveTo)
                if !cached.isEmpty {
                    print("📦 Using \(cached.count) cached meter records for finalized range")
                    let records = cached.map { $0.toMeterRecord() }
                    updateEarliestDate(from: records)
                    return records
                }
            }
        }
        
        // Check in-memory cache for recent data
        let key = cacheKey(from: fromDate, to: toDate)
        if !forceRefresh,
           let cached = meterRecordsCache[key],
           Date().timeIntervalSince(cached.fetchTime) < meterRecordsCacheMinutes * 60 {
            print("📦 Using in-memory cached meter records for \(key) (\(cached.records.count) records)")
            updateEarliestDate(from: cached.records)
            return cached.records
        }
        
        // Fetch from API
        let records = await fetchMeterRecordsFromAPI(siteId: id, fromDate: effectiveFrom, toDate: effectiveTo)
        
        // Save to SQLite
        if !records.isEmpty {
            dataStore.saveMeterRecords(records, siteId: id)
            
            // Finalize old records
            dataStore.finalizeMeterRecords(siteId: id)
        }
        
        // Update in-memory cache
        meterRecordsCache[key] = (records: records, fetchTime: Date())
        updateEarliestDate(from: records)
        
        return records
    }
    
    /// Check if entire date range is finalized (>7 days old)
    private func isEntireRangeFinalized(from startDate: Date, to endDate: Date, calendar: Calendar) -> Bool {
        let today = Date()
        let endAge = calendar.dateComponents([.day], from: endDate, to: today).day ?? 0
        return endAge > meterRecordFinalizationDays
    }
    
    /// Fetch meter records directly from API (no cache check)
    private func fetchMeterRecordsFromAPI(siteId: Int, fromDate: Date, toDate: Date) async -> [MeterRecord] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()
        
        let fromStr = dateFormatter.string(from: fromDate)
        let toStr = dateFormatter.string(from: toDate)
        
        let urlString = "\(baseURL)/api/meter_records/\(siteId)?from=\(fromStr)&to=\(toStr)"
        
        guard let url = URL(string: urlString) else {
            print("❌ Invalid meter records URL")
            return []
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        print("📊 Fetching meter records from API: \(fromStr) to \(toStr)")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("❌ Meter records: No HTTP response")
                return []
            }
            
            print("📊 Meter records response status: \(http.statusCode)")
            
            guard http.statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? "no body"
                print("❌ Meter records fetch failed: \(body)")
                return []
            }
            
            let decoded = try JSONDecoder().decode(MeterRecordsResponse.self, from: data)
            print("✅ Fetched \(decoded.records.count) meter records from API")
            
            return decoded.records
        } catch {
            print("❌ Meter records error: \(error)")
            return []
        }
    }
    
    // MARK: - Fetch Month Records (with SQLite Cache-Through)
    
    @MainActor
    func fetchMonthRecords(
        monthStart: Date,
        monthEnd: Date,
        forceRefresh: Bool = false,
        progressCallback: ((Int, Int) -> Void)? = nil
    ) async -> [MeterRecord] {
        guard let siteId = selectedSiteId else {
            print("❌ No site available for month records")
            return []
        }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        let dataStore = PowstonDataStore.shared
        
        // Check if entire month is finalized
        let today = Date()
        let monthAge = calendar.dateComponents([.day], from: monthEnd, to: today).day ?? 0
        let isMonthFinalized = monthAge > meterRecordFinalizationDays
        
        // For finalized months, try SQLite first
        if isMonthFinalized && !forceRefresh {
            let cached = dataStore.getMeterRecordsLocal(siteId: siteId, from: monthStart, to: monthEnd)
            if !cached.isEmpty {
                print("📦 Using \(cached.count) cached meter records for finalized month")
                return cached.map { $0.toMeterRecord() }
            }
        }
        
        // Check in-memory cache
        let monthKey = cacheKey(from: monthStart, to: monthEnd)
        if !forceRefresh,
           let cached = meterRecordsCache[monthKey],
           Date().timeIntervalSince(cached.fetchTime) < meterRecordsCacheMinutes * 60 {
            print("📦 Using in-memory cached month records for \(monthKey) (\(cached.records.count) records)")
            return cached.records
        }
        
        // Fetch in weekly chunks
        var weeks: [(start: Date, end: Date)] = []
        var currentStart = monthStart
        
        while currentStart <= monthEnd {
            let weekEnd = min(
                calendar.date(byAdding: .day, value: 6, to: currentStart) ?? currentStart,
                monthEnd
            )
            weeks.append((start: currentStart, end: weekEnd))
            currentStart = calendar.date(byAdding: .day, value: 7, to: currentStart) ?? monthEnd
        }
        
        print("📅 Fetching month in \(weeks.count) week chunks")
        
        var allRecords: [MeterRecord] = []
        
        for (index, week) in weeks.enumerated() {
            progressCallback?(index + 1, weeks.count)
            
            // For each week, use the cache-through fetch
            let weekRecords = await fetchMeterRecords(
                siteId: siteId,
                fromDate: week.start,
                toDate: week.end,
                forceRefresh: forceRefresh
            )
            allRecords.append(contentsOf: weekRecords)
            
            print("📅 Week \(index + 1)/\(weeks.count): fetched \(weekRecords.count) records (total: \(allRecords.count))")
        }
        
        allRecords.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        meterRecordsCache[monthKey] = (records: allRecords, fetchTime: Date())
        
        print("✅ Month complete: \(allRecords.count) records")
        return allRecords
    }
}
