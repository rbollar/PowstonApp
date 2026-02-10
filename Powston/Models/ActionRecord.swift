//
//  ActionRecord.swift
//  Powston
//
//  GRDB-compatible model for persisted inverter actions
//  Mirrors InverterAction but optimized for SQLite storage and analytical queries
//

import Foundation

// MARK: - Action Record (Persisted)

struct ActionRecord: Codable, Sendable {
    var id: Int
    var inverterId: Int
    var siteId: Int
    var intervalTime: Date
    var action: String
    
    // Prices (cents)
    var buyPrice: Double?
    var sellPrice: Double?
    
    // Energy (kWh)
    var energyImport: Double?
    var energyExport: Double?
    
    // Financial (cents)
    var earnings: Double?
    var costs: Double?
    
    // State
    var batterySoc: Double?
    var pvPower: Double?
    var gridPower: Double?
    var batteryPower: Double?
    var housePower: Double?
    
    // Metadata
    var reason: String?
    var isFinalized: Bool
    var createdAt: Date
    
    // Raw values JSON for forecast data (Decision Efficiency analysis)
    var valuesJson: String?

    enum CodingKeys: String, CodingKey {
        case id
        case inverterId = "inverter_id"
        case siteId = "site_id"
        case intervalTime = "interval_time"
        case action
        case buyPrice = "buy_price"
        case sellPrice = "sell_price"
        case energyImport = "energy_import"
        case energyExport = "energy_export"
        case earnings
        case costs
        case batterySoc = "battery_soc"
        case pvPower = "pv_power"
        case gridPower = "grid_power"
        case batteryPower = "battery_power"
        case housePower = "house_power"
        case reason
        case isFinalized = "is_finalized"
        case createdAt = "created_at"
        case valuesJson = "values_json"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.inverterId = try container.decode(Int.self, forKey: .inverterId)
        self.siteId = try container.decode(Int.self, forKey: .siteId)
        self.intervalTime = try container.decode(Date.self, forKey: .intervalTime)
        self.action = try container.decode(String.self, forKey: .action)
        self.buyPrice = try container.decodeIfPresent(Double.self, forKey: .buyPrice)
        self.sellPrice = try container.decodeIfPresent(Double.self, forKey: .sellPrice)
        self.energyImport = try container.decodeIfPresent(Double.self, forKey: .energyImport)
        self.energyExport = try container.decodeIfPresent(Double.self, forKey: .energyExport)
        self.earnings = try container.decodeIfPresent(Double.self, forKey: .earnings)
        self.costs = try container.decodeIfPresent(Double.self, forKey: .costs)
        self.batterySoc = try container.decodeIfPresent(Double.self, forKey: .batterySoc)
        self.pvPower = try container.decodeIfPresent(Double.self, forKey: .pvPower)
        self.gridPower = try container.decodeIfPresent(Double.self, forKey: .gridPower)
        self.batteryPower = try container.decodeIfPresent(Double.self, forKey: .batteryPower)
        self.housePower = try container.decodeIfPresent(Double.self, forKey: .housePower)
        self.reason = try container.decodeIfPresent(String.self, forKey: .reason)
        self.isFinalized = try container.decode(Bool.self, forKey: .isFinalized)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.valuesJson = try container.decodeIfPresent(String.self, forKey: .valuesJson)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(inverterId, forKey: .inverterId)
        try container.encode(siteId, forKey: .siteId)
        try container.encode(intervalTime, forKey: .intervalTime)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(buyPrice, forKey: .buyPrice)
        try container.encodeIfPresent(sellPrice, forKey: .sellPrice)
        try container.encodeIfPresent(energyImport, forKey: .energyImport)
        try container.encodeIfPresent(energyExport, forKey: .energyExport)
        try container.encodeIfPresent(earnings, forKey: .earnings)
        try container.encodeIfPresent(costs, forKey: .costs)
        try container.encodeIfPresent(batterySoc, forKey: .batterySoc)
        try container.encodeIfPresent(pvPower, forKey: .pvPower)
        try container.encodeIfPresent(gridPower, forKey: .gridPower)
        try container.encodeIfPresent(batteryPower, forKey: .batteryPower)
        try container.encodeIfPresent(housePower, forKey: .housePower)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(isFinalized, forKey: .isFinalized)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(valuesJson, forKey: .valuesJson)
    }
    
    // MARK: - Computed Properties
    
    var hour: Int {
        Calendar.current.component(.hour, from: intervalTime)
    }
    
