//
//  DecisionEfficiencyView.swift
//  Powston
//
//  SwiftUI view for Decision Efficiency analysis
//  Shows how well the system timed buys and sells vs best available prices
//

import SwiftUI
import FoundationModels

// MARK: - Main Analysis View

struct DecisionEfficiencyView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var analysis = DecisionEfficiencyAnalysis()
    @StateObject private var dataStore = PowstonDataStore.shared
    
    @State private var syncProgress: SyncProgress?
    @State private var showingReport = false
    @State private var syncResult: SyncResult?
    @State private var needsResync = false
    @State private var expandedMissedOpportunities: Set<Date> = []
    @State private var showMissedOpportunitiesList = false
    @State private var showAchievedOpportunitiesList = false
    @State private var expandedAchievedOpportunities: Set<Date> = []
    
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
            VStack(spacing: 16) {
                headerSection
                
                if syncProgress != nil && !syncProgress!.isComplete {
                    syncProgressSection
                } else if analysis.isAnalyzing {
                    analyzingSection
                } else if needsResync {
                    resyncRequiredSection
                } else if let result = analysis.result {
                    resultsSections(result)
                } else if let error = analysis.error {
                    errorSection(error)
                } else {
                    startAnalysisSection
                }
            }
            .padding()
        }
        .navigationTitle("Decision Efficiency")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if analysis.result != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingReport = true
                    } label: {
                        Image(systemName: "doc.text")
                    }
                }
            }
        }
        .sheet(isPresented: $showingReport) {
            if let result = analysis.result {
                ReportSheet(report: result.formattedReport())
            }
        }
        .onAppear {
            checkDataAndLoadCached()
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.needle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
            
            Text("Decision Efficiency")
                .font(.title2.bold())
            
            Text("Did you sell at the best prices? Did you buy at the cheapest?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }
    
    // MARK: - Sync Progress

    private var syncProgressSection: some View {
        AnalysisSyncProgressView(progress: syncProgress)
    }
    
    // MARK: - Analyzing
    
    private var analyzingSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            
            Text(analysis.progress)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Resync Required
    
    private var resyncRequiredSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            
            Text("Data Refresh Required")
                .font(.headline)
            
            Text("Decision Efficiency analysis requires forecast data that isn't in your current cache. This will re-sync 60 days of data.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                Task { await resyncAndAnalyze() }
            } label: {
                Label("Refresh Data & Analyze", systemImage: "arrow.clockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            
            Text("This may take a few minutes")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Start Analysis
    
    private var startAnalysisSection: some View {
        VStack(spacing: 16) {
            if let config = config {
                // Data availability
                let range = dataStore.getDataRange(siteId: config.siteId)
                
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "cylinder.split.1x2")
                        Text("Local Data")
                            .font(.headline)
                        Spacer()
                    }
                    
                    if range.count > 0 {
                        HStack {
                            Text("\(range.count.formatted()) records")
                            Spacer()
                            if let desc = dataStore.getDataRangeDescription(siteId: config.siteId) {
                                Text(desc)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                    } else {
                        Text("No local data yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                
                // Analysis description
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "info.circle")
                        Text("What This Analyzes")
                            .font(.headline)
                        Spacer()
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Export timing vs best available prices", systemImage: "arrow.up.right")
                        Label("Import timing vs cheapest available prices", systemImage: "arrow.down.left")
                        Label("Peak period capture rate", systemImage: "flame")
                        Label("Missed high-value opportunities", systemImage: "exclamationmark.triangle")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            
            Button {
                Task { await runAnalysis() }
            } label: {
                Label("Run Analysis", systemImage: "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .disabled(config == nil || api.isDemoMode)
            
            if api.isDemoMode {
                Text("Analysis not available in demo mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Error
    
    private func errorSection(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            
            Text(error)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            if error.contains("forecast") || error.contains("re-sync") {
                Button("Refresh Data") {
                    Task { await resyncAndAnalyze() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Try Again") {
                    Task { await runAnalysis() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Results
    
    @ViewBuilder
    private func resultsSections(_ result: DecisionEfficiencyResult) -> some View {
        // Overall Score Card
        overallScoreCard(result)
        
        // Export Efficiency
        exportEfficiencyCard(result.exportAnalysis)
        
        // Import Efficiency
        importEfficiencyCard(result.importAnalysis)
        
        // Peak Performance
        peakPerformanceCard(result.peakAnalysis)
        
        // Arbitrage Spread
        spreadCard(result)
        
        // Achieved Opportunities
        if let achieved = result.achievedOpportunities,
           achieved.achievedHighExports > 0 || achieved.achievedCheapImports > 0 {
            achievedOpportunitiesCard(achieved)
        }

        // Missed Opportunities
        if result.missedOpportunities.missedHighExports > 0 || result.missedOpportunities.missedCheapImports > 0 {
            missedOpportunitiesCard(result.missedOpportunities)
        }
        
        // Actions
        actionsSection(result)
    }
    
    // MARK: - Overall Score Card
    
    private func overallScoreCard(_ result: DecisionEfficiencyResult) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text("Overall Score")
                    .font(.headline)
                Spacer()
                Text("\(result.daysAnalyzed) days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            HStack(alignment: .center, spacing: 24) {
                VStack {
                    Text(result.grade)
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(gradeColor(result.grade))
                    Text("\(result.overallScore)%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 8) {
                    HStack {
                        Text("Net earnings:")
                            .foregroundStyle(.secondary)
                        Text("$\(String(format: "%.2f", result.netEarnings / 100))")
                            .foregroundStyle(result.netEarnings >= 0 ? .green : .red)
                    }
                    HStack {
                        Text("Spread capture:")
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.0f", result.spreadCaptureEfficiency))%")
                    }
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Export Efficiency Card
    
    private func exportEfficiencyCard(_ export: ExportEfficiencyAnalysis) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.green)
                Text("Export Efficiency")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            HStack(spacing: 16) {
                VStack {
                    Text("\(export.count)")
                        .font(.title3.bold())
                    Text("Exports")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                VStack {
                    Text("\(String(format: "%.0f", export.totalKwh))")
                        .font(.title3.bold())
                    Text("kWh")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                VStack {
                    if let capture = export.priceCapture {
                        Text("\(String(format: "%.0f", capture))%")
                            .font(.title3.bold())
                            .foregroundStyle(capture >= 80 ? .green : capture >= 60 ? .orange : .red)
                    } else {
                        Text("—")
                            .font(.title3.bold())
                    }
                    Text("Price Capture")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                VStack {
                    Text("$\(String(format: "%.0f", export.totalEarnings / 100))")
                        .font(.title3.bold())
                        .foregroundStyle(.green)
                    Text("Earned")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Import Efficiency Card
    
    private func importEfficiencyCard(_ imports: ImportEfficiencyAnalysis) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                Text("Import Efficiency")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            HStack(spacing: 16) {
                VStack {
                    Text("\(imports.count)")
                        .font(.title3.bold())
                    Text("Imports")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                VStack {
                    Text("\(String(format: "%.0f", imports.totalKwh))")
                        .font(.title3.bold())
                    Text("kWh")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                VStack {
                    if let efficiency = imports.priceEfficiency {
                        Text("\(String(format: "%.0f", efficiency))%")
                            .font(.title3.bold())
                            .foregroundStyle(efficiency >= 80 ? .green : efficiency >= 60 ? .orange : .red)
                    } else {
                        Text("—")
                            .font(.title3.bold())
                    }
                    Text("Efficiency")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                
                VStack {
                    Text("$\(String(format: "%.0f", imports.totalCosts / 100))")
                        .font(.title3.bold())
                        .foregroundStyle(.red)
                    Text("Spent")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
            
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Peak Performance Card
        
        private func peakPerformanceCard(_ peak: PeakPerformanceAnalysis) -> some View {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "flame.fill")
                        .foregroundStyle(.orange)
                    Text("Peak Performance")
                        .font(.headline)
                    Spacer()
                    if let config = config {
                        Text("\(config.peakStartHour):00–\(config.peakEndHour):00")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Divider()
                
                HStack(spacing: 16) {
                    VStack {
                        Text("\(peak.peakExports.formatted())")
                            .font(.title3.bold())
                        Text("Peak Exports")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack {
                        Text("\(String(format: "%.0f", peak.priceCapture))%")
                            .font(.title3.bold())
                            .foregroundStyle(peak.priceCapture >= 80 ? .green : peak.priceCapture >= 60 ? .orange : .red)
                        Text("Price Capture")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    
                    VStack {
                        Text("$\(String(format: "%.0f", peak.peakEarnings / 100))")
                            .font(.title3.bold())
                            .foregroundStyle(.green)
                        Text("Peak Earnings")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    
    // MARK: - Spread Card
    
    private func spreadCard(_ result: DecisionEfficiencyResult) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.purple)
                Text("Arbitrage Spread")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Realized")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(String(format: "%.1f", result.realizedSpread))¢/kWh")
                        .font(.title3.bold())
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Theoretical Best")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(String(format: "%.1f", result.theoreticalSpread))¢/kWh")
                        .font(.title3.bold())
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Capture")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(String(format: "%.0f", result.spreadCaptureEfficiency))%")
                        .font(.title3.bold())
                        .foregroundStyle(result.spreadCaptureEfficiency >= 70 ? .green : .orange)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Achieved Opportunities Card

    private func achievedOpportunitiesCard(_ achieved: AchievedOpportunitiesAnalysis) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Achieved Opportunities")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            if achieved.achievedHighExports > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("High-price exports:")
                            .foregroundStyle(.secondary)
                        Text("\(achieved.achievedHighExports)")
                            .bold()
                        Spacer()
                        Text("$\(String(format: "%.0f", achieved.achievedHighExportValue))")
                            .foregroundStyle(.green)
                    }
                    .font(.subheadline)
                    
                    Text("Periods ≥20¢ where you successfully exported")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    // Expandable list of top achieved exports
                    if !achieved.topAchievedExports.isEmpty {
                        VStack(spacing: 0) {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showAchievedOpportunitiesList.toggle()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: showAchievedOpportunitiesList ? "chevron.down" : "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 12)
                                    Text("Top \(achieved.topAchievedExports.count) by price")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            
                            if showAchievedOpportunitiesList {
                                Divider()
                                    .padding(.leading, 8)
                                
                                ForEach(achieved.topAchievedExports) { opportunity in
                                    AchievedOpportunityRow(
                                        opportunity: opportunity,
                                        isExpanded: expandedAchievedOpportunities.contains(opportunity.timestamp),
                                        onToggle: {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                if expandedAchievedOpportunities.contains(opportunity.timestamp) {
                                                    expandedAchievedOpportunities.remove(opportunity.timestamp)
                                                } else {
                                                    expandedAchievedOpportunities.insert(opportunity.timestamp)
                                                }
                                            }
                                        }
                                    )
                                    
                                    if opportunity.id != achieved.topAchievedExports.last?.id {
                                        Divider()
                                            .padding(.leading, 8)
                                    }
                                }
                            }
                        }
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(8)
                    }
                }
            }
            
            if achieved.achievedCheapImports > 0 {
                if achieved.achievedHighExports > 0 {
                    Divider()
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Cheap imports:")
                            .foregroundStyle(.secondary)
                        Text("\(achieved.achievedCheapImports)")
                            .bold()
                        Spacer()
                        Text("$\(String(format: "%.0f", achieved.achievedCheapImportCost))")
                            .foregroundStyle(.green)
                    }
                    .font(.subheadline)
                    
                    Text("Periods ≤5¢ where you successfully imported")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Missed Opportunities Card

    private func missedOpportunitiesCard(_ missed: MissedOpportunitiesAnalysis) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Missed Opportunities")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            if missed.missedHighExports > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Missed high-price exports:")
                            .foregroundStyle(.secondary)
                        Text("\(missed.missedHighExports)")
                            .bold()
                        Spacer()
                        Text("~$\(String(format: "%.0f", missed.missedHighExportValue))")
                            .foregroundStyle(.orange)
                    }
                    .font(.subheadline)
                    
                    Text("Periods ≥20¢ where you had battery above floor but didn't export")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    // Apple Intelligence Summary - always visible
                    if missed.topMissedExports.count >= 3 {
                        MissedOpportunitiesAISummary(opportunities: missed.topMissedExports)
                    }
                    
                    // Expandable list of top missed exports
                    if !missed.topMissedExports.isEmpty {
                        VStack(spacing: 0) {
                            // Chevron header to show/hide list
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showMissedOpportunitiesList.toggle()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: showMissedOpportunitiesList ? "chevron.down" : "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 12)
                                    Text("Top \(missed.topMissedExports.count) by price")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.vertical, 8)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            
                            if showMissedOpportunitiesList {
                                Divider()
                                    .padding(.leading, 8)
                                
                                ForEach(missed.topMissedExports) { opportunity in
                                    MissedOpportunityRow(
                                        opportunity: opportunity,
                                        isExpanded: expandedMissedOpportunities.contains(opportunity.timestamp),
                                        onToggle: {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                if expandedMissedOpportunities.contains(opportunity.timestamp) {
                                                    expandedMissedOpportunities.remove(opportunity.timestamp)
                                                } else {
                                                    expandedMissedOpportunities.insert(opportunity.timestamp)
                                                }
                                            }
                                        }
                                    )
                                    
                                    if opportunity.id != missed.topMissedExports.last?.id {
                                        Divider()
                                            .padding(.leading, 8)
                                    }
                                }
                            }
                        }
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(8)
                    }
                }
            }
            
            if missed.missedCheapImports > 0 {
                if missed.missedHighExports > 0 {
                    Divider()
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Missed cheap imports:")
                            .foregroundStyle(.secondary)
                        Text("\(missed.missedCheapImports)")
                            .bold()
                        Spacer()
                    }
                    .font(.subheadline)
                    
                    Text("Periods ≤5¢ where you needed charge but didn't import")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Actions Section
    
    private func actionsSection(_ result: DecisionEfficiencyResult) -> some View {
        VStack(spacing: 12) {
            Button {
                Task { await runAnalysis() }
            } label: {
                Label("Refresh Analysis", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                Text("Analysis based on \(result.daysAnalyzed) days ending yesterday. Results cached for 24 hours.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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
    
    private func checkDataAndLoadCached() {
        guard let config = config else { return }
        
        // Try to load cached result first
        if let cached: DecisionEfficiencyResult = analysis.getCachedResult(config: config) {
            analysis.result = cached
            return
        }
        
        // Check if we have forecast data in existing records
        let range = dataStore.getDataRange(siteId: config.siteId)
        if range.count > 0 {
            // We have data, but we need to check if it has forecast data
            // This will be determined when analysis runs
            // For now, just show the start analysis screen
        }
    }
    
    private func runAnalysis() async {
        guard let config = config, !inverterIds.isEmpty else { return }

        // Check data availability using day_rates canary
        await api.refreshLatestCompleteDataDate()
        let latestCompleteDate = api.latestCompleteDataDate

        var calendar = Calendar.current
        calendar.timeZone = config.timezone

        // Use latestCompleteDate for the end date, falling back to yesterday
        let effectiveEndDate = latestCompleteDate ?? calendar.date(byAdding: .day, value: -1, to: Date())!

        // Check how many days need fetching
        let missingCount = dataStore.missingDayCount(
            siteId: config.siteId,
            from: calendar.date(byAdding: .day, value: -config.analysisWindowDays, to: effectiveEndDate)!,
            to: effectiveEndDate
        )

        if missingCount > 0 {
            // Show initial progress before sync starts
            syncProgress = SyncProgress(
                currentDay: 0,
                totalDays: missingCount,
                recordsFetched: 0,
                status: "Fetching \(missingCount) missing days..."
            )
        }

        // Prepare data (sync missing days)
        let result = await dataStore.prepareForAnalysis(
            config: config,
            inverterIds: inverterIds
        ) { progress in
            Task { @MainActor in
                self.syncProgress = progress
            }
        }

        await MainActor.run {
            syncProgress = nil
            syncResult = result
        }

        // Run analysis with data availability check
        let analysisResult = await analysis.analyzeDecisionEfficiency(config: config, latestCompleteDataDate: latestCompleteDate)
        
        // Check if we need resync (insufficient forecast data)
        if analysisResult == nil && analysis.error?.contains("forecast") == true {
            await MainActor.run {
                needsResync = true
            }
        }
    }
    
    private func resyncAndAnalyze() async {
        guard let config = config, !inverterIds.isEmpty else { return }
        
        await MainActor.run {
            needsResync = false
        }
        
        // Clear existing data for this site to force full re-fetch
        await MainActor.run {
            dataStore.clearSiteData(siteId: config.siteId)
        }
        
        // Now run normal analysis flow which will fetch fresh data
        await runAnalysis()
    }
}

// MARK: - Compact Card (for embedding in Profit Intelligence hub)

struct DecisionEfficiencyCard: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var analysis = DecisionEfficiencyAnalysis()
    
    @State private var showingFullAnalysis = false
    
    var config: AnalysisConfig? {
        guard let site = api.selectedSite else { return nil }
        return AnalysisConfig.from(site: site)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "gauge.with.needle.fill")
                    .foregroundStyle(.blue)
                Text("Decision Efficiency")
                    .font(.headline)
                Spacer()
                
                Button {
                    showingFullAnalysis = true
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            if let result = analysis.result {
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("Score")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(result.grade)
                                .font(.title3.bold())
                                .foregroundStyle(gradeColor(result.grade))
                            Text("(\(result.overallScore)%)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Divider()
                        .frame(height: 30)
                    
                    VStack(alignment: .leading) {
                        Text("Export Capture")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let capture = result.exportAnalysis.priceCapture {
                            Text("\(String(format: "%.0f", capture))%")
                                .font(.title3.bold())
                                .foregroundStyle(capture >= 80 ? .green : .orange)
                        } else {
                            Text("—")
                                .font(.title3.bold())
                        }
                    }
                    
                    Divider()
                        .frame(height: 30)
                    
                    VStack(alignment: .leading) {
                        Text("Peak Capture")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.0f", result.peakAnalysis.highPriceCaptureRate))%")
                            .font(.title3.bold())
                            .foregroundStyle(result.peakAnalysis.highPriceCaptureRate >= 80 ? .green : .orange)
                    }
                    
                    Spacer()
                }
            } else if api.isDemoMode {
                Text("Not available in demo mode")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Button("Run Analysis") {
                    showingFullAnalysis = true
                }
                .font(.subheadline)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $showingFullAnalysis) {
            NavigationStack {
                DecisionEfficiencyView()
                    .environmentObject(api)
            }
        }
        .onAppear {
            if let config = config {
                if let cached: DecisionEfficiencyResult = analysis.getCachedResult(config: config) {
                    analysis.result = cached
                }
            }
        }
    }
    
    private func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "A": return .green
        case "B+", "B": return .blue
        case "C+", "C": return .orange
        default: return .red
        }
    }
}

// MARK: - Achieved Opportunity Row

struct AchievedOpportunityRow: View {
    let opportunity: DecisionAchievedOpportunity
    let isExpanded: Bool
    let onToggle: () -> Void

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        f.timeZone = powstonTimezone()
        return f
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row - always visible
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dateFormatter.string(from: opportunity.timestamp))
                            .font(.caption)
                        
                        HStack(spacing: 4) {
                            Text("\(String(format: "%.1f", opportunity.price))¢")
                                .font(.caption.bold())
                                .foregroundStyle(.green)
                            
                            Text("•")
                                .foregroundStyle(.tertiary)
                            
                            Text("\(String(format: "%.2f", opportunity.energyKwh)) kWh")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            Text("•")
                                .foregroundStyle(.tertiary)
                            
                            Text("SOC \(String(format: "%.0f", opportunity.soc))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer()
                    
                    Text("$\(String(format: "%.2f", opportunity.earnings))")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    // Context info
                    HStack(spacing: 12) {
                        if let floor = opportunity.floor {
                            Label("Floor: \(String(format: "%.0f", floor))%", systemImage: "arrow.down.to.line")
                        }
                        if let houseLoad = opportunity.houseLoadKw {
                            Label("House: \(String(format: "%.1f", houseLoad))kW", systemImage: "house")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    
                    // Decision chain
                    if let chain = opportunity.parsedDecisionChain {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Decision Chain:")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                            
                            ForEach(Array(chain.enumerated()), id: \.offset) { index, decision in
                                if let priority = decision["priority"] as? Int,
                                   let action = decision["action"] as? String,
                                   let reason = decision["reason"] as? String,
                                   let applied = decision["applied"] as? Bool {
                                    HStack(alignment: .top, spacing: 4) {
                                        Text("P\(priority)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(applied ? .green : .secondary)
                                        
                                        Image(systemName: applied ? "checkmark.circle.fill" : "circle")
                                            .font(.caption2)
                                            .foregroundStyle(applied ? .green : .secondary)
                                        
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(action)
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(applied ? .primary : .secondary)
                                            Text(reason)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                            }
                            
                            if let final = opportunity.finalDecision {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("Final: \(final.action)")
                                        .fontWeight(.medium)
                                    Text("(P\(final.priority))")
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption2)
                                .padding(.top, 2)
                            }
                        }
                    } else if let reason = opportunity.reason {
                        Text("Reason: \(reason)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 8)
            }
        }
    }
}

// MARK: - Missed Opportunity Row

struct MissedOpportunityRow: View {
    let opportunity: DecisionMissedOpportunity
    let isExpanded: Bool
    let onToggle: () -> Void
    
    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        f.timeZone = powstonTimezone()
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed row - always visible
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    
                    Text(timeFormatter.string(from: opportunity.timestamp))
                        .font(.caption)
                        .foregroundStyle(.primary)
                    
                    Spacer()
                    
                    Text("\(String(format: "%.1f", opportunity.price))¢")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    
                    if let potentialKwh = opportunity.potentialExportKwh {
                        Text("~\(String(format: "%.1f", potentialKwh)) kWh")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Text("$\(String(format: "%.2f", opportunity.estimatedMissedValue))")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Context info
                    HStack(spacing: 16) {
                        Label("\(String(format: "%.0f", opportunity.soc))% SOC", systemImage: "battery.75percent")
                        if let floor = opportunity.floor {
                            Label("\(String(format: "%.0f", floor))% floor", systemImage: "arrow.down.to.line")
                        }
                        if let houseLoad = opportunity.houseLoadKw {
                            Label("\(String(format: "%.1f", houseLoad)) kW load", systemImage: "house")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    
                    // Decision Chain (structured, from valuesJson)
                    if let decisions = opportunity.parsedDecisionChain {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Decision Chain")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            
                            ForEach(Array(decisions.enumerated()), id: \.offset) { index, decision in
                                MissedOpportunityDecisionRow(decision: decision)
                            }
                            
                            if let final = opportunity.finalDecision {
                                HStack(spacing: 4) {
                                    Text("Final:")
                                        .font(.caption.weight(.semibold))
                                    Text(final.action.uppercased())
                                        .font(.caption.weight(.bold))
                                        .foregroundColor(actionColor(final.action))
                                    Text("(P\(final.priority))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                    
                    // Raw reason (always show if available, as it may have additional context)
                    if let reason = opportunity.reason, !reason.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            // Only show header if we also showed decision chain above
                            if opportunity.parsedDecisionChain != nil {
                                Text("Raw Reason")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("Reason")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(opportunity.parsedDecisionChain != nil ? .secondary : .primary)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .padding(.leading, 24) // Align with content after chevron
            }
        }
    }
    
    private func actionColor(_ action: String) -> Color {
        switch action.lowercased() {
        case "import", "charge": return .blue
        case "export", "discharge": return .green
        case "auto": return .gray
        case "curtail": return .orange
        default: return .gray
        }
    }
}

// MARK: - Decision Row for Missed Opportunity

struct MissedOpportunityDecisionRow: View {
    let decision: [String: Any]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Priority badge
                if let priority = decision["priority"] as? Int {
                    Text("P-\(priority)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(priorityColor(priority).opacity(0.2))
                        .foregroundColor(priorityColor(priority))
                        .cornerRadius(4)
                }
                
                // Action
                if let action = decision["action"] as? String {
                    Text(action.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(actionColor(action))
                }
                
                // Applied indicator
                if let applied = decision["applied"] as? Bool {
                    Image(systemName: applied ? "checkmark.circle.fill" : "circle")
                        .font(.caption2)
                        .foregroundColor(applied ? .green : .secondary)
                }
                
                Spacer()
            }
            
            // Reason
            if let reason = decision["reason"] as? String {
                Text(cleanReason(reason))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(6)
    }
    
    private func priorityColor(_ priority: Int) -> Color {
        if priority >= 80 { return .red }
        if priority >= 60 { return .orange }
        if priority >= 40 { return .yellow }
        return .gray
    }
    
    private func actionColor(_ action: String) -> Color {
        switch action.lowercased() {
        case "import", "charge": return .blue
        case "export", "discharge": return .green
        case "auto": return .gray
        case "curtail": return .orange
        default: return .gray
        }
    }
    
    private func cleanReason(_ reason: String) -> String {
        reason
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .components(separatedBy: "\n").first ?? reason
    }
}

// MARK: - Apple Intelligence Summary

// MARK: - Apple Intelligence Summary

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GenerableMissedOpportunitySummary {
    /// Primary reason exports were blocked, e.g. "Floor logic blocked 45% of opportunities"
    let primaryBlocker: String
    /// Secondary contributing factors if any, otherwise nil
    let secondaryFactors: String?
}

struct MissedOpportunitiesAISummary: View {
    let opportunities: [DecisionMissedOpportunity]
    
    @AppStorage("enableAppleIntelligence") private var enableAppleIntelligence: Bool = true
    @State private var aiSummary: String?
    @State private var isGenerating = false
    
    private var opportunitiesWithReasons: Int {
        opportunities.filter { $0.parsedDecisionChain != nil || $0.reason != nil }.count
    }
    
    private var summaryPrompt: String {
        var prompt = """
        Analyze these missed solar battery export opportunities. Each shows why the system didn't export despite high prices (≥20¢/kWh).
        
        Missed opportunities (\(opportunities.count) total):
        """
        
        for (index, opp) in opportunities.prefix(10).enumerated() {
            prompt += "\n\n\(index + 1). \(formatDate(opp.timestamp)) at \(String(format: "%.1f", opp.price))¢:"
            prompt += "\n   SOC: \(String(format: "%.0f", opp.soc))%, Floor: \(String(format: "%.0f", opp.floor ?? 0))%"
            
            if let chain = opp.parsedDecisionChain {
                for decision in chain {
                    if let priority = decision["priority"] as? Int,
                       let action = decision["action"] as? String,
                       let reason = decision["reason"] as? String {
                        prompt += "\n   P\(priority) \(action): \(reason)"
                    }
                }
                if let final = opp.finalDecision {
                    prompt += "\n   → Final: \(final.action) (P\(final.priority))"
                }
            } else if let reason = opp.reason {
                prompt += "\n   Reason: \(reason)"
            }
        }
        
        prompt += """
        
        
        Summarize the blocking patterns. Be concise and technical. Describe what happened, not what to do about it.
        """
        
        return prompt
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if enableAppleIntelligence {
                    AppleIntelligenceIndicator()
                }
                Text("Root Cause Analysis")
                    .font(.caption.weight(.medium))
                Spacer()
                if opportunitiesWithReasons < opportunities.count {
                    Text("\(opportunitiesWithReasons)/\(opportunities.count) with details")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            
            if let summary = aiSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .padding(10)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(8)
            } else if isGenerating {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Analyzing decision patterns...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
            }
        }
        .padding(.top, 4)
        .onAppear {
            if aiSummary == nil && !isGenerating {
                generateSummary()
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        f.timeZone = powstonTimezone()
        return f.string(from: date)
    }
    
    private func generateSummary() {
        guard !isGenerating else { return }
        isGenerating = true
        
        Task {
            let result: String
            if enableAppleIntelligence {
                result = await generateWithFoundationModels()
            } else {
                result = generateLocalSummary()
            }
            await MainActor.run {
                aiSummary = result
                isGenerating = false
            }
        }
    }
    
    private func generateWithFoundationModels() async -> String {
        if #available(iOS 26.0, macOS 26.0, *) {
            let availability = SystemLanguageModel.default.availability
            guard case .available = availability else {
                return generateLocalSummary()
            }
            
            do {
                let session = LanguageModelSession(instructions: """
                    You are analyzing a home battery system's missed export opportunities.
                    Focus on decision logic patterns. Be direct and technical.
                    Describe what blocked exports, with percentages when patterns are clear.
                    Do NOT give advice or recommendations. Just describe what happened.
                    """)
                
                let response = try await session.respond(
                    to: summaryPrompt,
                    generating: GenerableMissedOpportunitySummary.self
                )
                
                let generated = response.content
                var parts: [String] = []
                
                parts.append(generated.primaryBlocker)
                
                if let secondary = generated.secondaryFactors, !secondary.isEmpty {
                    parts.append(secondary)
                }
                
                return parts.joined(separator: " ")
            } catch {
                print("⚠️ Foundation Models error: \(error)")
                return generateLocalSummary()
            }
        } else {
            return generateLocalSummary()
        }
    }
    
    /// Generate a basic summary locally when Apple Intelligence isn't available or disabled
    private func generateLocalSummary() -> String {
        var reasonCounts: [String: Int] = [:]
        
        for opp in opportunities {
            var foundReason = false
            
            if let chain = opp.parsedDecisionChain {
                for decision in chain {
                    if let reason = decision["reason"] as? String,
                       let applied = decision["applied"] as? Bool,
                       !applied {
                        let key = extractReasonKey(reason)
                        reasonCounts[key, default: 0] += 1
                        foundReason = true
                        break
                    }
                }
            }
            
            if !foundReason, let reason = opp.reason {
                let key = extractReasonKey(reason)
                reasonCounts[key, default: 0] += 1
            }
        }
        
        let totalMisses = opportunities.count
        guard totalMisses > 0, !reasonCounts.isEmpty else {
            return "Insufficient decision data."
        }
        
        let sorted = reasonCounts
            .map { (reason: $0.key, count: $0.value, pct: Int(Double($0.value) / Double(totalMisses) * 100)) }
            .sorted { $0.count > $1.count }
            .filter { $0.pct >= 5 }
            .prefix(3)
        
        let parts = sorted.map { "\($0.reason) (\($0.pct)%)" }
        return parts.isEmpty ? "Mixed factors" : parts.joined(separator: ", ")
    }
    
    private func extractReasonKey(_ reason: String) -> String {
        let lowered = reason.lowercased()
        
        if lowered.contains("floor") && lowered.contains("soc") {
            return "Floor SOC limit"
        } else if lowered.contains("floor") {
            return "Floor logic"
        } else if lowered.contains("near floor") || lowered.contains("holding") {
            return "Holding near floor"
        } else if lowered.contains("not optimal") || lowered.contains("waiting") {
            return "Waiting for better price"
        } else if lowered.contains("deficit") {
            return "Daytime deficit"
        } else if lowered.contains("physics") {
            return "Physics constraints"
        } else if lowered.contains("overnight") {
            return "Overnight protection"
        } else if lowered.contains("ultra cheap") || lowered.contains("negative") {
            return "Charging opportunity"
        } else if lowered.contains("trickle") {
            return "At floor (trickle)"
        } else if lowered.contains("auto") && lowered.contains("mode") {
            return "Auto mode"
        } else if lowered.contains("low") && lowered.contains("soc") {
            return "Low SOC"
        }
        
        let cleaned = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 20 ? String(cleaned.prefix(17)) + "..." : cleaned
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        DecisionEfficiencyView()
            .environmentObject(PowstonAPI())
    }
}
