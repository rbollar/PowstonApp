//
//  Inverter.swift
//  Powston
//

import Foundation

struct InverterList: Codable {
    let total: Int
    let items: [Inverter]
}

struct Inverter: Codable, Identifiable {
    let id: Int
    let serialNumber: String
    let manufacturer: String
    let productName: String
    let batteryCapacity: Int?
    let siteId: Int
    let siteName: String?  // Optional - API can return null
    let pvCapacity: Int?
    let phases: Int?
    let bdcRatedPower: Int?      // Battery discharge rated power (watts)
    let batteryPower: Int?       // Battery power capacity (watts)
    let maxDischarging: Int?     // Max discharge power (watts)
    let maxCharging: Int?        // Max charge power (watts)

    /// The inverter's discharge capacity in watts, from the best available field
    var dischargeCapacityWatts: Int {
        bdcRatedPower ?? batteryPower ?? maxDischarging ?? 5000
    }

    /// The inverter's charge capacity in watts
    var chargeCapacityWatts: Int {
        maxCharging ?? batteryPower ?? bdcRatedPower ?? 5000
    }

    enum CodingKeys: String, CodingKey {
        case id
        case serialNumber = "serial_number"
        case manufacturer
        case productName = "product_name"
        case batteryCapacity = "battery_capacity"
        case siteId = "site_id"
        case siteName = "site_name"
        case pvCapacity = "pv_capacity"
        case phases
        case bdcRatedPower = "bdc_rated_power"
        case batteryPower = "battery_power"
        case maxDischarging = "max_discharging"
        case maxCharging = "max_charging"
    }
}
