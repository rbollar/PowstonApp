//
//  PowstonAPI+Sites.swift
//  Powston
//
//  Site and inverter fetching, lead inverter detection, site switching
//

import Foundation
import SwiftUI
import Combine

extension PowstonAPI {
    
    // MARK: - Fetch Sites
    
    func fetchSites() async {
        await MainActor.run {
            withTransaction(Transaction(animation: nil)) {
                isLoading = true
                error = nil
                sites = []
            }
        }
        
        print("🌐 Fetching sites from API...")
        
        guard !apiKey.isEmpty else {
            await MainActor.run {
                error = "API key is empty"
                isLoading = false
            }
            return
        }
        
        let url = URL(string: "\(baseURL)/api/sites")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse else {
                await MainActor.run {
                    error = "Invalid response from server"
                    isLoading = false
                }
                return
            }
            
            if http.statusCode == 401 {
                await MainActor.run {
                    error = "Unauthorized (401) - Check your API key"
                    isLoading = false
                }
                return
            }
            
            if http.statusCode != 200 {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                await MainActor.run {
                    error = "HTTP \(http.statusCode): \(errorMessage)"
                    isLoading = false
                }
                return
            }
            
            let listed = try JSONDecoder().decode([Site].self, from: data)
            print("✅ Successfully decoded \(listed.count) sites")
            let decoded = await withRetailerKeys(listed)
            
            await MainActor.run {
                withTransaction(Transaction(animation: nil)) {
                    self.sites = decoded
                    self.isLoading = false
                    self.error = nil
                }
            }
        } catch {
            print("❌ Error: \(error.localizedDescription)")
            await MainActor.run {
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }
    
    // MARK: - Site Detail

    /// The /api/sites list omits secret fields such as amber_key, but the
    /// single-site endpoint returns them. Swap in the detailed record for
    /// Amber sites so the Powston-provided Amber key is available.
    private func withRetailerKeys(_ sites: [Site]) async -> [Site] {
        var result = sites
        for (index, site) in sites.enumerated()
        where site.activeRetailer?.lowercased() == "amber" && (site.amberKey ?? "").isEmpty {
            if let detail = await fetchSiteDetail(siteId: site.id) {
                result[index] = detail
            }
        }
        return result
    }

    /// Fetch one site's full record (GET /api/site/{site_id})
    func fetchSiteDetail(siteId: Int) async -> Site? {
        guard !apiKey.isEmpty, let url = URL(string: "\(baseURL)/api/site/\(siteId)") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("❌ Site detail fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            let site = try JSONDecoder().decode(Site.self, from: data)
            return site.id == siteId ? site : nil
        } catch {
            print("❌ Site detail error: \(error)")
            return nil
        }
    }

    // MARK: - Update Site
    
    func updateSite(siteId: Int, displayName: String? = nil, pvoutputApiKey: String? = nil) async -> Result<Void, Error> {
        guard !apiKey.isEmpty else {
            return .failure(NSError(domain: "PowstonAPI", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"]))
        }
        
        let url = URL(string: "\(baseURL)/api/site/\(siteId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var payload: [String: Any] = [:]
        if let displayName = displayName {
            payload["display_name"] = displayName
        }
        if let pvoutputApiKey = pvoutputApiKey {
            payload["pvoutput_api_key"] = pvoutputApiKey
        }
        
        guard !payload.isEmpty else {
            return .success(())
        }
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let http = response as? HTTPURLResponse else {
                return .failure(NSError(domain: "PowstonAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
            }
            
            if http.statusCode == 200 || http.statusCode == 204 {
                await fetchSites()
                return .success(())
            } else {
                let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                return .failure(NSError(domain: "PowstonAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        } catch {
            return .failure(error)
        }
    }
    
    // MARK: - Save Amber Key

    struct AmberKeySaveResult: Codable {
        let valid: Bool
        let saved: Bool
        let siteId: Int
        let amberSiteId: String
        let nmi: String?
        let message: String

        enum CodingKeys: String, CodingKey {
            case valid, saved, nmi, message
            case siteId = "site_id"
            case amberSiteId = "amber_site_id"
        }
    }

    /// Validate an Amber API key with Powston and save it on the site
    /// (POST /api/site/{site_id}/amber-key). Once saved, Powston distributes
    /// the key to all devices via the site's amber_key field.
    func saveAmberKeyToPowston(siteId: Int, amberApiKey: String) async -> Result<AmberKeySaveResult, Error> {
        guard !apiKey.isEmpty else {
            return .failure(NSError(domain: "PowstonAPI", code: 401, userInfo: [NSLocalizedDescriptionKey: "Not authenticated"]))
        }

        let url = URL(string: "\(baseURL)/api/site/\(siteId)/amber-key")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["api_key": amberApiKey])
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                return .failure(NSError(domain: "PowstonAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response"]))
            }

            if http.statusCode == 200 {
                let result = try JSONDecoder().decode(AmberKeySaveResult.self, from: data)
                if result.saved {
                    await fetchSites()  // pick up the new amber_key/amber_site_id
                }
                return .success(result)
            } else {
                let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                return .failure(NSError(domain: "PowstonAPI", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message]))
            }
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Fetch Inverters
    
    func fetchInverters(siteId: Int) async {
        await MainActor.run { isLoading = true; error = nil }
        
        let url = URL(string: "\(baseURL)/api/inverters/\(siteId)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                await MainActor.run { error = "Failed to fetch inverters"; isLoading = false }
                return
            }
            let decoded = try JSONDecoder().decode([Inverter].self, from: data)
            print("✅ Site \(siteId): \(decoded.count) inverters")
            await MainActor.run {
                withTransaction(Transaction(animation: nil)) {
                    self.inverters.removeAll { $0.siteId == siteId }
                    self.inverters.append(contentsOf: decoded)
                    if self.selectedInverterId == 0, let first = decoded.first {
                        self.selectedInverterId = first.id
                    }
                    self.isLoading = false
                }
            }
        } catch {
            print("❌ Inverter fetch error: \(error)")
            await MainActor.run { self.error = error.localizedDescription; isLoading = false }
        }
    }
    
    func fetchAllInverters(forceAll: Bool = false) async {
        await MainActor.run { isLoading = true; error = nil; inverters = [] }
        
        var allInverters: [Inverter] = []
        
        let sitesToFetch: [Site]
        if singleSiteMode && !forceAll && selectedInverterId != 0 {
            if let selected = selectedSite {
                sitesToFetch = [selected]
            } else {
                sitesToFetch = sites
            }
        } else {
            sitesToFetch = sites
        }
        
        var anyFetchFailed = false
        for site in sitesToFetch {
            let url = URL(string: "\(baseURL)/api/inverters/\(site.id)")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    print("⚠️ Site \(site.id) (\(site.displayName ?? site.name)): HTTP error")
                    anyFetchFailed = true
                    continue
                }
                let decoded = try JSONDecoder().decode([Inverter].self, from: data)
                allInverters.append(contentsOf: decoded)
                print("✅ Site \(site.id) (\(site.displayName ?? site.name)): \(decoded.count) inverters")
            } catch {
                print("❌ Failed to fetch inverters for site \(site.id): \(error)")
                anyFetchFailed = true
            }
        }
        
        await MainActor.run {
            withTransaction(Transaction(animation: nil)) {
                self.inverters = allInverters
                // Reset selection if unset OR pointing at an inverter that no longer
                // exists (e.g. replaced hardware — the old ID can keep answering the
                // API with stale telemetry forever)
                // Don't second-guess the selection when a site fetch failed — the
                // selected inverter may just be missing from a partial list
                let selectionIsValid = allInverters.contains { $0.id == self.selectedInverterId }
                if !selectionIsValid, !anyFetchFailed, let first = allInverters.first {
                    if self.selectedInverterId != 0 {
                        print("⚠️ Selected inverter \(self.selectedInverterId) no longer exists — switching to \(first.id)")
                    }
                    self.selectedInverterId = first.id
                }
                self.isLoading = false
            }
            print("✅ Total inverters loaded: \(allInverters.count) (single site mode: \(singleSiteMode))")
        }
    }
    
    // MARK: - Lead Inverter Management
    
    internal var leadInverterOverrides: [Int: Int] {
        get {
            guard let data = UserDefaults.standard.data(forKey: leadInverterOverridesKey),
                  let decoded = try? JSONDecoder().decode([Int: Int].self, from: data) else {
                return [:]
            }
            return decoded
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(encoded, forKey: leadInverterOverridesKey)
            }
        }
    }
    
    internal var detectedLeadInverters: [Int: Int] {
        get {
            guard let data = UserDefaults.standard.data(forKey: detectedLeadInvertersKey),
                  let decoded = try? JSONDecoder().decode([Int: Int].self, from: data) else {
                return [:]
            }
            return decoded
        }
        set {
            if let encoded = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(encoded, forKey: detectedLeadInvertersKey)
            }
        }
    }
    
