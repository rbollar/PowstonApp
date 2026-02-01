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
        self.inverterSerial = nil
        self.nestedInverterData = nil
    }
}
