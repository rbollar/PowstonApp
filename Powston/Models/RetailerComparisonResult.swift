//
//  RetailerComparisonResult.swift
//  Powston
//
//  Result model for retailer comparison analysis (LocalVolts vs Flowpower)
//

import Foundation

// MARK: - Retailer Enum

enum Retailer: String, Codable {
    case localVolts = "LocalVolts"
    case flowpower = "Flowpower"

    var displayName: String { rawValue }
}

// MARK: - Main Result

struct RetailerComparisonResult: Codable {
    let analysisDate: Date
    let periodDays: Int
    let totalImportKwh: Double
    let totalExportKwh: Double

    // Retailer costs
    let localVoltsActual: LocalVoltsCost
    let flowpowerSimulated: FlowpowerCost

    // Comparison metrics
    let difference: Double              // Positive = LocalVolts cheaper (lower cost)
    let cheaperRetailer: Retailer
    let dailyDifference: Double
    let annualizedDifference: Double

    // Data quality
    let dataCompleteness: Double        // Percentage of expected intervals
    let missingRrpIntervals: Int        // Intervals without RRP data

    var formattedReport: String {
        var lines: [String] = []
        lines.append("RETAILER COMPARISON REPORT")
        lines.append("==========================")
        lines.append("")
        lines.append("Period: \(periodDays) days")
        lines.append("Data completeness: \(String(format: "%.1f", dataCompleteness))%")
        if missingRrpIntervals > 0 {
            lines.append("Note: \(missingRrpIntervals) intervals missing RRP data")
        }
        lines.append("")
        lines.append("ENERGY TOTALS")
        lines.append("  Import: \(String(format: "%.1f", totalImportKwh)) kWh")
        lines.append("  Export: \(String(format: "%.1f", totalExportKwh)) kWh")
        lines.append("")
        lines.append("LOCALVOLTS (ACTUAL)")
        lines.append("  Import cost: $\(String(format: "%.2f", localVoltsActual.importCost))")
        lines.append("  Export revenue: $\(String(format: "%.2f", localVoltsActual.exportRevenue))")
        lines.append("  P2P revenue: $\(String(format: "%.2f", localVoltsActual.p2pRevenue))")
        lines.append("  Daily charges: $\(String(format: "%.2f", localVoltsActual.dailyCharges))")
        lines.append("  NET COST: $\(String(format: "%.2f", localVoltsActual.netCost))")
        lines.append("  Avg import: \(String(format: "%.1f", localVoltsActual.avgImportPrice))c/kWh")
        lines.append("  Avg export: \(String(format: "%.1f", localVoltsActual.avgExportPrice))c/kWh")
        lines.append("")
        lines.append("FLOWPOWER (SIMULATED)")
        lines.append("  Base import rate: \(String(format: "%.1f", flowpowerSimulated.baseImportRate))c/kWh")
        lines.append("  PEA adjustment: \(String(format: "%.1f", flowpowerSimulated.peaAdjustment))c/kWh")
        lines.append("  Effective rate: \(String(format: "%.1f", flowpowerSimulated.effectiveImportRate))c/kWh")
        lines.append("  Import cost: $\(String(format: "%.2f", flowpowerSimulated.importCost))")
        lines.append("  Peak exports: \(String(format: "%.1f", flowpowerSimulated.peakExportKwh)) kWh @ 45c")
        lines.append("  Off-peak exports: \(String(format: "%.1f", flowpowerSimulated.offPeakExportKwh)) kWh @ 0c")
        lines.append("  Export revenue: $\(String(format: "%.2f", flowpowerSimulated.exportRevenue))")
        lines.append("  Daily charges: $\(String(format: "%.2f", flowpowerSimulated.totalDailyCharges))")
        lines.append("  NET COST: $\(String(format: "%.2f", flowpowerSimulated.netCost))")
        lines.append("")
        lines.append("COMPARISON")
        lines.append("  \(cheaperRetailer.displayName) is cheaper by:")
        lines.append("    $\(String(format: "%.2f", abs(difference))) for period")
        lines.append("    $\(String(format: "%.2f", abs(dailyDifference)))/day")
        lines.append("    $\(String(format: "%.0f", abs(annualizedDifference)))/year (projected)")
        lines.append("")
        lines.append("PEA DETAILS")
        lines.append("  Total wholesale value: $\(String(format: "%.2f", flowpowerSimulated.peaDetails.totalWholesaleValue / 100))")
        lines.append("  Volume-weighted avg: \(String(format: "%.1f", flowpowerSimulated.peaDetails.volumeWeightedAvgPrice))c/kWh")
        lines.append("  Import timing grade: \(flowpowerSimulated.peaDetails.importTimingGrade)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - LocalVolts Cost

struct LocalVoltsCost: Codable {
    let importCost: Double              // Dollars
    let exportRevenue: Double           // Dollars (positive = earnings)
    let dailyCharges: Double            // Dollars
    let p2pRevenue: Double              // Dollars (LocalVolts P2P premium)
    let netCost: Double                 // import - export - p2p + daily (negative = profit)
    let avgImportPrice: Double          // c/kWh
    let avgExportPrice: Double          // c/kWh
}

// MARK: - Flowpower Cost

struct FlowpowerCost: Codable {
    // Import pricing
    let baseImportRate: Double          // c/kWh (e.g., 34)
    let peaAdjustment: Double           // c/kWh - volume-weighted avg wholesale during imports
    let effectiveImportRate: Double     // c/kWh = base - PEA
    let importCost: Double              // Dollars

    // Export pricing
    let peakExportKwh: Double           // kWh exported during 5:30-7:30pm window
    let offPeakExportKwh: Double        // kWh exported outside window (earns 0c)
    let exportRevenue: Double           // Dollars (only from peak window @ 45c)

    // Daily charges
    let dailyCharge: Double             // $/day
    let totalDailyCharges: Double       // $ for period

    // Net
    let netCost: Double                 // import - export + daily (negative = profit)

    // PEA calculation details
    let peaDetails: PEADetails
}

// MARK: - PEA Details

struct PEADetails: Codable {
    let totalWholesaleValue: Double     // Sum of (RRP * import kWh) in cents
    let totalImportKwh: Double          // Total import during period
    let volumeWeightedAvgPrice: Double  // PEA = totalWholesaleValue / totalImportKwh
    let importTimingGrade: String       // A/B/C/D based on how well timed imports are

    var gradeExplanation: String {
        switch importTimingGrade {
        case "A": return "Excellent - importing at very low wholesale prices"
        case "B": return "Good - importing mostly during cheap periods"
        case "C": return "Average - import timing could be improved"
        case "D": return "Poor - importing during expensive periods"
        default: return "Unknown"
        }
    }
}
