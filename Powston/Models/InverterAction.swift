//
//  InverterAction.swift
//  Powston
//
//  Data model for inverter actions with multi-inverter support
//
//  CHANGES FOR DECISION EFFICIENCY:
//  - Added earnings, costs fields from API response
//  - These are already present in your current file, verify they decode correctly
//

import Foundation

// MARK: - Inverter Action Model
struct InverterAction: Identifiable, Codable {
    let id: Int
    let inverterId: Int
    let action: String
    let reason: String
    let time: String
    let intervalTime: String
    let createdAt: String
    
    // Raw values JSON - we'll extract what we need
    let valuesJSON: String?
    
    // Meter truth - actual energy moved during this interval
    var energyImport: Double?
    var energyExport: Double?
    
    // Financial data from API (cents)
    var earnings: Double?
    var costs: Double?
    
    // Extracted fields (populated after parsing)
    var batterySoc: Double?
    var buyPrice: Double?
    var sellPrice: Double?
    var gridPower: Double?
    var solarPower: Double?
    var housePower: Double?
    var batteryPower: Double?
    
    // For multi-inverter support
    var inverterSerial: String?
    var nestedInverterData: [String: NestedInverterSOC]?
    
    // Parsed date
    var date: Date? {
        // Try intervalTime first (ISO format)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: intervalTime) {
            return date
        }
        // Try without fractional seconds
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: intervalTime) {
            return date
        }
        // Try time field with timezone
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        if let date = formatter.date(from: time) {
            return date
        }
        return nil
    }
    
    // Brisbane time for display
    var brisbaneDate: Date? {
        date
    }
    
    enum CodingKeys: String, CodingKey {
        case id
        case inverterId = "inverter_id"
        case action
        case reason
        case time
        case intervalTime = "interval_time"
        case createdAt = "created_at"
        case valuesJSON = "values"
        case energyImport = "energy_import"
        case energyExport = "energy_export"
        case earnings
        case costs
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(Int.self, forKey: .id)
        inverterId = try container.decode(Int.self, forKey: .inverterId)
        action = try container.decode(String.self, forKey: .action)
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        time = try container.decodeIfPresent(String.self, forKey: .time) ?? ""
        intervalTime = try container.decodeIfPresent(String.self, forKey: .intervalTime) ?? ""
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        
        // Meter truth - actual energy moved during this interval
        energyImport = try container.decodeIfPresent(Double.self, forKey: .energyImport)
        energyExport = try container.decodeIfPresent(Double.self, forKey: .energyExport)
        
        // Financial data
        earnings = try container.decodeIfPresent(Double.self, forKey: .earnings)
        costs = try container.decodeIfPresent(Double.self, forKey: .costs)
        
        // Values comes as a JSON string, not an object
        let valuesStr = try container.decodeIfPresent(String.self, forKey: .valuesJSON)
        valuesJSON = valuesStr
        
        // Parse values JSON inline to extract key fields
        if let json = valuesStr, let data = json.data(using: .utf8) {
            do {
                if let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    // Direct values
                    buyPrice = values["buy_price"] as? Double
                    sellPrice = values["sell_price"] as? Double
                    gridPower = values["grid_power"] as? Double ?? values["pgrid"] as? Double
                    solarPower = values["solar_power"] as? Double ?? values["ppv"] as? Double
                    housePower = values["house_power"] as? Double
                    batteryPower = values["battery_power"] as? Double
                    batterySoc = values["battery_soc"] as? Double
                    inverterSerial = values["serial_number"] as? String
                    
                    // Check runtime_params for more detailed data
                    if let runtimeParams = values["runtime_params"] as? [String: Any] {
                        if batterySoc == nil {
                            batterySoc = runtimeParams["battery_soc"] as? Double
                        }
                        if gridPower == nil {
                            gridPower = runtimeParams["grid_power"] as? Double ?? runtimeParams["pgrid"] as? Double
                        }
                        if solarPower == nil {
                            solarPower = runtimeParams["solar_power"] as? Double ?? runtimeParams["ppv"] as? Double
                        }
                        if housePower == nil {
                            housePower = runtimeParams["house_power"] as? Double
                        }
                        if batteryPower == nil {
                            batteryPower = runtimeParams["battery_power"] as? Double
                        }
                        
                        // Extract nested inverter data (for multi-inverter sites)
                        var nested: [String: NestedInverterSOC] = [:]
                        for (key, value) in runtimeParams {
                            if key.hasPrefix("A") && key.count > 8,
                               let inverterData = value as? [String: Any] {
                                let soc = inverterData["battery_soc"] as? Double
                                let grid = inverterData["grid_power"] as? Double
                                let solar = inverterData["solar_power"] as? Double ?? inverterData["ppv"] as? Double
                                let battery = inverterData["battery_power"] as? Double
                                let capacity = inverterData["battery_capacity"] as? Double
                                
                                nested[key] = NestedInverterSOC(
                                    serialNumber: key,
                                    batterySoc: soc,
                                    gridPower: grid,
                                    solarPower: solar,
                                    batteryPower: battery,
                                    batteryCapacity: capacity
                                )
                            }
                        }
                        if !nested.isEmpty {
                            nestedInverterData = nested
                        }
                    }
                }
            } catch {
                print("⚠️ Failed to parse action values: \(error)")
            }
        }
    }
    
    init(id: Int, inverterId: Int, action: String, reason: String, time: String, intervalTime: String, createdAt: String, valuesJSON: String?, earnings: Double? = nil, costs: Double? = nil) {
        self.id = id
        self.inverterId = inverterId
        self.action = action
        self.reason = reason
        self.time = time
        self.intervalTime = intervalTime
        self.createdAt = createdAt
        self.valuesJSON = valuesJSON
        self.earnings = earnings
        self.costs = costs
        parseValues()
    }
    
    // MARK: - Parse Values JSON
    mutating func parseValues() {
        guard let json = valuesJSON,
              let data = json.data(using: .utf8) else { return }
        
        do {
            if let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Direct values
                buyPrice = values["buy_price"] as? Double
                sellPrice = values["sell_price"] as? Double
                gridPower = values["grid_power"] as? Double ?? values["pgrid"] as? Double
                solarPower = values["solar_power"] as? Double ?? values["ppv"] as? Double
                housePower = values["house_power"] as? Double
                batteryPower = values["battery_power"] as? Double
                batterySoc = values["battery_soc"] as? Double
                
                // Check runtime_params for more detailed data
                if let runtimeParams = values["runtime_params"] as? [String: Any] {
                    // Main inverter values
                    if batterySoc == nil {
                        batterySoc = runtimeParams["battery_soc"] as? Double
                    }
                    if gridPower == nil {
                        gridPower = runtimeParams["grid_power"] as? Double ?? runtimeParams["pgrid"] as? Double
                    }
                    if solarPower == nil {
                        solarPower = runtimeParams["solar_power"] as? Double ?? runtimeParams["ppv"] as? Double
                    }
                    if housePower == nil {
                        housePower = runtimeParams["house_power"] as? Double
                    }
                    if batteryPower == nil {
                        batteryPower = runtimeParams["battery_power"] as? Double
                    }
                }
            }
        } catch {
            print("⚠️ Failed to parse action values: \(error)")
        }
    }
}

