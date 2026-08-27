//
//  HistoryCharts.swift
//  Powston
//
//  Reusable chart components for history analysis
//  Shared between iOS HistoryView and tvOS
//

import SwiftUI

// MARK: - Chart Section Helper

struct ChartSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var isLoading: Bool = false
    var legend: [(String, Color)]? = nil
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                if let sub = subtitle { Text(sub).font(.caption).foregroundColor(.green) }
                Spacer()
                if isLoading { ProgressView().scaleEffect(0.6) }
                if let leg = legend {
                    HStack(spacing: 12) {
                        ForEach(leg, id: \.0) { item in
                            HStack(spacing: 4) {
                                Circle().fill(item.1.opacity(0.7)).frame(width: 8, height: 8)
                                Text(item.0).font(.caption2)
                            }
                        }
                    }
                    .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            content.padding(.horizontal, 8)
        }
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}

// MARK: - Daily Summary (shared data structure)

struct DailySummary: Identifiable {
    let id = UUID()
    let date: Date
    let totalImport: Double
    let totalExport: Double
    let totalEarnings: Double
    let totalCosts: Double
    let avgSoc: Double
    let recordCount: Int
    let netProfit: Double  // Stored value from expectedBill, not computed
    
    /// Backward-compatible init that computes netProfit (for meter_records path)
    init(date: Date, totalImport: Double, totalExport: Double, totalEarnings: Double, totalCosts: Double, avgSoc: Double, recordCount: Int) {
        self.date = date
        self.totalImport = totalImport
        self.totalExport = totalExport
        self.totalEarnings = totalEarnings
        self.totalCosts = totalCosts
        self.avgSoc = avgSoc
        self.recordCount = recordCount
        self.netProfit = totalEarnings - totalCosts  // Fallback computation
    }
    
    /// Preferred init with explicit netProfit from expectedBill
    init(date: Date, totalImport: Double, totalExport: Double, totalEarnings: Double, totalCosts: Double, avgSoc: Double, recordCount: Int, netProfit: Double) {
        self.date = date
        self.totalImport = totalImport
        self.totalExport = totalExport
        self.totalEarnings = totalEarnings
        self.totalCosts = totalCosts
        self.avgSoc = avgSoc
        self.recordCount = recordCount
        self.netProfit = netProfit
    }
    
    var dayOfMonth: Int { Calendar.current.component(.day, from: date) }
    var dayLabel: String {
        let f = DateFormatter()
        f.dateFormat = "d"
        f.timeZone = powstonTimezone()
        return f.string(from: date)
    }
}

// MARK: - Data Not Available Card

struct DataNotAvailableCard: View {
    let title: String
    let message: String
    
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text(title).font(.headline); Spacer() }
            HStack(spacing: 8) {
                Image(systemName: "info.circle").foregroundColor(.secondary)
                Text(message).font(.subheadline).foregroundColor(.secondary)
                Spacer()
            }
            .padding().background(Color.gray.opacity(0.1)).cornerRadius(8)
        }
        .padding().background(Color.gray.opacity(0.05)).cornerRadius(12)
    }
}

// MARK: - Daily Energy Chart

struct DailyEnergyChart: View {
    let summaries: [DailySummary]
    var scrubIndex: Int?
    var onScrub: ((Int?) -> Void)?
    
    var maxEnergy: Double {
        max(summaries.map { $0.totalImport }.max() ?? 1, summaries.map { $0.totalExport }.max() ?? 1, 1)
    }
    
