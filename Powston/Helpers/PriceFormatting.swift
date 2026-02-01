//
//  PriceFormatting.swift
//  Powston
//
//  Shared utilities for consistent price formatting and color coding across all dashboards
//

import SwiftUI

// MARK: - Price Formatting
struct PriceFormat {
    /// Format a price in cents, switching to dollars at ≥100¢
    static func format(_ cents: Double) -> String {
        if abs(cents) >= 100 {
            return String(format: "$%.2f", cents / 100)
        }
        return String(format: "%.1f¢", cents)
    }
    
    /// Format with more precision for large price cards
    static func formatPrecise(_ cents: Double) -> String {
        if abs(cents) >= 100 {
            return String(format: "$%.2f", cents / 100)
        }
        return String(format: "%.2f¢", cents)
    }
}

// MARK: - Price Colors
struct PriceColors {
    /// Color for buy price based on value
    /// - Negative: Green (getting paid to consume - great!)
    /// - ≥50¢: Orange (expensive - notable)
    /// - Normal: Blue
    static func buyColor(_ cents: Double) -> Color {
        if cents < 0 {
            return .green
        }
        if cents >= 50 {
            return .orange
        }
        return .blue
    }
    
    /// Color for sell price based on value
    /// - Negative: Red (paying to export - bad)
    /// - ≥50¢: Green (great opportunity)
    /// - Normal: Green
    static func sellColor(_ cents: Double) -> Color {
        if cents < 0 {
            return .red
        }
        return .green
    }
    
    /// Whether the price is "notable" and should have visual emphasis (border, etc.)
    static func isNotable(_ cents: Double) -> Bool {
        cents < 0 || cents >= 50
    }
    
    /// Border color for notable prices
    static func notableBorderColor(isBuy: Bool, cents: Double) -> Color? {
        guard isNotable(cents) else { return nil }
        
        if isBuy {
            return cents < 0 ? .green : .orange
        } else {
            return cents < 0 ? .red : .green
        }
    }
}

// MARK: - Reusable Price Views

/// A small price pill for inline display
struct PricePillView: View {
    let label: String
    let cents: Double
    let isBuy: Bool
    
    var color: Color {
        isBuy ? PriceColors.buyColor(cents) : PriceColors.sellColor(cents)
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(PriceFormat.format(cents))
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(16)
        .overlay(
            Group {
                if let borderColor = PriceColors.notableBorderColor(isBuy: isBuy, cents: cents) {
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(borderColor, lineWidth: 1.5)
                }
            }
        )
    }
}

/// A large price card for prominent display
struct LargePriceCardView: View {
    let label: String
    let cents: Double
    let isBuy: Bool
    
    var color: Color {
        isBuy ? PriceColors.buyColor(cents) : PriceColors.sellColor(cents)
    }
    
    var isNotable: Bool {
        PriceColors.isNotable(cents)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(color)
            
            Text(PriceFormat.formatPrecise(cents))
                .font(.title)
                .fontWeight(.bold)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(color.opacity(0.1))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isNotable ? color : color.opacity(0.3), lineWidth: isNotable ? 2 : 1)
        )
    }
}

/// Inline price text with appropriate color
struct InlinePriceText: View {
    let cents: Double
    let isBuy: Bool
    var font: Font = .headline
    var fontWeight: Font.Weight = .semibold
    
    var color: Color {
        isBuy ? PriceColors.buyColor(cents) : PriceColors.sellColor(cents)
    }
    
    var body: some View {
        Text(PriceFormat.format(cents))
            .font(font)
            .fontWeight(fontWeight)
            .foregroundColor(color)
    }
}

// MARK: - Preview
#Preview("Price Formatting") {
    ScrollView {
        VStack(spacing: 20) {
            Text("Price Pills").font(.headline)
            HStack {
                PricePillView(label: "Buy", cents: 8.5, isBuy: true)
                PricePillView(label: "Sell", cents: 5.2, isBuy: false)
            }
            HStack {
                PricePillView(label: "Buy", cents: -5.0, isBuy: true)
                PricePillView(label: "Sell", cents: -2.0, isBuy: false)
            }
            HStack {
                PricePillView(label: "Buy", cents: 75.0, isBuy: true)
                PricePillView(label: "Sell", cents: 85.0, isBuy: false)
            }
            HStack {
                PricePillView(label: "Buy", cents: 150.0, isBuy: true)
                PricePillView(label: "Sell", cents: 200.0, isBuy: false)
            }
            
            Divider()
            
            Text("Large Price Cards").font(.headline)
            HStack(spacing: 12) {
                LargePriceCardView(label: "Buy Price", cents: 8.5, isBuy: true)
                LargePriceCardView(label: "Sell Price", cents: 5.2, isBuy: false)
            }
            HStack(spacing: 12) {
                LargePriceCardView(label: "Buy Price", cents: -5.0, isBuy: true)
                LargePriceCardView(label: "Sell Price", cents: -2.0, isBuy: false)
            }
            HStack(spacing: 12) {
                LargePriceCardView(label: "Buy Price", cents: 75.0, isBuy: true)
                LargePriceCardView(label: "Sell Price", cents: 85.0, isBuy: false)
            }
            HStack(spacing: 12) {
                LargePriceCardView(label: "Buy Price", cents: 150.0, isBuy: true)
                LargePriceCardView(label: "Sell Price", cents: 200.0, isBuy: false)
            }
        }
        .padding()
    }
}
