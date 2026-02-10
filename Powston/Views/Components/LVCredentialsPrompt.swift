//
//  LVCredentialsPrompt.swift
//  Powston
//
//  Reusable prompt for LocalVolts credentials setup
//  Use in P2P areas where LV data would enhance the experience
//

import SwiftUI

/// Compact credentials prompt for inline use
struct LVCredentialsPromptCompact: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var showSetup = false

    var body: some View {
        Button(action: { showSetup = true }) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.circle.fill")
                    .font(.title2)
                    .foregroundColor(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect LocalVolts")
                        .font(.subheadline.bold())
                        .foregroundColor(.primary)
                    Text("Get real-time trade data and contract tracking")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color.purple.opacity(0.1))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSetup) {
            LocalVoltsSetupView()
                .environmentObject(api)
        }
    }
}

/// Full card prompt with benefits list
struct LVCredentialsPromptCard: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var showSetup = false

    var title: String = "Connect LocalVolts"
    var subtitle: String = "Unlock detailed P2P trading insights"
    var benefits: [String] = [
        "Real-time trade data with per-interval detail",
        "Contract tracking with fill rate analysis",
        "Counterparty identification and patterns",
        "Data-driven pricing recommendations"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bolt.circle.fill")
                    .font(.title)
                    .foregroundColor(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(benefits, id: \.self) { benefit in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                        Text(benefit)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Button(action: { showSetup = true }) {
                HStack {
                    Image(systemName: "person.badge.key.fill")
                    Text("Set Up Credentials")
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.purple)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .sheet(isPresented: $showSetup) {
            LocalVoltsSetupView()
                .environmentObject(api)
        }
    }
}

/// Inline banner for areas that reference LV data
struct LVCredentialsBanner: View {
    @EnvironmentObject var api: PowstonAPI
    @State private var showSetup = false

    var message: String = "Connect LocalVolts to import your trade history automatically"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.circle.fill")
                .foregroundColor(.purple)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            Button("Connect") {
                showSetup = true
            }
            .font(.caption.bold())
            .foregroundColor(.purple)
        }
        .padding(10)
        .background(Color.purple.opacity(0.1))
        .cornerRadius(8)
        .sheet(isPresented: $showSetup) {
            LocalVoltsSetupView()
                .environmentObject(api)
        }
    }
}

/// Check if LV credentials are available
struct LVCredentialsGate<Content: View, Fallback: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var fallback: () -> Fallback

    private var hasCredentials: Bool {
        LocalVoltsCredentialManager.shared.hasCredentials
    }

    var body: some View {
        if hasCredentials {
            content()
        } else {
            fallback()
        }
    }
}

// MARK: - Preview

#Preview("Compact") {
    LVCredentialsPromptCompact()
        .environmentObject(PowstonAPI())
        .padding()
}

#Preview("Card") {
    LVCredentialsPromptCard()
        .environmentObject(PowstonAPI())
        .padding()
}

#Preview("Banner") {
    LVCredentialsBanner()
        .environmentObject(PowstonAPI())
        .padding()
}