    func updateDetectedLeadInverter() {
        guard let siteId = selectedSiteId else { return }
        
        if leadInverterOverrides[siteId] != nil {
            print("🔍 Skipping lead detection - user has manual override for site \(siteId)")
            return
        }
        
        let siteInverters = inverters.filter { $0.siteId == siteId }
        guard siteInverters.count > 1 else { return }
        
        print("🔍 Multi-inverter site \(siteId): \(siteInverters.map { "\($0.id)=\($0.serialNumber)" })")
        
        guard let params = data?.runtimeParams else {
            print("🔍 No runtime_params available")
            return
        }
        
        let mainGridPower = abs(params.mainInverter.gridPower ?? 0)
        
        var nestedHasGridActivity = false
        var nestedSerial: String? = nil
        for (serial, nestedData) in params.additionalInverters {
            let nestedGridPower = abs(nestedData.gridPower ?? 0)
            print("🔍 Nested \(serial) grid_power: \(nestedGridPower)")
            if nestedGridPower > 0 {
                nestedHasGridActivity = true
                nestedSerial = serial
            }
        }
        
        print("🔍 Main inverter grid_power: \(mainGridPower), nested has grid activity: \(nestedHasGridActivity)")
        
        var detectedLeadId: Int? = nil
        
        if mainGridPower > 0 && !nestedHasGridActivity {
            detectedLeadId = selectedInverterId
            print("✅ Lead inverter (has grid): \(selectedInverterId)")
        } else if nestedHasGridActivity, let serial = nestedSerial {
            if let leadInv = siteInverters.first(where: { $0.serialNumber == serial }) {
                detectedLeadId = leadInv.id
                print("✅ Lead inverter (nested has grid): \(leadInv.id) (\(serial))")
            }
        } else {
            print("🔍 Could not determine lead from grid activity, using first inverter")
            detectedLeadId = siteInverters[0].id
        }
        
        if let leadId = detectedLeadId {
            var detected = detectedLeadInverters
            detected[siteId] = leadId
            detectedLeadInverters = detected
        }
    }
    
