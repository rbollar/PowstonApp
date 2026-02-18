//
//  InverterResponse.swift
//  Powston
//

import Foundation

// MARK: - Runtime Params (contains per-inverter data)
struct RuntimeParams: Codable {
    let batterySoc: Double?
    let batteryCapacity: Int?
    let batteryPower: Double?
    let solarPower: Double?
    let gridPower: Double?
    let housePower: Double?
    
    enum CodingKeys: String, CodingKey {
        case batterySoc = "battery_soc"
        case batteryCapacity = "battery_capacity"
        case batteryPower = "battery_power"
        case solarPower = "solar_power"
        case gridPower = "grid_power"
        case housePower = "house_power"
    }
}

// MARK: - Nested Inverter Data (for additional inverters keyed by serial)
struct NestedInverterData: Codable {
    let batterySoc: Double?
    let batteryCapacity: Int?
    let batteryPower: Double?
    let solarPower: Double?
    let gridPower: Double?
    let housePower: Double?
    
    enum CodingKeys: String, CodingKey {
        case batterySoc = "battery_soc"
        case batteryCapacity = "battery_capacity"
        case batteryPower = "battery_power"
        case solarPower = "solar_power"
        case gridPower = "grid_power"
        case housePower = "house_power"
    }
}

struct InverterResponse: Codable {
    var batterySocRaw: Double?  // Top-level battery_soc (may be combined or single)
    var batteryPower: Double?   // W, negative = charging, positive = discharging
    var action: String?
    var lastAction: String?
    var solarPower: Double?
    var gridPower: Double?
    var housePower: Double?
    var buyPrice: Double?
    var sellPrice: Double?
    var rrp: Double?
    var reason: String?
    var userCodeName: String?
    var actionPattern: [String]?
    var currentHour: Int?
    var buyForecast: [Double]?
    var sellForecast: [Double]?
    var sunrise: String?
    var sunset: String?
    var intervalTime: String?
    var runtimeParams: RuntimeParamsContainer?
    
    enum CodingKeys: String, CodingKey {
        case batterySocRaw = "battery_soc"
        case batteryPower = "battery_power"
        case action
        case lastAction = "last_action"
        case solarPower = "solar_power"
        case gridPower = "grid_power"
        case housePower = "house_power"
        case buyPrice = "buy_price"
        case sellPrice = "sell_price"
        case rrp
        case reason
        case userCodeName = "user_code_name"
        case actionPattern = "action_pattern"
        case currentHour = "current_hour"
        case buyForecast = "buy_forecast"
        case sellForecast = "sell_forecast"
        case sunrise
        case sunset
        case intervalTime = "interval_time"
        case runtimeParams = "runtime_params"
    }
    
    // Custom decoder to make runtimeParams fail-safe
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        batterySocRaw = try container.decodeIfPresent(Double.self, forKey: .batterySocRaw)
        batteryPower = try container.decodeIfPresent(Double.self, forKey: .batteryPower)
        action = try container.decodeIfPresent(String.self, forKey: .action)
        lastAction = try container.decodeIfPresent(String.self, forKey: .lastAction)
        solarPower = try container.decodeIfPresent(Double.self, forKey: .solarPower)
        gridPower = try container.decodeIfPresent(Double.self, forKey: .gridPower)
        housePower = try container.decodeIfPresent(Double.self, forKey: .housePower)
        buyPrice = try container.decodeIfPresent(Double.self, forKey: .buyPrice)
        sellPrice = try container.decodeIfPresent(Double.self, forKey: .sellPrice)
        rrp = try container.decodeIfPresent(Double.self, forKey: .rrp)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        userCodeName = try container.decodeIfPresent(String.self, forKey: .userCodeName)
        actionPattern = try container.decodeIfPresent([String].self, forKey: .actionPattern)
        currentHour = try container.decodeIfPresent(Int.self, forKey: .currentHour)
        buyForecast = try container.decodeIfPresent([Double].self, forKey: .buyForecast)
        sellForecast = try container.decodeIfPresent([Double].self, forKey: .sellForecast)
        sunrise = try container.decodeIfPresent(String.self, forKey: .sunrise)
        sunset = try container.decodeIfPresent(String.self, forKey: .sunset)
        intervalTime = try container.decodeIfPresent(String.self, forKey: .intervalTime)
        
