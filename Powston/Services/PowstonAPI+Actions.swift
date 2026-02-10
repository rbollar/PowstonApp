//
//  PowstonAPI+Actions.swift
//  Powston
//
//  Inverter action fetching, SOC history, site-wide actions
//
//  Optimization: Delta fetches use maxPages=1 to avoid full-day pagination
//

import Foundation

// NOTE: ActionsFetchConfig, SiteActionsData, and ActionSOCPoint are defined elsewhere
// (likely in Models or a shared file). Do not redeclare here.

// MARK: - PowstonAPI Extension

extension PowstonAPI {
    
    // MARK: - Fetch Inverter Actions

    func fetchInverterActions(
        inverterId: Int,
        date: Date,
        pageSize: Int = 50,
        maxPages: Int = 10,
        timeout: TimeInterval = 30
    ) async -> [InverterAction] {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = powstonTimezone()
        let dateStr = dateFormatter.string(from: date)
        
        // Skip cache for single-page delta fetches (we want fresh data)
        let isDeltaFetch = maxPages == 1
        
        if !isDeltaFetch {
            let cacheKey = "\(inverterId)_\(dateStr)"
            if let cached = actionsCache[cacheKey] {
                let age = Date().timeIntervalSince(cached.fetchTime) / 60
                let isToday = Calendar.current.isDateInToday(date)
                let maxAge = isToday ? actionsCacheMinutes : 60.0
                if age < maxAge {
                    print("📦 Using cached actions for \(cacheKey) (\(cached.actions.count) actions)")
                    return cached.actions
                }
            }
        }
        
        var allActions: [InverterAction] = []
        var page = 1
        
        // For filtering to target date only
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let targetDay = calendar.startOfDay(for: date)
        
        while page <= maxPages {
            let urlString = "\(baseURL)/api/inverter_actions/\(inverterId)?start_date=\(dateStr)&page=\(page)&page_size=\(pageSize)"
            guard let url = URL(string: urlString) else {
                print("❌ Invalid URL for inverter_actions")
                break
            }
            
            if isDeltaFetch {
                print("🔄 Delta fetch page \(page): \(urlString)")
            } else {
                print("📊 Fetching actions page \(page): \(urlString)")
            }
            
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            // Shorter timeout for pagination - we already have some data
            request.timeoutInterval = (page == 1) ? timeout : min(timeout, 8)
            
            var actions: [InverterAction] = []
            var success = false
            
            // Only retry on page 1 - pagination failures should just accept partial data
            let maxRetries = (page == 1) ? 2 : 1
            
            for attempt in 1...maxRetries {
                let result: Result<(Data, URLResponse), Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        let result = try await URLSession.shared.data(for: request)
                        return .success(result)
                    } catch {
                        return .failure(error)
                    }
                }.value
                
                switch result {
                case .success(let (data, response)):
                    guard let http = response as? HTTPURLResponse else {
                        print("❌ Invalid response type")
                        break
                    }
                    
                    if http.statusCode == 504 || http.statusCode == 502 || http.statusCode == 503 {
                        print("⚠️ Server error \(http.statusCode) on attempt \(attempt)/\(maxRetries)")
                        if attempt < maxRetries {
                            try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * attempt))
                            continue
                        }
                        break
                    }
                    
                    guard http.statusCode == 200 else {
                        print("❌ inverter_actions HTTP error: \(http.statusCode)")
                        break
                    }
                    
