//
//  PowstonWatchApp.swift
//  PowstonWatch
//
//  Standalone watchOS app with iCloud credential sync
//

import SwiftUI

@main
struct PowstonWatchApp: App {
    @StateObject private var api = WatchAPI()
    
    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(api)
        }
    }
}
