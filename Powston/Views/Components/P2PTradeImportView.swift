//
//  P2PTradeImport.swift
//  Powston
//
//  Created by Rick Bollar on 1/29/26.
//


//
//  P2PTradeImportView.swift
//  Powston
//
//  Import P2P trade data from LocalVolts paste, calculate premium over spot
//

import SwiftUI

// MARK: - Data Models

struct P2PTradeImport: Identifiable {
    let id = UUID()
    let counterparty: String
    let dealtKwh: Double
    let settledKwh: Double
    let matchTime: Date
    let intervalStart: Date  // 5-min interval this falls into
}

struct P2PIntervalSummary: Identifiable {
    let id = UUID()
    let intervalStart: Date
    let settledKwh: Double
    let p2pPriceCents: Double
    let spotPriceCents: Double?
    
    var p2pRevenue: Double {
        settledKwh * p2pPriceCents / 100.0
    }
    
    var spotRevenue: Double? {
        guard let spot = spotPriceCents else { return nil }
        return settledKwh * spot / 100.0
    }
    
    var premium: Double? {
        guard let spot = spotRevenue else { return nil }
        return p2pRevenue - spot
    }
    
    var premiumPerKwh: Double? {
        guard let spot = spotPriceCents else { return nil }
        return p2pPriceCents - spot
    }
}

struct P2PTradeSummary {
    let tradeName: String
    let tradeDate: Date?
    let p2pPriceCents: Double
    let totalDealtKwh: Double
    let totalSettledKwh: Double
    let intervals: [P2PIntervalSummary]
    
    var totalP2PRevenue: Double {
        intervals.reduce(0) { $0 + $1.p2pRevenue }
    }
    
    var totalSpotRevenue: Double? {
        let revenues = intervals.compactMap { $0.spotRevenue }
        guard revenues.count == intervals.count else { return nil }
        return revenues.reduce(0, +)
    }
    
    var totalPremium: Double? {
        guard let spot = totalSpotRevenue else { return nil }
        return totalP2PRevenue - spot
    }
    
    var fillRate: Double {
        totalDealtKwh > 0 ? totalSettledKwh / totalDealtKwh * 100 : 0
    }
}

// MARK: - Parser

class P2PTradeParser {
    
    /// Parse the header to extract trade info
    /// Format: "Trade 5158878 (Standing)\nNMIDirectionVolume (kWh)Price (c/kWh)Trade date3120892347Sell39.1930.000028-Jan-26 22:03:57"
    func parseHeader(_ text: String) -> (tradeName: String, p2pPrice: Double, volumeKwh: Double, tradeDate: Date?)? {
        // Extract trade name (e.g., "Trade 5158878 (Standing)")
        let tradeNamePattern = #"(Trade\s+\d+\s*\([^)]+\))"#
        guard let tradeNameMatch = text.range(of: tradeNamePattern, options: .regularExpression),
              let tradeName = text[tradeNameMatch].components(separatedBy: "\n").first else {
            return nil
        }
        
        // Look for the header line pattern: ends with price and date
        // Pattern: Sell{volume}{price}{date} e.g., "Sell39.1930.000028-Jan-26 22:03:57"
        let headerPattern = #"Sell(\d+\.?\d*)(\d{2}\.\d{4})(\d{2}-\w{3}-\d{2}\s+\d{2}:\d{2}:\d{2})"#
        guard let headerMatch = text.range(of: headerPattern, options: .regularExpression) else {
            return nil
        }
        
        let headerStr = String(text[headerMatch])
        
        // Parse with regex groups
        let regex = try? NSRegularExpression(pattern: headerPattern)
        guard let match = regex?.firstMatch(in: headerStr, range: NSRange(headerStr.startIndex..., in: headerStr)) else {
            return nil
        }
        
        guard let volumeRange = Range(match.range(at: 1), in: headerStr),
              let priceRange = Range(match.range(at: 2), in: headerStr),
              let dateRange = Range(match.range(at: 3), in: headerStr) else {
            return nil
        }
        
        let volumeStr = String(headerStr[volumeRange])
        let priceStr = String(headerStr[priceRange])
        let dateStr = String(headerStr[dateRange])
        
        guard let volume = Double(volumeStr),
              let price = Double(priceStr) else {
            return nil
        }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MMM-yy HH:mm:ss"
        dateFormatter.timeZone = powstonTimezone()
        let tradeDate = dateFormatter.date(from: dateStr)
        
        return (String(tradeName), price, volume, tradeDate)
    }
    
