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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .balanced: return "Balanced"
        case .maximizeRevenue: return "Maximize Revenue"
        }
    }

    var description: String {
        switch self {
        case .balanced:
            return "Balance export revenue with import costs"
        case .maximizeRevenue:
            return "Prioritize getting the most from exports"
        }
    }

    var icon: String {
        switch self {
        case .balanced: return "scale.3d"
        case .maximizeRevenue: return "dollarsign.arrow.circlepath"
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
        // Maximize Revenue — prioritize export optimization
        case (.maximizeRevenue, .exportFloor): return 1.0
        case (.maximizeRevenue, .exportTiming): return 0.9
        case (.maximizeRevenue, .importTiming): return 0.6
        case (.maximizeRevenue, .batteryReserve): return 0.3
        case (.maximizeRevenue, .p2pPricing): return 0.7
        case (.maximizeRevenue, .p2pWindow): return 0.6
        case (.maximizeRevenue, .priceResponse): return 0.8

        // Balanced — weight all strategies roughly equally
        case (.balanced, .exportFloor): return 0.7
        case (.balanced, .exportTiming): return 0.7
        case (.balanced, .importTiming): return 0.7
        case (.balanced, .batteryReserve): return 0.6
        case (.balanced, .p2pPricing): return 0.5
        case (.balanced, .p2pWindow): return 0.5
        case (.balanced, .priceResponse): return 0.7
        }
    }
}
