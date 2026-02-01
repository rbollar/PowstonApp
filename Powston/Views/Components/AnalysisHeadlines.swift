//
//  AnalysisHeadlines.swift
//  Powston
//
//  Shared headline generation for Profit Intelligence analyses
//

import Foundation

struct AnalysisHeadlines {
    
    // MARK: - Peak Export Analysis
    
    static func peakExport(result: PeakAnalysisResult) -> String {
        let floor = Int(result.floorAnalysis.optimalFloorPrice)
        let improvement = result.improvementDollars
        
        if improvement >= 5 {
            return "A \(floor)¢ floor could capture $\(String(format: "%.0f", improvement)) more"
        } else if improvement >= 1 {
            return "A \(floor)¢ floor could add $\(String(format: "%.2f", improvement)) to earnings"
        } else {
            return "Your export strategy is well-optimized"
        }
    }
    
    // MARK: - Decision Efficiency
    
    static func decisionEfficiency(result: DecisionEfficiencyResult) -> String {
        let grade = result.overallGrade
        let efficiency = Int(result.overallEfficiency)
        let peakCapture = Int(result.peakAnalysis.highPriceCaptureRate)
        
        return "Grade \(grade): \(efficiency)% efficient, \(peakCapture)% peak capture"
    }
    
    // MARK: - Savings Breakdown
    
    static func savingsBreakdown(result: SavingsBreakdownResult) -> String {
        let total = result.totalSavings
        let daily = result.dailyAvgSavings
        
        if total >= 100 {
            return "Saved $\(String(format: "%.0f", total)) over 60 days — $\(String(format: "%.2f", daily))/day"
        } else {
            return "Saved $\(String(format: "%.2f", total)) over 60 days — $\(String(format: "%.2f", daily))/day"
        }
    }
}