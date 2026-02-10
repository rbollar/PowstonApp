//
//  LocalVoltsSetupView.swift
//  Powston
//
//  Settings UI for LocalVolts credential entry and connection testing
//  Credentials are per-site and stored securely in Keychain
//

import SwiftUI

struct LocalVoltsSetupView: View {
    @EnvironmentObject var api: PowstonAPI
    @StateObject private var lvService = LocalVoltsService.shared
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var hasStoredPassword = false
    @State private var showPassword = false
    @State private var isTesting = false
    @State private var testResult: TestResult?
    @State private var showDeleteConfirmation = false

    private enum TestResult {
        case success(String)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Site Info
                if let site = api.selectedSite {
                    Section {
                        HStack {
                            Image(systemName: "bolt.circle.fill")
                                .foregroundColor(.purple)
                            Text(site.name)
                                .fontWeight(.medium)
                            Spacer()
                            Text("Site \(site.id)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } footer: {
                        Text("LocalVolts credentials are stored per site. Each site can have different credentials.")
                    }
                }

                // MARK: - Credentials Section
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Username", text: $username)
                            .textContentType(.username)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()

                        HStack {
                            if hasStoredPassword && password.isEmpty {
                                // Show indicator that password exists
                                HStack(spacing: 4) {
                                    Text("••••••••")
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("Saved")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            } else if showPassword {
                                TextField("Password", text: $password)
                                    .textContentType(.password)
                                    .autocapitalization(.none)
                                    .autocorrectionDisabled()
                            } else {
                                SecureField("Password", text: $password)
                                    .autocorrectionDisabled()
                            }

                            if !hasStoredPassword || !password.isEmpty {
                                Button(action: { showPassword.toggle() }) {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                // Edit button when password is stored
                                Button(action: { hasStoredPassword = false; password = "" }) {
                                    Text("Edit")
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("LocalVolts Credentials")
                } footer: {
                    Text("Your LocalVolts market portal login. Stored securely in Keychain, never synced to iCloud.")
                        .font(.caption)
                }

                // MARK: - Test Connection
                Section {
                    Button(action: testConnection) {
                        HStack {
                            Spacer()
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isTesting ? "Testing..." : "Test Connection")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!canTest || isTesting)
                    .foregroundColor(.white)
                    .listRowBackground(canTest ? Color.blue : Color.gray.opacity(0.3))
                }

                // MARK: - Test Result
                if let result = testResult {
                    Section {
                        switch result {
                        case .success(let message):
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Connected")
                                        .fontWeight(.medium)
                                    Text(message)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if !password.isEmpty {
                                Button("Save Credentials") {
                                    saveCredentials()
                                }
                                .foregroundColor(.blue)
                            }

                        case .failure(let message):
                            HStack(alignment: .top) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(message)
                                    .font(.subheadline)
                                    .foregroundColor(.red)
                            }
                        }
                    }
                }

                // MARK: - Status (if configured)
                if lvService.hasCredentials {
                    Section("Status") {
                        HStack {
                            Image(systemName: statusIcon)
                                .foregroundColor(statusColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lvService.connectionStatus.displayText)
                                    .fontWeight(.medium)
                                if let lastSync = lvService.lastSyncDescription {
                                    Text("Last sync: \(lastSync)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if lvService.tradeCount > 0 {
                                Text("\(lvService.tradeCount) trades")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(8)
                            }
                        }
                    }

                    // MARK: - Remove Credentials
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Remove Credentials")
                            }
                        }
                    } footer: {
                        Text("Trade data will be preserved when removing credentials.")
                    }
                }

                // MARK: - About LocalVolts
                Section {
                    Link(destination: URL(string: "https://market.localvolts.com")!) {
                        HStack {
                            Image(systemName: "arrow.up.right.circle.fill")
                                .foregroundColor(.purple)
                            Text("Open LocalVolts Portal")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("LocalVolts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                loadStoredCredentials()
            }
            .confirmationDialog(
                "Remove LocalVolts credentials?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove", role: .destructive) {
                    deleteCredentials()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will disconnect from LocalVolts. Your trade data will be preserved.")
            }
        }
    }

    // MARK: - Helpers

    private var canTest: Bool {
        !username.isEmpty && (!password.isEmpty || hasStoredPassword)
    }

    private var statusIcon: String {
        switch lvService.connectionStatus {
        case .connected:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .disconnected:
            return "circle"
        default:
            return "arrow.clockwise"
        }
    }

    private var statusColor: Color {
        switch lvService.connectionStatus {
        case .connected:
            return .green
        case .error:
            return .red
        case .disconnected:
            return .gray
        default:
            return .blue
        }
    }

    private func loadStoredCredentials() {
        if let stored = LocalVoltsCredentialManager.shared.load() {
            username = stored.username
            hasStoredPassword = true
        }
    }

    private func testConnection() {
        guard !username.isEmpty else { return }

        // Use stored password if no new password entered
        let testPassword: String
        if password.isEmpty && hasStoredPassword {
            guard let stored = LocalVoltsCredentialManager.shared.load() else {
                testResult = .failure("Could not load stored password")
                return
            }
            testPassword = stored.password
        } else {
            testPassword = password
        }

        guard !testPassword.isEmpty else { return }

        isTesting = true
        testResult = nil

        Task {
            do {
                let verifiedUsername = try await lvService.testConnection(
                    username: username,
                    password: testPassword
                )
                await MainActor.run {
                    testResult = .success("Logged in as \(verifiedUsername)")
                }
            } catch {
                await MainActor.run {
                    testResult = .failure(error.localizedDescription)
                }
            }
            await MainActor.run {
                isTesting = false
            }
        }
    }

    private func saveCredentials() {
        guard !password.isEmpty else { return }

        do {
            try lvService.saveCredentials(username: username, password: password)
            hasStoredPassword = true
            password = ""  // Clear entered password
            testResult = .success("Credentials saved")

            // Auto-sync today after saving
            if let site = api.selectedSite {
                Task {
                    try? await lvService.syncToday(siteId: site.id)
                }
            }
        } catch {
            testResult = .failure("Failed to save: \(error.localizedDescription)")
        }
    }

    private func deleteCredentials() {
        do {
            try lvService.deleteCredentials()
            username = ""
            password = ""
            hasStoredPassword = false
            testResult = nil
        } catch {
            testResult = .failure("Failed to delete: \(error.localizedDescription)")
        }
    }
}

// MARK: - Summary for SettingsView

extension LocalVoltsSetupView {
    static func summary() -> String {
        LocalVoltsService.shared.statusBadge
    }

    /// Check if credentials are configured
    static var hasCredentials: Bool {
        LocalVoltsCredentialManager.shared.hasCredentials
    }
}

#Preview {
    LocalVoltsSetupView()
        .environmentObject(PowstonAPI())
}
