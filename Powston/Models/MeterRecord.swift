//
//  MeterRecord.swift
//  Powston
//

import Foundation

struct MeterRecord: Codable, Identifiable {
    var id: String { intervalTime }
    
    let intervalTime: String
    let energyImport: Double?
    let energyExport: Double?
    let gridW: Double?
    let batteryW: Double?
    let startBatterySoc: Double?
    let endBatterySoc: Double?
    let houseConsumption: Double?
    let ppvGeneration: Double?
    let rrp: Double?
    let earnings: Double?
    let costs: Double?
    let energyCosts: Double?
    let fixedCosts: Double?
    
    // Utility meter fields (alternative names from NMI smart meters)
    let generalKwh: Double?
    let feedInKwh: Double?
    
    enum CodingKeys: String, CodingKey {
        case intervalTime = "interval_time"
        case energyImport = "energy_import"
        case energyExport = "energy_export"
        case gridW = "grid_w"
        case batteryW = "battery_w"
        case startBatterySoc = "start_battery_soc"
        case endBatterySoc = "end_battery_soc"
        case houseConsumption = "house_consumption"
        case ppvGeneration = "ppv_generation"
        case rrp
        case earnings
        case costs
        case energyCosts = "energy_costs"
        case fixedCosts = "fixed_costs"
        case generalKwh = "general_kwh"
        case feedInKwh = "feed_in_kwh"
    }
    
    // MARK: - Unified Accessors
    
    /// Import energy in kWh - works with both data formats
    var effectiveImport: Double {
        energyImport ?? generalKwh ?? 0
    }
    
    /// Export energy in kWh - works with both data formats
    var effectiveExport: Double {
        energyExport ?? max(0, feedInKwh ?? 0)  // Clamp negative feed-in
    }
    
    /// Whether this is utility meter data (no inverter-specific fields)
    var isUtilityMeterData: Bool {
        generalKwh != nil && energyImport == nil
    }
    
    var date: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: intervalTime)
    }
    
    var brisbaneDate: Date? {
        guard let utcDate = date else { return nil }
        return utcDate
    }
}

struct MeterRecordsResponse: Codable {
    let meter: MeterInfo?
    let records: [MeterRecord]
}

struct MeterInfo: Codable {
    let nmi: String?
    let state: String?
    let region: String?
    let timezone: String?
    let importTariff: String?
    let exportTariff: String?
    
    enum CodingKeys: String, CodingKey {
        case nmi, state, region, timezone
        case importTariff = "import_tariff"
        case exportTariff = "export_tariff"
    }
}