    var body: some View {
        let count = summaries.count, maxE = maxEnergy
        GeometryReader { geo in
            let w = geo.size.width - 40, h = geo.size.height - 30, bw = w / CGFloat(max(count, 1))
            ZStack(alignment: .bottomLeading) {
                Canvas { ctx, size in
                    let cw = size.width - 40, ch = size.height - 30, cbw = cw / CGFloat(max(count, 1))
                    for frac in [0.25, 0.5, 0.75, 1.0] {
                        var p = Path(); p.move(to: CGPoint(x: 30, y: ch * (1 - frac))); p.addLine(to: CGPoint(x: cw + 30, y: ch * (1 - frac)))
                        ctx.stroke(p, with: .color(.gray.opacity(0.2)), lineWidth: 1)
                    }
                    for (i, s) in summaries.enumerated() {
                        let x = CGFloat(i) * cbw + 30
                        let ih = CGFloat(s.totalImport / maxE) * ch
                        if ih > 0 { ctx.fill(Path(CGRect(x: x + cbw * 0.1, y: ch - ih, width: max(2, cbw * 0.35), height: ih)), with: .color(.blue.opacity(0.7))) }
                        let eh = CGFloat(s.totalExport / maxE) * ch
                        if eh > 0 { ctx.fill(Path(CGRect(x: x + cbw * 0.55, y: ch - eh, width: max(2, cbw * 0.35), height: eh)), with: .color(.orange.opacity(0.7))) }
                    }
                    if let idx = scrubIndex, idx < count {
                        var sp = Path(); sp.move(to: CGPoint(x: CGFloat(idx) * cbw + 30 + cbw / 2, y: 0)); sp.addLine(to: CGPoint(x: CGFloat(idx) * cbw + 30 + cbw / 2, y: ch))
                        ctx.stroke(sp, with: .color(.white.opacity(0.8)), lineWidth: 1)
                    }
                }.drawingGroup()
                ForEach(Array(summaries.enumerated()), id: \.offset) { i, s in
                    if s.dayOfMonth % 5 == 1 || i == 0 {
                        Text(s.dayLabel).font(.caption2).foregroundColor(.secondary).position(x: CGFloat(i) * bw + 30 + bw / 2, y: h + 15)
                    }
                }
                Text(String(format: "%.0f kWh", maxE)).font(.caption2).foregroundColor(.secondary).position(x: 15, y: 10)
                HStack(spacing: 8) {
                    HStack(spacing: 2) { Rectangle().fill(Color.blue.opacity(0.7)).frame(width: 8, height: 8); Text("Import").font(.caption2) }
                    HStack(spacing: 2) { Rectangle().fill(Color.orange.opacity(0.7)).frame(width: 8, height: 8); Text("Export").font(.caption2) }
                }.foregroundColor(.secondary).position(x: w - 30, y: 10)
                if let idx = scrubIndex, idx < count {
                    let s = summaries[idx]
                    VStack(spacing: 2) {
                        Text(s.dayLabel).font(.caption).fontWeight(.semibold)
                        HStack(spacing: 8) { Text(String(format: "↓%.1f", s.totalImport)).foregroundColor(.blue); Text(String(format: "↑%.1f", s.totalExport)).foregroundColor(.orange) }.font(.caption2)
                    }.padding(6).background(Color(.systemBackground).opacity(0.9)).cornerRadius(6).position(x: w / 2 + 30, y: 35)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard w > 0, count > 0 else { return }
                onScrub?(max(0, min(count - 1, Int((v.location.x - 30) / bw))))
            }.onEnded { _ in onScrub?(nil) })
        }
    }
}

// MARK: - Daily Profit Chart

struct DailyProfitChart: View {
    let summaries: [DailySummary]
    var scrubIndex: Int?
    var onScrub: ((Int?) -> Void)?
    
    var maxP: Double { max(summaries.map { abs($0.netProfit) }.max() ?? 1, 1) }
    
