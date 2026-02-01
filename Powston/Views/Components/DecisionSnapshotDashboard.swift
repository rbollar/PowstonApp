//
//  DecisionSnapshotCard.swift
//  Powston
//
//  A 5-minute decision snapshot dashboard showing energy flow visualization
//

import SwiftUI

// MARK: - Main Dashboard View
struct DecisionSnapshotDashboard: View {
    let data: PowstonData
    
    // Animation state for flow dots
    @State private var flowPhase: CGFloat = 0
    
    var body: some View {
        VStack(spacing: 16) {
            // Main card
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Text("5-MINUTE DECISION SNAPSHOT")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    
                    Spacer()
                    
                    // Interval time
                    if let intervalTime = data.intervalTime {
                        Text(formatIntervalTime(intervalTime))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // SOC Bar
                SnapshotSOCBar(soc: data.batterySoc ?? 0)
                
                // Energy Flow Diagram
                SnapshotEnergyFlow(
                    solarKw: data.solarKw,
                    homeKw: data.displayHouseKw,
                    gridKw: data.gridKw,
                    batteryKw: data.batteryKw,
                    batterySoc: data.batterySoc ?? 0,
                    currentAction: data.currentAction,
                    flowPhase: flowPhase
                )
                .frame(height: 200)
                
                // Price Pills
                HStack(spacing: 12) {
                    SnapshotPricePill(label: "Buy", value: data.buyPrice ?? 0, color: .blue)
                    SnapshotPricePill(label: "Sell", value: data.sellPrice ?? 0, color: sellPriceColor)
                    Spacer()
                }
                
                // Decision Explanation
                SnapshotDecisionExplanation(
                    headline: decisionHeadline,
                    reason: decisionReason,
                    fullReason: data.reason
                )
                
                // Large Price Cards
                HStack(spacing: 12) {
                    SnapshotLargePriceCard(label: "Buy Price", value: data.buyPrice ?? 0, color: .blue)
                    SnapshotLargePriceCard(label: "Sell Price", value: data.sellPrice ?? 0, color: sellPriceColor)
                }
            }
            .padding(20)
            .background(Color(.systemBackground))
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 2)
            .padding(.horizontal)
            
            // P&L Card
            TodayPLCard()
                .padding(.horizontal)
        }
        .onAppear {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                flowPhase = 1
            }
        }
    }
    
    var sellPriceColor: Color {
        (data.sellPrice ?? 0) < 0 ? .red : .green
    }
    
    // MARK: - Decision Logic
    var decisionHeadline: String {
        let action = data.currentAction.lowercased()
        
        switch action {
        case "charge", "import":
            return "Charging battery from grid"
        case "discharge", "export":
            return "Exporting to grid for profit"
        case "auto":
            if data.solarKw > data.displayHouseKw {
                return "Solar covering home load"
            } else if abs(data.gridKw) < 0.1 {
                return "Balancing for minimal grid use"
            } else {
                return "Optimizing energy flow"
            }
        case "curtail":
            return "Curtailing to limit export"
        default:
            return "Optimizing energy flow"
        }
    }
    
    var decisionReason: String {
        let action = data.currentAction.lowercased()
        let buy = data.buyPrice ?? 0
        let sell = data.sellPrice ?? 0
        
        switch action {
        case "charge", "import":
            if buy < 5 {
                return "Ultra-low prices make grid charging very economical"
            }
            return "Low prices make grid charging economical"
        case "discharge", "export":
            if sell > 20 {
                return "High sell prices maximize revenue"
            }
            return "Favorable spread for battery arbitrage"
        case "auto":
            return "Letting the algorithm optimize in real time"
        case "curtail":
            return "Export limited to stay within grid constraints"
        default:
            return "Letting the algorithm optimize in real time"
        }
    }
    
    func formatIntervalTime(_ str: String) -> String {
        // Parse ISO format and show time
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        if let date = formatter.date(from: str) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            return timeFormatter.string(from: date)
        }
        
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: str) {
            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            return timeFormatter.string(from: date)
        }
        
        return str
    }
}

// MARK: - SOC Bar View
struct SnapshotSOCBar: View {
    let soc: Double
    
