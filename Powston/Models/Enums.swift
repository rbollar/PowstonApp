//
//  Enums.swift
//  Powston
//

import SwiftUI

// MARK: - Appearance Mode
enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case light
    case dark
    case system
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }
    
    var icon: String {
        switch self {
        case .light: return "sun.max"
        case .dark: return "moon"
        case .system: return "circle.lefthalf.filled"
        }
    }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

// MARK: - Override Mode
enum OverrideMode: String, CaseIterable, Identifiable {
    case auto
    case autoCurtail
    case charge
    case discharge
    case `import`
    case export
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .autoCurtail: return "Auto-Curtail"
        case .charge: return "Charge"
        case .discharge: return "Discharge"
        case .import: return "Import"
        case .export: return "Export"
        }
    }
    
    var icon: String {
        switch self {
        case .auto, .autoCurtail: return "arrow.triangle.2.circlepath"
        case .charge: return "battery.100.bolt"
        case .discharge: return "battery.25"
        case .import: return "arrow.down"
        case .export: return "sun.max"
        }
    }
    
    var description: String {
        switch self {
        case .auto: return "Let the inverter manage itself, bypassing the optimization script."
        case .autoCurtail: return "Auto mode with export limiting enabled."
        case .charge: return "The battery will charge from excess solar and discharge to meet demand."
        case .discharge: return "Force the battery to discharge to home and/or grid."
        case .import: return "Force import power from the grid to charge battery."
        case .export: return "Force export power to the grid from battery/solar."
        }
    }
    
    var apiValue: String {
        self == .autoCurtail ? "auto" : rawValue
    }
}