    func leadInverter(forSiteId siteId: Int) -> Inverter? {
        let siteInverters = inverters.filter { $0.siteId == siteId }
        guard !siteInverters.isEmpty else { return nil }
        
        if let overrideId = leadInverterOverrides[siteId],
           let overrideInverter = siteInverters.first(where: { $0.id == overrideId }) {
            return overrideInverter
        }
        
        if let detectedId = detectedLeadInverters[siteId],
           let detectedInverter = siteInverters.first(where: { $0.id == detectedId }) {
            return detectedInverter
        }
        
        return siteInverters.first
    }
    
    func setLeadInverterOverride(siteId: Int, inverterId: Int) {
        var overrides = leadInverterOverrides
        overrides[siteId] = inverterId
        leadInverterOverrides = overrides
        objectWillChange.send()
    }
    
    func clearLeadInverterOverride(siteId: Int) {
        var overrides = leadInverterOverrides
        overrides.removeValue(forKey: siteId)
        leadInverterOverrides = overrides
        objectWillChange.send()
    }
    
    // MARK: - Site Switching
    
    func switchToSite(_ site: Site) async {
        clearMeterRecordsCache()
        clearDayRateSummaryCache()

        let siteInverters = inverters.filter { $0.siteId == site.id }

        if siteInverters.isEmpty {
            // Zero-inverter site (e.g. hydro) — set site directly, clear inverter data
            await MainActor.run {
                withTransaction(Transaction(animation: nil)) {
                    persistedSiteId = site.id
                    selectedInverterId = 0
                    data = nil
                    isLoading = false
                    error = nil
                }
            }
            await MainActor.run {
                NotificationCenter.default.post(name: .siteDidChange, object: nil)
            }

            // Trigger LocalVolts daily sync for zero-inverter sites (fire-and-forget)
            let siteId = site.id
            let retailer = site.activeRetailer
            Task.detached { [siteId, retailer] in
                await LocalVoltsService.shared.performDailySyncIfNeeded(siteId: siteId, activeRetailer: retailer)
            }

            return
        }

        if let lead = leadInverter(forSiteId: site.id) {
            selectedInverterId = lead.id
            await fetchData()
        } else {
            selectedInverterId = siteInverters[0].id
            await fetchData()

            if let lead = leadInverter(forSiteId: site.id), lead.id != selectedInverterId {
                selectedInverterId = lead.id
                await fetchData()
            }
        }

        await MainActor.run {
            NotificationCenter.default.post(name: .siteDidChange, object: nil)
        }
    }
    
    // MARK: - Fetch User Coupons
    
    func fetchUserCoupons() async -> [UserCoupon] {
        guard !apiKey.isEmpty else { return [] }
        
        let urlString = "\(baseURL)/api/user_coupons"
        guard let url = URL(string: urlString) else { return [] }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return []
            }
            
            let coupons = try JSONDecoder().decode([UserCoupon].self, from: data)
            return coupons.filter { $0.deletedAt == nil }
        } catch {
            print("Error fetching user coupons: \(error)")
            return []
        }
    }
}
