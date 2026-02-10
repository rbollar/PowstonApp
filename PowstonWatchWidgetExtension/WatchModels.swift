//
//  WatchModels.swift
//  PowstonWatch
//

import Foundation
import SwiftUI

// MARK: - Display Data

struct WatchData {
    let soc: Double
    let batteryKw: Double
    let isCharging: Bool
    let action: String
    let buyPrice: Double
    let sellPrice: Double
}

// MARK: - API Response Models

struct WatchInverter: Codable {
    let id: Int
}

struct WatchInverterParams: Codable {
    let batterySoc: Double?
    let batteryPower: Double?
    let batteryCapacity: Double?
    let action: String?
    let lastAction: String?
    let buyPrice: Double?
    let sellPrice: Double?
    
    var currentAction: String {
        lastAction ?? action ?? "auto"
    }
}

// MARK: - Complication Data (for widget caching)

struct WatchComplicationData: Codable {
    let soc: Int
    let batteryKw: Double
    let isCharging: Bool
    let buyPrice: Double
    let sellPrice: Double
    let action: String
    let timestamp: Date
    
    var flowText: String {
        String(format: "%.1fkW", abs(batteryKw)) + (isCharging ? "↑" : "↓")
    }
    
    var buyPriceText: String {
        formatPrice(buyPrice)
    }
    
    var sellPriceText: String {
        formatPrice(sellPrice)
    }
    
    var socColor: Color {
        if soc >= 80 { return .green }
        if soc >= 50 { return .yellow }
        if soc >= 20 { return .orange }
        return .red
    }
    
    var isStale: Bool {
        Date().timeIntervalSince(timestamp) > 600 // 10 minutes
    }
    
    private func formatPrice(_ price: Double) -> String {
        if abs(price) >= 100 {
            return String(format: "$%.2f", price / 100)
        }
        if price < 0 {
            return String(format: "-%.0f¢", abs(price))
        }
        return String(format: "%.0f¢", price)
    }
    
    static var placeholder: WatchComplicationData {
        WatchComplicationData(
            soc: 50,
            batteryKw: 0,
            isCharging: false,
            buyPrice: 0,
            sellPrice: 0,
            action: "auto",
            timestamp: .distantPast
        )
    }
}

// MARK: - Auth State

enum WatchAuthState: Equatable {
    case checking
    case notConfigured
    case configured
    case demoMode
}