        // Fail-safe decode of runtimeParams - don't let it crash the whole decode
        runtimeParams = try? container.decodeIfPresent(RuntimeParamsContainer.self, forKey: .runtimeParams)
    }
    
    // Calculate weighted SOC from all inverters in runtime_params
    var batterySoc: Double? {
        guard let params = runtimeParams else {
            return batterySocRaw
        }
        
        var totalEnergy = 0.0
        var totalCapacity = 0.0
        
        // Main inverter
        if let soc = params.mainInverter.batterySoc,
           let capacity = params.mainInverter.batteryCapacity,
           capacity > 0 {
            totalEnergy += soc * Double(capacity) / 100.0
            totalCapacity += Double(capacity)
        }
        
        // Additional inverters (keyed by serial number)
        for (_, inverterData) in params.additionalInverters {
            if let soc = inverterData.batterySoc,
               let capacity = inverterData.batteryCapacity,
               capacity > 0 {
                totalEnergy += soc * Double(capacity) / 100.0
                totalCapacity += Double(capacity)
            }
        }
        
        // If we found multiple inverters, return weighted average
        if totalCapacity > 0 {
            return (totalEnergy / totalCapacity) * 100.0
        }
        
        // Fallback to top-level value
        return batterySocRaw
    }
    
    // Total battery capacity from all inverters (in Wh)
    var totalBatteryCapacity: Int? {
        guard let params = runtimeParams else { return nil }
        
        var total = 0
        
        if let capacity = params.mainInverter.batteryCapacity {
            total += capacity
        }
        
        for (_, inverterData) in params.additionalInverters {
            if let capacity = inverterData.batteryCapacity {
                total += capacity
            }
        }
        
        return total > 0 ? total : nil
    }
    
    // Total battery power from all inverters (in W) - negative = charging, positive = discharging
    var totalBatteryPower: Double? {
        guard let params = runtimeParams else { return batteryPower }
        
        var total = 0.0
        var hasData = false
        
        if let power = params.mainInverter.batteryPower {
            total += power
            hasData = true
        }
        
        for (_, inverterData) in params.additionalInverters {
            if let power = inverterData.batteryPower {
                total += power
                hasData = true
            }
        }
        
        return hasData ? total : batteryPower
    }
    
    // Total solar power from all inverters (in W)
    var totalSolarPower: Double? {
        guard let params = runtimeParams else { return solarPower }
        
        var total = 0.0
        var hasData = false
        
        if let power = params.mainInverter.solarPower {
            total += power
            hasData = true
        }
        
        for (_, inverterData) in params.additionalInverters {
            if let power = inverterData.solarPower {
                total += power
                hasData = true
            }
        }
        
        return hasData ? total : solarPower
    }
    
    // Total house power from all inverters (in W) - calculated per-inverter, needs summing
    var totalHousePower: Double? {
        guard let params = runtimeParams else { return housePower }
        
        var total = 0.0
        var hasData = false
        
        if let power = params.mainInverter.housePower {
            total += power
            hasData = true
        }
        
        for (_, inverterData) in params.additionalInverters {
            if let power = inverterData.housePower {
                total += power
                hasData = true
            }
        }
        
        return hasData ? total : housePower
    }
    
    // Total grid power from all inverters (in W) - negative = import, positive = export
    var totalGridPower: Double? {
        guard let params = runtimeParams else { return gridPower }
        
        var total = 0.0
        var hasData = false
        
        if let power = params.mainInverter.gridPower {
            total += power
            hasData = true
        }
        
        for (_, inverterData) in params.additionalInverters {
            if let power = inverterData.gridPower {
                total += power
                hasData = true
            }
        }
        
        return hasData ? total : gridPower
    }
    
    // Energy balance: Solar + Battery - Grid - Home should be ~0
    var energyImbalance: Double {
        let solar = totalSolarPower ?? solarPower ?? 0
        let battery = totalBatteryPower ?? batteryPower ?? 0
        let grid = totalGridPower ?? gridPower ?? 0
        let house = totalHousePower ?? housePower ?? 0
        return solar + battery - grid - house
    }

    var energyImbalanceKw: Double {
        energyImbalance / 1000
    }

    // Threshold: 3% of total power throughput (accounts for inverter inefficiency/losses)
    var hasSignificantImbalance: Bool {
        let solar = abs(totalSolarPower ?? solarPower ?? 0)
        let battery = abs(totalBatteryPower ?? batteryPower ?? 0)
        let grid = abs(totalGridPower ?? gridPower ?? 0)
        let house = abs(totalHousePower ?? housePower ?? 0)
        let totalPower = solar + battery + grid + house
        let threshold = totalPower * 0.03  // 3%
        return abs(energyImbalance) > max(threshold, 500)  // At least 500W to avoid noise
    }
    
    // Convenience: use lastAction if available, fallback to action
    var currentAction: String {
        lastAction ?? action ?? "auto"
    }
    
    // Serial numbers of non-lead (nested) inverters - the lead inverter is NOT in this list
    var nestedInverterSerials: [String] {
        runtimeParams?.nestedSerialNumbers ?? []
    }
    
    // Grid direction from API's signed grid_power value
    // positive = export, negative = import
    var isGridExporting: Bool {
        (totalGridPower ?? gridPower ?? 0) > 0
    }

    var solarKw: Double { (totalSolarPower ?? solarPower ?? 0) / 1000 }
    var gridKw: Double { (totalGridPower ?? gridPower ?? 0) / 1000 }
    var houseKw: Double { (totalHousePower ?? housePower ?? 0) / 1000 }
    var batteryKw: Double { (totalBatteryPower ?? batteryPower ?? 0) / 1000 }
    var displayHouseKw: Double { houseKw }
    var isCharging: Bool { (totalBatteryPower ?? batteryPower ?? 0) < 0 }
    var isDischarging: Bool { (totalBatteryPower ?? batteryPower ?? 0) > 0 }
    
    // Memberwise init for demo data and testing
    init(
        batterySocRaw: Double? = nil,
        batteryPower: Double? = nil,
        action: String? = nil,
        lastAction: String? = nil,
        solarPower: Double? = nil,
        gridPower: Double? = nil,
        housePower: Double? = nil,
        buyPrice: Double? = nil,
        sellPrice: Double? = nil,
        rrp: Double? = nil,
        reason: String? = nil,
        userCodeName: String? = nil,
        actionPattern: [String]? = nil,
        currentHour: Int? = nil,
        buyForecast: [Double]? = nil,
        sellForecast: [Double]? = nil,
        sunrise: String? = nil,
        sunset: String? = nil,
        intervalTime: String? = nil,
        runtimeParams: RuntimeParamsContainer? = nil
    ) {
        self.batterySocRaw = batterySocRaw
        self.batteryPower = batteryPower
        self.action = action
        self.lastAction = lastAction
        self.solarPower = solarPower
        self.gridPower = gridPower
        self.housePower = housePower
        self.buyPrice = buyPrice
        self.sellPrice = sellPrice
        self.rrp = rrp
        self.reason = reason
        self.userCodeName = userCodeName
        self.actionPattern = actionPattern
        self.currentHour = currentHour
        self.buyForecast = buyForecast
        self.sellForecast = sellForecast
        self.sunrise = sunrise
        self.sunset = sunset
        self.intervalTime = intervalTime
        self.runtimeParams = runtimeParams
    }
    
    // Parse the forecast start time
    var forecastStartDate: Date? {
        guard let intervalTime = intervalTime else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: intervalTime) {
            return date
        }
        
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: intervalTime)
    }
    
    // Get the absolute time for a forecast period
    func absoluteTimeForPeriod(_ period: Int) -> Date? {
        guard let startDate = forecastStartDate else { return nil }
        return Calendar.current.date(byAdding: .minute, value: period * 30, to: startDate)
    }
    
    // Convert ISO8601 timestamp to hour (decimal) relative to forecast start
    var sunriseHour: Double? {
        guard let sunrise = sunrise else { return nil }
        return parseHourFromISO8601(sunrise)
    }
    
    var sunsetHour: Double? {
        guard let sunset = sunset else { return nil }
        return parseHourFromISO8601(sunset)
    }
    
    // Get peak hours from UserDefaults
    var peakStartHour: Double? {
        guard UserDefaults.standard.bool(forKey: "peak_enabled") else { return nil }
        
        var peakHour = UserDefaults.standard.double(forKey: "peak_start_hour")
        if peakHour == 0 && !UserDefaults.standard.dictionaryRepresentation().keys.contains("peak_start_hour") {
            peakHour = 16.0
        }
        
        guard let startDate = forecastStartDate else { return peakHour }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        let forecastStartHour = calendar.component(.hour, from: startDate)
        let forecastStartMinute = calendar.component(.minute, from: startDate)
        let forecastStartDecimal = Double(forecastStartHour) + Double(forecastStartMinute) / 60.0
        
        return peakHour - forecastStartDecimal
    }

    var peakEndHour: Double? {
        guard UserDefaults.standard.bool(forKey: "peak_enabled") else { return nil }
        
        var peakHour = UserDefaults.standard.double(forKey: "peak_end_hour")
        if peakHour == 0 && !UserDefaults.standard.dictionaryRepresentation().keys.contains("peak_end_hour") {
            peakHour = 21.0
        }
        
        guard let startDate = forecastStartDate else { return peakHour }
        
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        let forecastStartHour = calendar.component(.hour, from: startDate)
        let forecastStartMinute = calendar.component(.minute, from: startDate)
        let forecastStartDecimal = Double(forecastStartHour) + Double(forecastStartMinute) / 60.0
        
        return peakHour - forecastStartDecimal
    }
    
    private func parseHourFromISO8601(_ timestamp: String) -> Double? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        guard let date = formatter.date(from: timestamp) else {
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: timestamp) else {
                return nil
            }
            return timeOffsetFromForecastStart(date)
        }
        
        return timeOffsetFromForecastStart(date)
    }
    
    private func timeOffsetFromForecastStart(_ date: Date) -> Double? {
        guard let startDate = forecastStartDate else {
            let calendar = Calendar.current
            let components = calendar.dateComponents([.hour, .minute], from: date)
            guard let hour = components.hour, let minute = components.minute else { return nil }
            return Double(hour) + Double(minute) / 60.0
        }
        
        let interval = date.timeIntervalSince(startDate)
        return interval / 3600.0
    }
}

