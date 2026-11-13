//
//  Site.swift
//  Powston
//

import Foundation
import SwiftUI

// MARK: - User Coupon
struct UserCoupon: Codable, Identifiable {
    let id: Int
    let userId: Int
    let codeSet: String
    let code: String
    let createdAt: String
    let discount: String?
    let deletedAt: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case code
        case discount
        case userId = "user_id"
        case codeSet = "code_set"
        case createdAt = "created_at"
        case deletedAt = "deleted_at"
    }
}
// MARK: - Site
struct Site: Codable, Identifiable {
    let id: Int
    let name: String
    let displayName: String?
    let state: String?
    let network: String?
    let installedSolar: Int?
    let installedBattery: Int?
    let windPower: Int?
    let hydroPower: Int?
    let primaryInverterId: Int?
    let latitude: Double?
    let longitude: Double?
    let location: String?
    let postcode: String?
    let timezone: String?
    let brand: String?
    let nmi: String?
    let tariff: String?
    let exportTariff: String?
    let gridPowerLimit: Int?
    let inverterPower: Int?
    let minSoc: Int?
    let controlled: Bool?
    let isCommercial: Bool?
    let readOnly: Bool?
    let haPublish: Bool?
    let mqttUser: String?
    let mqttPassword: String?
    let pvoutputSiteId: Int?
    let pvoutputApiKey: String?
    let vendorId: String?
    let installerId: Int?
    let amberKey: String?
    let amberSiteId: String?
    let localvoltsKey: String?
    let localvoltsPartnerId: String?
    let activeRetailer: String?
    let marketCosts: Double?

    enum CodingKeys: String, CodingKey {
        case id, name, state, network, latitude, longitude, location, postcode, timezone, brand, nmi, tariff, controlled
        case displayName = "display_name"
        case installedSolar = "installed_solar"
        case installedBattery = "installed_battery"
        case windPower = "wind_power"
        case hydroPower = "hydro_power"
        case primaryInverterId = "primary_inverter_id"
        case exportTariff = "export_tariff"
        case gridPowerLimit = "grid_power_limit"
        case inverterPower = "inverter_power"
        case minSoc = "min_soc"
        case isCommercial = "is_commercial"
        case readOnly = "read_only"
        case haPublish = "ha_publish"
        case mqttUser = "mqtt_user"
        case mqttPassword = "mqtt_password"
        case pvoutputSiteId = "pvoutput_site_id"
        case pvoutputApiKey = "pvoutput_api_key"
        case vendorId = "vendor_id"
        case installerId = "installer_id"
        case amberKey = "amber_key"
        case amberSiteId = "amber_site_id"
        case localvoltsKey = "localvolts_key"
        case localvoltsPartnerId = "localvolts_partner_id"
        case activeRetailer = "active_retailer"
        case marketCosts = "market_costs"
    }

    // MARK: - Generation Type

    var hasSolar: Bool { (installedSolar ?? 0) > 0 }
    var hasWind: Bool { (windPower ?? 0) > 0 }
    var hasHydro: Bool { (hydroPower ?? 0) > 0 }

    // MARK: - Retailer

    /// Whether LocalVolts is this site's retailer. Uses active_retailer, falling
    /// back to the LocalVolts fields for site records that don't report it.
    var isLocalVoltsSite: Bool {
        if let retailer = activeRetailer, !retailer.isEmpty {
            return retailer.lowercased() == "localvolts"
        }
        return localvoltsKey != nil || localvoltsPartnerId != nil
    }

    /// Display name of the site's retailer, or nil when unknown
    var retailerName: String? {
        switch activeRetailer?.lowercased() {
        case "amber": return "Amber Electric"
        case "localvolts": return "LocalVolts"
        case "flowpower": return "Flow Power"
        case "globird": return "GloBird Energy"
        case "other": return nil
        default: break
        }
        if localvoltsKey != nil || localvoltsPartnerId != nil { return "LocalVolts" }
        if amberKey != nil || amberSiteId != nil { return "Amber Electric" }
        return nil
    }

    /// Icon for the site's generation source(s)
    var generationIcon: String {
        let sources = [hasSolar, hasWind, hasHydro].filter { $0 }.count
        if sources > 1 { return "leaf.fill" }
        if hasWind { return "wind" }
        if hasHydro { return "drop.fill" }
        return "sun.max.fill" // default to solar
    }

    /// Color for the generation icon
    var generationColor: Color {
        let sources = [hasSolar, hasWind, hasHydro].filter { $0 }.count
        if sources > 1 { return .green }
        if hasWind { return .cyan }
        if hasHydro { return .blue }
        return .yellow // solar default
    }

    /// Label for generation savings/cost in analysis
    func generationLabel(isSavings: Bool) -> String {
        let sources = [hasSolar, hasWind, hasHydro].filter { $0 }.count
        let type: String
        if sources > 1 {
            type = "Generation"
        } else if hasWind {
            type = "Wind"
        } else if hasHydro {
            type = "Hydro"
        } else {
            type = "Solar"
        }
        return isSavings ? "\(type) savings:" : "\(type) cost:"
    }

    /// Short description of generation type for UI messages (e.g. "Hydro site", "Wind site")
    var generationTypeLabel: String {
        let sources = [hasSolar, hasWind, hasHydro].filter { $0 }.count
        if sources > 1 { return "Renewable site" }
        if hasWind { return "Wind site" }
        if hasHydro { return "Hydro site" }
        if hasSolar { return "Solar site" }
        return "Site"
    }
}