    var socColor: Color {
        if soc >= 80 { return .green }
        if soc >= 40 { return .yellow }
        if soc >= 20 { return .orange }
        return .red
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("State of Charge")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer()
                Text(String(format: "%.0f%%", soc))
                    .font(.title2)
                    .fontWeight(.bold)
            }
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.gray.opacity(0.2))
                        .frame(height: 8)
                    
                    // Filled portion
                    RoundedRectangle(cornerRadius: 4)
                        .fill(socColor)
                        .frame(width: geo.size.width * min(soc / 100, 1), height: 8)
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - Energy Flow Diagram
struct SnapshotEnergyFlow: View {
    let solarKw: Double
    let homeKw: Double
    let gridKw: Double
    let batteryKw: Double
    let batterySoc: Double
    let currentAction: String
    var flowPhase: CGFloat = 0
    
    var isGridExporting: Bool { gridKw < 0 }
    var isCharging: Bool { batteryKw < 0 }  // Negative = charging in our convention
    
    var body: some View {
        GeometryReader { geo in
            let centerX = geo.size.width / 2
            let centerY = geo.size.height / 2
            
            // Node positions
            let solarPos = CGPoint(x: centerX, y: 30)
            let gridPos = CGPoint(x: 50, y: centerY)
            let batteryPos = CGPoint(x: centerX, y: centerY)
            let homePos = CGPoint(x: geo.size.width - 50, y: centerY)
            
            ZStack {
                // Flow lines with animated dots
                // Solar to Battery
                if solarKw > 0.01 {
                    SnapshotFlowLine(from: solarPos, to: batteryPos, isActive: true, flowPhase: flowPhase, color: .yellow)
                }
                
                // Grid to/from Battery
                if abs(gridKw) > 0.01 {
                    if isGridExporting {
                        // Exporting: battery -> grid
                        SnapshotFlowLine(from: batteryPos, to: gridPos, isActive: true, flowPhase: flowPhase, color: .green)
                    } else {
                        // Importing: grid -> battery
                        SnapshotFlowLine(from: gridPos, to: batteryPos, isActive: true, flowPhase: flowPhase, color: .blue)
                    }
                }
                
                // Battery to Home
                if homeKw > 0.01 {
                    SnapshotFlowLine(from: batteryPos, to: homePos, isActive: true, flowPhase: flowPhase, color: .purple)
                }
                
                // Nodes
                // Solar Node
                SnapshotEnergyNode(
                    icon: "sun.max.fill",
                    label: "SOLAR",
                    value: formatPower(solarKw),
                    color: .yellow,
                    isHighlighted: solarKw > 0.01
                )
                .position(solarPos)
                
                // Grid Node
                SnapshotEnergyNode(
                    icon: "bolt.fill",
                    label: "GRID",
                    value: formatPower(abs(gridKw)),
                    color: isGridExporting ? .green : .blue,
                    isHighlighted: abs(gridKw) > 0.01,
                    subtitle: isGridExporting ? "Export" : "Import"
                )
                .position(gridPos)
                
                // Battery Node (center)
                SnapshotBatteryNode(
                    soc: batterySoc,
                    power: batteryKw,
                    action: currentAction
                )
                .position(batteryPos)
                
                // Home Node
                SnapshotEnergyNode(
                    icon: "house.fill",
                    label: "HOME",
                    value: formatPower(homeKw),
                    color: .purple,
                    isHighlighted: homeKw > 0.01
                )
                .position(homePos)
            }
        }
    }
    
    func formatPower(_ kw: Double) -> String {
        if abs(kw) < 1 {
            return String(format: "%.0f W", abs(kw) * 1000)
        }
        return String(format: "%.1f kW", abs(kw))
    }
}

// MARK: - Flow Line with Animated Dots
struct SnapshotFlowLine: View {
    let from: CGPoint
    let to: CGPoint
    let isActive: Bool
    var flowPhase: CGFloat = 0
    var color: Color = .blue
    
    var body: some View {
        ZStack {
            // Base line
            Path { path in
                path.move(to: from)
                path.addLine(to: to)
            }
            .stroke(Color.gray.opacity(0.3), lineWidth: 2)
            
            // Animated dots
            if isActive {
                SnapshotFlowDots(from: from, to: to, phase: flowPhase, color: color)
            }
        }
    }
}

// MARK: - Flow Dots Animation
struct SnapshotFlowDots: View {
    let from: CGPoint
    let to: CGPoint
    let phase: CGFloat
    var color: Color = .blue
    
