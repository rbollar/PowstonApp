//
//  ContentView.swift
//  Powston
//
//  Created by Rick Bollar on 12/26/25.
//

import SwiftUI
import Combine

enum AppTab: Int {
    case dashboard = 0
    case prices = 1
    case history = 2
    case decisions = 3
    case settings = 4
}

class TabSelection: ObservableObject {
    static let shared = TabSelection()
    @Published var selectedTab: AppTab = .dashboard
}

struct ContentView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var tabSelection = TabSelection.shared
    @AppStorage("appearance_mode") private var appearanceMode: AppearanceMode = .system
    
    
    
    var body: some View {
        TabView(selection: $tabSelection.selectedTab) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "bolt.fill") }
                .tag(AppTab.dashboard)
            
            PricesView()
                .tabItem { Label("Prices", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(AppTab.prices)
            
            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.history)
            
            DecisionsView()
                .tabItem { Label("Decisions", systemImage: "brain") }
                .tag(AppTab.decisions)
            
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(AppTab.settings)
        }
        .tint(.green)
        .preferredColorScheme(appearanceMode.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .refreshDataNeeded)) { _ in
            Task {
                await SmartRefreshManager.shared.forceRefresh()
            }
        }
        .onAppear {
            if api.selectedInverterId != 0 {
                SmartRefreshManager.shared.start(api: api)
            }
        }
        .onDisappear {
            SmartRefreshManager.shared.stop()
        }
        .onChange(of: api.selectedInverterId) { _, newId in
            if newId != 0 {
                SmartRefreshManager.shared.start(api: api)
            } else {
                SmartRefreshManager.shared.stop()
            }
        }
        .task {
            // Initialize WatchConnectivity early so it's ready when credentials are synced
            _ = WatchConnectivityManager.shared
            
            if api.demoModeEnabled {
                api.loadDemoData()
            } else if !api.apiKey.isEmpty {
                // Fetch sites first
                if api.sites.isEmpty {
                    await api.fetchSites()
                }
                
                // Discover earliest date after sites are loaded
                api.loadEarliestRecordDate()
                
                // Fetch ALL inverters (not just first site) and auto-select lead
                if api.inverters.isEmpty {
                    await api.fetchAllInverters()
                }
                
                // Now fetch data for selected inverter
                if api.selectedInverterId != 0 {
                    await api.fetchData()
                    // Start smart refresh after initial data load
                    SmartRefreshManager.shared.start(api: api)
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(PowstonAPI())
}
