//
//  ActionValuesExplorer.swift
//  Powston
//
//  Hierarchical explorer for action values JSON
//

import SwiftUI

struct ActionValuesExplorer: View {
    let valuesJSON: String
    let inverterSerial: String
    
    @State private var parsedValues: [String: Any] = [:]
    @State private var searchText = ""
    @State private var expandedSections: Set<String> = ["Decision Chain", "Current State"]
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Search bar
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search keys...", text: $searchText)
                            .textFieldStyle(.plain)
                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(10)
                    .padding(.horizontal)
                    
                    if searchText.isEmpty {
                        // Curated sections
                        curatedSectionsView
                    } else {
                        // Search results
                        searchResultsView
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Values Explorer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(inverterSerial)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            parseJSON()
        }
    }
    
    // MARK: - Curated Sections
    var curatedSectionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Decision Chain
            CollapsibleSection(
                title: "Decision Chain",
                icon: "arrow.triangle.branch",
                isExpanded: expandedSections.contains("Decision Chain"),
                onToggle: { toggleSection("Decision Chain") }
            ) {
                decisionChainView
            }
            
            // Current State
            CollapsibleSection(
                title: "Current State",
                icon: "gauge.with.dots.needle.bottom.50percent",
                isExpanded: expandedSections.contains("Current State"),
                onToggle: { toggleSection("Current State") }
            ) {
                currentStateView
            }
            
            // User Config
            CollapsibleSection(
                title: "User Config",
                icon: "slider.horizontal.3",
                isExpanded: expandedSections.contains("User Config"),
                onToggle: { toggleSection("User Config") }
            ) {
                userConfigView
            }
            
            // Thresholds
            CollapsibleSection(
                title: "Thresholds",
                icon: "dial.low",
                isExpanded: expandedSections.contains("Thresholds"),
                onToggle: { toggleSection("Thresholds") }
            ) {
                thresholdsView
            }
            
            // Floor Calculation
            CollapsibleSection(
                title: "Floor Calculation",
                icon: "square.stack.3d.down.right",
                isExpanded: expandedSections.contains("Floor Calculation"),
                onToggle: { toggleSection("Floor Calculation") }
            ) {
                floorCalculationView
            }
            
            // Forecasts
            CollapsibleSection(
                title: "Forecasts",
                icon: "chart.line.uptrend.xyaxis",
                isExpanded: expandedSections.contains("Forecasts"),
                onToggle: { toggleSection("Forecasts") }
            ) {
                forecastsView
            }
            
            // Weather
            CollapsibleSection(
                title: "Weather",
                icon: "cloud.sun",
                isExpanded: expandedSections.contains("Weather"),
                onToggle: { toggleSection("Weather") }
            ) {
                weatherView
            }
        }
        .padding(.horizontal)
    }
    
    // MARK: - Decision Chain
    var decisionChainView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let decisions = parsedValues["decisions"] as? [String: Any],
               let decisionArray = decisions["decisions"] as? [[String: Any]] {
                ForEach(Array(decisionArray.enumerated()), id: \.offset) { index, decision in
                    DecisionRow(decision: decision, index: index)
                }
                
                if let currentAction = decisions["current_action"] as? String,
                   let currentPriority = decisions["current_priority"] as? Int {
                    HStack {
                        Text("Final:")
                            .font(.caption.weight(.semibold))
                        Text(currentAction.uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundColor(actionColor(currentAction))
                        Text("(P\(currentPriority))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
            } else {
                Text("No decision data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Current State
    var currentStateView: some View {
        let stateKeys: [(key: String, label: String, unit: String)] = [
            ("battery_soc", "Battery SOC", "%"),
            ("buy_price", "Buy Price", "¢"),
            ("sell_price", "Sell Price", "¢"),
            ("solar_power", "Solar Power", "W"),
            ("grid_power", "Grid Power", "W"),
            ("house_power", "House Power", "W"),
            ("battery_power", "Battery Power", "W"),
            ("battery_kwh_current", "Battery kWh", "kWh"),
            ("solar_remaining_kwh", "Solar Remaining", "kWh"),
            ("daytime_deficit_kwh", "Daytime Deficit", "kWh"),
        ]
        
        return KeyValueGrid(items: stateKeys.compactMap { item in
            if let value = findValue(item.key) {
                return (item.label, formatValue(value, unit: item.unit))
            }
            return nil
        })
    }
    
    // MARK: - User Config
    var userConfigView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let config = parsedValues["CONFIG"] as? [String: Any] {
                let sortedKeys = config.keys.sorted()
                ForEach(sortedKeys, id: \.self) { key in
                    if let value = config[key], !isFunction(value) {
                        KeyValueRow(key: formatConfigKey(key), value: formatValue(value))
                    }
                }
            } else {
                Text("No config data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Thresholds
    var thresholdsView: some View {
        let thresholdKeys = parsedValues.keys.filter { 
            $0.contains("threshold") || $0.contains("THRESHOLD") || $0.hasPrefix("threshold_")
        }.sorted()
        
        return VStack(alignment: .leading, spacing: 4) {
            if thresholdKeys.isEmpty {
                Text("No threshold data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(thresholdKeys, id: \.self) { key in
                    if let value = parsedValues[key] {
                        KeyValueRow(key: formatConfigKey(key), value: formatValue(value))
                    }
                }
            }
        }
    }
    
    // MARK: - Floor Calculation
    var floorCalculationView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let floor = parsedValues["floor"] as? [String: Any] {
                let sortedKeys = floor.keys.sorted()
                ForEach(sortedKeys, id: \.self) { key in
                    if let value = floor[key], !isFunction(value) {
                        KeyValueRow(key: formatConfigKey(key), value: formatValue(value))
                    }
                }
            } else {
                // Fall back to top-level floor-related keys
                let floorKeys = ["active_floor", "floor_threshold", "floor_kwh", "export_floor_soc", 
                                "overnight_kwh", "deficit_kwh", "safety_kwh", "final_budget_kwh"]
                ForEach(floorKeys, id: \.self) { key in
                    if let value = parsedValues[key] {
                        KeyValueRow(key: formatConfigKey(key), value: formatValue(value))
                    }
                }
            }
        }
    }
    
    // MARK: - Forecasts
    var forecastsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Buy forecast
            if let buyForecast = parsedValues["buy_forecast_disc"] as? [Double] {
                ForecastSparkline(title: "Buy Forecast", values: buyForecast, color: .blue)
            }
            
            // Sell forecast
            if let sellForecast = parsedValues["sell_forecast_disc"] as? [Double] {
                ForecastSparkline(title: "Sell Forecast", values: sellForecast, color: .green)
            }
            
            // Solar GTI
            if let gti = parsedValues["hourly_gti"] as? [Double] {
                ForecastSparkline(title: "Solar GTI", values: gti, color: .orange)
            }
            
            // Action pattern
            if let pattern = parsedValues["action_pattern"] as? [String] {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Action Pattern")
                        .font(.caption.weight(.semibold))
                    HStack(spacing: 2) {
                        ForEach(Array(pattern.enumerated()), id: \.offset) { idx, action in
                            Rectangle()
                                .fill(actionColor(action))
                                .frame(width: 8, height: 20)
                                .cornerRadius(2)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Weather
    var weatherView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let weather = parsedValues["weather_data"] as? [String: Any] {
                // Current conditions
                if let current = weather["current"] as? [String: Any] {
                    if let cloudCover = current["cloud_cover"] as? Int {
                        KeyValueRow(key: "Cloud Cover", value: "\(cloudCover)%")
                    }
                }
                
                // Hourly data summary
                if let hourly = weather["hourly"] as? [String: Any] {
                    if let temps = hourly["temperature_2m"] as? [Double], !temps.isEmpty {
                        let nextTemps = Array(temps.prefix(12))
                        ForecastSparkline(title: "Temperature (12h)", values: nextTemps, color: .red, suffix: "°C")
                    }
                    if let clouds = hourly["cloud_cover"] as? [Int], !clouds.isEmpty {
                        let nextClouds = Array(clouds.prefix(12)).map { Double($0) }
                        ForecastSparkline(title: "Cloud Cover (12h)", values: nextClouds, color: .gray, suffix: "%")
                    }
                }
            } else {
                // Fall back to top-level weather keys
                if let cloudCover = parsedValues["cloud_cover"] {
                    KeyValueRow(key: "Cloud Cover", value: formatValue(cloudCover, unit: "%"))
                }
                if let sunrise = parsedValues["sunrise"] as? String {
                    KeyValueRow(key: "Sunrise", value: formatTimeString(sunrise))
                }
                if let sunset = parsedValues["sunset"] as? String {
                    KeyValueRow(key: "Sunset", value: formatTimeString(sunset))
                }
            }
        }
    }
    
    // MARK: - Search Results
    var searchResultsView: some View {
        let results = searchKeys(searchText)
        
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(results.count) results")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal)
            
            ForEach(results, id: \.key) { result in
                KeyValueRow(key: result.key, value: result.value)
                    .padding(.horizontal)
            }
        }
    }
    
    // MARK: - Helpers
    func parseJSON() {
        guard let data = valuesJSON.data(using: .utf8) else { return }
        do {
            if let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                parsedValues = dict
            }
        } catch {
            print("Failed to parse values JSON: \(error)")
        }
    }
    
    func toggleSection(_ section: String) {
        if expandedSections.contains(section) {
            expandedSections.remove(section)
        } else {
            expandedSections.insert(section)
        }
    }
    
    func findValue(_ key: String) -> Any? {
        // Check top level
        if let value = parsedValues[key] {
            return value
        }
        // Check runtime_params
        if let runtime = parsedValues["runtime_params"] as? [String: Any],
           let value = runtime[key] {
            return value
        }
        // Check floor
        if let floor = parsedValues["floor"] as? [String: Any],
           let value = floor[key] {
            return value
        }
        return nil
    }
    
    func searchKeys(_ query: String) -> [(key: String, value: String)] {
        let lowercaseQuery = query.lowercased()
        var results: [(key: String, value: String)] = []
        
        func searchDict(_ dict: [String: Any], prefix: String = "") {
            for (key, value) in dict {
                let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
                
                if key.lowercased().contains(lowercaseQuery) && !isFunction(value) {
                    results.append((fullKey, formatValue(value)))
                }
                
                if let nested = value as? [String: Any] {
                    searchDict(nested, prefix: fullKey)
                }
            }
        }
        
        searchDict(parsedValues)
        return results.sorted { $0.key < $1.key }
    }
    
    func isFunction(_ value: Any) -> Bool {
        if let str = value as? String {
            return str.hasPrefix("<function ")
        }
        return false
    }
    
    func formatValue(_ value: Any, unit: String = "") -> String {
        if let str = value as? String {
            // Clean up escaped characters
            let cleaned = str
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\/", with: "/")
            return cleaned
        }
        if let num = value as? Double {
            if unit == "%" {
                return String(format: "%.1f%%", num)
            } else if unit == "¢" {
                return String(format: "%.1f¢", num)
            } else if unit == "W" {
                return String(format: "%.0fW", num)
            } else if unit == "kWh" {
                return String(format: "%.1f kWh", num)
            }
            // Smart formatting
            if num == floor(num) {
                return String(format: "%.0f", num)
            } else if abs(num) < 0.01 {
                return String(format: "%.4f", num)
            } else {
                return String(format: "%.2f", num)
            }
        }
        if let num = value as? Int {
            return "\(num)"
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let array = value as? [Any] {
            if array.count <= 5 {
                return "[\(array.map { formatValue($0) }.joined(separator: ", "))]"
            }
            return "[\(array.count) items]"
        }
        if let dict = value as? [String: Any] {
            return "{\(dict.count) keys}"
        }
        if value is NSNull {
            return "null"
        }
        return String(describing: value)
    }
    
    func formatConfigKey(_ key: String) -> String {
        // Convert SCREAMING_SNAKE_CASE to Title Case
        key.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
    
    func formatTimeString(_ str: String) -> String {
        // Extract just the time portion from ISO string
        if let range = str.range(of: "\\d{2}:\\d{2}:\\d{2}", options: .regularExpression) {
            return String(str[range])
        }
        return str
    }
    
    func actionColor(_ action: String) -> Color {
        switch action.lowercased() {
        case "import", "charge": return .blue
        case "export", "discharge": return .green
        case "auto": return .gray
        case "curtail": return .orange
        default: return .gray
        }
    }
}

// MARK: - Supporting Views

struct CollapsibleSection<Content: View>: View {
    let title: String
    let icon: String
    let isExpanded: Bool
    let onToggle: () -> Void
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onToggle) {
                HStack {
                    Image(systemName: icon)
                        .frame(width: 24)
                        .foregroundColor(.accentColor)
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                content
                    .padding(.leading, 32)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.05))
        .cornerRadius(12)
    }
}

struct DecisionRow: View {
    let decision: [String: Any]
    let index: Int
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Priority badge
                if let priority = decision["priority"] as? Int {
                    Text("P\(priority)")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(priorityColor(priority).opacity(0.2))
                        .foregroundColor(priorityColor(priority))
                        .cornerRadius(4)
                }
                
                // Action
                if let action = decision["action"] as? String {
                    Text(action.uppercased())
                        .font(.caption.weight(.semibold))
                        .foregroundColor(actionColor(action))
                }
                
                // Applied indicator
                if let applied = decision["applied"] as? Bool {
                    Image(systemName: applied ? "checkmark.circle.fill" : "circle")
                        .font(.caption)
                        .foregroundColor(applied ? .green : .secondary)
                }
                
                Spacer()
            }
            
            // Reason (cleaned up)
            if let reason = decision["reason"] as? String {
                Text(cleanReason(reason))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
    }
    
    func priorityColor(_ priority: Int) -> Color {
        if priority >= 80 { return .red }
        if priority >= 60 { return .orange }
        if priority >= 40 { return .yellow }
        return .gray
    }
    
    func actionColor(_ action: String) -> Color {
        switch action.lowercased() {
        case "import", "charge": return .blue
        case "export", "discharge": return .green
        case "auto": return .gray
        case "curtail": return .orange
        default: return .gray
        }
    }
    
    func cleanReason(_ reason: String) -> String {
        // Remove escaped characters and clean up
        reason
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .components(separatedBy: "\n").first ?? reason
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: 140, alignment: .leading)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

struct KeyValueGrid: View {
    let items: [(String, String)]
    
    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 8) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(item.1)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct ForecastSparkline: View {
    let title: String
    let values: [Double]
    let color: Color
    var suffix: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                if let min = values.min(), let max = values.max() {
                    Text("\(formatNum(min))-\(formatNum(max))\(suffix)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            // Mini sparkline
            GeometryReader { geo in
                let maxVal = values.max() ?? 1
                let minVal = values.min() ?? 0
                let range = maxVal - minVal
                let safeRange = range > 0 ? range : 1
                
                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = geo.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                        let y = geo.size.height * (1 - CGFloat((value - minVal) / safeRange))
                        
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, lineWidth: 1.5)
            }
            .frame(height: 30)
        }
    }
    
    func formatNum(_ num: Double) -> String {
        if num == floor(num) {
            return String(format: "%.0f", num)
        }
        return String(format: "%.1f", num)
    }
}

// MARK: - Preview
#Preview {
    ActionValuesExplorer(
        valuesJSON: "{}",
        inverterSerial: "8053"
    )
}
