//
//  WatchSettingsView.swift
//  PowstonWatch
//
//  Manual credential entry and settings
//

import SwiftUI

struct WatchSettingsView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var credentials = WatchCredentialManager.shared
    
    @State private var manualApiKey: String = ""
    @State private var manualSiteId: String = ""
    @State private var showManualEntry = false
    
    var body: some View {
        NavigationStack {
            List {
                // Current status
                Section("Status") {
                    LabeledContent("Source", value: credentials.authSource.rawValue)
                    
                    if credentials.isConfigured && !credentials.isDemoMode {
                        LabeledContent("Site", value: credentials.siteName)
                        LabeledContent("Site ID", value: "\(credentials.siteId)")
                    }
                }
                
                // Actions
                Section {
                    Button {
                        Task {
                            await credentials.syncFromiCloud()
                        }
                    } label: {
                        Label("Sync from iCloud", systemImage: "icloud.and.arrow.down")
                    }
                    
                    Button {
                        showManualEntry = true
                    } label: {
                        Label("Enter Manually", systemImage: "keyboard")
                    }
                    
                    Button {
                        credentials.enableDemoMode()
                        dismiss()
                    } label: {
                        Label("Demo Mode", systemImage: "theatermasks")
                    }
                }
                
                if credentials.isConfigured {
                    Section {
                        Button(role: .destructive) {
                            credentials.clearCredentials()
                        } label: {
                            Label("Clear Credentials", systemImage: "trash")
                        }
                    }
                }
                
                // Debug info
                Section("Debug") {
                    Text(credentials.apiKey.isEmpty ? "No API key" : "Key: \(credentials.apiKey.prefix(12))...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showManualEntry) {
                manualEntrySheet
            }
        }
    }
    
    var manualEntrySheet: some View {
        NavigationStack {
            Form {
                Section("API Key") {
                    TextField("API Key", text: $manualApiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                }
                
                Section("Site ID") {
                    TextField("Site ID", text: $manualSiteId)
                }
                
                Section {
                    Text("Get your API key and Site ID from app.powston.com")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Manual Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showManualEntry = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let siteId = Int(manualSiteId), !manualApiKey.isEmpty {
                            credentials.setManualCredentials(apiKey: manualApiKey, siteId: siteId)
                            showManualEntry = false
                            dismiss()
                        }
                    }
                    .disabled(manualApiKey.isEmpty || Int(manualSiteId) == nil)
                }
            }
        }
    }
}

#Preview {
    WatchSettingsView()
}
