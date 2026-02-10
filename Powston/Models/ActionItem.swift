//
//  ActionItem.swift
//  Powston
//
//  Unified action item model for consolidating recommendations
//  from Scorecard, Peak Analysis, Bargain Hunter, Peer Power, and Decision Efficiency
//

import Foundation

// MARK: - ActionItem

/// A unified recommendation from any analysis source
struct ActionItem: Identifiable, Codable, Equatable {
    let id: UUID
    let source: ActionSource
    let category: ActionCategory
    let title: String
    let description: String
    let potentialImpact: Double      // Monthly $ impact (positive = savings/revenue)
    let confidence: Double           // 0-1, how reliable is this estimate
    let priority: ActionPriority
    let conflictsWith: [ActionCategory]
    let timestamp: Date

    init(
        id: UUID = UUID(),
        source: ActionSource,
        category: ActionCategory,
        title: String,
        description: String,
        potentialImpact: Double,
        confidence: Double = 0.7,
        priority: ActionPriority,
        conflictsWith: [ActionCategory] = [],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.category = category
        self.title = title
        self.description = description
        self.potentialImpact = potentialImpact
        self.confidence = confidence
        self.priority = priority
        self.conflictsWith = conflictsWith
        self.timestamp = timestamp
    }

    /// Get goal alignment for this item
    func alignment(for goal: UserGoal) -> Double {
        goal.alignment(for: category)
    }

    /// Formatted impact string
    var formattedImpact: String {
        if potentialImpact >= 0 {
            return "+$\(String(format: "%.0f", potentialImpact))/mo"
        } else {
            return "-$\(String(format: "%.0f", abs(potentialImpact)))/mo"
        }
    }
}

// MARK: - ActionSource

/// The analysis source that generated the recommendation
enum ActionSource: String, Codable, CaseIterable {
    case scorecard = "Scorecard"
    case peakAnalysis = "Peak Analysis"
    case bargainHunter = "Bargain Hunter"
    case peerPower = "Peer Power"
    case decisionEfficiency = "Decision Efficiency"

    var icon: String {
        switch self {
        case .scorecard: return "gauge.with.dots.needle.33percent"
        case .peakAnalysis: return "chart.line.uptrend.xyaxis"
        case .bargainHunter: return "tag.fill"
        case .peerPower: return "person.2.fill"
        case .decisionEfficiency: return "brain.head.profile"
        }
    }

    var color: String {
        switch self {
        case .scorecard: return "cyan"
        case .peakAnalysis: return "orange"
        case .bargainHunter: return "green"
        case .peerPower: return "purple"
        case .decisionEfficiency: return "blue"
        }
    }
}

// MARK: - ActionCategory

/// Categorizes recommendations by what they address
enum ActionCategory: String, Codable, CaseIterable {
    case exportFloor = "Export Floor"
    case exportTiming = "Export Timing"
    case importTiming = "Import Timing"
    case batteryReserve = "Battery Reserve"
    case p2pPricing = "P2P Pricing"
    case p2pWindow = "P2P Window"
    case priceResponse = "Price Response"

    var icon: String {
        switch self {
        case .exportFloor: return "arrow.up.square"
        case .exportTiming: return "clock.arrow.circlepath"
        case .importTiming: return "clock.badge.checkmark"
        case .batteryReserve: return "battery.75"
        case .p2pPricing: return "dollarsign.circle"
        case .p2pWindow: return "calendar.badge.clock"
        case .priceResponse: return "bolt.circle"
        }
    }
}

// MARK: - ActionPriority

/// Priority level for an action item
enum ActionPriority: Int, Codable, Comparable, CaseIterable {
    case high = 1
    case medium = 2
    case low = 3

    var displayName: String {
        switch self {
        case .high: return "High Priority"
        case .medium: return "Consider"
        case .low: return "Optional"
        }
    }

    var icon: String {
        switch self {
        case .high: return "exclamationmark.circle.fill"
        case .medium: return "circle.fill"
        case .low: return "circle"
        }
    }

    var color: String {
        switch self {
        case .high: return "red"
        case .medium: return "yellow"
        case .low: return "green"
        }
    }

    static func < (lhs: ActionPriority, rhs: ActionPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - ActionItemsResult

/// Result from the ActionItemsEngine containing processed items
struct ActionItemsResult: Codable {
    let items: [ActionItem]
    let combinedImpact: Double       // Realistic: best per bucket, not sum of all
    let rawTotalImpact: Double       // Naive sum (shown for context)
    let goal: UserGoal
    let generatedAt: Date
    let conflictsResolved: Int       // How many items were filtered due to conflicts

    /// Items grouped by priority
    var byPriority: [ActionPriority: [ActionItem]] {
        Dictionary(grouping: items) { $0.priority }
    }

    /// High priority items
    var highPriority: [ActionItem] {
        items.filter { $0.priority == .high }
    }

    /// Medium priority items
    var mediumPriority: [ActionItem] {
        items.filter { $0.priority == .medium }
    }

    /// Low priority items
    var lowPriority: [ActionItem] {
        items.filter { $0.priority == .low }
    }
}

// MARK: - ImpactBreakdown

/// Breakdown of realistic impact by strategy bucket
struct ImpactBreakdown {
    let bestExportStrategy: ActionItem?
    let bestImportStrategy: ActionItem?
    let p2pOpportunity: ActionItem?
    let exportAlternatives: Int    // Other export strategies not counted
    let importAlternatives: Int    // Other import strategies not counted

    var totalRealisticImpact: Double {
        (bestExportStrategy?.potentialImpact ?? 0) +
        (bestImportStrategy?.potentialImpact ?? 0) +
        (p2pOpportunity?.potentialImpact ?? 0)
    }

    var hasP2P: Bool {
        p2pOpportunity != nil && (p2pOpportunity?.potentialImpact ?? 0) > 0
    }
}
