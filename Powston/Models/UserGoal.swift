//
//  UserGoal.swift
//  Powston
//
//  User optimization goals for prioritizing recommendations
//

import Foundation

/// User's chosen optimization priority for filtering/sorting recommendations
enum UserGoal: String, CaseIterable, Codable, Identifiable {
    case balanced = "balanced"
    case maximizeRevenue = "maximize_revenue"
    case minimizeRisk = "minimize_risk"
    case maximizeP2P = "maximize_p2p"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .balanced: return "Balanced"
        case .maximizeRevenue: return "Maximize Revenue"
        case .minimizeRisk: return "Minimize Risk"
        case .maximizeP2P: return "Maximize P2P"
        }
    }

    var description: String {
        switch self {
        case .balanced:
            return "Trade off revenue vs risk"
        case .maximizeRevenue:
            return "Get the most money from exports"
        case .minimizeRisk:
            return "Ensure battery always has reserve"
        case .maximizeP2P:
            return "Focus on peer-to-peer trading"
        }
    }

    var icon: String {
        switch self {
        case .balanced: return "scale.3d"
        case .maximizeRevenue: return "dollarsign.arrow.circlepath"
        case .minimizeRisk: return "shield.checkered"
        case .maximizeP2P: return "person.2.fill"
        }
    }

    /// Initialize from raw string value, defaulting to balanced
    init(from rawValue: String) {
        self = UserGoal(rawValue: rawValue) ?? .balanced
    }
}

// MARK: - Goal Alignment Weights

extension UserGoal {
    /// Returns the alignment weight (0-1) for a given action category
    func alignment(for category: ActionCategory) -> Double {
        switch (self, category) {
        // Maximize Revenue
        case (.maximizeRevenue, .exportFloor): return 1.0
        case (.maximizeRevenue, .exportTiming): return 0.9
        case (.maximizeRevenue, .importTiming): return 0.6
        case (.maximizeRevenue, .batteryReserve): return 0.2
        case (.maximizeRevenue, .p2pPricing): return 0.7
        case (.maximizeRevenue, .p2pWindow): return 0.6
        case (.maximizeRevenue, .priceResponse): return 0.8

        // Minimize Risk
        case (.minimizeRisk, .exportFloor): return 0.3
        case (.minimizeRisk, .exportTiming): return 0.4
        case (.minimizeRisk, .importTiming): return 0.8
        case (.minimizeRisk, .batteryReserve): return 1.0
        case (.minimizeRisk, .p2pPricing): return 0.3
        case (.minimizeRisk, .p2pWindow): return 0.4
        case (.minimizeRisk, .priceResponse): return 0.5

        // Balanced (default)
        case (.balanced, .exportFloor): return 0.7
        case (.balanced, .exportTiming): return 0.7
        case (.balanced, .importTiming): return 0.7
        case (.balanced, .batteryReserve): return 0.6
        case (.balanced, .p2pPricing): return 0.5
        case (.balanced, .p2pWindow): return 0.5
        case (.balanced, .priceResponse): return 0.7

        // Maximize P2P
        case (.maximizeP2P, .exportFloor): return 0.5
        case (.maximizeP2P, .exportTiming): return 0.4
        case (.maximizeP2P, .importTiming): return 0.3
        case (.maximizeP2P, .batteryReserve): return 0.3
        case (.maximizeP2P, .p2pPricing): return 1.0
        case (.maximizeP2P, .p2pWindow): return 1.0
        case (.maximizeP2P, .priceResponse): return 0.4
        }
    }
}
