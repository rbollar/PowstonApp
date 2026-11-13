//
//  PowstonAPI+ControllerHealth.swift
//  Powston
//
//  Controller health monitoring, site monitors, communication devices
//

import Foundation
import SwiftUI

// MARK: - Powston Service Health Response

struct PowstonHealthResponse: Codable {
    let status: String
    let message: String
    let time: String
    let version: String
}

// MARK: - Controller Health Status

enum ControllerHealthStatus: Equatable {
    case unknown
    case healthy
    case degraded(count: Int)  // Some controllers offline
    case offline               // All controllers offline
    
    var color: Color {
        switch self {
        case .unknown: return .gray
        case .healthy: return .green
        case .degraded: return .orange
        case .offline: return .red
        }
    }
    
    var isHealthy: Bool {
        if case .healthy = self { return true }
        return false
    }
}

// MARK: - Runtime Diagnosis

/// Response from /api/diagnose/runtime/{inverter_id}: Powston's own check of
/// why an inverter's runtime data is stale or missing, as a single verdict
struct RuntimeDiagnosis: Codable {
    let verdict: String
    let headline: String?
    let nextSteps: [String]?
    let runtimeData: RuntimeData?

    struct RuntimeData: Codable {
        let rowsLast30Min: Int?
        let latestRowTime: String?

        enum CodingKeys: String, CodingKey {
            case rowsLast30Min = "rows_last_30min"
            case latestRowTime = "latest_row_time"
        }
    }

    enum CodingKeys: String, CodingKey {
        case verdict, headline
        case nextSteps = "next_steps"
        case runtimeData = "runtime_data"
    }

    /// Verdict code as readable text (e.g. "api_only_inverter" -> "Api only inverter")
    var verdictLabel: String {
        let words = verdict.replacingOccurrences(of: "_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

// MARK: - PowstonAPI Extension

extension PowstonAPI {
    
    // MARK: - Fetch Site Monitors
    
    func fetchSiteMonitors(siteId: Int) async -> [SiteMonitor] {
        guard !apiKey.isEmpty else { return [] }
        
        let urlString = "\(baseURL)/api/site_monitors/\(siteId)"
        guard let url = URL(string: urlString) else { return [] }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("❌ Site monitors fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return []
            }
            
            let monitors = try JSONDecoder().decode([SiteMonitor].self, from: data)
            print("✅ Fetched \(monitors.count) site monitors for site \(siteId)")
            return monitors
        } catch {
            print("❌ Site monitors error: \(error)")
            return []
        }
        
    }
    
    // MARK: - Fetch Controller Health
    
    func fetchControllerHealth(macAddress: String) async -> ControllerHealth? {
        guard !apiKey.isEmpty else { return nil }
        
        let urlString = "\(baseURL)/api/controller_health/\(macAddress)"
        guard let url = URL(string: urlString) else { return nil }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("❌ Controller health fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }
            
            let health = try JSONDecoder().decode(ControllerHealth.self, from: data)
            print("✅ Fetched controller health for \(macAddress)")
            return health
        } catch {
            print("❌ Controller health error: \(error)")
            return nil
        }
    }
    
    // MARK: - Fetch Runtime Diagnosis

    func fetchRuntimeDiagnosis(inverterId: Int) async -> RuntimeDiagnosis? {
        guard !apiKey.isEmpty else { return nil }

        let urlString = "\(baseURL)/api/diagnose/runtime/\(inverterId)"
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("❌ Runtime diagnosis fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return nil
            }

            return try JSONDecoder().decode(RuntimeDiagnosis.self, from: data)
        } catch {
            print("❌ Runtime diagnosis error: \(error)")
            return nil
        }
    }

    // MARK: - Fetch Communication Devices
    
    func fetchCommunicationDevices(siteId: Int) async -> [CommunicationDevice] {
        guard !apiKey.isEmpty else { return [] }
        
        let urlString = "\(baseURL)/api/communication_devices/\(siteId)"
        guard let url = URL(string: urlString) else { return [] }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("❌ Communication devices fetch failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return []
            }
            
            let devices = try JSONDecoder().decode([CommunicationDevice].self, from: data)
            print("✅ Fetched \(devices.count) communication devices for site \(siteId)")
            return devices
        } catch {
            print("❌ Communication devices error: \(error)")
            return []
        }
    }
    // MARK: - Check Powston Service Health
        
        func checkPowstonServiceHealth() async {
            let urlString = "\(baseURL)/api/health_checker"
            guard let url = URL(string: urlString) else {
                await MainActor.run {
                    powstonServiceOnline = false
                    powstonServiceLastCheck = Date()
                }
                return
            }
            
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "accept")
            request.timeoutInterval = 10
            
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    print("❌ Powston health check failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                    await MainActor.run {
                        powstonServiceOnline = false
                        powstonServiceLastCheck = Date()
                    }
                    return
                }
                
                let health = try JSONDecoder().decode(PowstonHealthResponse.self, from: data)
                let isOnline = (health.status == "success")
                print("✅ Powston service health: \(isOnline ? "online" : "offline")")
                
                await MainActor.run {
                    powstonServiceOnline = isOnline
                    powstonServiceLastCheck = Date()
                }
            } catch {
                print("❌ Powston health check error: \(error.localizedDescription)")
                await MainActor.run {
                    powstonServiceOnline = false
                    powstonServiceLastCheck = Date()
                }
            }
        }
}
