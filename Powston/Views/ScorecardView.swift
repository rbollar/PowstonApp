//
//  ScorecardView.swift
//  Powston
//
//  Performance scorecard display with period picker and component drill-down
//

import SwiftUI

struct ScorecardView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var cache = ScorecardCache.shared
    @Environment(\.intelligentSummary) private var summaryService
    
    @State private var selectedPeriod: ScorecardPeriod = .day
    @State private var scorecard: Scorecard?
    @State private var isLoading = false
    @State private var selectedComponent: ScoreComponent?
    @State private var aiSummary: PerformanceSummaryOutput?
    @State private var isGeneratingSummary = false
    @State private var financialSummary: ScorecardFinancialSummary?
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    periodPicker
                    
                    if isLoading {
                        loadingView
                    } else if let scorecard = scorecard {
                        scorecardContent(scorecard)
                    } else {
                        emptyState
                    }
                }
                .padding()
            }
            .navigationTitle("Performance")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await refresh(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .task {
                await refresh()
            }
            .onChange(of: selectedPeriod) { _, _ in
                            aiSummary = nil  // Clear previous summary when period changes
                            financialSummary = nil  // Clear financial summary when period changes
                            Task { await refresh() }
                        }            .sheet(item: $selectedComponent) { component in
                ComponentDetailView(component: component, metrics: scorecard?.metrics)
            }
        }
    }
    
    private var periodPicker: some View {
        Picker("Period", selection: $selectedPeriod) {
            ForEach(ScorecardPeriod.allCases) { period in
                Text(period.rawValue).tag(period)
            }
        }
        .pickerStyle(.segmented)
    }
    
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(cache.loadingProgress)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
    
    private var emptyState: some View {
        ContentUnavailableView(
            "No Data",
            systemImage: "chart.bar.xaxis",
            description: Text("Unable to load performance data")
        )
    }
    
    @ViewBuilder
    private func scorecardContent(_ scorecard: Scorecard) -> some View {
        overallGradeCard(scorecard)
        
        // AI Summary section
        if let summary = aiSummary {
            aiSummaryCard(summary)
        } else if isGeneratingSummary {
            aiSummaryLoadingCard
        }
        
        componentScoresSection(scorecard)
        financialSummarySection(scorecard)
        keyMetricsSection(scorecard)
        if !scorecard.recommendations.isEmpty {
            recommendationsSection(scorecard)
        }
        if !scorecard.dailyGrades.isEmpty {
            recentPerformanceSection(scorecard)
        }
    }
    
    // MARK: - AI Summary Card
    
    private func aiSummaryCard(_ summary: PerformanceSummaryOutput) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                Text("Summary")
                    .font(.headline)
                Spacer()
            }
            
            Text(summary.headline)
                .font(.subheadline)
                .fontWeight(.semibold)
            
            Text(summary.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            if let missed = summary.missedOpportunityNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.caption)
                    Text(missed)
                        .font(.caption)
                }
                .foregroundStyle(.orange)
            }
            
            if let context = summary.contextNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption)
                    Text(context)
                        .font(.caption)
                }
                .foregroundStyle(.blue)
            }
            
            if let hint = summary.investigationHint {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                    Text(hint)
                        .font(.caption)
                }
                .foregroundStyle(.red)
            }
            
            if let advice = summary.actionableAdvice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "lightbulb")
                        .font(.caption)
                    Text(advice)
                        .font(.caption)
                }
                .foregroundStyle(.green)
            }
            
            // Apple Intelligence indicator at the end
            if summaryService.isAvailable {
                ScorecardAppleIntelligenceIndicator()
                    .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private var aiSummaryLoadingCard: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text("Generating summary...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            ProgressView()
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Existing Cards
    
    private func overallGradeCard(_ scorecard: Scorecard) -> some View {
        VStack(spacing: 8) {
            Text("Overall Grade")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(scorecard.overallGrade)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(gradeColor(scorecard.overallGrade))

                Text("(\(Int(scorecard.overallScore))/100)")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            // Show cohort position when available
            if let positionText = scorecard.cohortPositionText {
                HStack(spacing: 4) {
                    Image(systemName: "trophy.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                    Text(positionText)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(cohortRankColor(scorecard.cohortRank))
                    if scorecard.cohortAdjusted {
                        Text("(grade adjusted)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("\(scorecard.daysAnalyzed) \(scorecard.daysAnalyzed == 1 ? "day" : "days") analyzed")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(formatDateRange(scorecard.periodStart, scorecard.periodEnd))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func cohortRankColor(_ rank: Int?) -> Color {
        guard let rank = rank else { return .secondary }
        switch rank {
        case 1: return .yellow
        case 2: return .gray
        case 3: return .orange
        default: return .primary
        }
    }
    
    private func formatDateRange(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "Australia/Brisbane")
        
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        
        let dayAfterStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: start))!
        let isSingleDay = calendar.isDate(end, inSameDayAs: dayAfterStart) || calendar.isDate(start, inSameDayAs: end)
        
        if isSingleDay {
            formatter.dateFormat = "d MMM yyyy"
            return formatter.string(from: start)
        } else {
            formatter.dateFormat = "d MMM"
            let startStr = formatter.string(from: start)
            let inclusiveEnd = calendar.date(byAdding: .day, value: -1, to: end) ?? end
            formatter.dateFormat = "d MMM yyyy"
            let endStr = formatter.string(from: inclusiveEnd)
            return "\(startStr) – \(endStr)"
        }
    }
    
    private func componentScoresSection(_ scorecard: Scorecard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Component Scores")
                .font(.headline)
            
            ForEach(scorecard.components) { component in
                Button {
                    selectedComponent = component
                } label: {
                    componentRow(component)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private func componentRow(_ component: ScoreComponent) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(component.status)
                    Text(component.name)
                        .fontWeight(.medium)
                }
                Text(component.value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(component.grade)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(gradeColor(component.grade))
                Text("\(Int(component.score))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }
    
    private func financialSummarySection(_ scorecard: Scorecard) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Financial Summary")
                    .font(.headline)
                
                VStack(spacing: 8) {
                    // Use API-sourced financials if available, otherwise fall back to scorecard
                    if let fin = financialSummary {
                        // Total Earnings first (Sold)
                        financialRow("Total Earnings", value: fin.totalEarnings)
                        
                        // Total Costs with breakdown
                        financialRow("Total Costs", value: fin.totalCosts)
                        financialRow("  Energy Costs", value: fin.energyCosts, indent: true)
                        financialRow("  Supply Costs", value: fin.supplyCosts, indent: true)
                        
                        Divider()
                        
                        // Net Position - color only, no sign
                        HStack {
                            Text("Net Position")
                                .fontWeight(.semibold)
                            Spacer()
                            Text(formatCurrencyNoSign(fin.netPosition))
                                .fontWeight(.bold)
                                .foregroundStyle(fin.netPosition >= 0 ? .green : .red)
                        }
                        
                        if scorecard.daysAnalyzed > 1 {
                            Divider()
                            let dailyAvg = fin.netPosition / Double(scorecard.daysAnalyzed)
                            financialRowNoSign("Daily Average", value: dailyAvg)
                            financialRowNoSign("Monthly Projected", value: dailyAvg * 30)
                        }
                    } else {
                        // Fallback to scorecard-computed values
                        financialRow("Total Earnings", value: scorecard.earnings)
                        financialRow("Total Costs", value: scorecard.totalCost)
                        financialRow("  Supply Costs", value: scorecard.fixedCosts, indent: true)
                        financialRow("  Energy Costs", value: scorecard.energyCosts, indent: true)
                        
                        Divider()
                        
                        HStack {
                            Text("Net Position")
                                .fontWeight(.semibold)
                            Spacer()
                            Text(formatCurrencyNoSign(abs(scorecard.netPosition)))
                                .fontWeight(.bold)
                                .foregroundStyle(scorecard.netPosition <= 0 ? .green : .red)
                        }
                        
                        if scorecard.daysAnalyzed > 1 {
                            Divider()
                            financialRow("Daily Average", value: scorecard.dailyAverage)
                            financialRow("Monthly Projected", value: scorecard.monthlyProjected)
                        }
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    
    private func financialRow(_ label: String, value: Double, indent: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(indent ? .secondary : .primary)
            Spacer()
            Text(formatCurrency(value))
                .foregroundStyle(indent ? .secondary : .primary)
        }
        .font(indent ? .subheadline : .body)
    }
    
    private func keyMetricsSection(_ scorecard: Scorecard) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Key Metrics")
                    .font(.headline)
                
                let t = scorecard.metrics.timing
                let o = scorecard.metrics.overnight
                
                VStack(alignment: .leading, spacing: 6) {
                    // Use API-sourced financials for accurate rates if available
                    if let fin = financialSummary {
                        let importKwh = fin.totalImport
                        let exportKwh = fin.totalExport
                        // Calculate actual rates from API data (energy costs only, not including supply)
                        let avgBuyRate = importKwh > 0 ? (fin.energyCosts / importKwh) * 100 : 0  // Convert $/kWh to ¢/kWh
                        let avgSellRate = exportKwh > 0 ? (fin.totalEarnings / exportKwh) * 100 : 0
                        
                        Text("Import: \(formatKwh(importKwh)) @ \(String(format: "%.1f", avgBuyRate))¢ avg")
                        Text("Export: \(formatKwh(exportKwh)) @ \(String(format: "%.1f", avgSellRate))¢ avg")
                    } else {
                        // Fallback to scorecard timing metrics
                        Text("Import: \(Int(t.totalImportKwh)) kWh @ \(String(format: "%.1f", t.avgBuyRate))¢ avg")
                        Text("Export: \(Int(t.totalExportKwh)) kWh @ \(String(format: "%.1f", t.avgSellRate))¢ avg")
                    }
                    
                    Text("Peak Import: \(String(format: "%.1f", t.peakImportKwh)) kWh")
                    
                    Divider()
                    
                    Text("Avg 9 PM SOC: \(Int(o.avg9pmSoc))%")
                    Text("Avg 6 AM SOC: \(Int(o.avg6amSoc))%")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    
    private func recommendationsSection(_ scorecard: Scorecard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recommendations")
                .font(.headline)
            
            ForEach(scorecard.recommendations) { rec in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(rec.priorityIcon)
                        Text(rec.category)
                            .fontWeight(.medium)
                    }
                    Text(rec.action)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private func recentPerformanceSection(_ scorecard: Scorecard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Performance")
                .font(.headline)
            
            ForEach(scorecard.dailyGrades.suffix(7)) { day in
                HStack {
                    Text(day.date)
                        .font(.subheadline)
                    Spacer()
                    Text(formatCurrency(day.netCost))
                        .font(.subheadline)
                        .foregroundStyle(day.netCost <= 0 ? .green : .primary)
                    Text(day.grade)
                        .fontWeight(.medium)
                        .foregroundStyle(gradeColor(day.grade))
                    Text(day.gradeIcon)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    // MARK: - Data Loading
    
    private func refresh(force: Bool = false) async {
            guard let siteId = api.selectedSiteId else { return }
            isLoading = true
            
            // Fetch scorecard (also fetches and caches financial summary)
            scorecard = await cache.getScorecard(
                siteId: siteId,
                period: selectedPeriod,
                api: api,
                forceRefresh: force
            )
            
            // Get the cached financial summary
            financialSummary = cache.getFinancialSummary(siteId: siteId, period: selectedPeriod)
            
            isLoading = false
            
            // Generate AI summary after scorecard loads
            if let sc = scorecard {
                await generateAISummary(for: sc)
            }
        }
    
    private func generateAISummary(for scorecard: Scorecard) async {
        isGeneratingSummary = true
        
        let batteryCapacity = Double(api.selectedSite?.installedBattery ?? 0) / 1000.0
        let inverterCapacity = Double(api.selectedSite?.inverterPower ?? 0) / 1000.0
        
        let input = PerformanceSummaryBuilder(
            scorecard: scorecard,
            period: selectedPeriod,
            batteryCapacityKWh: batteryCapacity > 0 ? batteryCapacity : nil,
            inverterCapacityKw: inverterCapacity > 0 ? inverterCapacity : nil
        ).build()
        
        aiSummary = await summaryService.generatePerformanceSummary(from: input)
        isGeneratingSummary = false
    }
    
    // MARK: - Helpers
    
    private func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "A", "A+": return .green
        case "B+", "B": return .blue
        case "C+", "C": return .orange
        default: return .red
        }
    }
    
    private func formatCurrency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
    
    private func formatCurrencyNoSign(_ value: Double) -> String {
            String(format: "$%.2f", abs(value))
        }
        
        private func financialRowNoSign(_ label: String, value: Double) -> some View {
            HStack {
                Text(label)
                Spacer()
                Text(formatCurrencyNoSign(value))
                    .foregroundStyle(value >= 0 ? .green : .red)
            }
            .font(.body)
        }
    
    private func formatKwh(_ value: Double) -> String {
            if value >= 1000 {
                return "\(Int(value)) kWh"
            } else {
                return "\(Int(round(value))) kWh"
            }
        }
}

// MARK: - Component Detail View

struct ComponentDetailView: View {
    let component: ScoreComponent
    let metrics: ScorecardMetrics?
    
    @Environment(\.dismiss) private var dismiss
    @AppStorage("peak_start_hour") private var peakStartHour: Double = 16.0
    @AppStorage("peak_end_hour") private var peakEndHour: Double = 21.0
    
    private var peakHoursText: String {
        let s = Int(peakStartHour), e = Int(peakEndHour)
        return "\(s > 12 ? s-12 : s) \(s >= 12 ? "PM" : "AM") – \(e > 12 ? e-12 : e) \(e >= 12 ? "PM" : "AM")"
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    explanationCard
                    if let metrics = metrics {
                        detailsCard(metrics)
                    }
                    scoringCard
                }
                .padding()
            }
            .navigationTitle(component.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
    
    private var headerCard: some View {
        VStack(spacing: 8) {
            Text(component.status).font(.largeTitle)
            Text(component.name).font(.title).fontWeight(.bold)
            HStack(spacing: 16) {
                Text(component.grade)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(gradeColor(component.grade))
                VStack(alignment: .leading) {
                    Text("\(Int(component.score))/100").font(.title2)
                    Text(component.value).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What This Measures").font(.headline)
            Text(explanationText).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private func detailsCard(_ metrics: ScorecardMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Details").font(.headline)
            Text(component.detail).foregroundStyle(.secondary)
            componentMetrics(metrics)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private var scoringCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How It's Scored").font(.headline)
            Text(scoringExplanation).foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
    
    private var explanationText: String {
        switch component.name {
        case "Timing Efficiency":
            if let t = metrics?.timing, t.usedCohortBenchmark {
                return "Compares your performance against the top performer in your cohort (similar battery size and state). This is a real-world benchmark — someone actually achieved it."
            }
            return "Compares your actual import/export performance against the theoretical optimal. How close did you get to the best possible strategy?"
        case "Peak Avoidance":
            return "Tracks how well you avoid importing during peak hours (\(peakHoursText))."
        case "Overnight Efficiency":
            return "Measures how often you needed to import overnight (9 PM - 6 AM)."
        case "Morning Survival":
            return "Tracks whether your battery survives from 6 AM until solar kicks in or cheap rates arrive."
        case "Opportunity Capture":
            return "Measures how well you capture price opportunities — high export and low/negative import prices."
        default:
            return component.detail
        }
    }
    
    private var scoringExplanation: String {
        switch component.name {
        case "Timing Efficiency":
            if let t = metrics?.timing, t.usedCohortBenchmark, let eff = t.cohortBestEfficiency {
                return "Compared against cohort leader (\(String(format: "%.1f", eff))¢/kWh). Profitable = passing grade (50+)."
            }
            return "Profitable = passing grade (50+). Bonus based on efficiency vs theoretical optimal."
        case "Peak Avoidance":
            return "Score = avoidance percentage. 100% avoidance = 100 points."
        case "Overnight Efficiency":
            return "Score based on percentage of nights without significant imports."
        case "Morning Survival":
            return "Score = survival rate. Target 80%+ for B+ grade."
        case "Opportunity Capture":
            return "Combines export spike capture (≥15¢) and cheap import capture (<2¢)."
        default:
            return "Higher scores = better performance."
        }
    }
    
    @ViewBuilder
    private func componentMetrics(_ metrics: ScorecardMetrics) -> some View {
        switch component.name {
        case "Timing Efficiency":
            timingMetrics(metrics.timing)
        case "Peak Avoidance":
            peakMetrics(metrics.timing)
        case "Overnight Efficiency":
            overnightMetrics(metrics.overnight)
        case "Morning Survival":
            survivalMetrics(metrics.overnight)
        case "Opportunity Capture":
            opportunityMetrics(metrics.opportunities)
        default:
            EmptyView()
        }
    }
    
    private func timingMetrics(_ t: TimingMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("Your Performance").font(.subheadline).fontWeight(.medium)
            metricRow("Import Cost", String(format: "$%.2f", t.actualImportCost / 100))
            metricRow("Export Revenue", String(format: "$%.2f", t.actualExportRevenue / 100))
            metricRow("Net Profit", String(format: "$%.2f", t.actualNet / 100))
            
            Divider()
            if t.usedCohortBenchmark {
                HStack {
                    Image(systemName: "person.3.fill").foregroundStyle(.blue)
                    Text("Cohort Leader Benchmark").font(.subheadline).fontWeight(.medium)
                }
                if let eff = t.cohortBestEfficiency {
                    metricRow("Leader Efficiency", "\(String(format: "%.1f", eff))¢/kWh")
                }
                metricRow("Benchmark Net", String(format: "$%.2f", t.optimalNet / 100))
            } else {
                Text("Optimal (Hindsight)").font(.subheadline).fontWeight(.medium)
                metricRow("Best Net Profit", String(format: "$%.2f", t.optimalNet / 100))
            }
            
            Divider()
            metricRow("Efficiency", "\(String(format: "%.0f", t.efficiencyPct))% of \(t.usedCohortBenchmark ? "cohort best" : "optimal")")
        }
    }
    
    private func peakMetrics(_ t: TimingMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            metricRow("Peak Import", "\(String(format: "%.1f", t.peakImportKwh)) kWh")
            metricRow("Avoidance Rate", "\(String(format: "%.1f", t.peakAvoidancePct))%")
        }
    }
    
    private func overnightMetrics(_ o: OvernightMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            metricRow("Nights Analyzed", "\(o.nightsAnalyzed)")
            metricRow("Nights with Imports", "\(o.nightsWithImports)")
            metricRow("Total Overnight", "\(Int(o.overnightImportKwh)) kWh")
        }
    }
    
    private func survivalMetrics(_ o: OvernightMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            metricRow("Mornings Survived", "\(o.morningSurvivals)")
            metricRow("Mornings Failed", "\(o.morningFailures)")
            metricRow("Survival Rate", "\(String(format: "%.0f", o.morningSurvivalRate))%")
        }
    }
    
    private func opportunityMetrics(_ op: OpportunityMetrics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            metricRow("Export Captured", "\(op.exportTaken)/\(op.exportOpportunities)")
            metricRow("Import Captured", "\(op.importTaken)/\(op.importOpportunities)")
            metricRow("Negative Captured", "\(op.negativeTaken)/\(op.negativePeriods)")
            
            // Missed Exports
            if !op.missedExports.isEmpty {
                Divider()
                missedOpportunitySection(
                    title: "Missed Export Opportunities",
                    icon: "arrow.up.circle",
                    color: .orange,
                    opportunities: op.missedExports
                )
            }
            
            // Missed Imports
            if !op.missedImports.isEmpty {
                Divider()
                missedOpportunitySection(
                    title: "Missed Cheap Imports",
                    icon: "arrow.down.circle",
                    color: .blue,
                    opportunities: op.missedImports
                )
            }
            
            // Missed Negatives (most important!)
            if !op.missedNegatives.isEmpty {
                Divider()
                missedOpportunitySection(
                    title: "Missed Negative Prices",
                    icon: "exclamationmark.triangle",
                    color: .red,
                    opportunities: op.missedNegatives
                )
                Text("⚠️ You get paid to import during negative prices!")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
    
    @ViewBuilder
    private func missedOpportunitySection(title: String, icon: String, color: Color, opportunities: [MissedOpportunity]) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(opportunities) { opp in
                    HStack {
                        Text(opp.timestamp)
                            .font(.subheadline)
                            .monospacedDigit()
                        
                        Spacer()
                        
                        Text(formatPrice(opp.price))
                            .font(.subheadline)
                            .foregroundStyle(opp.type == .export ? .green : (opp.price < 0 ? .red : .blue))
                        
                        Text(opp.inferredReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 100, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
            }
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(opportunities.count)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
    }
    
    private func formatPrice(_ price: Double) -> String {
        if price < 0 {
            return String(format: "%.1f¢", price)
        } else {
            return String(format: "%.1f¢", price)
        }
    }
    
    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.subheadline)
    }
    
    private func gradeColor(_ grade: String) -> Color {
        switch grade {
        case "A", "A+": return .green
        case "B+", "B": return .blue
        case "C+", "C": return .orange
        default: return .red
        }
    }
}

// MARK: - Apple Intelligence Indicator
struct ScorecardAppleIntelligenceIndicator: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            HStack(spacing: 4) {
                Image(systemName: "apple.intelligence")
                    .font(.caption2)
                Text("Apple Intelligence")
                    .font(.caption2)
            }
            .foregroundStyle(
                LinearGradient(
                    colors: [.purple, .blue, .cyan],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        } else {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                Text("AI Enhanced")
                    .font(.caption2)
            }
            .foregroundColor(.purple)
        }
    }
}
