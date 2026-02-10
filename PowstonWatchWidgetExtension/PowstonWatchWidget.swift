//
//  PowstonWatchWidget.swift
//  PowstonWatch
//
//  WidgetKit-based complications for watchOS 10+
//

import WidgetKit
import SwiftUI

// MARK: - Cached Data Access (standalone for widget)

enum WatchWidgetDataProvider {
    private static let watchAppGroup = "group.com.bollar.powston.watch"
    
    static func getCachedComplicationData() -> WatchComplicationData {
        guard let sharedDefaults = UserDefaults(suiteName: watchAppGroup),
              let data = sharedDefaults.data(forKey: "cached_complication_data"),
              let decoded = try? JSONDecoder().decode(WatchComplicationData.self, from: data) else {
            return .placeholder
        }
        return decoded
    }
}

// MARK: - Timeline Provider

struct PowstonWatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> PowstonWatchEntry {
        PowstonWatchEntry(date: Date(), data: .placeholder)
    }
    
    func getSnapshot(in context: Context, completion: @escaping (PowstonWatchEntry) -> Void) {
        let data = WatchWidgetDataProvider.getCachedComplicationData()
        completion(PowstonWatchEntry(date: Date(), data: data))
    }
    
    func getTimeline(in context: Context, completion: @escaping (Timeline<PowstonWatchEntry>) -> Void) {
        let data = WatchWidgetDataProvider.getCachedComplicationData()
        let entry = PowstonWatchEntry(date: Date(), data: data)
        
        // Refresh every 15 minutes
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())!
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Timeline Entry

struct PowstonWatchEntry: TimelineEntry {
    let date: Date
    let data: WatchComplicationData
}

// MARK: - Widget Views

struct PowstonAccessoryCircularView: View {
    let data: WatchComplicationData
    
    var body: some View {
        Gauge(value: Double(data.soc), in: 0...100) {
            Text("SOC")
        } currentValueLabel: {
            Text("\(data.soc)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
        }
        .gaugeStyle(.accessoryCircular)
        .tint(data.socColor)
    }
}

struct PowstonAccessoryRectangularView: View {
    let data: WatchComplicationData
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("POWSTON")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if data.isStale {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.orange)
                }
            }
            
            HStack(spacing: 4) {
                Text("\(data.soc)%")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(data.socColor)
                
                Text("•")
                    .foregroundColor(.secondary)
                
                Text(data.flowText)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(data.isCharging ? .green : .orange)
            }
            
            HStack(spacing: 8) {
                Label(data.buyPriceText, systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.blue)
                
                Label(data.sellPriceText, systemImage: "arrow.up.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.green)
            }
        }
    }
}

struct PowstonAccessoryCornerView: View {
    let data: WatchComplicationData
    
    var body: some View {
        Text("\(data.soc)%")
            .font(.system(size: 20, weight: .bold, design: .rounded))
            .foregroundColor(data.socColor)
            .widgetLabel {
                Gauge(value: Double(data.soc), in: 0...100) {
                    Text("")
                }
                .tint(data.socColor)
                .gaugeStyle(.accessoryLinear)
            }
    }
}

struct PowstonAccessoryInlineView: View {
    let data: WatchComplicationData
    
    var body: some View {
        Label {
            Text("\(data.soc)% • \(data.flowText)")
        } icon: {
            Image(systemName: "battery.100.bolt")
        }
    }
}

// MARK: - Widget Definition

struct PowstonWatchWidget: Widget {
    let kind: String = "PowstonWatchWidget"
    
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PowstonWatchProvider()) { entry in
            PowstonWatchWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Powston Battery")
        .description("Battery status and energy prices")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryCorner,
            .accessoryInline
        ])
    }
}

struct PowstonWatchWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: PowstonWatchEntry
    
    var body: some View {
        switch family {
        case .accessoryCircular:
            PowstonAccessoryCircularView(data: entry.data)
        case .accessoryRectangular:
            PowstonAccessoryRectangularView(data: entry.data)
        case .accessoryCorner:
            PowstonAccessoryCornerView(data: entry.data)
        case .accessoryInline:
            PowstonAccessoryInlineView(data: entry.data)
        default:
            PowstonAccessoryCircularView(data: entry.data)
        }
    }
}

// MARK: - Widget Bundle

@main
struct PowstonWatchWidgets: WidgetBundle {
    var body: some Widget {
        PowstonWatchWidget()
    }
}

// MARK: - Preview

#Preview("Circular", as: .accessoryCircular) {
    PowstonWatchWidget()
} timeline: {
    PowstonWatchEntry(date: Date(), data: .placeholder)
}

#Preview("Rectangular", as: .accessoryRectangular) {
    PowstonWatchWidget()
} timeline: {
    PowstonWatchEntry(date: Date(), data: .placeholder)
}