    /// Parse individual trade rows
    /// Format: "Chicken Mania4.259710.8696 %4.259728-Jan-26 22:04:39"
    func parseTradeRows(_ text: String) -> [P2PTradeImport] {
        var trades: [P2PTradeImport] = []
        
        // Pattern to match: Name + Dealt + Percentage + Settled + DateTime
        // The challenge is names can have spaces, numbers, special chars
        // We look for the pattern: decimal + decimal + % + decimal + date
        let rowPattern = #"([A-Za-z][A-Za-z0-9\s&'./()-]+?)(\d+\.\d+)(\d+\.\d+)\s*%(\d+\.\d+)(\d{2}-\w{3}-\d{2}\s+\d{2}:\d{2}:\d{2})"#
        
        let regex = try? NSRegularExpression(pattern: rowPattern, options: [])
        let nsText = text as NSString
        let matches = regex?.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) ?? []
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MMM-yy HH:mm:ss"
        dateFormatter.timeZone = powstonTimezone()
        
        for match in matches {
            guard match.numberOfRanges >= 6 else { continue }
            
            let nameRange = match.range(at: 1)
            let dealtRange = match.range(at: 2)
            let settledRange = match.range(at: 4)
            let dateRange = match.range(at: 5)
            
            let name = nsText.substring(with: nameRange).trimmingCharacters(in: .whitespaces)
            let dealtStr = nsText.substring(with: dealtRange)
            let settledStr = nsText.substring(with: settledRange)
            let dateStr = nsText.substring(with: dateRange)
            
            guard let dealt = Double(dealtStr),
                  let settled = Double(settledStr),
                  let matchTime = dateFormatter.date(from: dateStr) else {
                continue
            }
            
            // Calculate 5-minute interval start
            let intervalStart = floorToInterval(matchTime)
            
            trades.append(P2PTradeImport(
                counterparty: name,
                dealtKwh: dealt,
                settledKwh: settled,
                matchTime: matchTime,
                intervalStart: intervalStart
            ))
        }
        
        return trades
    }
    
    /// Floor a date to the start of its 5-minute interval
    private func floorToInterval(_ date: Date) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = components.minute ?? 0
        let flooredMinute = (minute / 5) * 5
        
        var newComponents = components
        newComponents.minute = flooredMinute
        newComponents.second = 0
        
        return calendar.date(from: newComponents) ?? date
    }
    
    /// Group trades by interval and calculate summaries
    func summarizeByInterval(trades: [P2PTradeImport], p2pPriceCents: Double, spotPrices: [Date: Double]) -> [P2PIntervalSummary] {
        let grouped = Dictionary(grouping: trades) { $0.intervalStart }
        
        return grouped.map { (interval, intervalTrades) in
            let totalSettled = intervalTrades.reduce(0) { $0 + $1.settledKwh }
            let spotPrice = spotPrices[interval]
            
            return P2PIntervalSummary(
                intervalStart: interval,
                settledKwh: totalSettled,
                p2pPriceCents: p2pPriceCents,
                spotPriceCents: spotPrice
            )
        }.sorted { $0.intervalStart < $1.intervalStart }
    }
}

// MARK: - View

