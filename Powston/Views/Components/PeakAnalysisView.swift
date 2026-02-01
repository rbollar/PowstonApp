//
//  PeakAnalysisView.swift
//  Powston
//
//  SwiftUI view for peak export profitability analysis
//  Displays results from ArbitrageAnalysis engine
//

import SwiftUI

// MARK: - Main Analysis View

struct PeakAnalysisView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var analysis = ArbitrageAnalysis()
    @StateObject private var dataStore = PowstonDataStore.shared
    
    @State private var syncProgress: SyncProgress?
    @State private var showingReport = false
    
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
                // Header
                headerSection
                
                if dataStore.isSyncing {
                    syncProgressSection
                } else if analysis.isAnalyzing {
                    analyzingSection
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
        .navigationTitle("Peak Export Analysis")
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
            // Check for cached result
            if let config = config, analysis.result == nil {
                if let cached: PeakAnalysisResult = analysis.getCachedResult(config: config) {
                    analysis.result = cached
                }
            }
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            
            Text("Peak Export Profitability")
                .font(.title2.bold())
            
            if let config = config {
                Text("Analyzes exports during peak hours (\(config.peakStartHour):00–\(config.peakEndHour):00)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical)
    }
    
    // MARK: - Sync Progress
    
    private var syncProgressSection: some View {
        VStack(spacing: 16) {
            ProgressView(value: syncProgress?.percentComplete ?? 0)
                .progressViewStyle(.linear)
            
            Text(syncProgress?.displayText ?? "Syncing data...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            if let progress = syncProgress {
                Text("\(progress.recordsFetched.formatted()) records fetched")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
    
    // MARK: - Start Analysis
    
    private var startAnalysisSection: some View {
        VStack(spacing: 16) {
            if let config = config {
                // Data availability
                let range = dataStore.getDataRange(siteId: config.siteId)
                let missingDays = dataStore.missingDayCount(
                    siteId: config.siteId,
                    from: Calendar.current.date(byAdding: .day, value: -config.analysisWindowDays, to: Date())!,
                    to: Calendar.current.date(byAdding: .day, value: -1, to: Date())!
                )
                
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
                    
                    if missingDays > 0 {
                        HStack {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.orange)
                            Text("\(missingDays) days will be fetched")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                        }
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                
                // Analysis parameters
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "gearshape")
                        Text("Analysis Parameters")
                            .font(.headline)
                        Spacer()
                    }
                    
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                        GridRow {
                            Text("Window")
                                .foregroundStyle(.secondary)
                            Text("\(config.analysisWindowDays) days")
                        }
                        GridRow {
                            Text("Peak Hours")
                                .foregroundStyle(.secondary)
                            Text("\(config.peakStartHour):00 – \(config.peakEndHour):00")
                        }
                        GridRow {
                            Text("Battery")
                                .foregroundStyle(.secondary)
                            Text("\(String(format: "%.1f", config.batteryCapacityKWh)) kWh @ \(Int(config.batteryEfficiency * 100))%")
                        }
                    }
                    .font(.subheadline)
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
            .tint(.orange)
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
            
            Button("Try Again") {
                Task { await runAnalysis() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Results
    
    @ViewBuilder
    private func resultsSections(_ result: PeakAnalysisResult) -> some View {
        // Summary Card
        summaryCard(result)
        
        // Optimal Floor Card
        optimalFloorCard(result.floorAnalysis)
        
        // Price Buckets
        priceBucketsSection(result.bucketAnalysis)
        
        // Source Breakdown
        sourceBreakdownSection(result.sourceBreakdown)
        
        // Actions
        actionsSection(result)
    }
    
    // MARK: - Summary Card
    
    private func summaryCard(_ result: PeakAnalysisResult) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                Text("Summary")
                    .font(.headline)
                Spacer()
                Text("\(result.config.analysisWindowDays) days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            HStack(spacing: 24) {
                VStack {
                    Text("\(result.totalExports)")
                        .font(.title2.bold())
                    Text("Exports")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                VStack {
                    Text("\(String(format: "%.0f", result.totalKwh))")
                        .font(.title2.bold())
                    Text("kWh")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                VStack {
                    Text("\(String(format: "%.0f", result.profitablePercent))%")
                        .font(.title2.bold())
                        .foregroundStyle(result.profitablePercent >= 50 ? .green : .orange)
                    Text("Profitable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                VStack {
                    Text("$\(String(format: "%.2f", result.totalProfitDollars))")
                        .font(.title2.bold())
                        .foregroundStyle(result.totalProfitDollars >= 0 ? .green : .red)
                    Text("Net Profit")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Optimal Floor Card
    
    private func optimalFloorCard(_ floor: FloorAnalysis) -> some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                Text("Optimal Sell Floor")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Int(floor.optimalFloorPrice))¢")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                    Text("Recommended minimum")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 8) {
                    HStack {
                        Text("Current profit:")
                            .foregroundStyle(.secondary)
                        Text("$\(String(format: "%.2f", floor.baseProfitCents / 100))")
                    }
                    HStack {
                        Text("With floor:")
                            .foregroundStyle(.secondary)
                        Text("$\(String(format: "%.2f", floor.optimalProfitCents / 100))")
                            .foregroundStyle(.green)
                    }
                    HStack {
                        Text("Improvement:")
                            .foregroundStyle(.secondary)
                        Text("+$\(String(format: "%.2f", floor.improvementCents / 100))")
                            .bold()
                            .foregroundStyle(.green)
                    }
                }
                .font(.subheadline)
            }
            
            if floor.improvementCents > 0 {
                Text("Setting a \(Int(floor.optimalFloorPrice))¢ minimum sell price would have improved profit by \(String(format: "%.0f", floor.improvementPercent))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Price Buckets
    
    private func priceBucketsSection(_ buckets: [PriceBucketAnalysis]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.xaxis")
                Text("Profitability by Price")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            ForEach(buckets) { bucket in
                HStack(spacing: 12) {
                    Text(bucket.priceRange)
                        .font(.system(.subheadline, design: .monospaced))
                        .frame(width: 70, alignment: .leading)
                    
                    // Profitability bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color(.systemGray5))
                            
                            Rectangle()
                                .fill(bucket.isProfitable ? Color.green : Color.red.opacity(0.6))
                                .frame(width: geo.size.width * (bucket.profitablePercent / 100))
                        }
                    }
                    .frame(height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    
                    Text("\(String(format: "%+.1f", bucket.avgProfitCents))¢")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(bucket.isProfitable ? .green : .red)
                        .frame(width: 50, alignment: .trailing)
                    
                    Image(systemName: bucket.isProfitable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(bucket.isProfitable ? .green : .red)
                        .font(.caption)
                }
            }
            
            Text("Average profit/loss per kWh at each price range")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Source Breakdown
    
    private func sourceBreakdownSection(_ sources: [SourceBreakdown]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("Replacement Sources")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            ForEach(sources) { source in
                HStack {
                    Circle()
                        .fill(colorForSource(source.source))
                        .frame(width: 10, height: 10)
                    
                    Text(source.source.displayName)
                        .font(.subheadline)
                    
                    Spacer()
                    
                    Text("\(source.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Text("\(String(format: "%.0f", source.totalKwh)) kWh")
                        .font(.caption)
                        .frame(width: 60, alignment: .trailing)
                    
                    Text("\(String(format: "%+.1f", source.avgProfit))¢")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(source.avgProfit >= 0 ? .green : .red)
                        .frame(width: 50, alignment: .trailing)
                }
            }
            
            Text("How exported energy was replaced")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    private func colorForSource(_ source: ReplacementSource) -> Color {
        switch source {
        case .pv: return .green
        case .mixedPv: return .mint
        case .cheapGrid: return .blue
        case .expensiveGrid: return .orange
        case .unknown: return .gray
        }
    }
    
    // MARK: - Actions
    
    private func actionsSection(_ result: PeakAnalysisResult) -> some View {
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
                Text("Analysis based on \(result.config.analysisWindowDays) days ending yesterday. Results cached for 24 hours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Run Analysis
    
    private func runAnalysis() async {
        guard let config = config, !inverterIds.isEmpty else { return }
        
        // Prepare data (sync missing days)
        await dataStore.prepareForAnalysis(
            config: config,
            inverterIds: inverterIds
        ) { progress in
            Task { @MainActor in
                self.syncProgress = progress
            }
        }
        
        syncProgress = nil
        
        // Run analysis
        _ = await analysis.analyzePeakExports(config: config)
    }
}

// MARK: - Report Sheet

struct ReportSheet: View {
    let report: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("Analysis Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: report) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

// MARK: - Compact Analysis Card (for embedding in DecisionsView)

struct PeakAnalysisCard: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var analysis = ArbitrageAnalysis()
    
    @State private var showingFullAnalysis = false
    
    var config: AnalysisConfig? {
        guard let site = api.selectedSite else { return nil }
        return AnalysisConfig.from(site: site)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .foregroundStyle(.orange)
                Text("Peak Export Analysis")
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
                        Text("Optimal Floor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int(result.floorAnalysis.optimalFloorPrice))¢")
                            .font(.title3.bold())
                            .foregroundStyle(.orange)
                    }
                    
                    Divider()
                        .frame(height: 30)
                    
                    VStack(alignment: .leading) {
                        Text("Potential Gain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("+$\(String(format: "%.2f", result.improvementDollars))")
                            .font(.title3.bold())
                            .foregroundStyle(.green)
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
                PeakAnalysisView()
                    .environmentObject(api)
            }
        }
        .onAppear {
            // Load cached result
            if let config = config {
                if let cached: PeakAnalysisResult = analysis.getCachedResult(config: config) {
                    analysis.result = cached
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        PeakAnalysisView()
            .environmentObject(PowstonAPI())
    }
}