    var body: some View {
        let count = summaries.count, mp = maxP
        GeometryReader { geo in
            let w = geo.size.width - 40, h = geo.size.height - 30, bw = w / CGFloat(max(count, 1)), cy = h / 2
            ZStack(alignment: .bottomLeading) {
                Canvas { ctx, size in
                    let cw = size.width - 40, ch = size.height - 30, cbw = cw / CGFloat(max(count, 1)), ccy = ch / 2
                    var zp = Path(); zp.move(to: CGPoint(x: 30, y: ccy)); zp.addLine(to: CGPoint(x: cw + 30, y: ccy))
                    ctx.stroke(zp, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                    for (i, s) in summaries.enumerated() {
                        let x = CGFloat(i) * cbw + 30, profit = s.netProfit, bh = CGFloat(abs(profit) / mp) * (ch / 2)
                        let col = profit >= 0 ? Color.green.opacity(0.7) : Color.red.opacity(0.7)
                        let rect = profit >= 0 ? CGRect(x: x + 1, y: ccy - bh, width: max(2, cbw - 2), height: bh) : CGRect(x: x + 1, y: ccy, width: max(2, cbw - 2), height: bh)
                        ctx.fill(Path(rect), with: .color(col))
                    }
                    if let idx = scrubIndex, idx < count {
                        var sp = Path(); sp.move(to: CGPoint(x: CGFloat(idx) * cbw + 30 + cbw / 2, y: 0)); sp.addLine(to: CGPoint(x: CGFloat(idx) * cbw + 30 + cbw / 2, y: ch))
                        ctx.stroke(sp, with: .color(.white.opacity(0.8)), lineWidth: 1)
                    }
                }.drawingGroup()
                ForEach(Array(summaries.enumerated()), id: \.offset) { i, s in
                    if s.dayOfMonth % 5 == 1 || i == 0 { Text(s.dayLabel).font(.caption2).foregroundColor(.secondary).position(x: CGFloat(i) * bw + 30 + bw / 2, y: h + 15) }
                }
                Text(String(format: "+$%.0f", mp)).font(.caption2).foregroundColor(.green).position(x: 15, y: 10)
                Text(String(format: "-$%.0f", mp)).font(.caption2).foregroundColor(.red).position(x: 15, y: h - 10)
                if let idx = scrubIndex, idx < count {
                    let s = summaries[idx], profit = s.netProfit
                    VStack(spacing: 2) {
                        Text(s.dayLabel).font(.caption).fontWeight(.semibold)
                        Text(String(format: "%@$%.2f", profit >= 0 ? "+" : "", profit)).font(.caption).fontWeight(.medium).foregroundColor(profit >= 0 ? .green : .red)
                    }.padding(6).background(Color(.systemBackground).opacity(0.9)).cornerRadius(6).position(x: w / 2 + 30, y: cy)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard w > 0, count > 0 else { return }
                onScrub?(max(0, min(count - 1, Int((v.location.x - 30) / bw))))
            }.onEnded { _ in onScrub?(nil) })
        }
    }
}

// MARK: - Monthly Energy Chart

struct MonthlyEnergyChart: View {
    let summaries: [DailySummary]
    var scrubIndex: Int?
    var onScrub: ((Int?) -> Void)?
    private let monthLabels = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
    
    var maxE: Double { max(summaries.map { $0.totalImport }.max() ?? 1, summaries.map { $0.totalExport }.max() ?? 1, 1) }
    
