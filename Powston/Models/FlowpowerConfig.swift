//
//  FlowpowerConfig.swift
//  Powston
//
//  Network-specific pricing configuration for Flowpower retailer simulation
//

import Foundation

// MARK: - Network Region

enum NetworkRegion: String, Codable, CaseIterable, Identifiable {
    case nswEndeavour = "NSW - Endeavour"
    case nswAusgrid = "NSW - Ausgrid"
    case nswEssential = "NSW - Essential"
    case qldEnergex = "QLD - Energex"
    case qldErgon = "QLD - Ergon"
    case vicCitipower = "VIC - Citipower"
    case vicPowercor = "VIC - Powercor"
    case saAPD = "SA - SA Power"

    var id: String { rawValue }

    var shortName: String {
        switch self {
        case .nswEndeavour: return "Endeavour"
        case .nswAusgrid: return "Ausgrid"
        case .nswEssential: return "Essential"
        case .qldEnergex: return "Energex"
        case .qldErgon: return "Ergon"
        case .vicCitipower: return "Citipower"
        case .vicPowercor: return "Powercor"
        case .saAPD: return "SA Power"
        }
    }

    var state: String {
        switch self {
        case .nswEndeavour, .nswAusgrid, .nswEssential: return "NSW"
        case .qldEnergex, .qldErgon: return "QLD"
        case .vicCitipower, .vicPowercor: return "VIC"
        case .saAPD: return "SA"
        }
    }

    var timezone: TimeZone {
        switch self {
        case .qldEnergex, .qldErgon:
            return TimeZone(identifier: "Australia/Brisbane") ?? .current
        case .saAPD:
            return TimeZone(identifier: "Australia/Adelaide") ?? .current
        case .vicCitipower, .vicPowercor:
            return TimeZone(identifier: "Australia/Melbourne") ?? .current
        default:
            return TimeZone(identifier: "Australia/Sydney") ?? .current
        }
    }
}

// MARK: - Flowpower Config

struct FlowpowerConfig: Codable, Equatable {
    let networkRegion: NetworkRegion
    let dailyCharge: Double              // $/day
    let baseImportRate: Double           // c/kWh before PEA
    let peakExportRate: Double           // c/kWh during window
    let peakExportStartMinute: Int       // Minutes from midnight (1050 = 17:30)
    let peakExportEndMinute: Int         // Minutes from midnight (1170 = 19:30)

    var timezone: TimeZone {
        networkRegion.timezone
    }

    var peakExportWindowDescription: String {
        let startHour = peakExportStartMinute / 60
        let startMin = peakExportStartMinute % 60
        let endHour = peakExportEndMinute / 60
        let endMin = peakExportEndMinute % 60
        return String(format: "%d:%02d–%d:%02dpm", startHour > 12 ? startHour - 12 : startHour, startMin, endHour > 12 ? endHour - 12 : endHour, endMin)
    }

    // MARK: - Default Configs by Network

    static let nswEndeavour = FlowpowerConfig(
        networkRegion: .nswEndeavour,
        dailyCharge: 1.21,
        baseImportRate: 34.0,
        peakExportRate: 45.0,
        peakExportStartMinute: 1050,  // 17:30
        peakExportEndMinute: 1170     // 19:30
    )

    static let nswAusgrid = FlowpowerConfig(
        networkRegion: .nswAusgrid,
        dailyCharge: 1.15,
        baseImportRate: 32.0,
        peakExportRate: 45.0,
        peakExportStartMinute: 1050,
        peakExportEndMinute: 1170
    )

    static let nswEssential = FlowpowerConfig(
        networkRegion: .nswEssential,
        dailyCharge: 1.25,
        baseImportRate: 35.0,
        peakExportRate: 45.0,
        peakExportStartMinute: 1050,
        peakExportEndMinute: 1170
    )

    static let qldEnergex = FlowpowerConfig(
        networkRegion: .qldEnergex,
        dailyCharge: 1.10,
        baseImportRate: 30.0,
        peakExportRate: 45.0,
        peakExportStartMinute: 1050,
        peakExportEndMinute: 1170
    )

    static let qldErgon = FlowpowerConfig(
        networkRegion: .qldErgon,
        dailyCharge: 1.30,
        baseImportRate: 32.0,
        peakExportRate: 45.0,
        peakExportStartMinute: 1050,
        peakExportEndMinute: 1170
    )

    static let vicCitipower = FlowpowerConfig(
        networkRegion: .vicCitipower,
        dailyCharge: 1.18,
        baseImportRate: 28.0,
        peakExportRate: 45.0,
        peakExportStartMinute: 1050,
        peakExportEndMinute: 1170
    )

    static let vicPowercor = FlowpowerConfig(
        networkRegion: .vicPowercor,
        dailyCharge: 1.22,
        baseImportRate: 29.0,
        peakExportRate: 45.0,
        peakExportStartMinute: 1050,
        peakExportEndMinute: 1170
    )

    static let saAPD = FlowpowerConfig(
        networkRegion: .saAPD,
        dailyCharge: 1.35,
        baseImportRate: 36.0,
        peakExportRate: 45.0,
        peakExportStartMinute: 1050,
        peakExportEndMinute: 1170
    )

    static func forRegion(_ region: NetworkRegion) -> FlowpowerConfig {
        switch region {
        case .nswEndeavour: return .nswEndeavour
        case .nswAusgrid: return .nswAusgrid
        case .nswEssential: return .nswEssential
        case .qldEnergex: return .qldEnergex
        case .qldErgon: return .qldErgon
        case .vicCitipower: return .vicCitipower
        case .vicPowercor: return .vicPowercor
        case .saAPD: return .saAPD
        }
    }

    /// Check if a given date falls within the peak export window (local time)
    func isInExportWindow(date: Date) -> Bool {
        var calendar = Calendar.current
        calendar.timeZone = timezone

        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let totalMinutes = hour * 60 + minute

        return totalMinutes >= peakExportStartMinute && totalMinutes < peakExportEndMinute
    }
}