struct P2PTradeImportView: View {
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.dismiss) var dismiss
    
    @State private var pastedText: String = ""
    @State private var parsedSummary: P2PTradeSummary?
    @State private var parseError: String?
    @State private var isProcessing = false
    
    private let parser = P2PTradeParser()
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    instructionsCard
                    pasteInputCard
                    
                    if isProcessing {
                        ProgressView("Processing...")
                            .padding()
                    } else if let error = parseError {
                        errorCard(error)
                    } else if let summary = parsedSummary {
                        resultsView(summary)
                    }
                }
                .padding()
            }
            .navigationTitle("Import P2P Trade")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
    
    // MARK: - Instructions
    
    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "doc.on.clipboard")
                    .foregroundColor(.blue)
                Text("How to Import")
                    .font(.headline)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                instructionRow(number: 1, text: "Go to LocalVolts → Sell Electricity → Explore Trades")
                instructionRow(number: 2, text: "Click on a trade to see details")
                instructionRow(number: 3, text: "Select all the trade text (Cmd+A or Ctrl+A)")
                instructionRow(number: 4, text: "Copy and paste below")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .fontWeight(.medium)
                .frame(width: 20)
            Text(text)
        }
    }
    
    // MARK: - Paste Input
    
    private var pasteInputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "rectangle.and.pencil.and.ellipsis")
                    .foregroundColor(.purple)
                Text("Paste Trade Data")
                    .font(.headline)
                Spacer()
                
                if !pastedText.isEmpty {
                    Button(action: { pastedText = ""; parsedSummary = nil; parseError = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            TextEditor(text: $pastedText)
                .frame(minHeight: 150, maxHeight: 200)
                .padding(8)
                .background(Color(.tertiarySystemBackground))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            
            Button(action: processInput) {
                Label("Process Trade", systemImage: "arrow.right.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(pastedText.isEmpty ? Color.gray : Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(pastedText.isEmpty || isProcessing)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Error Card
    
    private func errorCard(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)
            
            Text("Parse Error")
                .font(.headline)
            
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Results View
    
    private func resultsView(_ summary: P2PTradeSummary) -> some View {
        VStack(spacing: 16) {
            // Header
            tradeHeaderCard(summary)
            
            // Totals
            totalsSummaryCard(summary)
            
            // Interval breakdown
            intervalBreakdownCard(summary)
        }
    }
    
    private func tradeHeaderCard(_ summary: P2PTradeSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                Text(summary.tradeName)
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.0f¢", summary.p2pPriceCents))
                        .font(.title3.bold())
                        .foregroundColor(.purple)
                    Text("P2P price")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.2f kWh", summary.totalSettledKwh))
                        .font(.title3.bold())
                    Text("settled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "%.0f%%", summary.fillRate))
                        .font(.title3.bold())
                        .foregroundColor(summary.fillRate >= 50 ? .green : .orange)
                    Text("fill rate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func totalsSummaryCard(_ summary: P2PTradeSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundColor(.green)
                Text("Revenue Summary")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("P2P Revenue")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(formatCurrency(summary.totalP2PRevenue))
                        .font(.title2.bold())
                        .foregroundColor(.purple)
                }
                
                Spacer()
                
                if let spotRevenue = summary.totalSpotRevenue {
                    VStack(alignment: .center, spacing: 4) {
                        Text("vs Spot")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(formatCurrency(spotRevenue))
                            .font(.title3)
                            .foregroundColor(.orange)
                    }
                    
                    Spacer()
                    
                    if let premium = summary.totalPremium {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Premium")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("+\(formatCurrency(premium))")
                                .font(.title2.bold())
                                .foregroundColor(.green)
                        }
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Spot data")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Not available")
                            .font(.subheadline)
                            .foregroundColor(.orange)
                    }
                }
            }
            
            if let premium = summary.totalPremium, summary.totalSettledKwh > 0 {
                let premiumPerKwh = premium / summary.totalSettledKwh * 100
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right.circle.fill")
                        .foregroundColor(.green)
                    Text("You earned \(String(format: "%.1f", premiumPerKwh))¢/kWh more than spot")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func intervalBreakdownCard(_ summary: P2PTradeSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "clock.fill")
                    .foregroundColor(.orange)
                Text("Interval Breakdown")
                    .font(.headline)
                Spacer()
                Text("\(summary.intervals.count) interval\(summary.intervals.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
            
            // Header
            HStack {
                Text("Time")
                    .frame(width: 60, alignment: .leading)
                Text("kWh")
                    .frame(width: 50, alignment: .trailing)
                Text("P2P")
                    .frame(width: 45, alignment: .trailing)
                Text("Spot")
                    .frame(width: 45, alignment: .trailing)
                Text("Premium")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
            
            ForEach(summary.intervals) { interval in
                HStack {
                    Text(formatTime(interval.intervalStart))
                        .frame(width: 60, alignment: .leading)
                    Text(String(format: "%.2f", interval.settledKwh))
                        .frame(width: 50, alignment: .trailing)
                    Text(String(format: "%.0f¢", interval.p2pPriceCents))
                        .frame(width: 45, alignment: .trailing)
                        .foregroundColor(.purple)
                    
                    if let spot = interval.spotPriceCents {
                        Text(String(format: "%.1f¢", spot))
                            .frame(width: 45, alignment: .trailing)
                            .foregroundColor(.orange)
                    } else {
                        Text("--")
                            .frame(width: 45, alignment: .trailing)
                            .foregroundColor(.secondary)
                    }
                    
                    if let premium = interval.premium {
                        Text("+\(formatCurrency(premium))")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(.green)
                    } else {
                        Text("--")
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(.secondary)
                    }
                }
                .font(.caption.monospacedDigit())
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    // MARK: - Processing
    
    private func processInput() {
        isProcessing = true
        parseError = nil
        parsedSummary = nil
        
        Task {
            await processTradeData()
            isProcessing = false
        }
    }
    
    @MainActor
    private func processTradeData() async {
        // Parse header
        guard let header = parser.parseHeader(pastedText) else {
            parseError = "Could not parse trade header. Make sure you copied the full trade details including the header line."
            return
        }
        
        // Parse rows
        let trades = parser.parseTradeRows(pastedText)
        
        guard !trades.isEmpty else {
            parseError = "No trade rows found. Make sure the counterparty data is included."
            return
        }
        
        // Get spot prices for the intervals
        let intervals = Set(trades.map { $0.intervalStart })
        var spotPrices: [Date: Double] = [:]
        
        if let siteId = api.selectedSite?.id {
            let dataStore = PowstonDataStore.shared
            
            for interval in intervals {
                // Look up action record for this interval
                let actions = dataStore.fetchActions(
                    siteId: siteId,
                    from: interval,
                    to: interval.addingTimeInterval(1)  // Just this interval
                )
                
                if let action = actions.first, let sellPrice = action.sellPrice {
                    spotPrices[interval] = sellPrice
                }
            }
        }
        
        // Summarize by interval
        let intervalSummaries = parser.summarizeByInterval(
            trades: trades,
            p2pPriceCents: header.p2pPrice,
            spotPrices: spotPrices
        )
        
        let totalDealt = trades.reduce(0) { $0 + $1.dealtKwh }
        let totalSettled = trades.reduce(0) { $0 + $1.settledKwh }
        
        parsedSummary = P2PTradeSummary(
            tradeName: header.tradeName,
            tradeDate: header.tradeDate,
            p2pPriceCents: header.p2pPrice,
            totalDealtKwh: totalDealt,
            totalSettledKwh: totalSettled,
            intervals: intervalSummaries
        )
    }
    
    // MARK: - Helpers
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
}

// MARK: - Preview

#Preview {
    P2PTradeImportView()
        .environmentObject(PowstonAPI())
}