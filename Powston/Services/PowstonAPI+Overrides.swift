//
//  PowstonAPI+Overrides.swift
//  Powston
//
//  Manual override management, fetching, grouping, and cancellation
//

import Foundation

extension PowstonAPI {
    
    // MARK: - Set Manual Override
    
    func setManualOverride(
        inverterId: Int,
        mode: String,
        minutes: Int?,
        notes: String?,
        minSoc: Int?,
        maxSoc: Int?,
        minBuyPrice: Double? = nil,
        maxBuyPrice: Double? = nil,
        minSellPrice: Double? = nil,
        maxSellPrice: Double? = nil,
        exportLimit: Bool = false,
        startTime: Date? = nil,
        endTime: Date? = nil,
        actionParams: [String: Double] = [:]
    ) async -> Bool {
        let url = URL(string: "\(baseURL)/api/set_manual_action/\(inverterId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = [
            "mode": mode,
            "notes": notes ?? "",
            "min_sell_price": minSellPrice.map { $0 as Any } ?? NSNull(),
            "max_sell_price": maxSellPrice.map { $0 as Any } ?? NSNull(),
            "min_buy_price": minBuyPrice.map { $0 as Any } ?? NSNull(),
            "max_buy_price": maxBuyPrice.map { $0 as Any } ?? NSNull(),
            "min_soc": minSoc.map { $0 as Any } ?? NSNull(),
            "max_soc": maxSoc.map { $0 as Any } ?? NSNull(),
            "exportLimit": exportLimit,
            "action_params": actionParams
        ]
        
        if let start = startTime, let end = endTime {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            body["minutes"] = NSNull()
            body["start_time"] = formatter.string(from: start)
            body["end_time"] = formatter.string(from: end)
        } else {
            body["minutes"] = minutes ?? 5
            body["start_time"] = NSNull()
            body["end_time"] = NSNull()
        }
        
        print("🔧 Manual Override Request:")
        print("   URL: \(url)")
        print("   Body: \(body)")
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: body)
            request.httpBody = jsonData
            
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print("   JSON: \(jsonString)")
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("❌ Manual override: No HTTP response")
                return false
            }
            
            let responseBody = String(data: data, encoding: .utf8) ?? "no body"
            print("📥 Manual Override Response:")
            print("   Status: \(http.statusCode)")
            print("   Body: \(responseBody)")
            
            return http.statusCode == 200 || http.statusCode == 201
        } catch {
            print("❌ Manual override error: \(error)")
            return false
        }
    }
    
    // MARK: - Action Params Metadata

    /// Fetch the action_params supported for an inverter brand
    /// (GET /api/action_params/metadata/{brand}). Cached per brand.
    func fetchActionParamsMetadata(brand: String) async -> ActionParamsMetadata? {
        let key = brand.lowercased()
        if let cached = actionParamsMetadataCache[key] { return cached }

        guard let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(baseURL)/api/action_params/metadata/\(encoded)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("❌ action_params metadata fetch failed for \(brand)")
                return nil
            }
            let metadata = try JSONDecoder().decode(ActionParamsMetadata.self, from: data)
            await MainActor.run { self.actionParamsMetadataCache[key] = metadata }
            return metadata
        } catch {
            print("❌ action_params metadata error: \(error)")
            return nil
        }
    }

    // MARK: - End Manual Action
    
    func endManualAction(actionId: Int) async -> Bool {
        let url = URL(string: "\(baseURL)/api/manual_action/\(actionId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["end_time": ISO8601DateFormatter().string(from: Date())]
        
        print("🛑 End Manual Action Request:")
        print("   URL: \(url)")
        print("   Body: \(body)")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("❌ End manual action: No HTTP response")
                return false
            }
            
            let responseBody = String(data: data, encoding: .utf8) ?? "no body"
            print("📥 End Manual Action Response:")
            print("   Status: \(http.statusCode)")
            print("   Body: \(responseBody)")
            
            return http.statusCode == 200 || http.statusCode == 201
        } catch {
            print("❌ End manual action error: \(error)")
            return false
        }
    }
    
    // MARK: - Fetch Manual Actions
    
    func fetchManualActions(inverterId: Int) async -> [ManualAction] {
        let url = URL(string: "\(baseURL)/api/manual_actions/\(inverterId)?page=1&page_size=72")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("❌ Manual actions fetch failed")
                return []
            }
            
            if let actions = try? JSONDecoder().decode([ManualAction].self, from: data) {
                print("✅ Fetched \(actions.count) manual actions")
                return actions
            }
            
            let decoded = try JSONDecoder().decode(ManualActionsResponse.self, from: data)
            print("✅ Fetched \(decoded.items.count) manual actions")
            return decoded.items
        } catch {
            print("❌ Manual actions error: \(error)")
            return []
        }
    }
    
    func fetchActiveManualActions(inverterId: Int) async -> [ManualAction] {
        let actions = await fetchManualActions(inverterId: inverterId)
        return actions.filter { $0.isActive }
    }
    
    // MARK: - Refresh Active Overrides
    
    func refreshActiveOverrides() async {
        let siteInverterIds = getCurrentSiteInverterIds()
        guard !siteInverterIds.isEmpty else { return }
        
        var allActions: [ManualAction] = []
        
        for inverterId in siteInverterIds {
            let actions = await fetchManualActions(inverterId: inverterId)
            print("🔍 Inverter \(inverterId) raw actions: \(actions.count)")
            for action in actions {
                print("   - id:\(action.id) \(action.action) active:\(action.isActive) scheduled:\(action.isScheduled) start:\(action.startTime ?? "nil")")
            }
            let activeActions = actions.filter { $0.isActive }
            print("🔍 Inverter \(inverterId) after isActive filter: \(activeActions.count)")
            allActions.append(contentsOf: activeActions)
        }
        
        print("🔍 Total active actions across all inverters: \(allActions.count)")
        print("🔍 Queried inverter IDs: \(siteInverterIds)")
        
        let currentAll = allActions.filter { $0.isCurrentlyActive }
        let scheduledAll = allActions.filter { $0.isScheduled }
        
        print("🔍 currentAll (isCurrentlyActive): \(currentAll.count)")
        print("🔍 scheduledAll (isScheduled): \(scheduledAll.count)")
        
        let currentGrouped = groupOverridesByTimeSlot(currentAll)
        let scheduledGrouped = groupOverridesByTimeSlot(scheduledAll).sorted {
            ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture)
        }
        
        print("🔍 After grouping - current: \(currentGrouped.count), scheduled: \(scheduledGrouped.count)")
        
        await MainActor.run {
            self.currentOverrides = currentGrouped
            self.scheduledOverrides = scheduledGrouped
            self.allOverrideActions = allActions
        }
        
        let siteName = selectedSite?.displayName ?? selectedSite?.name ?? "My Site"
        let currentInverterCount = currentAll.count
        let scheduledInverterCount = scheduledAll.count
        
        await LiveActivityManager.shared.syncWithOverrides(
            currentOverrides: currentGrouped,
            scheduledOverrides: scheduledGrouped,
            siteName: siteName,
            currentInverterCount: currentInverterCount,
            scheduledInverterCount: scheduledInverterCount
        )
    }
    
    // MARK: - Override Grouping
    
    private func groupOverridesByTimeSlot(_ actions: [ManualAction]) -> [ManualAction] {
        var seen: Set<String> = []
        var result: [ManualAction] = []
        
        for action in actions {
            let startKey = action.startDate.map { Int($0.timeIntervalSince1970 / 60) }.map { String($0) } ?? "nil"
            let endKey = action.endDate.map { Int($0.timeIntervalSince1970 / 60) }.map { String($0) } ?? "nil"
            let key = "\(startKey)_\(endKey)_\(action.action)"
            if !seen.contains(key) {
                seen.insert(key)
                result.append(action)
            }
        }
        return result
    }
    
    func getOverrideGroup(matching action: ManualAction) -> [ManualAction] {
        let targetStartMin = action.startDate.map { Int($0.timeIntervalSince1970 / 60) }
        let targetEndMin = action.endDate.map { Int($0.timeIntervalSince1970 / 60) }
        
        return allOverrideActions.filter {
            let startMin = $0.startDate.map { Int($0.timeIntervalSince1970 / 60) }
            let endMin = $0.endDate.map { Int($0.timeIntervalSince1970 / 60) }
            return startMin == targetStartMin &&
                   endMin == targetEndMin &&
                   $0.action == action.action
        }
    }
    
    // MARK: - Cancel Overrides
    
    func cancelOverrideGroup(_ action: ManualAction) async -> (success: Int, failed: Int) {
        let group = getOverrideGroup(matching: action)
        var successCount = 0
        var failCount = 0
        
        for override in group {
            let success = await endManualAction(actionId: override.id)
            if success {
                successCount += 1
            } else {
                failCount += 1
            }
        }
        
        return (successCount, failCount)
    }
    
    func cancelOverride(_ action: ManualAction) async -> Bool {
        return await endManualAction(actionId: action.id)
    }
    
    // MARK: - Find Overlapping Overrides
    
    func findOverlappingOverrides(start: Date, end: Date) -> [ManualAction] {
        return activeOverrides.filter { $0.overlaps(with: start, end: end) }
    }
}