    var isExport: Bool {
        action.lowercased().contains("export")
    }
    
    var isImport: Bool {
        action.lowercased().contains("import") || action.lowercased().contains("charge")
    }
    
    // MARK: - Init from InverterAction
    
    init(from action: InverterAction, siteId: Int) {
        self.id = action.id
        self.inverterId = action.inverterId
        self.siteId = siteId
        self.intervalTime = action.date ?? Date()
        self.action = action.action
        self.buyPrice = action.buyPrice
        self.sellPrice = action.sellPrice
        self.energyImport = action.energyImport
        self.energyExport = action.energyExport
        self.earnings = action.earnings
        self.costs = action.costs
        self.batterySoc = action.batterySoc
        self.pvPower = action.solarPower
        self.gridPower = action.gridPower
        self.batteryPower = action.batteryPower
        self.housePower = action.housePower
        self.reason = action.reason
        self.isFinalized = false
        self.createdAt = Date()
        self.valuesJson = action.valuesJSON  // Store raw values JSON for forecast data
    }
    
    // MARK: - Direct init for database reads
    
    init(
        id: Int,
        inverterId: Int,
        siteId: Int,
        intervalTime: Date,
        action: String,
        buyPrice: Double? = nil,
        sellPrice: Double? = nil,
        energyImport: Double? = nil,
        energyExport: Double? = nil,
        earnings: Double? = nil,
        costs: Double? = nil,
        batterySoc: Double? = nil,
        pvPower: Double? = nil,
        gridPower: Double? = nil,
        batteryPower: Double? = nil,
        housePower: Double? = nil,
        reason: String? = nil,
        isFinalized: Bool = false,
        createdAt: Date = Date(),
        valuesJson: String? = nil
    ) {
        self.id = id
        self.inverterId = inverterId
        self.siteId = siteId
        self.intervalTime = intervalTime
        self.action = action
        self.buyPrice = buyPrice
        self.sellPrice = sellPrice
        self.energyImport = energyImport
        self.energyExport = energyExport
        self.earnings = earnings
        self.costs = costs
        self.batterySoc = batterySoc
        self.pvPower = pvPower
        self.gridPower = gridPower
        self.batteryPower = batteryPower
        self.housePower = housePower
        self.reason = reason
        self.isFinalized = isFinalized
        self.createdAt = createdAt
        self.valuesJson = valuesJson
    }
}

// MARK: - Analysis Configuration

struct AnalysisConfig: Codable, Hashable, Sendable {
    let siteId: Int
    let batteryCapacityKWh: Double
    let batteryEfficiency: Double
    let peakStartHour: Int
    let peakEndHour: Int
    let timezoneIdentifier: String
    let analysisWindowDays: Int
    let inverterExportCapacityKw: Double
    let lvExportBudgetKwh: Double?  // LocalVolts weekly export budget (nil = no limit)

    var timezone: TimeZone {
        TimeZone(identifier: timezoneIdentifier) ?? .current
    }

    /// Generate hash for cache key
    var parametersHash: String {
        let data = try? JSONEncoder().encode(self)
        return data?.base64EncodedString().prefix(32).description ?? "\(siteId)"
    }

    /// Create from site and user settings
    @MainActor
    static func from(site: Site) -> AnalysisConfig {
        let peakStart = UserDefaults.standard.object(forKey: "peak_start_hour") as? Double ?? 16.0
        let peakEnd = UserDefaults.standard.object(forKey: "peak_end_hour") as? Double ?? 21.0
        let efficiency = UserDefaults.standard.object(forKey: "battery_efficiency") as? Double ?? 0.90

        // LV export budget (stored per site, weekly kWh)
        let lvBudgetKey = "lv_export_budget_kwh_\(site.id)"
        let lvBudget = UserDefaults.standard.object(forKey: lvBudgetKey) as? Double

        // Inverter power in Watts, convert to kW (default 10kW if not set)
        let inverterPowerKw = Double(site.inverterPower ?? 10000) / 1000.0

        return AnalysisConfig(
            siteId: site.id,
            batteryCapacityKWh: Double(site.installedBattery ?? 0) / 1000.0,
            batteryEfficiency: efficiency > 0 ? efficiency : 0.90,
            peakStartHour: Int(peakStart),
            peakEndHour: Int(peakEnd),
            timezoneIdentifier: site.timezone ?? "Australia/Brisbane",
            analysisWindowDays: 60,
            inverterExportCapacityKw: inverterPowerKw,
            lvExportBudgetKwh: lvBudget
        )
    }
}