    var body: some View {
        let count = summaries.count, me = maxE
        GeometryReader { geo in
            let w = geo.size.width - 40, h = geo.size.height - 30, bw = w / 12
            ZStack(alignment: .bottomLeading) {
                Canvas { ctx, size in
                    let cw = size.width - 40, ch = size.height - 30, cbw = cw / 12
                    for frac in [0.25, 0.5, 0.75, 1.0] {
                        var p = Path(); p.move(to: CGPoint(x: 30, y: ch * (1 - frac))); p.addLine(to: CGPoint(x: cw + 30, y: ch * (1 - frac)))
                        ctx.stroke(p, with: .color(.gray.opacity(0.2)), lineWidth: 1)
                    }
                    for (i, s) in summaries.enumerated() {
                        let x = CGFloat(i) * cbw + 30
                        let ih = CGFloat(s.totalImport / me) * ch
                        if ih > 0 { ctx.fill(Path(CGRect(x: x + cbw * 0.1, y: ch - ih, width: max(2, cbw * 0.35), height: ih)), with: .color(.blue.opacity(0.7))) }
                        let eh = CGFloat(s.totalExport / me) * ch
                        if eh > 0 { ctx.fill(Path(CGRect(x: x + cbw * 0.55, y: ch - eh, width: max(2, cbw * 0.35), height: eh)), with: .color(.orange.opacity(0.7))) }
                    }
                    if let idx = scrubIndex, idx < count {
                        var sp = Path(); sp.move(to: CGPoint(x: CGFloat(idx) * cbw + 30 + cbw / 2, y: 0)); sp.addLine(to: CGPoint(x: CGFloat(idx) * cbw + 30 + cbw / 2, y: ch))
                        ctx.stroke(sp, with: .color(.white.opacity(0.8)), lineWidth: 1)
                    }
                }.drawingGroup()
                ForEach(0..<12, id: \.self) { i in
                    Text(monthLabels[i]).font(.caption2).foregroundColor(i < count ? .secondary : .secondary.opacity(0.3)).position(x: CGFloat(i) * bw + 30 + bw / 2, y: h + 15)
                }
                Text(String(format: "%.0f kWh", me)).font(.caption2).foregroundColor(.secondary).position(x: 15, y: 10)
                HStack(spacing: 8) {
                    HStack(spacing: 2) { Rectangle().fill(Color.blue.opacity(0.7)).frame(width: 8, height: 8); Text("Import").font(.caption2) }
                    HStack(spacing: 2) { Rectangle().fill(Color.orange.opacity(0.7)).frame(width: 8, height: 8); Text("Export").font(.caption2) }
                }.foregroundColor(.secondary).position(x: w - 30, y: 10)
                if let idx = scrubIndex, idx < count {
                    let s = summaries[idx]
                    VStack(spacing: 2) {
                        Text(monthLabels[idx]).font(.caption).fontWeight(.semibold)
                        HStack(spacing: 8) { Text(String(format: "↓%.0f", s.totalImport)).foregroundColor(.blue); Text(String(format: "↑%.0f", s.totalExport)).foregroundColor(.orange) }.font(.caption2)
                    }.padding(6).background(Color(.systemBackground).opacity(0.9)).cornerRadius(6).position(x: w / 2 + 30, y: 35)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard w > 0 else { return }
                onScrub?(max(0, min(count - 1, Int((v.location.x - 30) / bw))))
            }.onEnded { _ in onScrub?(nil) })
        }
    }
}

// MARK: - Monthly Profit Chart

struct MonthlyProfitChart: View {
    let summaries: [DailySummary]
    var scrubIndex: Int?
    var onScrub: ((Int?) -> Void)?
    private let monthLabels = ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
    
    var maxP: Double { max(summaries.map { abs($0.netProfit) }.max() ?? 1, 1) }
    
