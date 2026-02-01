//
//  PowstonLiveActivity.swift
//  PowstonWidgetExtension
//
//  Live Activity UI for Dynamic Island and Lock Screen
//  Add to widget extension target
//

import ActivityKit
import SwiftUI
import WidgetKit

struct PowstonLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PowstonActivityAttributes.self) { context in
            // Lock Screen / Banner UI
            LockScreenView(context: context)
                .activityBackgroundTint(backgroundColor(for: context.state.status))
                .activitySystemActionForegroundColor(.white)
            
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded regions
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeadingView(context: context)
                }
                
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailingView(context: context)
                }
                
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottomView(context: context)
                }
                
                DynamicIslandExpandedRegion(.center) {
                    ExpandedCenterView(context: context)
                }
                
            } compactLeading: {
                CompactLeadingView(context: context)
                
            } compactTrailing: {
                CompactTrailingView(context: context)
                
            } minimal: {
                MinimalView(context: context)
            }
            .widgetURL(URL(string: "powston://override"))
            .keylineTint(tintColor(for: context.state.status))
        }
    }
    
    // MARK: - Colors
    
    func backgroundColor(for status: OverrideStatus) -> Color {
        switch status {
        case .pending, .scheduled: return .blue.opacity(0.8)
        case .active: return .orange.opacity(0.8)
        case .completed: return .green.opacity(0.8)
        case .cancelled: return .red.opacity(0.8)
        }
    }
    
    func tintColor(for status: OverrideStatus) -> Color {
        switch status {
        case .pending, .scheduled: return .blue
        case .active: return .orange
        case .completed: return .green
        case .cancelled: return .red
        }
    }
}

// MARK: - Lock Screen View

struct LockScreenView: View {
    let context: ActivityViewContext<PowstonActivityAttributes>
    
    var body: some View {
        HStack(spacing: 16) {
            // Status icon
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 50, height: 50)
                
                if context.state.status == .pending {
                    ProgressView()
                        .tint(statusColor)
                } else {
                    Image(systemName: context.state.status.icon)
                        .font(.title2)
                        .foregroundColor(statusColor)
                }
            }
            
            // Main content
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(context.state.mode.uppercased())
                        .font(.headline)
                        .fontWeight(.bold)
                    