// MARK: - Nested Inverter Data (for multi-inverter sites)
struct NestedInverterSOC: Codable {
    let serialNumber: String
    let batterySoc: Double?
    let gridPower: Double?
    let solarPower: Double?
    let batteryPower: Double?
    let batteryCapacity: Double?
}

// MARK: - Lightweight SOC Point (for charting)
struct ActionSOCPoint: Identifiable {
    let id = UUID()
    let time: Date
    let soc: Double
    let action: String
    let buyPrice: Double
    let sellPrice: Double
    let inverterId: Int
    let inverterSerial: String?
    
    init(time: Date, soc: Double, action: String, buyPrice: Double, sellPrice: Double, inverterId: Int, inverterSerial: String?) {
        self.time = time
        self.soc = soc
        self.action = action
        self.buyPrice = buyPrice
        self.sellPrice = sellPrice
        self.inverterId = inverterId
        self.inverterSerial = inverterSerial
    }
    
    init(from action: InverterAction) {
        self.time = action.date ?? Date()
        self.soc = action.batterySoc ?? 0
        self.action = action.action
        self.buyPrice = action.buyPrice ?? 0
        self.sellPrice = action.sellPrice ?? 0
        self.inverterId = action.inverterId
        self.inverterSerial = action.inverterSerial
    }
    
    init(from record: ActionRecord) {
        self.time = record.intervalTime
        self.soc = record.batterySoc ?? 0
        self.action = record.action
        self.buyPrice = record.buyPrice ?? 0
        self.sellPrice = record.sellPrice ?? 0
        self.inverterId = record.inverterId
        self.inverterSerial = nil  // ActionRecord doesn't store serial
    }
}



// MARK: - Site Actions (combined view for multi-inverter)
struct SiteActionsData {
    let siteId: Int
    let date: Date
    let inverterActions: [Int: [InverterAction]]  // Keyed by inverterId
    
    // Combined timeline (all inverters merged by time)
    var combinedTimeline: [Date: [InverterAction]] {
        var timeline: [Date: [InverterAction]] = [:]
        for (_, actions) in inverterActions {
            for action in actions {
                if let date = action.date {
                    // Round to nearest 5 minutes for alignment
                    let rounded = date.rounded(toNearest: 300)
                    if timeline[rounded] == nil {
                        timeline[rounded] = []
                    }
                    timeline[rounded]?.append(action)
                }
            }
        }
        return timeline
    }
    
