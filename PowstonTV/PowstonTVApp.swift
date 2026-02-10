//
//  PowstonTVApp.swift
//  PowstonTV
//

import SwiftUI

@main
struct PowstonTVApp: App {
    @StateObject private var api = TVAPI()
    
    var body: some Scene {
        WindowGroup {
            TVContentView()
                .environmentObject(api)
                .task {
                    await api.loadCredentialsAndFetch()
                }
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}
