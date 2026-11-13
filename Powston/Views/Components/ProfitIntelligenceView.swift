//
//  ProfitIntelligenceView.swift
//  Powston
//
//  Hub view for deep arbitrage analysis tools
//

import SwiftUI

struct ProfitIntelligenceView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var peakAnalysis = ArbitrageAnalysis()
    @StateObject private var efficiencyAnalysis = DecisionEfficiencyAnalysis()
    @StateObject private var savingsAnalysis = SavingsBreakdownAnalysis()
    @StateObject private var bargainHunterAnalysis = BargainHunterAnalysis()

    // Background sync state
    @State private var syncState: AnalysisSyncState = .idle
    @State private var hasTriggeredSync = false

    var config: AnalysisConfig? {
        guard let site = api.selectedSite else { return nil }
        return AnalysisConfig.from(site: site)
    }

    var inverterIds: [Int] {
        guard let site = api.selectedSite else { return [] }
        return api.inverters.filter { $0.siteId == site.id }.map { $0.id }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                headerSection

                // Sync Status Banner (shows during/after background sync)
                if syncState != .idle {
                    AnalysisSyncStatusBanner(syncState: syncState)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Analysis Cards
                VStack(spacing: 12) {
                    // Peak Export Analysis - enabled
                    peakExportCard

                    // Decision Efficiency - enabled
                    decisionEfficiencyCard

                    // Savings Breakdown - enabled
                    savingsBreakdownCard

                    // Bargain Hunter - enabled
                    bargainHunterCard

                    // Battery ROI - enabled
                    batteryROICard

                    // Retailer Comparison - enabled
                    retailerComparisonCard

                    // Morning Survival - coming soon
                    comingSoonCard(
                        icon: "sunrise.fill",
                        color: .orange,
                        title: "Morning Survival",
                        description: "Can you bridge from overnight to cheap rates?"
                    )

                    // Export Replacement - coming soon
                    comingSoonCard(
                        icon: "arrow.triangle.2.circlepath",
                        color: .green,
                        title: "Export Replacement",
                        description: "What's your true round-trip cost?"
                    )
                }

                // Footer
                footerSection
            }
            .padding()
            .animation(.easeInOut(duration: 0.3), value: syncState)
        }
        .navigationTitle("Profit Intelligence")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadCachedResults()

            // Trigger background data sync if not already done
            if !hasTriggeredSync {
                hasTriggeredSync = true
                Task { await preloadAnalysisData() }
            }
        }
    }

    // MARK: - Background Data Preload

    private func preloadAnalysisData() async {
        guard let config = config else { return }

        // Check if we need to sync
        withAnimation { syncState = .checking }

        let dataStore = PowstonDataStore.shared
        let calendar = Calendar.current
        let endDate = calendar.date(byAdding: .day, value: -1, to: Date())!
        let startDate = calendar.date(byAdding: .day, value: -config.analysisWindowDays, to: endDate)!

        let missingDays = dataStore.findMissingDays(siteId: config.siteId, from: startDate, to: endDate)

        if missingDays.isEmpty {
            // Data is already ready
            let recordCount = dataStore.countRecords(siteId: config.siteId, from: startDate, to: endDate)
            withAnimation { syncState = .ready(recordCount: recordCount) }

            // Also trigger valuesJson backfill in background (non-blocking)
            dataStore.backfillMissingValuesJsonIfNeeded(siteId: config.siteId, inverterIds: inverterIds)

            // Hide the banner after a few seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { syncState = .idle }
            }
            return
        }

        // Need to sync - show progress
        withAnimation { syncState = .syncing(SyncProgress(currentDay: 0, totalDays: missingDays.count, recordsFetched: 0, status: "Starting sync...")) }

        let result = await dataStore.prepareForAnalysis(
            config: config,
            inverterIds: inverterIds,
            progressHandler: { progress in
                DispatchQueue.main.async {
                    withAnimation { syncState = .syncing(progress) }
                }
            }
        )

        // Sync complete
        if result.recordsFetched > 0 || result.daysFetched >= 0 {
            let recordCount = dataStore.countRecords(siteId: config.siteId, from: startDate, to: endDate)
            withAnimation { syncState = .ready(recordCount: recordCount) }

            // Also trigger valuesJson backfill
            dataStore.backfillMissingValuesJsonIfNeeded(siteId: config.siteId, inverterIds: inverterIds)

            // Hide banner after showing success
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { syncState = .idle }
            }
        } else if result.stoppedEarly {
            withAnimation { syncState = .error("Sync incomplete - some data unavailable") }
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 40))
                .foregroundStyle(.purple)
            
            Text("Profit Intelligence")
                .font(.title2.bold())
            
            Text("Deep analysis to optimize your arbitrage strategy")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }
    
    // MARK: - Peak Export Card (enabled)
    
    private var peakExportCard: some View {
        NavigationLink(destination: PeakAnalysisView()) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.title3)
                        .foregroundColor(.orange)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Peak Export Analysis")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text("Find your optimal sell floor")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Teaser if results available
                if let result = peakAnalysis.result {
                    Text(AnalysisHeadlines.peakExport(result: result))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(result.floorAnalysis.optimalFloorPrice))¢ floor")
                                .font(.subheadline.bold())
                                .foregroundColor(.orange)
                            Text("recommended")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("+\(formatCurrency(result.improvementDollars))")
                                .font(.subheadline.bold())
                                .foregroundColor(.green)
                            Text("potential gain")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(String(format: "%.0f", result.profitablePercent))%")
                                .font(.subheadline.bold())
                                .foregroundColor(result.profitablePercent >= 50 ? .green : .orange)
                            Text("profitable")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                } else if !api.isDemoMode {
                    Divider()
                    
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .foregroundColor(.orange)
                        Text("Analyze 60 days of export data")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(api.isDemoMode)
        .opacity(api.isDemoMode ? 0.6 : 1)
    }
    
    // MARK: - Decision Efficiency Card (enabled)
    
    private var decisionEfficiencyCard: some View {
        NavigationLink(destination: DecisionEfficiencyView()) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "gauge.with.needle.fill")
                        .font(.title3)
                        .foregroundColor(.blue)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Decision Efficiency")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text("Did you sell at the best available prices?")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Teaser if results available
                if let result = efficiencyAnalysis.result {
                    Text(AnalysisHeadlines.decisionEfficiency(result: result))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.grade)
                                .font(.subheadline.bold())
                                .foregroundColor(gradeColor(result.grade))
                            Text("grade")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(result.overallScore)%")
                                .font(.subheadline.bold())
                                .foregroundColor(result.overallScore >= 80 ? .green : .orange)
                            Text("efficiency")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(String(format: "%.0f", result.peakAnalysis.highPriceCaptureRate))%")
                                .font(.subheadline.bold())
                                .foregroundColor(result.peakAnalysis.highPriceCaptureRate >= 80 ? .green : .orange)
                            Text("peak capture")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                } else if !api.isDemoMode {
                    Divider()
                    
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .foregroundColor(.blue)
                        Text("Analyze 60 days of decision timing")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(api.isDemoMode)
        .opacity(api.isDemoMode ? 0.6 : 1)
    }
    
    // MARK: - Savings Breakdown Card (enabled)
    
    private var savingsBreakdownCard: some View {
        NavigationLink(destination: SavingsBreakdownView()) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "lightbulb.fill")
                        .font(.title3)
                        .foregroundColor(.yellow)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Savings Breakdown")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text("Solar, battery & Powston value analysis")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Teaser if results available
                if let result = savingsAnalysis.result {
                    Text(AnalysisHeadlines.savingsBreakdown(result: result))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatCurrencyRounded(result.totalSavings))
                                .font(.subheadline.bold())
                                .foregroundColor(.green)
                            Text("total saved")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(formatCurrency(result.dailyAvgSavings))/day")
                                .font(.subheadline.bold())
                                .foregroundColor(.green)
                            Text("average")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.powstonSavings >= 0 ? "+\(formatCurrencyRounded(result.powstonSavings))" : "-\(formatCurrencyRounded(result.powstonSavings))")
                                .font(.subheadline.bold())
                                .foregroundColor(result.powstonSavings >= 0 ? .green : .orange)
                            Text("Powston")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                    }
                } else if !api.isDemoMode {
                    Divider()
                    
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .foregroundColor(.yellow)
                        Text("Analyze 60 days of savings data")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(api.isDemoMode)
        .opacity(api.isDemoMode ? 0.6 : 1)
    }
    
    // MARK: - Bargain Hunter Card (enabled)

    private var bargainHunterCard: some View {
        NavigationLink(destination: BargainHunterView()) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "tag.fill")
                        .font(.title3)
                        .foregroundColor(.cyan)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bargain Hunter")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Text("Did you catch the cheapest import windows?")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                // Teaser if results available
                if let result = bargainHunterAnalysis.result {
                    Text(bargainHunterHeadline(result))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    Divider()
                    
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.grade)
                                .font(.subheadline.bold())
                                .foregroundColor(gradeColor(result.grade))
                            Text("grade")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(String(format: "%.0f", 100 - result.expensivePercent))%")
                                .font(.subheadline.bold())
                                .foregroundColor(result.expensivePercent < 20 ? .green : .orange)
                            Text("cheap imports")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
                        if result.potentialSavingsDollars > 0.50 {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("$\(String(format: "%.0f", result.potentialSavingsDollars))")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.orange)
                                Text("potential")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        Spacer()
                    }
                } else if !api.isDemoMode {
                    Divider()
                    
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .foregroundColor(.cyan)
                        Text("Analyze 60 days of import data")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(api.isDemoMode)
        .opacity(api.isDemoMode ? 0.6 : 1)
    }

    private func bargainHunterHeadline(_ result: BargainHunterResult) -> String {
        let bestNCount = result.breakdown.bestNFailures.count
        if bestNCount == 0 {
            return "Great timing! No missed bargains found."
        } else if result.potentialSavingsDollars > 1.0 {
            return "\(bestNCount) imports could have saved $\(String(format: "%.0f", result.potentialSavingsDollars))"
        } else {
            return "\(bestNCount) imports had cheaper alternatives available"
        }
    }
    
    // MARK: - Battery ROI Card

    private var batteryROICard: some View {
        NavigationLink(destination: MarketROIView()) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "battery.100.bolt")
                        .font(.title3)
                        .foregroundColor(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Battery ROI")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)

                        Text("Arbitrage, solar time-shift & self-supply")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(api.isDemoMode)
        .opacity(api.isDemoMode ? 0.6 : 1)
    }

    // MARK: - Retailer Comparison Card

    private var retailerComparisonCard: some View {
        NavigationLink(destination: RetailerComparisonView()) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "building.2")
                        .font(.title3)
                        .foregroundColor(.teal)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Retailer Comparison")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)

                        Text("Your costs & Energy Made Easy")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(api.isDemoMode)
        .opacity(api.isDemoMode ? 0.6 : 1)
    }

    // MARK: - Coming Soon Card
    
    private func comingSoonCard(
        icon: String,
        color: Color,
        title: String,
        description: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color.opacity(0.5))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary.opacity(0.5))
                    
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                
                Spacer()
                
                Text("Coming Soon")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.gray.opacity(0.15))
                    .cornerRadius(6)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 8) {
            if let config = config {
                let recordCount = PowstonDataStore.shared.countRecords(
                    siteId: config.siteId,
                    from: Calendar.current.date(byAdding: .day, value: -60, to: Date())!,
                    to: Date()
                )

                HStack(spacing: 4) {
                    Image(systemName: "cylinder.split.1x2")
                    if recordCount > 0 {
                        Text("\(recordCount.formatted()) records available for analysis")
                    } else {
                        Text("No data cached yet. Tap an analysis to sync.")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                Text("All analyses use 60 days of historical data.")
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(.top, 8)
    }
    
    // MARK: - Load Cached
    
    private func loadCachedResults() {
        if let config = config {
            // Load Peak Analysis cached result
            if let cached = peakAnalysis.getCachedResult(config: config) {
                peakAnalysis.result = cached
            }
            
            // Load Decision Efficiency cached result
            if let cached = efficiencyAnalysis.getCachedResult(config: config) {
                efficiencyAnalysis.result = cached
            }
            
            // Load Savings Breakdown cached result
            if let cached = savingsAnalysis.getCachedResult(config: config) {
                savingsAnalysis.result = cached
            }
            
            // Load Bargain Hunter cached result
            if let cached = bargainHunterAnalysis.getCachedResult(config: config) {
                bargainHunterAnalysis.result = cached
            }
            
        }
    }

    // MARK: - Helpers
    
    private func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "A": return .green
        case "B+", "B": return .blue
        case "C+", "C": return .orange
        default: return .red
        }
    }
    
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
    
    private func formatCurrency(_ value: Double) -> String {
        Self.currencyFormatter.string(from: NSNumber(value: abs(value))) ?? "$0.00"
    }
    
    private func formatCurrencyRounded(_ value: Double) -> String {
        Self.currencyRoundedFormatter.string(from: NSNumber(value: abs(value))) ?? "$0"
    }
}

#Preview {
    NavigationStack {
        ProfitIntelligenceView()
            .environmentObject(PowstonAPI())
    }
}
