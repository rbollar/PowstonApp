//
//  PowstonApp.swift
//  Powston
//
//  Created by Rick Bollar on 12/26/25.
//

import SwiftUI

@main
struct PowstonApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var api = PowstonAPI()
    @State private var showSplash = true
    @State private var showManualOverride = false
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(api)
                    .sheet(isPresented: $showManualOverride) {
                        NavigationStack {
                            ManualOverrideView()
                                .environmentObject(api)
                        }
                    }
                
                if showSplash {
                    SplashScreen()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .onAppear {
                // Configure DataStore with API reference
                PowstonDataStore.shared.configure(api: api)

                // One-time cleanup: stale P2P sync blobs from the removed
                // feature share the 1MB iCloud KVS quota with credential sync
                let kvs = NSUbiquitousKeyValueStore.default
                for key in ["p2p_contracts_v1", "p2p_trade_records_v1", "p2p_counterparty_trades_v1"] {
                    kvs.removeObject(forKey: key)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showSplash = false
                    }
                }
            }
        }
    }
}

// MARK: - Splash Screen
struct SplashScreen: View {
    @State private var isAnimating = false
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.green.opacity(0.8), Color.green.opacity(0.4)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 20) {
                // App icon / logo
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 120, height: 120)
                    
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.white)
                        .scaleEffect(isAnimating ? 1.1 : 1.0)
                }
                
                VStack(spacing: 6) {
                    Text("Energy Controller")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                    Text("for Powston")
                        .font(.system(size: 18, weight: .regular, design: .rounded))
                        .opacity(0.7)
                }
                .foregroundColor(.white)
                
                Text("Monitor • Optimize • Control")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.2)
                    .padding(.top, 30)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isAnimating = true
            }
        }
    }
}
