//
//  PowstonAPI+MarketROI.swift
//  Powston
//
//  Battery-attributed market ROI from GET /api/market_roi/{inverter_id}.
//  Prices are c/kWh, energy kWh, money dollars. Any story is null when that
//  flow didn't happen in the window.
//

import Foundation

// MARK: - Market ROI Model

struct MarketROI: Codable {
    let inverterId: Int?
    let startDate: String?
    let endDate: String?
    /// Share of the window computed from settled utility meter data (0-100);
    /// the rest is estimated from runtime data
    let settledPct: Double?
    let arbitrage: Arbitrage?
    let solarShift: SolarShift?
    let selfSupply: SelfSupply?
    let context: Context?

    /// Grid -> battery -> grid
    struct Arbitrage: Codable {
        let kwh: Double?
        let buyAvgCentsPerKwh: Double?
        let sellAvgCentsPerKwh: Double?
        let spreadCentsPerKwh: Double?
        let netDollars: Double?

        enum CodingKeys: String, CodingKey {
            case kwh
            case buyAvgCentsPerKwh = "buy_avg_c_per_kwh"
            case sellAvgCentsPerKwh = "sell_avg_c_per_kwh"
            case spreadCentsPerKwh = "spread_c_per_kwh"
            case netDollars = "net_dollars"
        }
    }

    /// Solar -> battery -> grid
    struct SolarShift: Codable {
        let exportKwh: Double?
        let sellAvgCentsPerKwh: Double?
        let revenueDollars: Double?

        enum CodingKeys: String, CodingKey {
            case exportKwh = "export_kwh"
            case sellAvgCentsPerKwh = "sell_avg_c_per_kwh"
            case revenueDollars = "revenue_dollars"
        }
    }

    /// Battery -> house
    struct SelfSupply: Codable {
        let batteryToHouseKwh: Double?
        let storedForHomeKwh: Double?
        let avoidedBuyAvgCentsPerKwh: Double?
        let avoidedDollars: Double?

        enum CodingKeys: String, CodingKey {
            case batteryToHouseKwh = "battery_to_house_kwh"
            case storedForHomeKwh = "stored_for_home_kwh"
            case avoidedBuyAvgCentsPerKwh = "avoided_buy_avg_c_per_kwh"
            case avoidedDollars = "avoided_dollars"
        }
    }

    /// Flows that bypassed the battery
    struct Context: Codable {
        let directSolarExportKwh: Double?
        let directHouseholdImportKwh: Double?

        enum CodingKeys: String, CodingKey {
            case directSolarExportKwh = "direct_solar_export_kwh"
            case directHouseholdImportKwh = "direct_household_import_kwh"
        }
    }

    enum CodingKeys: String, CodingKey {
        case arbitrage, context
        case inverterId = "inverter_id"
        case startDate = "start_date"
        case endDate = "end_date"
        case settledPct = "settled_pct"
        case solarShift = "solar_shift"
        case selfSupply = "self_supply"
    }

    /// Total battery value across the three stories (dollars)
    var totalDollars: Double {
        (arbitrage?.netDollars ?? 0) + (solarShift?.revenueDollars ?? 0) + (selfSupply?.avoidedDollars ?? 0)
    }
}

enum MarketROIResult {
    case success(MarketROI)
    /// The API returns 404 when the window has no battery activity at all
    case noActivity
    case failure(String)
}

// MARK: - API Extension

extension PowstonAPI {

    /// Fetch the battery ROI breakdown for an inclusive local date range.
    func fetchMarketROI(inverterId: Int, startDate: Date, endDate: Date) async -> MarketROIResult {
        guard !apiKey.isEmpty else { return .failure("No API key") }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = powstonTimezone()

        let urlString = "\(baseURL)/api/market_roi/\(inverterId)?start_date=\(formatter.string(from: startDate))&end_date=\(formatter.string(from: endDate))"
        guard let url = URL(string: urlString) else { return .failure("Invalid URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await persistentSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("Invalid response")
            }
            if httpResponse.statusCode == 404 { return .noActivity }
            guard httpResponse.statusCode == 200 else {
                print("❌ Market ROI fetch failed: HTTP \(httpResponse.statusCode)")
                return .failure("HTTP \(httpResponse.statusCode)")
            }

            return .success(try JSONDecoder().decode(MarketROI.self, from: data))
        } catch {
            print("❌ Market ROI error: \(error)")
            return .failure(error.localizedDescription)
        }
    }
}