    var body: some View {
        let count = summaries.count, mp = maxP
        GeometryReader { geo in
            let w = geo.size.width - 40, h = geo.size.height - 30, bw = w / 12, cy = h / 2
            ZStack(alignment: .bottomLeading) {
                Canvas { ctx, size in
                    let cw = size.width - 40, ch = size.height - 30, cbw = cw / 12, ccy = ch / 2
                    var zp = Path(); zp.move(to: CGPoint(x: 30, y: ccy)); zp.addLine(to: CGPoint(x: cw + 30, y: ccy))
                    ctx.stroke(zp, with: .color(.gray.opacity(0.5)), lineWidth: 1)
                    for (i, s) in summaries.enumerated() {
                        let x = CGFloat(i) * cbw + 30, profit = s.netProfit, bh = CGFloat(abs(profit) / mp) * (ch / 2)
                        let col = profit >= 0 ? Color.green.opacity(0.7) : Color.red.opacity(0.7)
                        let rect = profit >= 0 ? CGRect(x: x + 2, y: ccy - bh, width: max(2, cbw - 4), height: bh) : CGRect(x: x + 2, y: ccy, width: max(2, cbw - 4), height: bh)
                        ctx.fill(Path(rect), with: .color(col))
                    }
                    if let idx = scrubIndex, idx < count {
                        var sp = Path(); sp.move(to: CGPoint(x: CGFloat(idx) * cbw + 30 + cbw / 2, y: 0)); sp.addLine(to: CGPoint(x: CGFloat(idx) * cbw + 30 + cbw / 2, y: ch))
                        ctx.stroke(sp, with: .color(.white.opacity(0.8)), lineWidth: 1)
                    }
                }.drawingGroup()
                ForEach(0..<12, id: \.self) { i in
                    Text(monthLabels[i]).font(.caption2).foregroundColor(i < count ? .secondary : .secondary.opacity(0.3)).position(x: CGFloat(i) * bw + 30 + bw / 2, y: h + 15)
                }
                Text(String(format: "+$%.0f", mp)).font(.caption2).foregroundColor(.green).position(x: 15, y: 10)
                Text(String(format: "-$%.0f", mp)).font(.caption2).foregroundColor(.red).position(x: 15, y: h - 10)
                if let idx = scrubIndex, idx < count {
                    let s = summaries[idx], profit = s.netProfit
                    VStack(spacing: 2) {
                        Text(monthLabels[idx]).font(.caption).fontWeight(.semibold)
                        Text(String(format: "%@$%.0f", profit >= 0 ? "+" : "", profit)).font(.caption).fontWeight(.medium).foregroundColor(profit >= 0 ? .green : .red)
                    }.padding(6).background(Color(.systemBackground).opacity(0.9)).cornerRadius(6).position(x: w / 2 + 30, y: cy)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                guard w > 0 else { return }
                onScrub?(max(0, min(count - 1, Int((v.location.x - 30) / bw))))
            }.onEnded { _ in onScrub?(nil) })
        }
    }
}

// MARK: - Savings Analysis Card

struct SavingsAnalysisCard: View {
    let analysis: SavingsAnalysis
    let networkName: String?
    let importTariff: String?
    let exportTariff: String?
    var site: Site? = nil

    private func formatCurrency(_ value: Double) -> String {
        String(format: "$%.2f", abs(value))
    }

    // Generation: savings (positive) or cost (negative) — adapts to solar/wind/hydro/mixed
    private var solarLabel: String {
        if let site = site {
            return site.generationLabel(isSavings: analysis.solarSavings >= 0)
        }
        return analysis.solarSavings >= 0 ? "Solar savings:" : "Solar cost:"
    }

    private var generationIcon: String { site?.generationIcon ?? "sun.max.fill" }
    private var generationColor: Color { site?.generationColor ?? .yellow }
    
    // Powston: savings (positive) or cost (negative)
    private var powstonLabel: String {
        analysis.powstonSavings >= 0 ? "Powston savings:" : "Arbitrage cost:"
    }
    