// MARK: - Runtime Params Container (handles dynamic keys for additional inverters)
struct RuntimeParamsContainer: Codable {
    let mainInverter: RuntimeParams
    var additionalInverters: [String: NestedInverterData] = [:]
    var nestedSerialNumbers: [String] = []  // Serial numbers of non-lead inverters
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        
        // Decode main inverter fields
        mainInverter = RuntimeParams(
            batterySoc: try? container.decode(Double.self, forKey: DynamicCodingKey(stringValue: "battery_soc")!),
            batteryCapacity: try? container.decode(Int.self, forKey: DynamicCodingKey(stringValue: "battery_capacity")!),
            batteryPower: try? container.decode(Double.self, forKey: DynamicCodingKey(stringValue: "battery_power")!),
            solarPower: try? container.decode(Double.self, forKey: DynamicCodingKey(stringValue: "solar_power")!),
            gridPower: try? container.decode(Double.self, forKey: DynamicCodingKey(stringValue: "grid_power")!),
            housePower: try? container.decode(Double.self, forKey: DynamicCodingKey(stringValue: "house_power")!)
        )
        
        // Look for nested inverter objects (keyed by serial number like "A23B0200864")
        var nested: [String: NestedInverterData] = [:]
        var serials: [String] = []
        
        for key in container.allKeys {
            // Serial numbers typically start with a letter and contain digits
            let keyString = key.stringValue
            if keyString.count > 8,
               keyString.first?.isLetter == true,
               keyString.contains(where: { $0.isNumber }) {
                if let nestedData = try? container.decode(NestedInverterData.self, forKey: key) {
                    nested[keyString] = nestedData
                    serials.append(keyString)
                }
            }
        }
        
        additionalInverters = nested
        nestedSerialNumbers = serials
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        
        if let soc = mainInverter.batterySoc {
            try container.encode(soc, forKey: DynamicCodingKey(stringValue: "battery_soc")!)
        }
        if let capacity = mainInverter.batteryCapacity {
            try container.encode(capacity, forKey: DynamicCodingKey(stringValue: "battery_capacity")!)
        }
        
        for (serial, data) in additionalInverters {
            try container.encode(data, forKey: DynamicCodingKey(stringValue: serial)!)
        }
    }
}

// MARK: - Dynamic Coding Key
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    
    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
    
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
