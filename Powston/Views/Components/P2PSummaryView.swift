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

    // Trend (current vs previous window)
    var previousPremium: Double?        // nil = no previous data
    var premiumTrend: Double = 0        // positive = improving

    // Period
    var periodDays: Int = 0
    var periodDescription: String = ""

    // Forward position
    var sellOfferedKwh: Double = 0
    var sellSubscribedKwh: Double = 0
    var buyOfferedKwh: Double = 0
    var buySubscribedKwh: Double = 0

    // Value row
    var settledValue: Double = 0        // revenue from delivered trades
    var upcomingValue: Double = 0       // contracted, delivery window still open
    var undeliveredValue: Double = 0    // contracted, delivery window passed
    var undeliveredKwh: Double = 0      // kWh that was offered but not filled
    var elapsedOfferedKwh: Double = 0   // total kWh offered in elapsed days

    // Fill rate trend (current vs previous window)
    var currentFillRate: Double?        // current window fill rate (0-1)
    var previousFillRate: Double?       // previous window fill rate (0-1)

    // Weekly sell cap progress
    var weeklySellCapKwh: Double?       // LV weekly export limit (nil = not set)
    var weekSoldKwh: Double = 0         // kWh actually sold this week (spot + P2P)

    // Sparkline buckets (average fill% per 4-week bucket, trailing empties trimmed)
    var fillBuckets: [Double] = []
    var fillBucketLabels: [String] = []

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

    // Premium calculation — current window
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

    // Trend — previous 7-day window
    if let prevEnd = calendar.date(byAdding: .day, value: -1, to: rangeStart),
       let prevStart = calendar.date(byAdding: .day, value: -6, to: prevEnd) {
        let prevResult = store.calculateP2PPremiumForRangeDetailed(
            siteId: siteId,
            from: prevStart,
            to: prevEnd,
            settlementCutoff: cutoff
        )
        if let prev = prevResult {
            data.previousPremium = prev.premium
            data.premiumTrend = result.premium - prev.premium
        }
    }

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

    // Value row — uses settlement data (authoritative) for settled & undelivered
    // Settled: actual P2P revenue from lv_daily_cashflow for elapsed days
    // Upcoming: pro-rated estimated revenue for future days
    // Undelivered: offered value for elapsed days minus actual settled revenue
    let allOrderGroups = sellGroups + buyGroups
    for group in allOrderGroups {
        guard let perf = sellPerfs[group.id] ?? buyPerfs[group.id] else { continue }
        let contract = perf.contract

        let totalDays = max(1, (calendar.dateComponents([.day], from: group.dateFrom, to: group.dateTo).day ?? 0) + 1)
        let elapsedEnd = min(group.dateTo, calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        let elapsedDays = max(0, (calendar.dateComponents([.day], from: group.dateFrom, to: elapsedEnd).day ?? 0) + 1)
        let futureDays = max(0, totalDays - elapsedDays)

        // Settled: sum actual P2P revenue & kWh from settlement data for elapsed days
        var groupSettled: Double = 0
        var groupSettledKwh: Double = 0
        var checkDate = group.dateFrom
        while checkDate <= elapsedEnd {
            if let cf = store.getLVCashflowSummary(siteId: siteId, date: checkDate) {
                groupSettled += cf.p2pMatchedRevenue
                groupSettledKwh += cf.energySoldP2PKwh
            }
            checkDate = calendar.date(byAdding: .day, value: 1, to: checkDate) ?? elapsedEnd.addingTimeInterval(86400)
        }

        // If no settlement data, fall back to trade-level data
        if groupSettled < 0.01 {
            let trades = store.getLVIntervalTrades(siteId: siteId, from: group.dateFrom, to: elapsedEnd)
            let dirMatch = contract.direction
            for trade in trades where trade.direction.rawValue == dirMatch.rawValue {
                groupSettled += trade.revenue
                groupSettledKwh += trade.volumeKwh
            }
        }

        data.settledValue += groupSettled

        // Upcoming: pro-rated estimated revenue for future days
        if futureDays > 0 {
            let dailyEstimate = contract.estimatedRevenue / Double(totalDays)
            data.upcomingValue += dailyEstimate * Double(futureDays)
        }

        // Undelivered: what was offered for elapsed days minus what was actually delivered
        if elapsedDays > 0 {
            let elapsedFraction = Double(elapsedDays) / Double(totalDays)
            let elapsedEstimate = contract.estimatedRevenue * elapsedFraction
            let elapsedOffered = contract.totalVolumeKwh * elapsedFraction
            let undelivered = max(0, elapsedEstimate - groupSettled)
            let undeliveredKwh = max(0, elapsedOffered - groupSettledKwh)
            data.undeliveredValue += undelivered
            data.undeliveredKwh += undeliveredKwh
            data.elapsedOfferedKwh += elapsedOffered
        }
    }

    // Fill sparkline: group sell order groups by weeks-out into 6 buckets of 4 weeks
    let allLabels = ["0-4w", "4-8w", "8-12w", "12-16w", "16-20w", "20w+"]
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

        // Compute averages and trim trailing empty buckets
        let averages = buckets.map { values in
            values.isEmpty ? -1.0 : values.reduce(0, +) / Double(values.count)
        }

        // Find last bucket that has orders (not empty)
        let lastPopulated = averages.lastIndex(where: { $0 >= 0 }) ?? -1
        if lastPopulated >= 0 {
            // Replace -1 (no orders in bucket) with 0, trim trailing empties
            let trimmed = Array(averages.prefix(lastPopulated + 1))
            data.fillBuckets = trimmed.map { $0 < 0 ? 0 : $0 }
            data.fillBucketLabels = Array(allLabels.prefix(lastPopulated + 1))
        }
    }

    // Fill rate trend — compare latest vs second-latest snapshot for each active sell order
    if data.sellOfferedKwh > 0 {
        data.currentFillRate = data.sellSubscribedKwh / data.sellOfferedKwh

        var latestTotal: Double = 0
        var previousTotal: Double = 0
        var hasComparison = false
        for order in sellOrders {
            let snapshots = store.getContractSnapshots(orderId: order.id)
            guard snapshots.count >= 2 else { continue }
            let curr = snapshots[snapshots.count - 1]
            let prev = snapshots[snapshots.count - 2]
            if curr.offeredVolumeKwh > 0 && prev.offeredVolumeKwh > 0 {
                latestTotal += curr.subscribedVolumeKwh / curr.offeredVolumeKwh
                previousTotal += prev.subscribedVolumeKwh / prev.offeredVolumeKwh
                hasComparison = true
            }
        }
        if hasComparison {
            data.previousFillRate = previousTotal / Double(sellOrders.count)
        }
    }

    // Weekly sell cap progress — same logic as analysis page:
    // Priority: 1) UserDefaults budget, 2) Contract-derived limit
    let lvBudgetKey = "lv_export_budget_kwh_\(siteId)"
    var weeklyCap: Double?
    if let userBudget = UserDefaults.standard.object(forKey: lvBudgetKey) as? Double, userBudget > 0 {
        weeklyCap = userBudget
    } else {
        // Fall back to contract-derived limit (same as analysis page)
        let sellContracts = store.getP2PContracts(siteId: siteId).filter { $0.direction == .sell }
        let upcomingContract = sellContracts
            .filter { calendar.startOfDay(for: $0.startDate) > today }
            .sorted { $0.startDate < $1.startDate }
            .first
        let mostRecentContract = sellContracts
            .sorted { $0.createdAt > $1.createdAt }
            .first
        if let upcoming = upcomingContract {
            weeklyCap = upcoming.totalVolumeKwh
        } else if let recent = mostRecentContract {
            weeklyCap = recent.totalVolumeKwh
        }
    }

    if let cap = weeklyCap, cap > 0 {
        data.weeklySellCapKwh = cap

        // Find start of current week (Monday)
        var weekStart = today
        while calendar.component(.weekday, from: weekStart) != 2 { // Monday = 2
            weekStart = calendar.date(byAdding: .day, value: -1, to: weekStart)!
        }

        // Sum exported kWh from settlement data for this week
        var weekExported: Double = 0
        var checkDate = weekStart
        while checkDate < today {
            if let cf = store.getLVCashflowSummary(siteId: siteId, date: checkDate) {
                weekExported += cf.energySoldSpotKwh + cf.energySoldP2PKwh
            }
            checkDate = calendar.date(byAdding: .day, value: 1, to: checkDate)!
        }
        data.weekSoldKwh = weekExported
    }

    // Insight detection — priority ordered

    // Priority 1: Repricing events (sell price UP or buy price DOWN)
    data.insightText = nil
    data.insightType = .default

    for order in sellOrders.prefix(10) {
        let history = store.getContractSnapshots(orderId: order.id)
        guard history.count >= 2 else { continue }

        let prev = history[history.count - 2]
        let curr = history[history.count - 1]

        if let prevPrice = prev.priceCents, let currPrice = curr.priceCents, abs(currPrice - prevPrice) > 0.01 {
            if currPrice > prevPrice {
                data.insightText = String(format: "Sell ceiling probed higher: %.1f\u{2192}%.1f\u{00A2}", prevPrice, currPrice)
                data.insightType = .repricing
                break
            }
        }
    }

    if data.insightText == nil {
        for order in buyOrders.prefix(10) {
            let history = store.getContractSnapshots(orderId: order.id)
            guard history.count >= 2 else { continue }

            let prev = history[history.count - 2]
            let curr = history[history.count - 1]

            if let prevPrice = prev.priceCents, let currPrice = curr.priceCents, abs(currPrice - prevPrice) > 0.01 {
                if currPrice < prevPrice {
                    data.insightText = String(format: "Buy floor dropped: %.1f\u{2192}%.1f\u{00A2}", prevPrice, currPrice)
                    data.insightType = .repricing
                    break
                }
            }
        }
    }

    // Priority 2: Revenue spike (any day in window > 2x average)
    if data.insightText == nil && data.sellKwh > 0.001 {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE"
        dateFormatter.timeZone = powstonTimezone()

        var dailyRevenues: [(Date, Double)] = []
        var currentDate = rangeStart
        while currentDate <= rangeEnd {
            if let dayResult = store.calculateP2PPremium(siteId: siteId, date: currentDate) {
                dailyRevenues.append((currentDate, dayResult.sellRevenue))
            }
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? rangeEnd
        }

        if dailyRevenues.count >= 3 {
            let avgRevenue = dailyRevenues.map(\.1).reduce(0, +) / Double(dailyRevenues.count)
            if let best = dailyRevenues.max(by: { $0.1 < $1.1 }), avgRevenue > 0.01 && best.1 > avgRevenue * 2 {
                let dayName = dateFormatter.string(from: best.0)
                data.insightText = String(format: "Best day: $%.2f on %@", best.1, dayName)
                data.insightType = .spike
            }
        }
    }

    // Priority 3: Default fallback
    if data.insightText == nil && data.sellKwh > 0.001 {
        data.insightText = String(format: "P2P adds %.1f\u{00A2}/kWh above spot", data.premiumPerKwh)
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
                Text("Contracts \u{2193}")
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
                if data.previousPremium != nil {
                    trendArrow(data.premiumTrend)
                }
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
                    Text(String(format: "%.1f\u{00A2}/kWh", data.premiumPerKwh))
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
                    if data.previousPremium != nil {
                        trendArrow(-data.premiumTrend, invertColors: true)  // Inverted: lower cost is better for buy
                    }
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

    // MARK: - Trend Arrow

    private func trendArrow(_ delta: Double, invertColors: Bool = false) -> some View {
        let upColor: Color = invertColors ? .red : .green
        let downColor: Color = invertColors ? .green : .red
        return Group {
            if abs(delta) < 0.50 {
                // Less than 50c change — flat
                Image(systemName: "minus")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if delta > 0 {
                Image(systemName: "arrow.up")
                    .font(.caption2.bold())
                    .foregroundColor(upColor)
            } else {
                Image(systemName: "arrow.down")
                    .font(.caption2.bold())
                    .foregroundColor(downColor)
            }
        }
    }

    /// Fill rate trend arrow — uses percentage point delta (0-1 scale)
    private func fillRateTrendArrow(_ current: Double?, _ previous: Double?) -> some View {
        Group {
            if let curr = current, let prev = previous {
                let delta = curr - prev
                if abs(delta) < 0.02 {
                    Image(systemName: "minus")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if delta > 0 {
                    Image(systemName: "arrow.up")
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "arrow.down")
                        .font(.caption2.bold())
                        .foregroundColor(.red)
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

                // Fill rate with trend arrow
                if let fillRate = data.currentFillRate {
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 3) {
                            Text(String(format: "%.0f%%", fillRate * 100))
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundColor(.primary)
                            fillRateTrendArrow(data.currentFillRate, data.previousFillRate)
                        }
                        Text("Fill rate")
                            .font(.caption2)
                            .foregroundColor(.primary.opacity(0.7))
                    }
                }
            }

            // Weekly sell cap progress
            if let cap = data.weeklySellCapKwh, cap > 0 {
                weeklyCapRow(sold: data.weekSoldKwh, cap: cap)
            }

            // Value row (if any values exist)
            if data.settledValue > 0.01 || data.upcomingValue > 0.01 || data.undeliveredValue > 0.01 {
                valueRow(data)
            }

            // Sparkline (if we have fill data)
            if !data.fillBuckets.isEmpty && data.fillBuckets.contains(where: { $0 > 0 }) {
                fillSparkline(data.fillBuckets, labels: data.fillBucketLabels)
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

    // MARK: - Weekly Cap Row

    private func weeklyCapRow(sold: Double, cap: Double) -> some View {
        let pct = min(1.0, sold / cap)
        let barColor: Color = pct > 0.9 ? .red : pct > 0.7 ? .orange : .green
        return VStack(spacing: 4) {
            HStack {
                Text("LV Limit")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f / %.0f kWh (%.0f%%)", sold, cap, pct * 100))
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.primary.opacity(0.7))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.2))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: geo.size.width * pct)
                }
            }
            .frame(height: 4)
        }
    }

    // MARK: - Value Row

    private func valueRow(_ data: P2PSummaryData) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                valueColumn(
                    label: "Settled",
                    value: data.settledValue,
                    color: .green
                )
                Spacer()
                valueColumn(
                    label: "Upcoming",
                    value: data.upcomingValue,
                    color: .orange
                )
                Spacer()
                valueColumn(
                    label: "Undelivered",
                    value: data.undeliveredValue,
                    color: .primary.opacity(0.6)
                )
            }

            // Undelivered detail line
            if data.undeliveredKwh > 0.1 {
                let pct = data.elapsedOfferedKwh > 0
                    ? (data.undeliveredKwh / data.elapsedOfferedKwh) * 100
                    : 0
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                    Text(String(format: "$%.2f / %.1f kWh undelivered (%.0f%% of offered)", data.undeliveredValue, data.undeliveredKwh, pct))
                        .font(.caption2)
                }
                .foregroundColor(.primary.opacity(0.6))
            }
        }
    }

    private func valueColumn(label: String, value: Double, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(String(format: "$%.0f", value))
                .font(.subheadline.bold().monospacedDigit())
                .foregroundColor(color)
        }
    }

    // MARK: - Sparkline

    private func fillSparkline(_ buckets: [Double], labels: [String]) -> some View {
        let chartData = buckets.enumerated().map { (index, value) in
            (label: index < labels.count ? labels[index] : "\(index)", fill: value)
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
            AxisMarks { _ in
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
