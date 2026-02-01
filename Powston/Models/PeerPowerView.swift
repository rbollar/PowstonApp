//
//  PeerPowerView.swift
//  Powston
//
//  Detail view for P2P trading opportunity analysis
//

import SwiftUI
import Charts

struct PeerPowerView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var analysis = PeerPowerAnalysis()
    
    var config: AnalysisConfig? {
        guard let site = api.selectedSite else { return nil }
        return AnalysisConfig.from(site: site)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if analysis.isAnalyzing {
                    loadingView
                } else if let result = analysis.result {
                    resultsView(result)
                } else if let error = analysis.error {
                    errorView(error)
                } else {
                    startView
                }
            }
            .padding()
        }
        .navigationTitle("Peer Power")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadCachedOrRun()
        }
    }
    
    // MARK: - Loading View
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text(analysis.progress)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
    
    // MARK: - Start View
    
    private var startView: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 50))
                .foregroundColor(.purple)
            
            Text("Peer Power Analysis")
                .font(.title2.bold())
            
            Text("Analyze your peak exports to find P2P trading opportunities. Compare what you earned at spot vs what buyers paid to identify the sweet spot for P2P offers.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button(action: runAnalysis) {
                Label("Run Analysis", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.top)
        }
        .padding()
    }
    
    // MARK: - Error View
    
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)
            
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Button("Try Again", action: runAnalysis)
                .buttonStyle(.bordered)
        }
        .padding()
    }
    
    // MARK: - Results View
    
    private func resultsView(_ result: PeerPowerResult) -> some View {
        VStack(spacing: 20) {
            summaryCard(result)
            spreadCard(result)
            recommendationCard(result)
            scenariosCard(result)
            hourlyCard(result)
            footerView(result)
        }
    }
    
    // MARK: - Summary Card
    
    private func summaryCard(_ result: PeerPowerResult) -> some View {
        VStack(spacing: 12) {
            HStack {
                Text("Peak Export Summary")
                    .font(.headline)
                Spacer()
                Text("\(result.peakStartHour % 12 == 0 ? 12 : result.peakStartHour % 12)\(result.peakStartHour < 12 ? "am" : "pm")–\(result.peakEndHour % 12 == 0 ? 12 : result.peakEndHour % 12)\(result.peakEndHour < 12 ? "am" : "pm")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text(String(format: "%.0f", result.totalPeakExportKwh))
                        .font(.title2.bold())
                        .foregroundColor(.purple)
                    Text("kWh exported")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text(formatCurrency(result.totalPeakExportRevenue))
                        .font(.title3.bold())
                        .foregroundColor(.green)
                    Text("earned at spot")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(spacing: 4) {
                    Text("\(result.periodDays)")
                        .font(.title3.bold())
                        .foregroundColor(.secondary)
                    Text("days")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Spread Card
    
    private func spreadCard(_ result: PeerPowerResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundColor(.blue)
                Text("Price Spread")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    Text(String(format: "%.1f¢", result.avgSellPrice))
                        .font(.title3.bold())
                        .foregroundColor(.orange)
                    Text("You received")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                
                VStack(spacing: 4) {
                    Text(String(format: "%.1f¢", result.avgSpread))
                        .font(.title3.bold())
                        .foregroundColor(.purple)
                    Text("Spread")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                Image(systemName: "arrow.right")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                
                VStack(spacing: 4) {
                    Text(String(format: "%.1f¢", result.avgBuyPrice))
                        .font(.title3.bold())
                        .foregroundColor(.red)
                    Text("Buyers paid")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            
            Text("The spread is the gap where P2P can benefit both parties. You offer somewhere in the middle — more than spot, less than grid.")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Recommendation Card
    
    private func recommendationCard(_ result: PeerPowerResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("Recommended Offer")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(format: "%.0f", result.recommendedPrice))
                            .font(.system(size: 48, weight: .bold))
                            .foregroundColor(.purple)
                        Text("¢/kWh")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    Text("sweet spot price")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundColor(.green)
                        Text(formatCurrency(result.maxOpportunityDollars))
                            .font(.headline)
                            .foregroundColor(.green)
                    }
                    Text("potential extra")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                        Text(String(format: "%.0f%%", result.winWinPercent))
                            .font(.headline)
                            .foregroundColor(.blue)
                    }
                    Text("win-win coverage")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if result.maxOpportunityDollars > 5 {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.purple)
                    Text("At \(String(format: "%.0f¢", result.recommendedPrice)), \(String(format: "%.0f%%", result.winWinPercent)) of your peak exports would have been win-win trades — you'd earn more than spot while buyers pay less than grid.")
                        .font(.caption)
                }
                .padding(8)
                .background(Color.purple.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Scenarios Card
    
    private func scenariosCard(_ result: PeerPowerResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.cyan)
                Text("Price Scenarios")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            if #available(iOS 16.0, *) {
                scenarioChart(result.scenarios, recommended: result.recommendedPrice)
                    .frame(height: 180)
            }
            
            // Table
            VStack(spacing: 4) {
                HStack {
                    Text("Offer")
                        .frame(width: 50, alignment: .leading)
                    Text("Win-Win")
                        .frame(width: 60, alignment: .trailing)
                    Text("kWh")
                        .frame(width: 50, alignment: .trailing)
                    Text("Extra $")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                
                ForEach(result.scenarios) { scenario in
                    let isRecommended = scenario.offerPrice == result.recommendedPrice
                    HStack {
                        Text("\(Int(scenario.offerPrice))¢")
                            .frame(width: 50, alignment: .leading)
                        Text(String(format: "%.0f%%", scenario.winWinPercent))
                            .frame(width: 60, alignment: .trailing)
                        Text(String(format: "%.0f", scenario.eligibleKwh))
                            .frame(width: 50, alignment: .trailing)
                        Text("+\(formatCurrency(scenario.additionalRevenue))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(scenario.additionalRevenue > 0 ? .green : .secondary)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundColor(isRecommended ? .purple : .primary)
                    .fontWeight(isRecommended ? .semibold : .regular)
                }
            }
            
            Text("Win-Win % = intervals where your offer beats spot AND undercuts grid")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    @available(iOS 16.0, *)
    private func scenarioChart(_ scenarios: [P2PPriceScenario], recommended: Double) -> some View {
        Chart {
            ForEach(scenarios) { scenario in
                BarMark(
                    x: .value("Price", "\(Int(scenario.offerPrice))¢"),
                    y: .value("Revenue", scenario.additionalRevenue)
                )
                .foregroundStyle(scenario.offerPrice == recommended ? Color.purple : Color.purple.opacity(0.4))
                .annotation(position: .top, alignment: .center) {
                    if scenario.offerPrice == recommended {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    }
                }
            }
        }
        .chartYAxisLabel("Extra Revenue ($)")
    }
    
    // MARK: - Hourly Card
    
    private func hourlyCard(_ result: PeerPowerResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(.orange)
                Text("Hourly Breakdown")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            Text("Best P2P windows within your peak hours:")
                .font(.caption)
                .foregroundColor(.secondary)
            
            // Sort by opportunity (best first)
            let sortedHours = result.hourlyBreakdown
                .filter { $0.intervalCount > 0 }
                .sorted { $0.avgSpread > $1.avgSpread }
            
            if #available(iOS 16.0, *) {
                hourlySpreadChart(result.hourlyBreakdown)
                    .frame(height: 140)
            }
            
            VStack(spacing: 4) {
                HStack {
                    Text("Hour")
                        .frame(width: 60, alignment: .leading)
                    Text("Spread")
                        .frame(width: 50, alignment: .trailing)
                    Text("Best @")
                        .frame(width: 50, alignment: .trailing)
                    Text("Extra $")
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                
                ForEach(sortedHours) { hour in
                    let hourLabel = formatHour(hour.hour)
                    let isBest = hour == sortedHours.first
                    
                    HStack {
                        Text(hourLabel)
                            .frame(width: 60, alignment: .leading)
                        Text(String(format: "%.0f¢", hour.avgSpread))
                            .frame(width: 50, alignment: .trailing)
                            .foregroundColor(spreadColor(hour.avgSpread))
                        Text("\(Int(hour.bestOfferPrice))¢")
                            .frame(width: 50, alignment: .trailing)
                        Text("+\(formatCurrency(hour.opportunityDollars))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(hour.opportunityDollars > 0 ? .green : .secondary)
                    }
                    .font(.caption.monospacedDigit())
                    .fontWeight(isBest ? .semibold : .regular)
                }
            }
            
            if let best = sortedHours.first, let worst = sortedHours.last, best.avgSpread > worst.avgSpread + 10 {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundColor(.yellow)
                    Text("\(formatHour(best.hour)) has \(String(format: "%.0f¢", best.avgSpread - worst.avgSpread)) more spread than \(formatHour(worst.hour)). Consider focusing P2P offers on higher-spread hours.")
                        .font(.caption)
                }
                .padding(8)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    @available(iOS 16.0, *)
    private func hourlySpreadChart(_ hours: [P2PHourlyBreakdown]) -> some View {
        Chart {
            ForEach(hours.filter { $0.intervalCount > 0 }) { hour in
                BarMark(
                    x: .value("Hour", formatHour(hour.hour)),
                    y: .value("Spread", hour.avgSpread)
                )
                .foregroundStyle(spreadColor(hour.avgSpread))
            }
        }
        .chartYAxisLabel("Avg Spread (¢)")
    }
    
    // MARK: - Footer
    
    private func footerView(_ result: PeerPowerResult) -> some View {
        VStack(spacing: 8) {
            Button(action: runAnalysis) {
                Label("Refresh Analysis", systemImage: "arrow.clockwise")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered)
            
            Text("Based on \(result.periodDays) days of peak export data (\(result.intervalsWithExport) intervals)")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("Adjust peak hours in Settings → Peak Hours")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.top)
    }
    
    // MARK: - Helpers
    
    private func formatHour(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        let suffix = hour < 12 ? "am" : "pm"
        return "\(h)\(suffix)"
    }
    
    private func spreadColor(_ spread: Double) -> Color {
        if spread >= 30 { return .green }
        if spread >= 20 { return .orange }
        return .red
    }
    
    private static let currencyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencySymbol = "$"
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        return f
    }()
    
    private func formatCurrency(_ value: Double) -> String {
        Self.currencyFormatter.string(from: NSNumber(value: abs(value))) ?? "$0.00"
    }
    
    private func loadCachedOrRun() {
        if let config = config, let cached = analysis.getCachedResult(config: config) {
            analysis.result = cached
        }
    }
    
    private func runAnalysis() {
        guard let config = config else { return }
        Task {
            await analysis.runAnalysis(api: api, config: config)
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PeerPowerView()
            .environmentObject(PowstonAPI())
    }
}