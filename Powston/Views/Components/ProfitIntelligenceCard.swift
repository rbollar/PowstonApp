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
        } else if let result = peakAnalysis.result {
            HStack(spacing: 4) {
                Text("Optimal floor: \(Int(result.floorAnalysis.optimalFloorPrice))¢")
                Text("•")
                Text("+$\(String(format: "%.2f", result.improvementDollars)) potential")
                    .foregroundColor(.green)
            }
        } else {
            Text("Run your first analysis")
        }
    }
    
    private func loadCachedResults() {
        if let config = config {
            if let cached: PeakAnalysisResult = peakAnalysis.getCachedResult(config: config) {
                peakAnalysis.result = cached
            }
        }
    }
}

#Preview {
    ProfitIntelligenceCard()
        .environmentObject(PowstonAPI())
        .padding()
}
