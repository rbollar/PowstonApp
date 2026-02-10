//
//  AnalysisHeadlines.swift
//  Powston
//
//  Shared headline generation for Profit Intelligence analyses
//

import Foundation

struct AnalysisHeadlines {
    
    // MARK: - Formatters
    
    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()
    
    private static let currencyRoundedFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 0
        formatter.minimumFractionDigits = 0
        return formatter
    }()
    
    private static func formatCurrency(_ value: Double) -> String {
        currencyFormatter.string(from: NSNumber(value: abs(value))) ?? "$0.00"
    }
    
    private static func formatCurrencyRounded(_ value: Double) -> String {
        currencyRoundedFormatter.string(from: NSNumber(value: abs(value))) ?? "$0"
    }
    
    // MARK: - Peak Export Analysis
    
    static func peakExport(result: PeakAnalysisResult) -> String {
        let floor = Int(result.floorAnalysis.optimalFloorPrice)
        let improvement = result.improvementDollars
        
        if improvement >= 5 {
            return "A \(floor)¢ floor could capture \(formatCurrencyRounded(improvement)) more"
        } else if improvement >= 1 {
            return "A \(floor)¢ floor could add \(formatCurrency(improvement)) to earnings"
        } else {
            return "Your export strategy is well-optimized"
        }
    }
    
    // MARK: - Decision Efficiency

    static func decisionEfficiency(result: DecisionEfficiencyResult) -> String {
        let grade = result.grade
        let efficiency = result.overallScore
        let peakCapture = Int(result.peakAnalysis.highPriceCaptureRate)
        
        return "Grade \(grade): \(efficiency)% efficient, \(peakCapture)% peak capture"
    }
    
    // MARK: - Savings Breakdown

    static func savingsBreakdown(result: SavingsBreakdownResult) -> String {
        let total = result.totalSavings
        let daily = result.dailyAvgSavings

        if total >= 100 {
            return "Saved \(formatCurrencyRounded(total)) over 60 days — \(formatCurrency(daily))/day"
        } else {
            return "Saved \(formatCurrency(total)) over 60 days — \(formatCurrency(daily))/day"
        }
    }

    // MARK: - Retailer Comparison

    static func retailerComparison(result: RetailerComparisonResult) -> String {
        let annual = Int(result.annualizedDifference)
        let retailer = result.cheaperRetailer.displayName

        if annual >= 100 {
            return "\(retailer) saves ~\(formatCurrencyRounded(result.annualizedDifference))/year"
        } else if annual >= 10 {
            return "\(retailer) saves ~\(formatCurrency(result.annualizedDifference))/year"
        } else {
            return "Both retailers cost about the same"
        }
    }
}
