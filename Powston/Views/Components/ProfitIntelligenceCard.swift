//
//  ProfitIntelligenceCard.swift
//  Powston
//
//  Entry card for Profit Intelligence hub on DecisionsView
//

import SwiftUI

struct ProfitIntelligenceCard: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var peakAnalysis = ArbitrageAnalysis()
    @StateObject private var efficiencyAnalysis = DecisionEfficiencyAnalysis()
    @StateObject private var savingsAnalysis = SavingsBreakdownAnalysis()
    
    var config: AnalysisConfig? {
        guard let site = api.selectedSite else { return nil }
        return AnalysisConfig.from(site: site)
    }
    
    var body: some View {
        NavigationLink(destination: ProfitIntelligenceView()) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.title3)
                    .foregroundColor(.purple)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Profit Intelligence")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    
                    teaserText
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .onAppear {
            loadCachedResults()
        }
    }
    
    @ViewBuilder
    private var teaserText: some View {
        if api.isDemoMode {
            Text("Not available in demo mode")
        } else if let result = savingsAnalysis.result {
            Text(AnalysisHeadlines.savingsBreakdown(result: result))
        } else if let result = peakAnalysis.result {
            Text(AnalysisHeadlines.peakExport(result: result))
        } else if let result = efficiencyAnalysis.result {
            Text(AnalysisHeadlines.decisionEfficiency(result: result))
        } else {
            Text("Run your first analysis")
        }
    }
    
    private func loadCachedResults() {
        if let config = config {
            // Load Savings Breakdown cached result (priority for headline)
            if let cached = savingsAnalysis.getCachedResult(config: config) {
                savingsAnalysis.result = cached
            }
            
            // Load Peak Analysis cached result
            if let cached: PeakAnalysisResult = peakAnalysis.getCachedResult(config: config) {
                peakAnalysis.result = cached
            }
            
            // Load Decision Efficiency cached result
            if let cached: DecisionEfficiencyResult = efficiencyAnalysis.getCachedResult(config: config) {
                efficiencyAnalysis.result = cached
            }
        }
    }
}

#Preview {
    ProfitIntelligenceCard()
        .environmentObject(PowstonAPI())
        .padding()
}
