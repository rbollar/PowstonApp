//
//  ActionRecord+InverterAction.swift
//  Powston
//
//  Extension to convert ActionRecord back to InverterAction
//  Used by views that need InverterAction's display helpers
//

import Foundation

extension ActionRecord {
    /// Convert ActionRecord back to InverterAction for views that need display helpers
    /// Note: Some computed properties from the original API response (e.g., reason parsing)
    /// will be reconstructed from stored values
    func toInverterAction() -> InverterAction {
        // Format the intervalTime for the InverterAction's string fields
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let intervalTimeStr = isoFormatter.string(from: intervalTime)
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        dateFormatter.timeZone = powstonTimezone()
        let timeStr = dateFormatter.string(from: intervalTime)
        
        let createdAtFormatter = DateFormatter()
        createdAtFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let createdAtStr = createdAtFormatter.string(from: createdAt)
        
        // Create InverterAction with stored values
        // Use the synthetic initializer that sets parsed values directly
        return InverterAction(
            id: id,
            inverterId: inverterId,
            action: action,
            reason: reason ?? "",
            time: timeStr,
            intervalTime: intervalTimeStr,
            createdAt: createdAtStr,
            valuesJSON: valuesJson,
            energyImport: energyImport,
            energyExport: energyExport,
            earnings: earnings,
            costs: costs,
            batterySoc: batterySoc,
            buyPrice: buyPrice,
            sellPrice: sellPrice,
            gridPower: gridPower,
            solarPower: pvPower,
            housePower: housePower,
            batteryPower: batteryPower
        )
    }
}

// MARK: - InverterAction synthetic init for ActionRecord conversion
extension InverterAction {
    /// Synthetic initializer for creating InverterAction from ActionRecord
    /// Sets all values directly without parsing from JSON
    init(
        id: Int,
        inverterId: Int,
        action: String,
        reason: String,
        time: String,
        intervalTime: String,
        createdAt: String,
        valuesJSON: String?,
        energyImport: Double?,
        energyExport: Double?,
        earnings: Double?,
        costs: Double?,
        batterySoc: Double?,
        buyPrice: Double?,
        sellPrice: Double?,
        gridPower: Double?,
        solarPower: Double?,
        housePower: Double?,
        batteryPower: Double?
    ) {
        self.id = id
        self.inverterId = inverterId
        self.action = action
        self.reason = reason
        self.time = time
        self.intervalTime = intervalTime
        self.createdAt = createdAt
        self.valuesJSON = valuesJSON
        self.energyImport = energyImport
        self.energyExport = energyExport
        self.earnings = earnings
        self.costs = costs
        self.batterySoc = batterySoc
        self.buyPrice = buyPrice
        self.sellPrice = sellPrice
        self.gridPower = gridPower
        self.solarPower = solarPower
        self.housePower = housePower
        self.batteryPower = batteryPower

        // Parse nestedInverterData from valuesJSON if available
        // This is needed for multi-inverter sites to show per-inverter values
        var serial: String? = nil
        var nested: [String: NestedInverterSOC]? = nil

        if let json = valuesJSON, let data = json.data(using: .utf8) {
            do {
                if let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    serial = values["serial_number"] as? String

                    // Extract optimal charge/discharge for limited-rate detection
                    self.optimalDischarging = values["optimal_discharging"] as? Double
                    self.optimalCharging = values["optimal_charging"] as? Double

                    if let runtimeParams = values["runtime_params"] as? [String: Any] {
                        if self.optimalDischarging == nil {
                            self.optimalDischarging = runtimeParams["optimal_discharging"] as? Double
                        }
                        if self.optimalCharging == nil {
                            self.optimalCharging = runtimeParams["optimal_charging"] as? Double
                        }
                        var nestedDict: [String: NestedInverterSOC] = [:]
                        for (key, value) in runtimeParams {
                            // Keys starting with "A" and length > 8 are inverter serial numbers
                            if key.hasPrefix("A") && key.count > 8,
                               let inverterData = value as? [String: Any] {
                                let soc = inverterData["battery_soc"] as? Double
                                let grid = inverterData["grid_power"] as? Double
                                let solar = inverterData["solar_power"] as? Double ?? inverterData["ppv"] as? Double
                                let battery = inverterData["battery_power"] as? Double
                                let capacity = inverterData["battery_capacity"] as? Double
                                let house = inverterData["house_power"] as? Double

                                nestedDict[key] = NestedInverterSOC(
                                    serialNumber: key,
                                    batterySoc: soc,
                                    gridPower: grid,
                                    solarPower: solar,
                                    batteryPower: battery,
                                    batteryCapacity: capacity,
                                    housePower: house
                                )
                            }
                        }
                        if !nestedDict.isEmpty {
                            nested = nestedDict
                        }
                    }
                }
            } catch {
                // Ignore parsing errors - values will remain nil
            }
        }

        self.inverterSerial = serial
        self.nestedInverterData = nested
    }
}
