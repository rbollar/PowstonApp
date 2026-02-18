//
//  APISetupView.swift
//  Powston
//

import SwiftUI

struct APISetupView: View {
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.dismiss) private var dismiss
    @AppStorage("api_key") private var apiKey = ""
    @AppStorage("has_completed_onboarding") private var hasCompletedOnboarding = false
    @State private var tempApiKey = ""
    @State private var showApiKey = false
    @State private var connectionStatus: ConnectionStatus = .idle
    @State private var selectedSiteId: Int? = nil
    @State private var showDashboardPicker = false
    
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
                                        Text("\(site.state ?? "–") • \(site.network ?? "–")")
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
                
                // Show inverters for selected site (or all if only one site)
                let siteInverters = api.sites.count > 1
                    ? api.inverters.filter { $0.siteId == selectedSiteId }
                    : api.inverters
                
                if siteInverters.count > 1 {
                    let currentSiteId = selectedSiteId ?? api.sites.first?.id
                    let leadInv = currentSiteId != nil ? api.leadInverter(forSiteId: currentSiteId!) : nil
                    
                    Section {
                        ForEach(siteInverters) { inverter in
                            let isLead = leadInv?.id == inverter.id
                            Button(action: {
                                if let siteId = currentSiteId {
                                    api.setLeadInverterOverride(siteId: siteId, inverterId: inverter.id)
                                }
                            }) {
                                HStack {
                                    Image(systemName: "star.fill")
                                        .font(.caption)
                                        .foregroundColor(isLead ? .yellow : .clear)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(inverter.manufacturer) \(inverter.productName)")
                                            .fontWeight(.medium)
                                            .foregroundColor(.primary)
                                        HStack(spacing: 4) {
                                            Text("SN: \(inverter.serialNumber)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                            if isLead {
                                                Text("• Lead")
                                                    .font(.caption)
                                                    .foregroundColor(.yellow)
                                            }
                                        }
                                    }
                                    Spacer()
                                    if isLead {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Lead Inverter")
                    } footer: {
                        Text("Select the inverter that controls grid export. For Sungrow dual systems, this is typically the one with the meter connected. You can change this later in Settings → Sites & Inverters.")
                            .font(.caption)
                    }
                }
                
                Section("Demo Mode") {
                    Toggle("Use Demo Data", isOn: $api.demoModeEnabled)
                        .onChange(of: api.demoModeEnabled) { _, newValue in
                            if newValue {
                                api.loadDemoData()
                            } else {
                                api.clearDemoData()
                                if !tempApiKey.isEmpty {
                                    Task { await connect() }
                                }
                            }
                            // Sync demo mode to Watch
                            #if os(iOS)
                            WatchConnectivityManager.shared.sendDemoModeToWatch(enabled: newValue, from: api)
                            #endif
                        }
                    if api.demoModeEnabled {
                        HStack {
                            Image(systemName: "info.circle.fill").foregroundColor(.blue)
                            Text("Demo mode lets you explore the app without an API key.")
                                .font(.caption).foregroundColor(.secondary)
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
                    .disabled(!api.isDemoMode && api.selectedInverterId == 0 && api.persistedSiteId == 0)
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
            .sheet(isPresented: $showDashboardPicker) {
                DashboardPickerSheet(isDemo: false) {
                    hasCompletedOnboarding = true
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
        
        // Fetch inverters for ALL sites (forceAll bypasses single site mode filter)
        connectionStatus = .fetchingInverters
        await api.fetchAllInverters(forceAll: true)
        
        // Select first site that has inverters, or first site if none have inverters
        if let firstSiteWithInverters = api.sites.first(where: { site in
            api.inverters.contains { $0.siteId == site.id }
        }) {
            selectedSiteId = firstSiteWithInverters.id
        } else {
            selectedSiteId = api.sites.first?.id
        }

        // Auto-select inverter if only one total, or first from selected site
        if api.inverters.count == 1 {
            api.selectedInverterId = api.inverters[0].id
        } else if let siteId = selectedSiteId,
                  let firstInverter = api.inverters.first(where: { $0.siteId == siteId }) {
            api.selectedInverterId = firstInverter.id
        } else if api.inverters.isEmpty, let siteId = selectedSiteId {
            // All sites are zero-inverter — set site directly
            api.selectedInverterId = 0
            api.persistedSiteId = siteId
        }

        connectionStatus = .success(siteCount: api.sites.count, inverterCount: api.inverters.count)

        // Fetch data to detect lead inverter, then switch to it
        if api.selectedInverterId != 0 {
            await api.fetchData()

            // After fetch, check if we detected a lead inverter and switch to it
            if let siteId = selectedSiteId,
               let lead = api.leadInverter(forSiteId: siteId),
               lead.id != api.selectedInverterId {
                print("🔄 Switching to detected lead inverter \(lead.id)")
                api.selectedInverterId = lead.id
                await api.fetchData()
            }

            // Show dashboard picker on first connection
            if !hasCompletedOnboarding {
                showDashboardPicker = true
            }
        } else if !hasCompletedOnboarding {
            showDashboardPicker = true
        }
    }
    
    func selectSite(_ site: Site) async {
        let siteInverters = api.inverters.filter { $0.siteId == site.id }

        if siteInverters.isEmpty {
            // Zero-inverter site — set site directly, clear inverter selection
            api.persistedSiteId = site.id
            api.selectedInverterId = 0
            api.data = nil
            connectionStatus = .success(siteCount: api.sites.count, inverterCount: 0)
            return
        }

        // Select first inverter to fetch data and detect lead
        if let first = siteInverters.first {
            api.selectedInverterId = first.id
            await api.fetchData()

            // After fetch, check if we detected a different lead inverter
            if let lead = api.leadInverter(forSiteId: site.id),
               lead.id != api.selectedInverterId {
                print("🔄 Switching to detected lead inverter \(lead.id)")
                api.selectedInverterId = lead.id
                await api.fetchData()
            }
        }

        connectionStatus = .success(siteCount: api.sites.count, inverterCount: siteInverters.count)
    }
}

#Preview {
    APISetupView()
        .environmentObject(PowstonAPI())
}
