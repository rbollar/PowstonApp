//
//  PowstonAPI+Tariffs.swift
//  Powston
//
//  Tariff rates API endpoint for time-of-use period analysis
//

import Foundation

// MARK: - Tariff Rates Response Models

/// Performance data for a single tariff period (e.g., Peak, Off-Peak, Shoulder)
struct TariffPeriodPerformance: Codable, Identifiable {
    var id: String { periodName }
    
    let periodName: String
    let expectedBill: Double      // Expected bill amount (cents)
    let fixedCosts: Double        // Fixed costs (cents)
    let totalCosts: Double        // Total costs (cents)
    let energyImport: Double      // kWh imported during this period
    let energyExport: Double      // kWh exported during this period
    let earnings: Double          // Cents earned from exports
    let costs: Double             // Cents paid for imports
    let buyRate: Double           // Average buy rate in cents/kWh
    let sellRate: Double          // Average sell rate in cents/kWh
    let periodRate: Double        // Base period rate in cents/kWh
    
    enum CodingKeys: String, CodingKey {
        case periodName = "period_name"
        case expectedBill = "expected_bill"
        case fixedCosts = "fixed_costs"
        case totalCosts = "total_costs"
        case energyImport = "energy_import"
        case energyExport = "energy_export"
        case earnings
        case costs
        case buyRate = "buy_rate"
        case sellRate = "sell_rate"
        case periodRate = "period_rate"
    }
    
    /// Net value in cents (earnings - costs)
    var netCents: Double {
        earnings - costs
    }
    
    /// Net value in dollars
    var netDollars: Double {
        netCents / 100.0
    }
}

/// Time range definition for a tariff period
/// API returns: ["Evening", "16:00:00", "21:00:00", 19.367]
struct TariffPeriodDefinition: Identifiable {
    var id: String { periodName }
    
    let periodName: String
    let startTime: String         // "16:00:00"
    let endTime: String           // "21:00:00"
    let periodRate: Double        // cents/kWh
    
    /// Parse start hour from time string
    var startHour: Int {
        Int(startTime.prefix(2)) ?? 0
    }
    
    /// Parse end hour from time string
    var endHour: Int {
        Int(endTime.prefix(2)) ?? 0
    }
    
    /// Formatted time range for display
    var timeRange: String {
        "\(formatTime(startTime)) – \(formatTime(endTime))"
    }
    
    private func formatTime(_ time: String) -> String {
        guard let hour = Int(time.prefix(2)) else { return time }
        if hour == 0 { return "12a" }
        if hour == 12 { return "12p" }
        if hour < 12 { return "\(hour)a" }
        return "\(hour - 12)p"
    }
}

/// Response from tariff_rates endpoint
struct TariffRatesResponse: Codable {
    let data: [TariffPeriodPerformance]
    let periodDefinitions: [TariffPeriodDefinition]
    
    /// Total net value across all periods (dollars)
    var totalNetDollars: Double {
        data.reduce(0) { $0 + $1.netDollars }
    }
    
    enum CodingKeys: String, CodingKey {
        case data
        case periods
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode([TariffPeriodPerformance].self, forKey: .data)
        
        // Decode periods as [[Any]] - each is [String, String, String, Double]
        var periodsArray: [TariffPeriodDefinition] = []
        var periodsContainer = try container.nestedUnkeyedContainer(forKey: .periods)
        
        while !periodsContainer.isAtEnd {
            var periodContainer = try periodsContainer.nestedUnkeyedContainer()
            let name = try periodContainer.decode(String.self)
            let startTime = try periodContainer.decode(String.self)
            let endTime = try periodContainer.decode(String.self)
            let rate = try periodContainer.decode(Double.self)
            
            periodsArray.append(TariffPeriodDefinition(
                periodName: name,
                startTime: startTime,
                endTime: endTime,
                periodRate: rate
            ))
        }
        
        periodDefinitions = periodsArray
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(data, forKey: .data)
        // periods encoding not needed for our use case
    }
}

// MARK: - API Extension

extension PowstonAPI {
    
    /// Fetch tariff rates breakdown by time-of-use periods
    /// - Parameters:
    ///   - startDate: Start date for the query
    ///   - endDate: End date for the query
    /// - Returns: TariffRatesResponse with period performance and definitions, or nil on error
    func fetchTariffRates(startDate: Date, endDate: Date) async -> TariffRatesResponse? {
        guard !isDemoMode else {
            print("📊 Tariff rates not available in demo mode")
            return nil
        }
        
        guard let siteId = selectedSiteId, siteId > 0 else {
            print("❌ No site selected for tariff rates")
            return nil
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = powstonTimezone()
        let startString = formatter.string(from: startDate)
        let endString = formatter.string(from: endDate)
        
        let urlString = "\(baseURL)/api/tariff_rates/\(siteId)?start_date=\(startString)&end_date=\(endString)"
        
        guard let url = URL(string: urlString) else {
            print("❌ Invalid tariff_rates URL")
            return nil
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        do {
            print("📊 Fetching tariff rates: \(startString) to \(endString)")
            let (data, response) = try await URLSession.shared.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                print("❌ Tariff rates: Invalid response type")
                return nil
            }
            
            guard httpResponse.statusCode == 200 else {
                print("❌ Tariff rates: HTTP \(httpResponse.statusCode)")
                if let errorText = String(data: data, encoding: .utf8) {
                    print("   Error: \(errorText.prefix(200))")
                }
                return nil
            }
            
            let decoded = try JSONDecoder().decode(TariffRatesResponse.self, from: data)
            print("📊 Tariff rates: \(decoded.data.count) periods")
            return decoded
            
        } catch {
            print("❌ Tariff rates error: \(error)")
            return nil
        }
    }
}