    var body: some View {
        let dotCount = 4
        
        ForEach(0..<dotCount, id: \.self) { i in
            let progress = (phase + CGFloat(i) / CGFloat(dotCount)).truncatingRemainder(dividingBy: 1)
            let x = from.x + (to.x - from.x) * progress
            let y = from.y + (to.y - from.y) * progress
            
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .position(x: x, y: y)
                .opacity(progress > 0.1 && progress < 0.9 ? 1 : 0)
        }
    }
}

// MARK: - Energy Node
struct SnapshotEnergyNode: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    var isHighlighted: Bool = false
    var subtitle: String? = nil
    
    var body: some View {
        VStack(spacing: 4) {
            // Icon container
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHighlighted ? color.opacity(0.15) : Color.gray.opacity(0.1))
                    .frame(width: 56, height: 56)
                
                if isHighlighted {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(color, lineWidth: 2)
                        .frame(width: 56, height: 56)
                }
                
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(isHighlighted ? color : .gray)
            }
            
            Text(label)
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(isHighlighted ? color : .secondary)
            
            if let subtitle = subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Battery Node (Center)
struct SnapshotBatteryNode: View {
    let soc: Double
    let power: Double
    let action: String
    
    var displayAction: String {
        action.uppercased()
    }
    
    var isCharging: Bool { power < 0 }
    
    var body: some View {
        VStack(spacing: 4) {
            Text(displayAction)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(actionColor)
            
            // Battery icon with SOC visualization
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.1))
                    .frame(width: 64, height: 64)
                
                // Battery shape
                VStack(spacing: 2) {
                    // Battery tip
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.4))
                        .frame(width: 12, height: 4)
                    
                    // Battery body
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.4), lineWidth: 2)
                            .frame(width: 28, height: 36)
                        
                        RoundedRectangle(cornerRadius: 2)
                            .fill(socColor)
                            .frame(width: 24, height: max(2, 32 * soc / 100))
                            .padding(.bottom, 2)
                    }
                }
            }
            
            Text(formatPower(power))
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(.systemBackground))
                .cornerRadius(8)
                .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
        }
    }
    
    var socColor: Color {
        if soc >= 80 { return .green }
        if soc >= 40 { return .yellow }
        if soc >= 20 { return .orange }
        return .red
    }
    
    var actionColor: Color {
        switch action.lowercased() {
        case "import", "charge": return .blue
        case "export", "discharge": return .green
        case "curtail": return .orange
        default: return .gray
        }
    }
    
    func formatPower(_ kw: Double) -> String {
        if abs(kw) < 1 {
            return String(format: "%.0f W", abs(kw) * 1000)
        }
        return String(format: "%.1f kW", abs(kw))
    }
}

// MARK: - Price Pill
struct SnapshotPricePill: View {
    let label: String
    let value: Double
    let color: Color
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(String(format: "%.1f¢", value))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(16)
    }
}

// MARK: - Decision Explanation
struct SnapshotDecisionExplanation: View {
    let headline: String
    let reason: String
    let fullReason: String?
    
    @State private var showingTrace = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.title3)
                .fontWeight(.semibold)
            
            Text("Why: \(reason)")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            if fullReason != nil {
                Button(action: { showingTrace.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: showingTrace ? "chevron.down" : "chevron.right")
                            .font(.caption)
                        Text("Show decision trace")
                            .font(.subheadline)
                    }
                    .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                
                if showingTrace, let trace = fullReason {
                    Text(cleanReasonTrace(trace))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                }
            }
        }
    }
    
    func cleanReasonTrace(_ trace: String) -> String {
        // Clean up the reason trace for display
        trace
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }
}

// MARK: - Large Price Card
struct SnapshotLargePriceCard: View {
    let label: String
    let value: Double
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(color)
            
            Text(String(format: "%.2f¢", value))
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Preview
#Preview {
    ScrollView {
        DecisionSnapshotDashboard(
            data: PowstonData(
                batterySocRaw: 85,
                batteryPower: -5000,
                action: "import",
                solarPower: 8000,
                gridPower: 3000,
                housePower: 2500,
                buyPrice: 8.5,
                sellPrice: 5.2,
                reason: "P82: Physics urgent charge→import"
            )
        )
    }
    .background(Color.gray.opacity(0.1))
}
