//
//  Helpers.swift
//  Powston
//

import Foundation
import SwiftUI
// MARK: - Global Timezone Helper

// Map Australian states to timezones
private func timezoneForState(_ state: String?) -> TimeZone {
    switch state?.uppercased() {
    case "NSW", "ACT":
        return TimeZone(identifier: "Australia/Sydney") ?? .current
    case "VIC":
        return TimeZone(identifier: "Australia/Melbourne") ?? .current
    case "QLD":
        return TimeZone(identifier: "Australia/Brisbane") ?? .current
    case "SA":
        return TimeZone(identifier: "Australia/Adelaide") ?? .current
    case "WA":
        return TimeZone(identifier: "Australia/Perth") ?? .current
    case "TAS":
        return TimeZone(identifier: "Australia/Hobart") ?? .current
    case "NT":
        return TimeZone(identifier: "Australia/Darwin") ?? .current
    default:
        // Default to Brisbane (NEM time) if unknown
        return TimeZone(identifier: "Australia/Brisbane") ?? .current
    }
}

// Get timezone - needs access to current site
func powstonTimezone(for site: Site? = nil) -> TimeZone {
    if UserDefaults.standard.bool(forKey: "use_system_timezone") {
        // Use site's timezone
        if let site = site {
            // First try explicit timezone field from site
            if let tz = site.timezone, let timezone = TimeZone(identifier: tz) {
                return timezone
            }
            // Fall back to state-based mapping
            return timezoneForState(site.state)
        }
        // No site provided - try to get from shared instance
        // Fall back to Brisbane/NEM time
        return TimeZone(identifier: "Australia/Brisbane") ?? .current
    } else {
        // Use phone's local timezone
        return .current
    }
}

// Convenience for when we don't have site context - uses stored site state
func powstonTimezone() -> TimeZone {
    if UserDefaults.standard.bool(forKey: "use_system_timezone") {
        // Try to get state from UserDefaults (set when site is selected)
        let state = UserDefaults.standard.string(forKey: "selected_site_state")
        let timezone = UserDefaults.standard.string(forKey: "selected_site_timezone")
        
        // First try explicit timezone
        if let tz = timezone, let zone = TimeZone(identifier: tz) {
            return zone
        }
        // Fall back to state mapping
        return timezoneForState(state)
    } else {
        return .current
    }
}

// MARK: - String Extension for Decision Trace Formatting

extension String {
    /// Formats a decision trace with line breaks before each decision indicator
    var formattedDecisionTrace: String {
        self
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
            // Insert newline before each decision indicator
            .replacingOccurrences(of: "✅", with: "\n\n✅")
            .replacingOccurrences(of: "❌", with: "\n\n❌")
            .replacingOccurrences(of: "ℹ️", with: "\n\nℹ️")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Apple Intelligence Indicator
/// Shared indicator for Apple Intelligence-powered features
struct AppleIntelligenceIndicator: View {
    var body: some View {
        if #available(iOS 26.0, *) {
            HStack(spacing: 4) {
                Image(systemName: "apple.intelligence")
                    .font(.caption2)
                Text("Apple Intelligence")
                    .font(.caption2)
            }
            .foregroundStyle(
                LinearGradient(
                    colors: [.purple, .blue, .cyan],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }
}
