//
//  PowstonAPI+TrainingParameters.swift
//  Powston
//
//  Training parameters (tuning variables) for Magic Mode AI
//

import Foundation

// MARK: - Training Parameters Model

struct TrainingParameters: Codable {
    var minSoc: Int?
    var maxSoc: Int?
    var cRating: Int?
    var batterySocNeeded: Int?
    var batterySocAc: Int?
    var alwaysImportSoc: Int?
    var defaultExport: Int?
    
    enum CodingKeys: String, CodingKey {
        case minSoc = "min_soc"
        case maxSoc = "max_soc"
        case cRating = "c_rating"
        case batterySocNeeded = "BATTERY_SOC_NEEDED"
        case batterySocAc = "BATTERY_SOC_AC"
        case alwaysImportSoc = "ALWAYS_IMPORT_SOC"
        case defaultExport = "DEFAULT_EXPORT"
    }
    
    /// Create empty parameters
    static var empty: TrainingParameters {
        TrainingParameters(
            minSoc: nil,
            maxSoc: nil,
            cRating: nil,
            batterySocNeeded: nil,
            batterySocAc: nil,
            alwaysImportSoc: nil,
            defaultExport: nil
        )
    }
}

// MARK: - API Extension

extension PowstonAPI {
    
    /// Fetch training parameters for a site
    /// - Parameter siteId: The site ID
    /// - Returns: TrainingParameters or nil on error
    func fetchTrainingParameters(siteId: Int) async -> TrainingParameters? {
        guard !apiKey.isEmpty else {
            print("❌ Training parameters: No API key")
            return nil
        }
        
        let urlString = "\(baseURL)/api/training_parameters/\(siteId)"
        guard let url = URL(string: urlString) else {
            print("❌ Training parameters: Invalid URL")
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            print("📊 Fetching training parameters for site \(siteId)")
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Training parameters: Invalid response type")
                return nil
            }
            
            guard httpResponse.statusCode == 200 else {
                print("❌ Training parameters: HTTP \(httpResponse.statusCode)")
                if let errorText = String(data: data, encoding: .utf8) {
                    print("   Error: \(errorText.prefix(200))")
                }
                return nil
            }
            
            let decoded = try JSONDecoder().decode(TrainingParameters.self, from: data)
            print("✅ Training parameters loaded")
            return decoded
            
        } catch {
            print("❌ Training parameters error: \(error)")
            return nil
        }
    }
    
    /// Update training parameters for a site
    /// - Parameters:
    ///   - siteId: The site ID
    ///   - params: The parameters to update
    /// - Returns: Result with success or error message
    func updateTrainingParameters(siteId: Int, params: TrainingParameters) async -> Result<Void, String> {
        guard !apiKey.isEmpty else {
            return .failure("No API key")
        }
        
        let urlString = "\(baseURL)/api/training_parameters/\(siteId)"
        guard let url = URL(string: urlString) else {
            return .failure("Invalid URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            let jsonData = try JSONEncoder().encode(params)
            request.httpBody = jsonData
            
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                print("📤 Updating training parameters: \(jsonString)")
            }
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("Invalid response")
            }
            
            if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
                print("✅ Training parameters updated")
                return .success(())
            } else {
                let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("❌ Training parameters update failed: HTTP \(httpResponse.statusCode) - \(errorText)")
                return .failure("HTTP \(httpResponse.statusCode): \(errorText)")
            }
            
        } catch {
            print("❌ Training parameters update error: \(error)")
            return .failure(error.localizedDescription)
        }
    }
}