    // Weighted average SOC across all inverters at each time point
    func combinedSOC(capacities: [Int: Double]) -> [ActionSOCPoint] {
        var points: [ActionSOCPoint] = []
        
        for (time, actions) in combinedTimeline.sorted(by: { $0.key < $1.key }) {
            var totalCapacity: Double = 0
            var weightedSOC: Double = 0
            
            for action in actions {
                let capacity = capacities[action.inverterId] ?? 50.0  // Default 50kWh
                if let soc = action.batterySoc {
                    weightedSOC += soc * capacity
                    totalCapacity += capacity
                }
            }
            
            if totalCapacity > 0, let firstAction = actions.first {
                let avgSOC = weightedSOC / totalCapacity
                // Create point with combined/averaged values
                points.append(ActionSOCPoint(
                    time: time,
                    soc: avgSOC,
                    action: firstAction.action,
                    buyPrice: firstAction.buyPrice ?? 0,
                    sellPrice: firstAction.sellPrice ?? 0,
                    inverterId: firstAction.inverterId,
                    inverterSerial: nil  // Combined, no single serial
                ))
            }
        }
        
        return points
    }
}

// MARK: - Fetch Configuration
struct ActionsFetchConfig {
    let inverterId: Int
    let siteId: Int
    let allInvertersAtSite: [Int]
    let showAllInverters: Bool
    let pageSize: Int
    let date: Date
    
    init(inverterId: Int, siteId: Int, allInvertersAtSite: [Int], showAllInverters: Bool = false, pageSize: Int = 288, date: Date = Date()) {
        self.inverterId = inverterId
        self.siteId = siteId
        self.allInvertersAtSite = allInvertersAtSite
        self.showAllInverters = showAllInverters
        self.pageSize = pageSize
        self.date = date
    }
    
    // Convenience for single inverter
    static func single(inverterId: Int, siteId: Int, date: Date = Date()) -> ActionsFetchConfig {
        ActionsFetchConfig(inverterId: inverterId, siteId: siteId, allInvertersAtSite: [inverterId], showAllInverters: false, date: date)
    }
    
    // Convenience for all inverters at site
    static func allAtSite(siteId: Int, inverterIds: [Int], date: Date = Date()) -> ActionsFetchConfig {
        ActionsFetchConfig(inverterId: inverterIds.first ?? 0, siteId: siteId, allInvertersAtSite: inverterIds, showAllInverters: true, date: date)
    }
}

// MARK: - Paginated Response Wrapper
struct InverterActionsResponse: Codable {
    let actions: [InverterAction]
    let page: Int?
    let pageSize: Int?
    let total: Int?
    let totalPages: Int?
    
    // Convenience to match expected interface
    var items: [InverterAction] { actions }
    
    enum CodingKeys: String, CodingKey {
        case actions
        case page
        case pageSize = "page_size"
        case total
        case totalPages = "total_pages"
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actions = try container.decodeIfPresent([InverterAction].self, forKey: .actions) ?? []
        page = try container.decodeIfPresent(Int.self, forKey: .page)
        pageSize = try container.decodeIfPresent(Int.self, forKey: .pageSize)
        total = try container.decodeIfPresent(Int.self, forKey: .total)
        totalPages = try container.decodeIfPresent(Int.self, forKey: .totalPages)
    }
}

// MARK: - Date Rounding Helper
extension Date {
    func rounded(toNearest seconds: TimeInterval) -> Date {
        let rounded = (timeIntervalSince1970 / seconds).rounded() * seconds
        return Date(timeIntervalSince1970: rounded)
    }
}

// MARK: - Display Helpers
extension InverterAction {
    // Check if this action has meaningful data (not just a silent placeholder)
    var hasMeaningfulData: Bool {
        // If action is "silent", check for actual inverter data (not just grid from meter)
        if action.lowercased() == "silent" {
            // Must have SOC or inverter-specific power readings
            // Grid alone doesn't count - it can come from utility meter
            let hasSOC = batterySoc != nil && batterySoc! > 0
            let hasInverterPower = (solarPower != nil && solarPower != 0) ||
                                   (batteryPower != nil && batteryPower != 0) ||
                                   (housePower != nil && housePower != 0)
            return hasSOC || hasInverterPower
        }
        // Non-silent actions are considered meaningful
        return true
    }
    
    // Simplified action name for display
    var displayAction: String {
        let lower = action.lowercased()
        if lower.contains("curtail") { return "Curtail" }
        if lower.contains("export") { return "Export" }
        if lower.contains("import") { return "Import" }
        if lower.contains("charge") { return "Charge" }
        if lower.contains("discharge") { return "Discharge" }
        if lower.contains("auto") { return "Auto" }
        return action
    }
    
    // First line of reason (summary)
    var reasonSummary: String {
        let lines = reason.components(separatedBy: "\n")
        guard let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return reason.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Truncate if too long
        if first.count > 60 {
            return String(first.prefix(57)) + "..."
        }
        return first
    }
    
    // Full reason with line breaks preserved
    var reasonFull: String {
        reason
    }
    
    // Time formatted for Brisbane
    var displayTime: String {
        guard let date = date else { return time }
        let formatter = DateFormatter()
        formatter.timeZone = powstonTimezone()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
    
    // Date + time for full display
    var displayDateTime: String {
        guard let date = date else { return time }
        let formatter = DateFormatter()
        formatter.timeZone = powstonTimezone()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }
}
