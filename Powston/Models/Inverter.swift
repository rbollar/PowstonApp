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
    }
}
