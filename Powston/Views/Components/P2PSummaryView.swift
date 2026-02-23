import SwiftUI
import Charts

// MARK: - Data Model

enum P2PInsightType {
    case repricing
    case trend
    case spike
    case `default`
}

struct P2PSummaryData {
    // Premium hero
    var sellPremium: Double = 0         // $ above spot (hero number)
    var sellRevenue: Double = 0
    var sellKwh: Double = 0
    var sellSpotEquivalent: Double = 0
    var buyKwh: Double = 0
    var buyCost: Double = 0
    var buySpotEquivalent: Double = 0
    var premiumPerKwh: Double = 0       // cents/kWh above spot

    // Period
    var periodDays: Int = 0
    var periodDescription: String = ""

    // Forward position
    var sellOfferedKwh: Double = 0
    var sellSubscribedKwh: Double = 0
    var buyOfferedKwh: Double = 0
    var buySubscribedKwh: Double = 0

    // Sparkline buckets (6 values, each = average fill% for a 4-week bucket)
    var fillBuckets: [Double] = []

    // Insight
    var insightText: String?
    var insightType: P2PInsightType = .default
}

// MARK: - Data Loader

@MainActor
func loadP2PSummaryData(api: PowstonAPI) -> P2PSummaryData? {
    guard let siteId = api.selectedSiteId else { return nil }

    var calendar = Calendar.current
    calendar.timeZone = powstonTimezone()
    let today = calendar.startOfDay(for: Date())

    // Settlement cutoff: latest complete data date or today - 2 days
    let cutoff = api.latestCompleteDataDate ?? calendar.date(byAdding: .day, value: -2, to: today) ?? today

    // Rolling 7 finalized days before cutoff
    let rangeEnd = cutoff
    guard let rangeStart = calendar.date(byAdding: .day, value: -6, to: rangeEnd) else { return nil }

    let store = PowstonDataStore.shared

    // Premium calculation
    guard let result = store.calculateP2PPremiumForRangeDetailed(
        siteId: siteId,
        from: rangeStart,
        to: rangeEnd,
        settlementCutoff: cutoff
    ) else { return nil }

    var data = P2PSummaryData()

    // Premium hero
    data.sellPremium = result.premium
    data.sellRevenue = result.sellRevenue
    data.sellKwh = result.sellKwh
    data.sellSpotEquivalent = result.sellSpotEquivalent
    data.buyKwh = result.buyKwh
    data.buyCost = result.buyCost
    data.buySpotEquivalent = result.buySpotEquivalent
    data.premiumPerKwh = result.sellKwh > 0.001
        ? ((result.sellRevenue - result.sellSpotEquivalent) / result.sellKwh) * 100
        : 0

    // Period
    let days = (calendar.dateComponents([.day], from: rangeStart, to: rangeEnd).day ?? 0) + 1
    data.periodDays = days
    data.periodDescription = "\(days) days settled"

    // Forward position — use order group performances (same source as contract cards)
    let sellOrders = store.getActiveLVOrders(siteId: siteId, direction: "Sell")
    let buyOrders = store.getActiveLVOrders(siteId: siteId, direction: "Buy")

    let sellGroups = LVOrder.groupByContract(sellOrders)
    let buyGroups = LVOrder.groupByContract(buyOrders)

    let sellPerfs = store.getLVOrderGroupPerformances(sellGroups)
    let buyPerfs = store.getLVOrderGroupPerformances(buyGroups)

    for group in sellGroups {
        if let perf = sellPerfs[group.id] {
            data.sellOfferedKwh += perf.contract.totalVolumeKwh
            data.sellSubscribedKwh += perf.totalMatchedKwh
        } else {
            data.sellOfferedKwh += group.sumVolume
        }
    }

    for group in buyGroups {
        if let perf = buyPerfs[group.id] {
            data.buyOfferedKwh += perf.contract.totalVolumeKwh
            data.buySubscribedKwh += perf.totalMatchedKwh
        } else {
            data.buyOfferedKwh += group.sumVolume
        }
    }

    // Fill sparkline: group active sell order groups by weeks-out into 6 buckets of 4 weeks
    if !sellGroups.isEmpty {
        var buckets: [[Double]] = Array(repeating: [], count: 6)

        for group in sellGroups {
            let daysOut = max(0, calendar.dateComponents([.day], from: today, to: group.dateFrom).day ?? 0)
            let weeksOut = daysOut / 7
            let bucketIndex = min(5, weeksOut / 4)

            if let perf = sellPerfs[group.id], perf.contract.totalVolumeKwh > 0 {
                let fill = perf.totalMatchedKwh / perf.contract.totalVolumeKwh
                buckets[bucketIndex].append(min(1.0, fill))
            } else {
                buckets[bucketIndex].append(0)
            }
        }

        data.fillBuckets = buckets.map { values in
            values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
    }

    // Insight detection — check price changes on sell orders
    data.insightText = nil
    data.insightType = .default

    for order in sellOrders.prefix(10) {
        let history = store.getContractSnapshots(orderId: order.id)
        guard history.count >= 2 else { continue }

        let prev = history[history.count - 2]
        let curr = history[history.count - 1]

        if let prevPrice = prev.priceCents, let currPrice = curr.priceCents, abs(currPrice - prevPrice) > 0.01 {
            if currPrice > prevPrice {
                // Sell price UP → notable
                data.insightText = String(format: "Sell ceiling probed higher: %.1f→%.1f¢", prevPrice, currPrice)
                data.insightType = .repricing
                break
            }
        }
    }

    // If no sell repricing found, check buy orders
    if data.insightText == nil {
        for order in buyOrders.prefix(10) {
            let history = store.getContractSnapshots(orderId: order.id)
            guard history.count >= 2 else { continue }

            let prev = history[history.count - 2]
            let curr = history[history.count - 1]

            if let prevPrice = prev.priceCents, let currPrice = curr.priceCents, abs(currPrice - prevPrice) > 0.01 {
                if currPrice < prevPrice {
                    // Buy price DOWN → notable
                    data.insightText = String(format: "Buy floor dropped: %.1f→%.1f¢", prevPrice, currPrice)
                    data.insightType = .repricing
                    break
                }
            }
        }
    }

    // Default insight if none detected
    if data.insightText == nil && data.sellKwh > 0.001 {
        let premiumPerKwh = data.premiumPerKwh
        data.insightText = String(format: "P2P adds %.1f¢/kWh above spot", premiumPerKwh)
        data.insightType = .default
    }

    return data
}

// MARK: - View

struct P2PSummaryView: View {
    var directionFilter: P2PTradeDirection

    @EnvironmentObject var api: PowstonAPI
    @State private var summaryData: P2PSummaryData?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if let data = summaryData {
                summaryContent(data)
            } else {
                placeholderView
            }
        }
        .task {
            summaryData = loadP2PSummaryData(api: api)
            isLoading = false
        }
    }

    private var placeholderView: some View {
        HStack {
            Image(systemName: "chart.bar.doc.horizontal")
                .foregroundColor(.secondary)
            Text("Waiting for settlement data...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func summaryContent(_ data: P2PSummaryData) -> some View {
        VStack(spacing: 12) {
            // Section 1: P2P Premium Hero
            premiumSection(data)

            // Divider
            HStack {
                VStack { Divider() }
                Text("Contracts ↓")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                VStack { Divider() }
            }

            // Section 2: Forward Position (if there are active orders)
            if data.sellOfferedKwh > 0 || data.buyOfferedKwh > 0 {
                forwardPositionSection(data)
            }

            // Section 3: Rotating Insight
            if let insight = data.insightText {
                insightRow(insight, type: data.insightType)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Premium Section

    @ViewBuilder
    private func premiumSection(_ data: P2PSummaryData) -> some View {
        if directionFilter == .sell {
            sellPremiumDetail(data)
        } else {
            buyPremiumDetail(data)
        }
    }

    private func sellPremiumDetail(_ data: P2PSummaryData) -> some View {
        VStack(spacing: 8) {
            // Hero row
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "$%.2f above spot", data.sellPremium))
                    .font(.title2.bold())
                    .foregroundColor(data.sellPremium >= 0 ? .green : .red)
                Spacer()
                Text(data.periodDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Sell breakdown
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Revenue")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "$%.2f", data.sellRevenue))
                        .font(.subheadline.monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sold")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f kWh", data.sellKwh))
                        .font(.subheadline.monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Premium")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f¢/kWh", data.premiumPerKwh))
                        .font(.subheadline.monospacedDigit())
                        .foregroundColor(data.premiumPerKwh >= 0 ? .green : .red)
                }
                Spacer()
            }

            // Buy summary (collapsed if negligible)
            if data.buyKwh >= 1.0 {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text(String(format: "Buy: $%.2f for %.1f kWh", data.buyCost, data.buyKwh))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if data.buyKwh > 0.001 {
                HStack {
                    Text(String(format: "Buy: negligible (%.1f kWh)", data.buyKwh))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func buyPremiumDetail(_ data: P2PSummaryData) -> some View {
        VStack(spacing: 8) {
            // Hero row — for buying, show savings vs spot
            let buySavings = data.buySpotEquivalent - data.buyCost
            HStack(alignment: .firstTextBaseline) {
                if data.buyKwh >= 1.0 {
                    Text(String(format: "$%.2f %@ spot", abs(buySavings), buySavings >= 0 ? "below" : "above"))
                        .font(.title2.bold())
                        .foregroundColor(buySavings >= 0 ? .green : .red)
                } else {
                    Text("No buy trades yet")
                        .font(.title2.bold())
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(data.periodDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Buy breakdown
            if data.buyKwh >= 1.0 {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cost")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(String(format: "$%.2f", data.buyCost))
                            .font(.subheadline.monospacedDigit())
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bought")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f kWh", data.buyKwh))
                            .font(.subheadline.monospacedDigit())
                    }
                    Spacer()
                }
            }

            // Sell summary (collapsed)
            if data.sellKwh >= 1.0 {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text(String(format: "Sell: $%.2f from %.1f kWh", data.sellRevenue, data.sellKwh))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
        }
    }

    // MARK: - Forward Position

    private func forwardPositionSection(_ data: P2PSummaryData) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                if data.sellOfferedKwh > 0 {
                    forwardRing(
                        label: "Sell",
                        offered: data.sellOfferedKwh,
                        subscribed: data.sellSubscribedKwh,
                        color: .orange
                    )
                }
                if data.buyOfferedKwh > 0 {
                    forwardRing(
                        label: "Buy",
                        offered: data.buyOfferedKwh,
                        subscribed: data.buySubscribedKwh,
                        color: .blue
                    )
                }
                Spacer()
            }

            // Sparkline (if we have fill data)
            if !data.fillBuckets.isEmpty && data.fillBuckets.contains(where: { $0 > 0 }) {
                fillSparkline(data.fillBuckets)
            }
        }
    }

    private func forwardRing(label: String, offered: Double, subscribed: Double, color: Color) -> some View {
        let fill = offered > 0 ? min(1.0, subscribed / offered) : 0

        return HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fill)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 36, height: 36)
            .overlay(
                Text(String(format: "%.0f%%", fill * 100))
                    .font(.system(size: 9, weight: .bold))
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2.bold())
                    .foregroundColor(color)
                Text(String(format: "%.0f/%.0f kWh", subscribed, offered))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func fillSparkline(_ buckets: [Double]) -> some View {
        let labels = ["0-4w", "4-8w", "8-12w", "12-16w", "16-20w", "20w+"]
        let chartData = buckets.enumerated().map { (index, value) in
            (label: labels[min(index, labels.count - 1)], fill: value)
        }

        return Chart {
            ForEach(Array(chartData.enumerated()), id: \.offset) { _, item in
                BarMark(
                    x: .value("Period", item.label),
                    y: .value("Fill", item.fill * 100)
                )
                .foregroundStyle(Color.orange.opacity(0.6))
                .cornerRadius(2)
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)%")
                            .font(.system(size: 8))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel()
                    .font(.system(size: 8))
            }
        }
        .frame(height: 100)
    }

    // MARK: - Insight

    private func insightRow(_ text: String, type: P2PInsightType) -> some View {
        HStack(spacing: 6) {
            Image(systemName: insightIcon(type))
                .font(.caption)
                .foregroundColor(.orange)
            Text(text)
                .font(.caption)
                .foregroundColor(.primary.opacity(0.8))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func insightIcon(_ type: P2PInsightType) -> String {
        switch type {
        case .repricing: return "arrow.triangle.2.circlepath"
        case .trend: return "chart.line.uptrend.xyaxis"
        case .spike: return "bolt.fill"
        case .default: return "lightbulb.fill"
        }
    }
}
