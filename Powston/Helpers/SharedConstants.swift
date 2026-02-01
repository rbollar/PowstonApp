//
//  SharedConstants.swift
//  Powston
//
//  Shared constants for iOS app and Watch app
//

import Foundation

// App Group identifier - must be enabled in both iOS and Watch targets
let appGroupID = "group.com.bollar.powston"

// Shared UserDefaults for App Group
let sharedDefaults = UserDefaults(suiteName: appGroupID)

// Keys for shared settings
enum SharedSettingsKey {
    static let apiKey = "api_key"
    static let baseURL = "base_url"
    static let selectedInverterId = "selected_inverter_id"
}
