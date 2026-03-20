//
//  DecisionsView.swift
//  Powston
//

import SwiftUI

struct DecisionsView: View {
    @EnvironmentObject var api: PowstonAPI
    @AppStorage("scorecard_enabled") private var scorecardEnabled: Bool = true
    @AppStorage("show_experimental_features") private var showExperimentalFeatures: Bool = false
    @State private var showDecisionTrace = false
    @State private var showActionsTable = false

    var body: some View {
        NavigationStack {
            Group {
                if let d = api.data {
                    portraitView(d)
                } else if api.selectedSite != nil && !api.apiKey.isEmpty {
                    // Zero-inverter site — show what works without inverter data
                    ScrollView {
                        VStack(spacing: 16) {
                            // Info banner
                            HStack {
                                if let site = api.selectedSite {
                                    Image(systemName: site.generationIcon)
                                        .foregroundColor(site.generationColor)
                                    Text("\(site.generationTypeLabel) — live decisions not available")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding()
                            .background((api.selectedSite?.generationColor ?? .blue).opacity(0.1))
                            .cornerRadius(12)

                            // Scorecard (uses meter_records)
                            if scorecardEnabled {
                                NavigationLink(destination: ScorecardView()) {
                                    HStack {
                                        Image(systemName: "gauge.with.dots.needle.33percent")
                                            .font(.title3)
                                            .foregroundColor(.cyan)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Performance Scorecard")
                                                .font(.subheadline)
                                                .fontWeight(.medium)
                                            Text("View detailed analysis")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding()
                                    .background(Color.gray.opacity(0.05))
                                    .cornerRadius(12)
                                }
                                .buttonStyle(.plain)
                            }

                            // Profit Intelligence (uses meter_records / site_id)
                            if !api.isDemoMode {
                                ProfitIntelligenceCard()
                            }
                        }
                        .padding()
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "brain")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No decision data")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle(api.isDemoMode ? "Decisions (Demo)" : "Decisions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SiteIndicatorPill()
                }
            }
        }
        .fullScreenCover(isPresented: $showActionsTable) {
            LandscapeContainerView {
                ActionsTableView()
                    .environmentObject(api)
            }
        }
    }
    
    // MARK: - Portrait View
    func portraitView(_ d: InverterResponse) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Current Action & Override (prominent, standalone)
                actionOverrideCard(d)

                // SOC & Price Chart (24h context)
                DecisionsChartCard()

                // Strategy / Action Items (experimental - hidden by default)
                if showExperimentalFeatures && !api.isDemoMode {
                    ActionItemsDashboardCard()
                }

                // Scorecard link (informs future decisions)
                if scorecardEnabled {
                    NavigationLink(destination: ScorecardView()) {
                        HStack {
                            Image(systemName: "gauge.with.dots.needle.33percent")
                                .font(.title3)
                                .foregroundColor(.cyan)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Performance Scorecard")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Text("View detailed analysis")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.05))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }

                // Profit Intelligence (informs future decisions)
                if !api.isDemoMode {
                    ProfitIntelligenceCard()
                }

                // Actions Table button
                Button(action: { showActionsTable = true }) {
                    HStack(spacing: 12) {
                        Image(systemName: "tablecells.badge.ellipsis")
                            .font(.title2)
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Actions Table")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("Full actions history in landscape view")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)

                // Decision Reasons Trace (detailed, at bottom)
                reasonCard(d)

                // Script version footnote
                if let scriptName = d.userCodeName {
                    HStack {
                        Spacer()
                        Text(scriptName)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
        .refreshable {
            await api.fetchData()
        }
    }
    
    // MARK: - Action Override Card (streamlined, prominent)
    func actionOverrideCard(_ d: InverterResponse) -> some View {
        NavigationLink(destination: ManualOverrideView()) {
            VStack(spacing: 12) {
                // Main action display
                HStack(spacing: 16) {
                    // Large action icon
                    ZStack {
                        Circle()
                            .fill(actionBackgroundColor(d).opacity(0.2))
                            .frame(width: 64, height: 64)

                        if api.hasPendingOverride {
                            ProgressView()
                                .scaleEffect(1.2)
                        } else if api.hasActiveOverride {
                            Image(systemName: "hand.raised.fill")
                                .font(.title)
                                .foregroundColor(.orange)
                        } else if api.hasScheduledOverride {
                            Image(systemName: "clock.fill")
                                .font(.title)
                                .foregroundColor(.blue)
                        } else {
                            Image(systemName: actionIcon(d.currentAction))
                                .font(.title)
                                .foregroundColor(actionColor(d.currentAction))
                        }
                    }

                    // Action text
                    VStack(alignment: .leading, spacing: 4) {
                        if api.hasPendingOverride {
                            Text("Override Pending")
                                .font(.title2.weight(.bold))
                                .foregroundColor(.blue)
                            Text("Waiting for confirmation...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else if api.hasActiveOverride, let firstActive = api.currentOverrides.first {
                            Text("Manual Override")
                                .font(.caption)
                                .foregroundColor(.orange)
                            Text(firstActive.action.uppercased())
                                .font(.title2.weight(.bold))
                                .foregroundColor(.orange)
                            if let endTime = firstActive.endTime {
                                Text("Until \(endTime)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        } else if api.hasScheduledOverride, let firstScheduled = api.scheduledOverrides.first {
                            Text("Scheduled Override")
                                .font(.caption)
                                .foregroundColor(.blue)
                            Text(firstScheduled.action.uppercased())
                                .font(.title2.weight(.bold))
                                .foregroundColor(.blue)
                            Text(firstScheduled.formattedStartsIn)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Current Action")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(displayAction(d.currentAction, gridKw: d.gridKw).uppercased())
                                .font(.title2.weight(.bold))
                                .foregroundColor(actionColor(d.currentAction))
                            Text(snapshotTimeText(d))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    // Override chevron
                    VStack {
                        Image(systemName: "chevron.right")
                            .font(.title3)
                            .foregroundColor(.secondary)
                        Text("Override")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding()
            .background(Color.gray.opacity(0.05))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(currentDecisionAccessibilityLabel(d))
        .accessibilityHint("Double tap to open manual override controls")
    }

    func actionBackgroundColor(_ d: InverterResponse) -> Color {
        if api.hasPendingOverride { return .blue }
        if api.hasActiveOverride { return .orange }
        if api.hasScheduledOverride { return .blue }
        return actionColor(d.currentAction)
    }

   
    // MARK: - Price & P/L Card
    
    
    // MARK: - Reason Card
    func reasonCard(_ d: InverterResponse) -> some View {
        VStack(spacing: 0) {
            // Header row (always visible)
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showDecisionTrace.toggle() } }) {
                HStack {
                    Image(systemName: "list.bullet.clipboard")
                        .font(.title3)
                        .foregroundColor(.indigo)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Decision Reasons Trace")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text(decisionTraceSummary(d.reason))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showDecisionTrace ? 90 : 0))
                }
                .padding()
            }
            .buttonStyle(.plain)
            
            // Expanded content
            if showDecisionTrace {
                Divider()
                    .padding(.horizontal)
                
                Text((d.reason ?? "No reason provided").formattedDecisionTrace)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Decision reason: \(d.reason ?? "No reason provided")")
    }

    // Add helper function after reasonCard:
    func decisionTraceSummary(_ reason: String?) -> String {
        guard let reason = reason, !reason.isEmpty else {
            return "No decision data"
        }
        
        let components = reason.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let blockedCount = components.filter { $0.contains("blocked") }.count
        
        // Find the selected priority (one without "blocked")
        if let selected = components.first(where: { !$0.contains("blocked") }) {
            // Extract priority identifier (e.g., "P1: Auto")
            if let colonIndex = selected.firstIndex(of: ":") {
                let prefix = selected.prefix(upTo: colonIndex)
                let afterColon = selected.suffix(from: selected.index(after: colonIndex)).trimmingCharacters(in: .whitespaces)
                let action = afterColon.components(separatedBy: "(").first?.trimmingCharacters(in: .whitespaces) ?? afterColon
                return "\(blockedCount) blocked → \(prefix): \(action)"
            }
        }
        
        return "\(blockedCount) priorities evaluated"
    }

    
    func currentDecisionAccessibilityLabel(_ d: InverterResponse) -> String {
        if api.hasPendingOverride {
            return "Override pending"
        } else if api.hasActiveOverride, let firstActive = api.currentOverrides.first {
            return "Manual override active: \(firstActive.action)"
        } else if api.hasScheduledOverride, let firstScheduled = api.scheduledOverrides.first {
            return "Scheduled override: \(firstScheduled.action), starts \(firstScheduled.formattedStartsIn)"
        } else {
            return "Current action: \(displayAction(d.currentAction, gridKw: d.gridKw))"
        }
    }
    
    // MARK: - Helpers
    func snapshotTimeText(_ d: InverterResponse) -> String {
        if let date = d.forecastStartDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            formatter.timeZone = powstonTimezone()
            return "Snapshot at \(formatter.string(from: date))"
        }
        return "Snapshot time unavailable"
    }
    
    /// Display action label. For export actions, just shows "export" — real-time data
    /// lacks optimal_discharging so we can't reliably distinguish trickle/p2p here.
    func displayAction(_ action: String, gridKw: Double? = nil) -> String {
        let lower = action.lowercased()
        if lower.contains("curtail") { return "curtail" }
        if lower.contains("export") { return "export" }
        if lower.contains("import") { return "import" }
        if lower.contains("discharge") { return "discharge" }
        if lower.contains("charge") { return "charge" }
        if lower.contains("auto") { return "auto" }
        return action
    }

    /// Normalized action category for color/icon matching
    private func actionCategory(_ action: String) -> String {
        let lower = action.lowercased()
        if lower.contains("curtail") { return "curtail" }
        if lower.contains("export") { return "export" }
        if lower.contains("import") { return "import" }
        if lower.contains("charge") { return "charge" }
        if lower.contains("discharge") { return "discharge" }
        if lower.contains("auto") { return "auto" }
        return lower
    }

    func actionColor(_ action: String) -> Color {
        switch actionCategory(action) {
        case "import", "charge": return .blue
        case "export", "discharge": return .green
        case "curtail": return .orange
        case "hold": return .gray
        default: return .gray
        }
    }

    func actionIcon(_ action: String) -> String {
        switch actionCategory(action) {
        case "import": return "arrow.down.circle.fill"
        case "export": return "arrow.up.circle.fill"
        case "charge": return "battery.100.bolt"
        case "curtail": return "sun.max.trianglebadge.exclamationmark"
        default: return "arrow.triangle.2.circlepath"
        }
    }
}

// MARK: - Decisions Chart Card (SOC + Prices over time)
struct DecisionsChartCard: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var socPoints: [ActionSOCPoint] = []
    @State private var isLoading = false
    @State private var loadError: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 24 Hours")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }
            
            if let error = loadError {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 40)
                    Spacer()
                }
            } else if socPoints.isEmpty && !isLoading {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "chart.xyaxis.line")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text("No data yet")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Retry") {
                            Task { await loadSOCData() }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 40)
                    Spacer()
                }
            } else if !socPoints.isEmpty {
                DecisionsChart(points: socPoints)
                    .frame(height: 180)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
        .task {
            await loadSOCData()
        }
        .onChange(of: api.selectedInverterId) { _, _ in
            Task { await loadSOCData() }
        }
    }
    
    func loadSOCData() async {
        guard !api.isDemoMode else {
            socPoints = generateDemoPoints()
            return
        }

        guard api.selectedInverterId != 0 else {
            loadError = "No inverter selected"
            return
        }

        guard let siteId = api.selectedSiteId else {
            loadError = "No site selected"
            return
        }

        isLoading = true
        loadError = nil

        let inverterId = api.selectedInverterId
        print("📊 [TIMING] Start fetch for inverter \(inverterId) (last 24h)")
        let fetchStart = Date()

        // Use the new 24-hour rolling window function
        let points = await PowstonDataStore.shared.fetchSOCHistoryLast24Hours(
            siteId: siteId,
            inverterId: inverterId
        )

        print("📊 [TIMING] Fetch complete: \(Date().timeIntervalSince(fetchStart))s, \(points.count) points")
        let renderStart = Date()

        await MainActor.run {
            if points.isEmpty {
                print("📊 No SOC points returned")
                loadError = "No action data available"
            } else {
                print("📊 [TIMING] Assigning \(points.count) points")
                socPoints = points
            }
            isLoading = false
        }

        print("📊 [TIMING] Render complete: \(Date().timeIntervalSince(renderStart))s")
    }
    
    func generateDemoPoints() -> [ActionSOCPoint] {
        var points: [ActionSOCPoint] = []
        let calendar = Calendar.current
        let now = Date()
        
        // Generate 24 hours of demo data
        for i in 0..<48 {
            let time = calendar.date(byAdding: .minute, value: -i * 30, to: now) ?? now
            let hour = calendar.component(.hour, from: time)
            
            // Simulate SOC pattern
            let soc: Double
            if hour >= 6 && hour < 10 {
                soc = Double(30 + (hour - 6) * 15)  // Morning charge
            } else if hour >= 10 && hour < 16 {
                soc = Double(90 + Int.random(in: -5...5))  // Peak solar
            } else if hour >= 16 && hour < 21 {
                soc = Double(90 - (hour - 16) * 10)  // Evening discharge
            } else {
                soc = Double(40 + Int.random(in: -5...5))  // Night
            }
            
            points.append(ActionSOCPoint(
                time: time,
                soc: max(10, min(100, soc)),
                action: "auto",
                buyPrice: Double.random(in: 5...30),
                sellPrice: Double.random(in: -5...15),
                inverterId: 0,
                inverterSerial: nil
            ))
        }
        
        return points.reversed()
    }
}

// MARK: - Decisions Chart (SOC + Prices)
struct DecisionsChart: View {
    let points: [ActionSOCPoint]
    @State private var selectedIndex: Int?
    @GestureState private var isDragging = false
    
    // Pre-compute once
    private var sortedPoints: [ActionSOCPoint] {
        points.sorted { $0.time < $1.time }
    }
    
    var body: some View {
        let sorted = sortedPoints
        let timeRange = computeTimeRange(sorted)
        let priceRange = computePriceRange(sorted)
        
        VStack(spacing: 4) {
            // Scrub info box (above chart)
            scrubInfoBox(sorted: sorted)
            
            // Chart using Canvas (much faster than Path views)
            Canvas { context, size in
                let width = size.width - 50
                let height = size.height - 30
                
                drawGridLines(context: context, height: height, width: width)
                drawSOCFill(context: context, sorted: sorted, timeRange: timeRange, width: width, height: height)
                drawSOCLine(context: context, sorted: sorted, timeRange: timeRange, width: width, height: height)
                drawPriceLine(context: context, sorted: sorted, timeRange: timeRange, priceRange: priceRange, width: width, height: height, color: .blue, keyPath: \.buyPrice)
                drawPriceLine(context: context, sorted: sorted, timeRange: timeRange, priceRange: priceRange, width: width, height: height, color: .orange, keyPath: \.sellPrice)
                
                // Scrub indicator
                if let idx = selectedIndex, idx < sorted.count {
                    drawScrubIndicator(context: context, point: sorted[idx], timeRange: timeRange, priceRange: priceRange, width: width, height: height)
                }
            }
            .frame(height: 150)
            .overlay(alignment: .bottom) {
                // Legend
                HStack(spacing: 12) {
                    legendItem(color: .green, label: "SOC")
                    legendItem(color: .blue, label: "Buy")
                    legendItem(color: .orange, label: "Sell")
                }
                .padding(.bottom, 4)
            }
            .overlay(alignment: .leading) {
                // Y-axis labels
                VStack {
                    Text("100%").font(.system(size: 8)).foregroundColor(.secondary)
                    Spacer()
                    Text("50%").font(.system(size: 8)).foregroundColor(.secondary)
                    Spacer()
                    Text("0%").font(.system(size: 8)).foregroundColor(.secondary)
                }
                .frame(width: 30)
                .padding(.bottom, 30)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, state, _ in
                        state = true
                    }
                    .onChanged { value in
                        let x = value.location.x - 40
                        let width = UIScreen.main.bounds.width - 80 - 50 // Approximate
                        guard width > 0, !sorted.isEmpty else { return }
                        let ratio = max(0, min(1, x / width))
                        let newIndex = Int(ratio * Double(sorted.count - 1))
                        if newIndex != selectedIndex {
                            selectedIndex = max(0, min(sorted.count - 1, newIndex))
                        }
                    }
                    .onEnded { _ in
                        selectedIndex = nil
                    }
            )
        }
    }
    
    @ViewBuilder
    func scrubInfoBox(sorted: [ActionSOCPoint]) -> some View {
        if let idx = selectedIndex, idx < sorted.count, isDragging {
            let point = sorted[idx]
            HStack(spacing: 12) {
                Text(formatTime(point.time))
                    .font(.caption.monospacedDigit())
                    .fontWeight(.semibold)
                
                Text(displayAction(point.action))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(actionColor(point.action))
                
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("\(Int(point.soc))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.green)
                }
                
                HStack(spacing: 4) {
                    Circle().fill(PriceColors.buyColor(point.buyPrice)).frame(width: 6, height: 6)
                    Text(PriceFormat.format(point.buyPrice))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(PriceColors.buyColor(point.buyPrice))
                }
                
                HStack(spacing: 4) {
                    Circle().fill(PriceColors.sellColor(point.sellPrice)).frame(width: 6, height: 6)
                    Text(PriceFormat.format(point.sellPrice))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(PriceColors.sellColor(point.sellPrice))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
        } else {
            Color.clear.frame(height: 28)
        }
    }
    
    // MARK: - Canvas Drawing Functions
    
    func drawGridLines(context: GraphicsContext, height: CGFloat, width: CGFloat) {
        for soc in [0.0, 25.0, 50.0, 75.0, 100.0] {
            let y = height * (1 - soc / 100)
            var path = Path()
            path.move(to: CGPoint(x: 40, y: y))
            path.addLine(to: CGPoint(x: width + 40, y: y))
            context.stroke(path, with: .color(.gray.opacity(0.2)), lineWidth: 1)
        }
    }
    
    func drawSOCLine(context: GraphicsContext, sorted: [ActionSOCPoint], timeRange: (min: Date, max: Date), width: CGFloat, height: CGFloat) {
        var path = Path()
        for (index, point) in sorted.enumerated() {
            let x = xPosition(for: point.time, timeRange: timeRange, width: width) + 40
            let y = height * (1 - point.soc / 100)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(.green), lineWidth: 2)
    }
    
    func drawSOCFill(context: GraphicsContext, sorted: [ActionSOCPoint], timeRange: (min: Date, max: Date), width: CGFloat, height: CGFloat) {
        guard let first = sorted.first else { return }
        var path = Path()
        let startX = xPosition(for: first.time, timeRange: timeRange, width: width) + 40
        path.move(to: CGPoint(x: startX, y: height))
        
        for point in sorted {
            let x = xPosition(for: point.time, timeRange: timeRange, width: width) + 40
            let y = height * (1 - point.soc / 100)
            path.addLine(to: CGPoint(x: x, y: y))
        }
        
        if let last = sorted.last {
            let endX = xPosition(for: last.time, timeRange: timeRange, width: width) + 40
            path.addLine(to: CGPoint(x: endX, y: height))
        }
        path.closeSubpath()
        context.fill(path, with: .color(.green.opacity(0.15)))
    }
    
    func drawPriceLine(context: GraphicsContext, sorted: [ActionSOCPoint], timeRange: (min: Date, max: Date), priceRange: (min: Double, max: Double), width: CGFloat, height: CGFloat, color: Color, keyPath: KeyPath<ActionSOCPoint, Double>) {
        var path = Path()
        for (index, point) in sorted.enumerated() {
            let x = xPosition(for: point.time, timeRange: timeRange, width: width) + 40
            let y = yPositionForPrice(point[keyPath: keyPath], priceRange: priceRange, height: height)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(color.opacity(0.6)), lineWidth: 1.5)
    }
    
    func drawScrubIndicator(context: GraphicsContext, point: ActionSOCPoint, timeRange: (min: Date, max: Date), priceRange: (min: Double, max: Double), width: CGFloat, height: CGFloat) {
        let x = xPosition(for: point.time, timeRange: timeRange, width: width) + 40
        
        // Vertical line
        var linePath = Path()
        linePath.move(to: CGPoint(x: x, y: 0))
        linePath.addLine(to: CGPoint(x: x, y: height))
        context.stroke(linePath, with: .color(.white.opacity(0.8)), lineWidth: 1)
        
        // SOC dot
        let socY = height * (1 - point.soc / 100)
        context.fill(Circle().path(in: CGRect(x: x - 4, y: socY - 4, width: 8, height: 8)), with: .color(.green))
        
        // Buy dot
        let buyY = yPositionForPrice(point.buyPrice, priceRange: priceRange, height: height)
        context.fill(Circle().path(in: CGRect(x: x - 3, y: buyY - 3, width: 6, height: 6)), with: .color(.blue))
        
        // Sell dot
        let sellY = yPositionForPrice(point.sellPrice, priceRange: priceRange, height: height)
        context.fill(Circle().path(in: CGRect(x: x - 3, y: sellY - 3, width: 6, height: 6)), with: .color(.orange))
    }
    
    // MARK: - Helper Functions
    
    func computeTimeRange(_ sorted: [ActionSOCPoint]) -> (min: Date, max: Date) {
        guard let first = sorted.first?.time, let last = sorted.last?.time else {
            return (Date(), Date())
        }
        return (first, last)
    }
    
    func computePriceRange(_ sorted: [ActionSOCPoint]) -> (min: Double, max: Double) {
        let allPrices = sorted.flatMap { [$0.buyPrice, $0.sellPrice] }
        let minPrice = allPrices.min() ?? 0
        let maxPrice = allPrices.max() ?? 50
        return (min(minPrice, 0) - 5, maxPrice + 5)
    }
    
    func xPosition(for date: Date, timeRange: (min: Date, max: Date), width: CGFloat) -> CGFloat {
        let totalSeconds = timeRange.max.timeIntervalSince(timeRange.min)
        guard totalSeconds > 0 else { return 0 }
        let pointSeconds = date.timeIntervalSince(timeRange.min)
        return CGFloat(pointSeconds / totalSeconds) * width
    }
    
    func yPositionForPrice(_ price: Double, priceRange: (min: Double, max: Double), height: CGFloat) -> CGFloat {
        let range = priceRange.max - priceRange.min
        guard range > 0 else { return height / 2 }
        let normalized = (price - priceRange.min) / range
        return height * (1 - normalized)
    }
    
    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = powstonTimezone()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
    
    func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
        }
    }
    
    func displayAction(_ action: String) -> String {
        let lower = action.lowercased()
        if lower.contains("curtail") { return "Curtail" }
        else if lower.contains("export") { return "Export" }
        else if lower.contains("import") { return "Import" }
        else if lower.contains("discharge") { return "Dchg" }
        else if lower.contains("charge") { return "Charge" }
        else if lower.contains("auto") || lower.contains("hold") { return "Auto" }
        return action
    }
    
    func actionColor(_ action: String) -> Color {
        let lower = action.lowercased()
        if lower.contains("curtail") { return .orange }
        else if lower.contains("export") { return .green }
        else if lower.contains("import") { return .blue }
        else if lower.contains("discharge") { return .orange }
        else if lower.contains("charge") { return .blue }
        else if lower.contains("auto") || lower.contains("hold") { return .purple }
        return .secondary
    }
}

// MARK: - Preview
#Preview {
    DecisionsView()
        .environmentObject(PowstonAPI())
}