    // Build tariff description
    private var tariffDescription: String? {
        var parts: [String] = []
        if let network = networkName, !network.isEmpty {
            parts.append(network)
        }
        if let importT = importTariff, !importT.isEmpty {
            parts.append(importT)
        }
        if let exportT = exportTariff, !exportT.isEmpty, exportT != importTariff {
            parts.append(exportT)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundColor(.yellow)
                Text("Savings Analysis")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if analysis.usedDerivedData {
                    Label("Estimated", systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            
            Divider()
            
            // Grid only baseline
            HStack {
                Image(systemName: "powerplug.fill")
                    .foregroundColor(.gray)
                    .frame(width: 20)
                Text("Grid only:")
                    .font(.subheadline)
                Spacer()
                Text(formatCurrency(analysis.gridOnlyCost))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            
            // Generation contribution (solar/wind/hydro/mixed)
            HStack {
                Image(systemName: generationIcon)
                    .foregroundColor(generationColor)
                    .frame(width: 20)
                Text(solarLabel)
                    .font(.subheadline)
                Spacer()
                Text(formatCurrency(analysis.solarSavings))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(analysis.solarSavings >= 0 ? .green : .red)
            }
            
            // Battery contribution (always savings)
            HStack {
                Image(systemName: "battery.100percent")
                    .foregroundColor(.green)
                    .frame(width: 20)
                Text("Battery savings:")
                    .font(.subheadline)
                Spacer()
                Text(formatCurrency(analysis.batterySavings))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.green)
            }
            
            // Powston optimization (can be savings or cost)
            HStack {
                Image(systemName: "brain.head.profile")
                    .foregroundColor(.purple)
                    .frame(width: 20)
                Text(powstonLabel)
                    .font(.subheadline)
                Spacer()
                Text(formatCurrency(analysis.powstonSavings))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(analysis.powstonSavings >= 0 ? .green : .red)
            }
            
            Divider()
            
            // Actual result
            HStack {
                Image(systemName: analysis.actualCost <= 0 ? "checkmark.circle.fill" : "dollarsign.circle.fill")
                    .foregroundColor(analysis.actualCost <= 0 ? .green : .orange)
                    .frame(width: 20)
                Text(analysis.actualCost <= 0 ? "Actual profit:" : "Actual cost:")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text(formatCurrency(analysis.actualCost))
                    .font(.subheadline.monospacedDigit())
                    .fontWeight(.medium)
            }
            

            // Powston API reported result — memo line (may differ slightly from LV settlement)
            if let powstonCost = analysis.powstonAPINetCost {
                HStack {
                    Image(systemName: "server.rack")
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                    Text(powstonCost <= 0 ? "Powston profit:" : "Powston cost:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatCurrency(powstonCost))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }

            // Flat rate comparison
            HStack {
                Image(systemName: "equal.circle.fill")
                    .foregroundColor(.blue)
                    .frame(width: 20)
                Text("Flat rate (\(Int(analysis.flatBuyRate))¢/\(Int(analysis.flatSellRate))¢):")
                    .font(.subheadline)
                Spacer()
                Text(formatCurrency(analysis.flatRateCost))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            }
            
            // Flat rate comparison result
            if analysis.flatRateSavings > 0.01 {
                HStack {
                    Spacer()
                    Text("Beat flat rate by \(formatCurrency(analysis.flatRateSavings))")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            } else if analysis.flatRateSavings < -0.01 {
                HStack {
                    Spacer()
                    Text("Flat rate would save \(formatCurrency(analysis.flatRateSavings))")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            
            // Total savings summary
            if analysis.totalSavings > 0 {
                HStack {
                    Spacer()
                    Text("Saved \(formatCurrency(analysis.totalSavings)) vs grid-only")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            // Tariff disclaimer
            if let tariffDesc = tariffDescription {
                HStack {
                    Spacer()
                    Text("Based on \(tariffDesc)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
}

// MARK: - Year Insights Card

struct YearInsightsCard: View {
    let summary: DayRateSummary
    let monthlySummaries: [DailySummary]
    private let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    
    var bestMonth: (Int, Double)? {
        guard !monthlySummaries.isEmpty else { return nil }
        var best = (0, monthlySummaries[0].netProfit)
        for (i, s) in monthlySummaries.enumerated() { if s.netProfit > best.1 { best = (i, s.netProfit) } }
        return best
    }
    var worstMonth: (Int, Double)? {
        guard !monthlySummaries.isEmpty else { return nil }
        var worst = (0, monthlySummaries[0].netProfit)
        for (i, s) in monthlySummaries.enumerated() { if s.netProfit < worst.1 { worst = (i, s.netProfit) } }
        return worst
    }
    var creditMonths: Int { monthlySummaries.filter { $0.netProfit > 0 }.count }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let best = bestMonth, best.1 > 0, best.0 < monthNames.count {
                Text("💰 Best month: \(monthNames[best.0]) (+$\(String(format: "%.0f", best.1)))").font(.subheadline).foregroundColor(.secondary)
            }
            if let worst = worstMonth, worst.1 < 0, worst.0 < monthNames.count {
                Text("📉 Worst month: \(monthNames[worst.0]) ($\(String(format: "%.0f", worst.1)))").font(.subheadline).foregroundColor(.secondary)
            }
            if creditMonths > 0 {
                Text("📈 \(creditMonths) of \(monthlySummaries.count) months in credit").font(.subheadline).foregroundColor(.secondary)
            }
            Text("⚡️ Avg sell rate: \(summary.formattedSellRate)").font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding().background(Color.gray.opacity(0.05)).cornerRadius(12)
    }
}