                    Text("• \(context.state.status.displayName)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                switch context.state.status {
                case .pending:
                    Text("Waiting for confirmation...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                case .scheduled:
                    if let start = context.state.startTime {
                        Text("Starts \(context.state.formattedStartsIn)")
                            .font(.subheadline)
                            .foregroundColor(.blue)
                    }
                    
                case .active:
                    if let end = context.state.endTime {
                        HStack(spacing: 8) {
                            Text(context.state.formattedRemaining + " remaining")
                                .font(.subheadline)
                                .foregroundColor(.orange)
                            
                            // Progress bar
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(height: 4)
                                    
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.orange)
                                        .frame(width: geo.size.width * context.state.progress, height: 4)
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                    
                case .completed, .cancelled:
                    Text(context.state.status == .completed ? "Override finished" : "Override cancelled")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                // Inverter count
                Text("\(context.state.inverterCount) inverter\(context.state.inverterCount == 1 ? "" : "s") • \(context.attributes.siteName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
    }
    
    var statusColor: Color {
        switch context.state.status {
        case .pending, .scheduled: return .blue
        case .active: return .orange
        case .completed: return .green
        case .cancelled: return .red
        }
    }
}

// MARK: - Dynamic Island Compact Views

struct CompactLeadingView: View {
    let context: ActivityViewContext<PowstonActivityAttributes>
    
    var body: some View {
        HStack(spacing: 4) {
            if context.state.status == .pending {
                ProgressView()
                    .scaleEffect(0.6)
            } else {
                Image(systemName: context.state.status.icon)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
        }
    }
    
    var statusColor: Color {
        switch context.state.status {
        case .pending, .scheduled: return .blue
        case .active: return .orange
        case .completed: return .green
        case .cancelled: return .red
        }
    }
}

struct CompactTrailingView: View {
    let context: ActivityViewContext<PowstonActivityAttributes>
    
    var body: some View {
        switch context.state.status {
        case .pending:
            Text("...")
                .font(.caption)
                .foregroundColor(.secondary)
            
        case .scheduled:
            Text(context.state.formattedStartsIn)
                .font(.caption.monospacedDigit())
                .foregroundColor(.blue)
            
        case .active:
            Text(context.state.formattedRemaining)
                .font(.caption.monospacedDigit())
                .foregroundColor(.orange)
            
        case .completed, .cancelled:
            Image(systemName: context.state.status.icon)
                .font(.caption)
        }
    }
}

struct MinimalView: View {
    let context: ActivityViewContext<PowstonActivityAttributes>
    
    var body: some View {
        if context.state.status == .pending {
            ProgressView()
                .scaleEffect(0.5)
        } else {
            Image(systemName: modeIcon)
                .font(.caption)
                .foregroundColor(statusColor)
        }
    }
    
    var modeIcon: String {
        let mode = context.state.mode.lowercased()
        if mode.contains("charge") { return "bolt.fill" }
        if mode.contains("discharge") || mode.contains("export") { return "arrow.up.circle.fill" }
        if mode.contains("import") { return "arrow.down.circle.fill" }
        return "arrow.triangle.2.circlepath"
    }
    
    var statusColor: Color {
        switch context.state.status {
        case .pending, .scheduled: return .blue
        case .active: return .orange
        case .completed: return .green
        case .cancelled: return .red
        }
    }
}

// MARK: - Dynamic Island Expanded Views

struct ExpandedLeadingView: View {
    let context: ActivityViewContext<PowstonActivityAttributes>
    
    var body: some View {
        VStack(alignment: .leading) {
            if context.state.status == .pending {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: context.state.status.icon)
                    .font(.title2)
                    .foregroundColor(statusColor)
            }
        }
    }
    
    var statusColor: Color {
        switch context.state.status {
        case .pending, .scheduled: return .blue
        case .active: return .orange
        case .completed: return .green
        case .cancelled: return .red
        }
    }
}

struct ExpandedTrailingView: View {
    let context: ActivityViewContext<PowstonActivityAttributes>
    
    var body: some View {
        VStack(alignment: .trailing) {
            switch context.state.status {
            case .pending:
                Text("Verifying")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
            case .scheduled:
                Text(context.state.formattedStartsIn)
                    .font(.title3.monospacedDigit())
                    .fontWeight(.semibold)
                    .foregroundColor(.blue)
                
            case .active:
                Text(context.state.formattedRemaining)
                    .font(.title3.monospacedDigit())
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
                
            case .completed, .cancelled:
                Text(context.state.status.displayName)
                    .font(.caption)
            }
        }
    }
}

struct ExpandedCenterView: View {
    let context: ActivityViewContext<PowstonActivityAttributes>
    
    var body: some View {
        Text(context.state.mode.uppercased())
            .font(.headline)
            .fontWeight(.bold)
    }
}

struct ExpandedBottomView: View {
    let context: ActivityViewContext<PowstonActivityAttributes>
    
    var body: some View {
        HStack {
            Text("\(context.state.inverterCount) inverter\(context.state.inverterCount == 1 ? "" : "s")")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Spacer()
            
            if context.state.status == .active {
                // Progress indicator
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 4)
                        
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.orange)
                            .frame(width: geo.size.width * context.state.progress, height: 4)
                    }
                }
                .frame(width: 100, height: 4)
            }
        }
    }
}

// MARK: - Preview

#Preview("Lock Screen", as: .content, using: PowstonActivityAttributes(activityId: "preview", siteName: "Home")) {
    PowstonLiveActivity()
} contentStates: {
    PowstonActivityAttributes.ContentState(
        status: .active,
        mode: "Export",
        endTime: Date().addingTimeInterval(1800),
        startTime: nil,
        inverterCount: 2,
        progress: 0.6
    )
    PowstonActivityAttributes.ContentState(
        status: .pending,
        mode: "Charge",
        endTime: nil,
        startTime: nil,
        inverterCount: 2,
        progress: 0
    )
    PowstonActivityAttributes.ContentState(
        status: .scheduled,
        mode: "Discharge",
        endTime: Date().addingTimeInterval(7200),
        startTime: Date().addingTimeInterval(3600),
        inverterCount: 1,
        progress: 0
    )
}
