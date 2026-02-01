//
//  SettingsView.swift
//  Powston
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var api: PowstonAPI
    @AppStorage("api_key") private var apiKey = ""
    @AppStorage("appearance_mode") private var appearanceMode: AppearanceMode = .system
    @AppStorage("use_system_timezone") private var useSystemTimezone: Bool = true
    @AppStorage("peak_start_hour") private var peakStartHour: Double = 16.0
    @AppStorage("peak_end_hour") private var peakEndHour: Double = 21.0
    @AppStorage("peak_enabled") private var peakEnabled: Bool = false
    @AppStorage("price_alerts_enabled") private var priceAlertsEnabled: Bool = false
    @AppStorage("sell_above_enabled") private var sellAboveEnabled: Bool = false
    @AppStorage("sell_above_threshold") private var sellAboveThreshold: Double = 40.0
    @AppStorage("sell_below_enabled") private var sellBelowEnabled: Bool = false
    @AppStorage("sell_below_threshold") private var sellBelowThreshold: Double = 20.0
    @AppStorage("buy_above_enabled") private var buyAboveEnabled: Bool = false
    @AppStorage("buy_above_threshold") private var buyAboveThreshold: Double = 40.0
    @AppStorage("buy_below_enabled") private var buyBelowEnabled: Bool = false
    @AppStorage("buy_below_threshold") private var buyBelowThreshold: Double = 15.0
    @State private var showingApiSetup = false
    @StateObject private var notificationManager = NotificationManager.shared
    
    var aboutURL: URL {
        if api.isDemoMode {
            return URL(string: "https://powston.com.au")!
        } else if let site = api.sites.first {
            return URL(string: "https://app.powston.com/summary/\(site.id)")!
        } else {
            return URL(string: "https://app.powston.com")!
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    if api.isDemoMode {
                        HStack {
                            Image(systemName: "theatermasks.fill").foregroundColor(.orange)
                            Text("Demo Mode").fontWeight(.medium)
                            Spacer()
                            Button("Configure API") { showingApiSetup = true }.font(.subheadline)
                        }
                    } else if api.data != nil {
                        HStack {
                            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connected").fontWeight(.medium)
                                if let inverter = api.inverters.first(where: { $0.id == api.selectedInverterId }) {
                                    Text("\(inverter.manufacturer) \(inverter.productName)")
                                        .font(.caption).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button("Change") { showingApiSetup = true }.font(.subheadline)
                        }
                    } else if api.isLoading {
                        HStack { ProgressView(); Text("Connecting...").foregroundColor(.secondary) }
                    } else {
                        HStack {
                            Image(systemName: "bolt.slash.circle").foregroundColor(.secondary)
                            Text("Not connected").foregroundColor(.secondary)
                            Spacer()
                            Button("Set Up") { showingApiSetup = true }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                    if let error = api.error, !api.isDemoMode {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                            Text(error).font(.caption).foregroundColor(.orange)
                        }
                    }
                }
                
                Section("Appearance") {
                    Picker("Theme", selection: $appearanceMode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            HStack { Image(systemName: mode.icon); Text(mode.displayName) }.tag(mode)
                        }
                    }.pickerStyle(.menu)
                    
                    Toggle(isOn: $useSystemTimezone) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use System Time")
                            Text(useSystemTimezone ? "Brisbane (AEST)" : "Phone Local")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Section("Demo Mode") {
                    Toggle("Use Demo Data", isOn: $api.demoModeEnabled)
                        .onChange(of: api.demoModeEnabled) { _, newValue in
                            if newValue { api.loadDemoData() }
                            else {
                                api.clearDemoData()
                                if !apiKey.isEmpty { Task { await api.fetchSites() } }
                            }
                        }
                    if api.demoModeEnabled {
                        HStack {
                            Image(systemName: "info.circle.fill").foregroundColor(.blue)
                            Text("Demo data is active. Disable to use real API data.")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                
                Section("Peak Hours") {
                    Toggle("Enable Peak Period Markers", isOn: $peakEnabled)
                    if peakEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Peak Start: \(formatHour(peakStartHour))").font(.subheadline)
                            Slider(value: $peakStartHour, in: 0...23.75, step: 0.25)
                            Text("Peak End: \(formatHour(peakEndHour))").font(.subheadline)
                            Slider(value: $peakEndHour, in: 0...23.75, step: 0.25)
                        }.padding(.vertical, 4)
                        Button("Queensland Default (4 PM - 9 PM)") {
                            peakStartHour = 16.0; peakEndHour = 21.0
                        }.font(.caption)
                        if peakStartHour >= peakEndHour {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                                Text("Peak start must be before peak end").font(.caption).foregroundColor(.orange)
                            }
                        }
                    }
                }
                
                Section("Price Alerts") {
                    if !notificationManager.isAuthorized {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "bell.slash").foregroundColor(.orange)
                                Text("Notifications not enabled").font(.subheadline)
                            }
                            Button("Enable Notifications") { notificationManager.requestPermission() }
                                .buttonStyle(.borderedProminent)
                            Text("Allow notifications to receive price alerts")
                                .font(.caption).foregroundColor(.secondary)
                        }.padding(.vertical, 4)
                    } else {
                        Toggle("Enable Price Alerts", isOn: $priceAlertsEnabled)
                        if priceAlertsEnabled {
                            PriceAlertRow(icon: "🚀", title: "Sell Above", subtitle: "High export price",
                                enabled: $sellAboveEnabled, threshold: $sellAboveThreshold,
                                currentPrice: api.data?.sellPrice, thresholdColor: .green, isAbove: true)
                            PriceAlertRow(icon: "⚠️", title: "Sell Below", subtitle: "Low export price",
                                enabled: $sellBelowEnabled, threshold: $sellBelowThreshold,
                                currentPrice: api.data?.sellPrice, thresholdColor: .orange, isAbove: false)
                            PriceAlertRow(icon: "💰", title: "Buy Below", subtitle: "Low import price",
                                enabled: $buyBelowEnabled, threshold: $buyBelowThreshold,
                                currentPrice: api.data?.buyPrice, thresholdColor: .blue, isAbove: false)
                            PriceAlertRow(icon: "⚠️", title: "Buy Above", subtitle: "High import price",
                                enabled: $buyAboveEnabled, threshold: $buyAboveThreshold,
                                currentPrice: api.data?.buyPrice, thresholdColor: .red, isAbove: true)
                            HStack {
                                Image(systemName: "info.circle").foregroundColor(.blue)
                                Text("Each alert type won't repeat within 30 minutes")
                                    .font(.caption).foregroundColor(.secondary)
                            }.padding(.top, 4)
                        }
                    }
                }
                
                if !api.sites.isEmpty {
                    Section("Sites & Inverters") {
                        ForEach(api.sites) { site in
                            NavigationLink(destination: SiteDetailView(site: site)) {
                                HStack {
                                    Image(systemName: "building.2.fill")
                                        .foregroundColor(.blue)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(site.displayName ?? site.name)
                                            .fontWeight(.medium)
                                        HStack(spacing: 8) {
                                            Text(site.state)
                                            Text("•")
                                            Text(site.network.capitalized)
                                            if let solar = site.installedSolar {
                                                Text("•")
                                                Text(formatPower(solar))
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        
                        ForEach(api.inverters) { inverter in
                            HStack {
                                Image(systemName: inverter.id == api.selectedInverterId ? "bolt.circle.fill" : "bolt.circle")
                                    .foregroundColor(inverter.id == api.selectedInverterId ? .green : .secondary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(inverter.manufacturer) \(inverter.productName)")
                                        .fontWeight(inverter.id == api.selectedInverterId ? .semibold : .regular)
                                    Text("SN: \(inverter.serialNumber)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if inverter.id == api.selectedInverterId {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                api.selectedInverterId = inverter.id
                                Task { await api.fetchData() }
                            }
                        }
                        
                        NavigationLink(destination: AllSitesMapView(sites: api.sites)) {
                            HStack {
                                Image(systemName: "map.fill")
                                    .foregroundColor(.green)
                                    .frame(width: 24)
                                Text("View All Sites on Map")
                                Spacer()
                                Text("\(api.sites.count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(8)
                            }
                        }
                    }
                }
                
                Section("About") {
                    Link(destination: aboutURL) {
                        HStack {
                            Text(api.isDemoMode ? "Powston Website" : "View in Powston Web")
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear { notificationManager.checkAuthorization() }
            .sheet(isPresented: $showingApiSetup) { APISetupView() }
        }
    }
    
    func formatHour(_ hour: Double) -> String {
        guard let tz = TimeZone(identifier: "Australia/Brisbane") else {
            return String(format: "%02d:%02d", Int(hour), Int((hour - Double(Int(hour))) * 60))
        }
        var cal = Calendar.current; cal.timeZone = tz
        let startOfDay = cal.startOfDay(for: Date())
        guard let date = cal.date(byAdding: .hour, value: Int(hour), to: startOfDay),
              let dateWithMinutes = cal.date(byAdding: .minute, value: Int((hour - Double(Int(hour))) * 60), to: date) else {
            return String(format: "%02d:%02d", Int(hour), Int((hour - Double(Int(hour))) * 60))
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short; formatter.dateStyle = .none; formatter.timeZone = tz
        return formatter.string(from: dateWithMinutes)
    }
    
    func formatPower(_ watts: Int) -> String {
        if watts >= 1000 {
            return String(format: "%.1f kW", Double(watts) / 1000)
        }
        return "\(watts) W"
    }
}

// MARK: - Price Alert Row
struct PriceAlertRow: View {
    let icon: String
    let title: String
    let subtitle: String
    @Binding var enabled: Bool
    @Binding var threshold: Double
    let currentPrice: Double?
    let thresholdColor: Color
    let isAbove: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $enabled) {
                HStack {
                    Text(icon)
                    VStack(alignment: .leading) {
                        Text(title)
                            .fontWeight(.medium)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            if enabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Threshold: \(String(format: "%.1f¢", threshold))/kWh")
                        .font(.subheadline)
                        .foregroundColor(thresholdColor)
                    
                    Slider(value: $threshold, in: -10...100, step: 0.5)
                    
                    if let current = currentPrice {
                        let triggered = isAbove ? current >= threshold : current <= threshold
                        HStack {
                            Text("Current:")
                                .font(.caption)
                            Spacer()
                            Text("\(String(format: "%.1f¢", current))/kWh")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundColor(triggered ? thresholdColor : .secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                    }
                }
                .padding(.leading, 32)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - API Setup View
struct APISetupView: View {
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.dismiss) private var dismiss
    @AppStorage("api_key") private var apiKey = ""
    @State private var tempApiKey = ""
    @State private var showApiKey = false
    @State private var connectionStatus: ConnectionStatus = .idle
    @State private var selectedSiteId: Int? = nil
    
    enum ConnectionStatus: Equatable {
        case idle
        case connecting
        case fetchingSites
        case fetchingInverters
        case success(siteCount: Int, inverterCount: Int)
        case error(String)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            if showApiKey {
                                TextField("API Key", text: $tempApiKey)
                                    .textContentType(.password)
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                                    .font(.system(.body, design: .monospaced))
                            } else {
                                SecureField("API Key", text: $tempApiKey)
                                    .autocorrectionDisabled()
                            }
                            
                            Button(action: { showApiKey.toggle() }) {
                                Image(systemName: showApiKey ? "eye.slash" : "eye")
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if !tempApiKey.isEmpty {
                            Text("\(tempApiKey.count) characters")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("API Key")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How to get your API key:")
                            .fontWeight(.medium)
                        Text("1. Visit your Powston profile page")
                        Text("2. Select \"Generate API Key\" at the bottom")
                        
                        Link(destination: URL(string: "https://app.powston.com/profile")!) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right.circle.fill")
                                Text("Open Powston Profile")
                            }
                            .font(.subheadline)
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
                
                Section {
                    Button(action: { Task { await connect() } }) {
                        HStack {
                            Spacer()
                            if case .connecting = connectionStatus {
                                ProgressView().padding(.trailing, 8)
                            } else if case .fetchingSites = connectionStatus {
                                ProgressView().padding(.trailing, 8)
                            } else if case .fetchingInverters = connectionStatus {
                                ProgressView().padding(.trailing, 8)
                            }
                            Text(connectButtonText).fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(tempApiKey.isEmpty || connectionStatus == .connecting || connectionStatus == .fetchingSites || connectionStatus == .fetchingInverters)
                    .foregroundColor(.white)
                    .listRowBackground(tempApiKey.isEmpty ? Color.gray.opacity(0.3) : Color.blue)
                }
                
                if connectionStatus != .idle {
                    Section("Status") {
                        switch connectionStatus {
                        case .idle:
                            EmptyView()
                        case .connecting:
                            StatusRow(icon: "network", text: "Connecting to Powston...", color: .blue, spinning: true)
                        case .fetchingSites:
                            StatusRow(icon: "building.2", text: "Fetching sites...", color: .blue, spinning: true)
                        case .fetchingInverters:
                            StatusRow(icon: "bolt", text: "Fetching inverters...", color: .blue, spinning: true)
                        case .success(let siteCount, let inverterCount):
                            VStack(alignment: .leading, spacing: 8) {
                                StatusRow(icon: "checkmark.circle.fill", text: "Connected successfully", color: .green)
                                StatusRow(icon: "building.2.fill", text: "\(siteCount) site(s) found", color: .secondary)
                                StatusRow(icon: "bolt.fill", text: "\(inverterCount) inverter(s) found", color: .secondary)
                            }
                        case .error(let message):
                            StatusRow(icon: "exclamationmark.triangle.fill", text: message, color: .red)
                        }
                    }
                }
                
                if api.sites.count > 1 {
                    Section("Select Site") {
                        ForEach(api.sites) { site in
                            Button(action: {
                                selectedSiteId = site.id
                                Task { await selectSite(site) }
                            }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(site.displayName ?? site.name)
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                        Text("\(site.state) • \(site.network)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedSiteId == site.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }
                    }
                }
                
                if api.inverters.count > 1 {
                    Section("Select Inverter") {
                        ForEach(api.inverters) { inverter in
                            Button(action: { api.selectedInverterId = inverter.id }) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(inverter.manufacturer) \(inverter.productName)")
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                        Text("SN: \(inverter.serialNumber)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if api.selectedInverterId == inverter.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("API Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        apiKey = tempApiKey
                        if api.selectedInverterId != 0 {
                            Task { await api.fetchData() }
                        }
                        dismiss()
                    }
                    .disabled(api.selectedInverterId == 0 && !api.isDemoMode)
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                tempApiKey = apiKey
                if !api.sites.isEmpty {
                    connectionStatus = .success(siteCount: api.sites.count, inverterCount: api.inverters.count)
                    if let site = api.sites.first(where: { site in
                        api.inverters.contains(where: { $0.siteId == site.id })
                    }) {
                        selectedSiteId = site.id
                    }
                }
            }
        }
    }
    
    var connectButtonText: String {
        switch connectionStatus {
        case .connecting, .fetchingSites, .fetchingInverters: return "Connecting..."
        case .success: return "Reconnect"
        case .error: return "Retry"
        case .idle: return "Connect"
        }
    }
    
    func connect() async {
        tempApiKey = tempApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = tempApiKey
        
        connectionStatus = .connecting
        connectionStatus = .fetchingSites
        await api.fetchSites()
        
        if let error = api.error {
            connectionStatus = .error(error)
            return
        }
        
        if api.sites.isEmpty {
            connectionStatus = .error("No sites found. Check your API key permissions.")
            return
        }
        
        let targetSite = api.sites[0]
        selectedSiteId = targetSite.id
        
        connectionStatus = .fetchingInverters
        await api.fetchInverters(siteId: targetSite.id)
        
        if api.inverters.isEmpty {
            connectionStatus = .error("No inverters found for site: \(targetSite.displayName ?? targetSite.name)")
            return
        }
        
        if api.inverters.count == 1 {
            api.selectedInverterId = api.inverters[0].id
        }
        
        connectionStatus = .success(siteCount: api.sites.count, inverterCount: api.inverters.count)
        
        if api.sites.count == 1 && api.inverters.count == 1 {
            await api.fetchData()
        }
    }
    
    func selectSite(_ site: Site) async {
        connectionStatus = .fetchingInverters
        await api.fetchInverters(siteId: site.id)
        
        if api.inverters.isEmpty {
            connectionStatus = .error("No inverters found for this site")
            return
        }
        
        if api.inverters.count == 1 {
            api.selectedInverterId = api.inverters[0].id
            await api.fetchData()
        }
        
        connectionStatus = .success(siteCount: api.sites.count, inverterCount: api.inverters.count)
    }
}