                    // Try different response formats
                    if let decoded = try? JSONDecoder().decode([InverterAction].self, from: data) {
                        actions = decoded
                        success = true
                    }
                    else if let decoded = try? JSONDecoder().decode(InverterActionsResponse.self, from: data) {
                        actions = decoded.items
                        success = true
                    }
                    else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        // Check for "actions" key first (primary format)
                        if let actionsArray = json["actions"] as? [[String: Any]],
                           let actionsData = try? JSONSerialization.data(withJSONObject: actionsArray),
                           let decoded = try? JSONDecoder().decode([InverterAction].self, from: actionsData) {
                            actions = decoded
                            success = true
                        }
                        // Fallback to "items" key
                        else if let items = json["items"] as? [[String: Any]],
                                let itemsData = try? JSONSerialization.data(withJSONObject: items),
                                let decoded = try? JSONDecoder().decode([InverterAction].self, from: itemsData) {
                            actions = decoded
                            success = true
                        }
                        // Fallback to "results" key
                        else if let results = json["results"] as? [[String: Any]],
                                let resultsData = try? JSONSerialization.data(withJSONObject: results),
                                let decoded = try? JSONDecoder().decode([InverterAction].self, from: resultsData) {
                            actions = decoded
                            success = true
                        }
                    }
                    
                    if success {
                        break // Exit retry loop on success
                    }
                    
                case .failure(let error):
                    print("⚠️ Fetch error on attempt \(attempt)/\(maxRetries): \(error.localizedDescription)")
                    if attempt < maxRetries {
                        try? await Task.sleep(nanoseconds: UInt64(1_000_000_000 * attempt))
                        continue
                    }
                }
                
                break // Exit retry loop if not continuing
            }
            
            if !success || actions.isEmpty {
                if page == 1 {
                    print("📊 Page 1 failed - no data for \(dateStr)")
                } else {
                    print("📊 Page \(page): pagination stopped (got \(allActions.count) records so far)")
                }
                break
            }
            
            // Filter to target date only - API pages backwards into older dates
            let targetDateActions = actions.filter { action in
                guard let actionDate = action.date else { return false }
                return calendar.startOfDay(for: actionDate) == targetDay
            }
            
            let olderDateCount = actions.count - targetDateActions.count
            
            if olderDateCount > 0 {
                // Hit older dates - add only target date records and stop
                print("📊 Page \(page): found \(olderDateCount) records from older dates, stopping pagination")
                allActions.append(contentsOf: targetDateActions)
                break
            }
            
            if isDeltaFetch {
                print("✅ Delta page \(page): fetched \(actions.count) actions")
            } else {
                print("✅ Page \(page): fetched \(actions.count) actions")
            }
            allActions.append(contentsOf: actions)
            
            // Stop if we got fewer than pageSize (last page)
            if actions.count < pageSize {
                print("📊 Last page reached (got \(actions.count) < \(pageSize))")
                break
            }
            
            page += 1
        }
        
        // Only update cache for full fetches, not delta
        if !isDeltaFetch {
            let cacheKey = "\(inverterId)_\(dateStr)"
            if !allActions.isEmpty {
                print("✅ Total fetched for \(dateStr): \(allActions.count) actions")
                actionsCache[cacheKey] = (allActions, Date())
            } else if let cached = actionsCache[cacheKey] {
                print("📦 Returning stale cache on failure (\(cached.actions.count) actions)")
                return cached.actions
            }
        } else {
            if !allActions.isEmpty {
                print("✅ Delta fetch complete: \(allActions.count) recent actions")
            }
        }
        
        return allActions
    }
    
    // MARK: - Fetch Site Actions
    
    func fetchSiteActions(siteId: Int, date: Date, pageSize: Int = 288, maxPages: Int = 10) async -> [Int: [InverterAction]] {
        let siteInverters = inverters.filter { $0.siteId == siteId }
        guard !siteInverters.isEmpty else {
            print("⚠️ No inverters found for site \(siteId)")
            return [:]
        }
        
        var results: [Int: [InverterAction]] = [:]
        
        await withTaskGroup(of: (Int, [InverterAction]).self) { group in
            for inverter in siteInverters {
                group.addTask {
                    let actions = await self.fetchInverterActions(
                        inverterId: inverter.id,
                        date: date,
                        pageSize: pageSize,
                        maxPages: maxPages
                    )
                    return (inverter.id, actions)
                }
            }
            
            for await (inverterId, actions) in group {
                results[inverterId] = actions
            }
        }
        
        print("✅ Fetched actions for \(results.count) inverters at site \(siteId)")
        return results
    }
    
    // MARK: - Fetch Actions (Config-based)
    
    func fetchActions(config: ActionsFetchConfig) async -> SiteActionsData {
        let actions: [Int: [InverterAction]]
        
        if config.showAllInverters && config.allInvertersAtSite.count > 1 {
            actions = await fetchSiteActions(siteId: config.siteId, date: config.date, pageSize: config.pageSize)
        } else {
            let singleActions = await fetchInverterActions(inverterId: config.inverterId, date: config.date, pageSize: config.pageSize)
            actions = [config.inverterId: singleActions]
        }
        
        return SiteActionsData(siteId: config.siteId, date: config.date, inverterActions: actions)
    }
    
    // MARK: - SOC History
    
    func fetchSOCHistory(inverterId: Int, date: Date) async -> [ActionSOCPoint] {
        let actions = await fetchInverterActions(inverterId: inverterId, date: date)
        return actions.compactMap { action -> ActionSOCPoint? in
            guard action.batterySoc != nil else { return nil }
            return ActionSOCPoint(from: action)
        }
    }
    
    func fetchSiteSOCHistory(siteId: Int, date: Date) async -> [Int: [ActionSOCPoint]] {
        let siteActions = await fetchSiteActions(siteId: siteId, date: date)
        var results: [Int: [ActionSOCPoint]] = [:]
        
        for (inverterId, actions) in siteActions {
            let points = actions.compactMap { action -> ActionSOCPoint? in
                guard action.batterySoc != nil else { return nil }
                return ActionSOCPoint(from: action)
            }
            results[inverterId] = points
        }
        
        return results
    }
}
