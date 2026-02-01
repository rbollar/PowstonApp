//
//  BargainHunterView.swift
//  Powston
//
//  Detail view for Bargain Hunter analysis
//  Shows expensive import breakdown and actionable samples
//

import SwiftUI

struct BargainHunterView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var analysis = BargainHunterAnalysis()
    
    @State private var showingReport = false
    
    var config: AnalysisConfig? {
        guard let site = api.selectedSite else { return nil }
        return AnalysisConfig.from(site: site)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header
                headerSection
                
                if analysis.isAnalyzing {
                    progressSection
                } else if let result = analysis.result {
                    resultSections(result)
                } else if let error = analysis.error {
                    errorSection(error)
                } else {
                    startSection
                }
            }
            .padding()
        }
        .navigationTitle("Bargain Hunter")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if analysis.result != nil {
                ToolbarItem(placement: .primaryAction) {
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
                ReportSheet(title: "Bargain Hunter Report", content: result.formattedReport())
            }
        }
        .task {
            // Load cached or run analysis
            if let config = config {
                if let cached = analysis.getCachedResult(config: config) {
                    analysis.result = cached
                }
            }
        }
    }
    
    // MARK: - Header
    
    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "tag.fill")
                .font(.system(size: 40))
                .foregroundStyle(.cyan)
            
            Text("Bargain Hunter")
                .font(.title2.bold())
            
            Text("Did you catch the cheapest import windows?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical)
    }
    
    // MARK: - Progress
    
    private var progressSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            
            Text(analysis.progress)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
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
                runAnalysis()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    // MARK: - Start
    
    private var startSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 50))
                .foregroundStyle(.cyan.opacity(0.6))
            
            Text("Analyze your import timing to find savings opportunities")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            
            Button {
                runAnalysis()
            } label: {
                Label("Analyze 60 Days", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    // MARK: - Results
    
    @ViewBuilder
    private func resultSections(_ result: BargainHunterResult) -> some View {
        // Summary Card
        summaryCard(result)
        
        // Breakdown Card
        breakdownCard(result)
        
        // Could Have Waited Section
        if !result.topCouldHaveWaited.isEmpty {
            couldHaveWaitedSection(result)
        }
        
        // By Hour Card
        if !result.byHour.isEmpty {
            byHourCard(result)
        }
        
        // By Priority Card
        if !result.byPriority.isEmpty {
            byPriorityCard(result)
        }
        
        // Refresh Button
        Button {
            runAnalysis()
        } label: {
            Label("Refresh Analysis", systemImage: "arrow.clockwise")
                .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .padding(.top, 8)
    }
    
    // MARK: - Summary Card
    
    private func summaryCard(_ result: BargainHunterResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "star.fill")
                    .foregroundColor(.yellow)
                Text("Overall Score")
                    .font(.headline)
                Spacer()
                Text("\(result.config.analysisWindowDays) days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Divider()
            
            HStack(alignment: .top, spacing: 24) {
                // Grade
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.grade)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundColor(gradeColor(result.grade))
                    Text("\(result.score)%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Stats
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Potential savings:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("$\(String(format: "%.2f", result.potentialSavingsDollars))")
                        .font(.title3.bold())
                        .foregroundColor(result.potentialSavingsDollars > 0 ? .orange : .green)
                    
                    Text("Expensive imports:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    Text("\(result.expensiveImports) of \(result.totalImports)")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Breakdown Card
    
    private func breakdownCard(_ result: BargainHunterResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.pie.fill")
                    .foregroundColor(.cyan)
                Text("Expensive Import Breakdown")
                    .font(.headline)
            }
            
            Divider()
            
            let total = result.breakdown.total
            
            if total == 0 {
                Text("No expensive imports found! 🎉")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    breakdownRow(
                        icon: "exclamationmark.triangle.fill",
                        color: .red,
                        label: "Could Have Waited",
                        count: result.breakdown.bestNFailures.count,
                        total: total,
                        subtitle: "Best-N logic could improve"
                    )
                    
                    breakdownRow(
                        icon: "clock.badge.exclamationmark",
                        color: .orange,
                        label: "Deadline Pressure",
                        count: result.breakdown.deadlinePressure.count,
                        total: total,
                        subtitle: "Not enough time to wait"
                    )
                    
                    breakdownRow(
                        icon: "cloud.bolt.fill",
                        color: .purple,
                        label: "Forecast Miss",
                        count: result.breakdown.forecastMiss.count,
                        total: total,
                        subtitle: "Forecast didn't show cheap prices"
                    )
                    
                    if result.breakdown.noForecast.count > 0 {
                        breakdownRow(
                            icon: "questionmark.circle.fill",
                            color: .gray,
                            label: "No Forecast Data",
                            count: result.breakdown.noForecast.count,
                            total: total,
                            subtitle: "Missing forecast information"
                        )
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    private func breakdownRow(icon: String, color: Color, label: String, count: Int, total: Int, subtitle: String) -> some View {
        let percent = total > 0 ? Double(count) / Double(total) * 100 : 0
        
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(count)")
                    .font(.subheadline.bold())
                Text("\(String(format: "%.0f", percent))%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - Could Have Waited Section
    
    private func couldHaveWaitedSection(_ result: BargainHunterResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text("Could Have Waited")
                    .font(.headline)
                Spacer()
                Text("Top \(result.topCouldHaveWaited.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Text("Imports where forecast showed cheap prices and there was time to wait")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Divider()
            
            ForEach(result.topCouldHaveWaited) { sample in
                sampleRow(sample, timezone: result.config.timezone)
                
                if sample.id != result.topCouldHaveWaited.last?.id {
                    Divider()
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    private func sampleRow(_ sample: BargainHunterSample, timezone: TimeZone) -> some View {
        let df = DateFormatter()
        df.dateFormat = "MMM d, HH:mm"
        df.timeZone = timezone
        
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(df.string(from: sample.timestamp))
                    .font(.subheadline.bold())
                
                Spacer()
                
                Text("-$\(String(format: "%.2f", sample.overpaidDollars))")
                    .font(.subheadline.bold())
                    .foregroundColor(.red)
            }
            
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paid")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(String(format: "%.1f", sample.buyPrice))¢")
                        .font(.caption.bold())
                        .foregroundColor(.red)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Best Avail")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(String(format: "%.1f", sample.cheapestInForecast))¢")
                        .font(.caption.bold())
                        .foregroundColor(.green)
                }
                
                if let hours = sample.hoursToWait {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wait")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("\(String(format: "%.1f", hours))h")
                            .font(.caption.bold())
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("SOC")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("\(String(format: "%.0f", sample.soc))%")
                        .font(.caption.bold())
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Priority")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("P\(sample.priority)")
                        .font(.caption.bold())
                }
                
                Spacer()
            }
            
            if let reason = sample.reason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
    
    // MARK: - By Hour Card
    
    private func byHourCard(_ result: BargainHunterResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(.blue)
                Text("Expensive Imports by Hour")
                    .font(.headline)
            }
            
            Divider()
            
            // Header
            HStack {
                Text("Hour")
                    .frame(width: 50, alignment: .leading)
                Text("Count")
                    .frame(width: 50, alignment: .trailing)
                Text("Avg ¢")
                    .frame(width: 50, alignment: .trailing)
                Text("Forecast OK")
                    .frame(width: 70, alignment: .trailing)
                Text("Could Wait")
                    .frame(width: 70, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            
            ForEach(result.byHour.filter { $0.count > 0 }) { stat in
                HStack {
                    Text(String(format: "%02d:00", stat.hour))
                        .frame(width: 50, alignment: .leading)
                    Text("\(stat.count)")
                        .frame(width: 50, alignment: .trailing)
                    Text(String(format: "%.1f", stat.avgPrice))
                        .frame(width: 50, alignment: .trailing)
                    Text("\(stat.forecastHadCheap)/\(stat.count)")
                        .frame(width: 70, alignment: .trailing)
                        .foregroundColor(stat.forecastHadCheap > 0 ? .orange : .green)
                    Text("\(stat.couldWait)/\(stat.count)")
                        .frame(width: 70, alignment: .trailing)
                        .foregroundColor(stat.couldWait > 0 ? .red : .green)
                }
                .font(.caption)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - By Priority Card
    
    private func byPriorityCard(_ result: BargainHunterResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "list.number")
                    .foregroundColor(.purple)
                Text("Expensive Imports by Priority")
                    .font(.headline)
            }
            
            Divider()
            
            ForEach(result.byPriority) { stat in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("P\(stat.priority)")
                            .font(.subheadline.bold())
                        if let reason = stat.topReason {
                            Text(reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(stat.count)")
                            .font(.subheadline.bold())
                        Text("\(String(format: "%.1f", stat.avgPrice))¢ avg")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(String(format: "%.0f", stat.avgSoc))%")
                            .font(.subheadline)
                        Text("SOC")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 50)
                }
                .padding(.vertical, 4)
                
                if stat.id != result.byPriority.last?.id {
                    Divider()
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Helpers
    
    private func runAnalysis() {
        guard let config = config else { return }
        Task {
            await analysis.analyzeImports(config: config)
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

// MARK: - Report Sheet

private struct ReportSheet: View {
    let title: String
    let content: String
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: content) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        BargainHunterView()
            .environmentObject(PowstonAPI())
    }
}