//
//  P2PTradeImportView.swift
//  Powston
//
//  Import P2P trade data from LocalVolts paste, calculate premium over spot
//

import SwiftUI

// MARK: - Data Models

struct P2PMobileTradeRow: Identifiable {
    let id: UUID
    let counterparty: String
    let volumeKwh: Double
    let priceCents: Double
    let direction: P2PTradeDirection  // Buy or Sell

    init(counterparty: String, volumeKwh: Double, priceCents: Double, direction: P2PTradeDirection) {
        self.id = UUID()
        self.counterparty = counterparty
        self.volumeKwh = volumeKwh
        self.priceCents = priceCents
        self.direction = direction
    }
}

struct P2PMobileSummary {
    let trades: [P2PMobileTradeRow]

    // Separated by direction
    var sellTrades: [P2PMobileTradeRow] { trades.filter { $0.direction == .sell } }
    var buyTrades: [P2PMobileTradeRow] { trades.filter { $0.direction == .buy } }

    var sellKwh: Double { sellTrades.reduce(0) { $0 + $1.volumeKwh } }
    var buyKwh: Double { buyTrades.reduce(0) { $0 + $1.volumeKwh } }
    var sellRevenue: Double { sellTrades.reduce(0) { $0 + $1.volumeKwh * $1.priceCents / 100.0 } }
    var buyCost: Double { buyTrades.reduce(0) { $0 + $1.volumeKwh * $1.priceCents / 100.0 } }
    var netRevenue: Double { sellRevenue - buyCost }

    var sellAvgPrice: Double { sellKwh > 0 ? (sellRevenue / sellKwh) * 100 : 0 }
    var buyAvgPrice: Double { buyKwh > 0 ? (buyCost / buyKwh) * 100 : 0 }

    // Legacy compatibility
    let byPricePoint: [Double: (count: Int, totalKwh: Double, totalRevenue: Double)]
    var totalKwh: Double { sellKwh + buyKwh }
    var totalRevenue: Double { sellRevenue }  // For backwards compat, but should use netRevenue
    var avgPrice: Double { sellAvgPrice }
    let counterpartyCount: Int

    // Counterparties that appear in both directions
    var bidirectionalCounterparties: Set<String> {
        let sellNames = Set(sellTrades.map { $0.counterparty })
        let buyNames = Set(buyTrades.map { $0.counterparty })
        return sellNames.intersection(buyNames)
    }
}

// MARK: - Parser

class P2PTradeParser {

    // MARK: - Mobile Trades Parser

    /// Parse mobile "My Trades" format
    /// Format can be multi-line where price is on a separate line:
    /// "Alexander Hawkins    0.2"
    /// "26.291"
    /// Or single line: "Chicken Mania    0.38    24.1846"
    /// Direction is determined by "Sell" or "Buy" section headers
    /// Parse mobile "My Trades" format
    /// - Parameters:
    ///   - text: The pasted text to parse
    ///   - defaultDirection: User-specified direction (used when auto-detection isn't possible)
    func parseMobileTrades(_ text: String, defaultDirection: P2PTradeDirection = .sell, priceThreshold: Double? = nil) -> [P2PMobileTradeRow] {
        var trades: [P2PMobileTradeRow] = []

        // Keep original lines with whitespace for column detection
        let rawLines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        // Use user-specified direction as default
        var currentDirection: P2PTradeDirection = defaultDirection
        var foundDirectionHeader = false  // Track if we found any Sell/Buy headers

        // Process lines, detecting direction changes
        // Store both original (with whitespace) and trimmed versions
        var dataLines: [(original: String, trimmed: String, direction: P2PTradeDirection)] = []

        for rawLine in rawLines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()

            // Check for direction headers (various formats from LocalVolts)
            // "Sell (c/kWh)" or "Buy (c/kWh)" - the column headers indicate direction
            if lower.hasPrefix("sell") && (lower.contains("c/kwh") || lower.contains("(c/") || lower == "sell") {
                currentDirection = .sell
                foundDirectionHeader = true
                continue
            }
            if lower.hasPrefix("buy") && (lower.contains("c/kwh") || lower.contains("(c/") || lower == "buy") {
                currentDirection = .buy
                foundDirectionHeader = true
                continue
            }

            // Other sell variations: "Sell Trades", "Sold", "Selling"
            if lower == "sell" || lower.contains("sell trades") ||
               lower == "sold" || lower.hasPrefix("sold ") || lower.contains("sold trades") ||
               lower == "selling" || lower.hasPrefix("selling ") {
                currentDirection = .sell
                foundDirectionHeader = true
                continue
            }
            // Other buy variations: "Buy Trades", "Bought", "Buying"
            if lower == "buy" || lower.contains("buy trades") ||
               lower == "bought" || lower.hasPrefix("bought ") || lower.contains("bought trades") ||
               lower == "buying" || lower.hasPrefix("buying ") {
                currentDirection = .buy
                foundDirectionHeader = true
                continue
            }

            // Skip other header lines
            if lower.contains("counterparty") ||
               lower.contains("volume") ||
               lower.contains("(kwh)") {
                continue
            }

            // Skip standalone "c/kwh" lines (but not if they're direction headers)
            if lower == "c/kwh" || lower == "(c/kwh)" {
                continue
            }

            dataLines.append((original: rawLine, trimmed: trimmed, direction: currentDirection))
        }

        // If no direction headers found, calculate a threshold from the data
        let useThreshold = !foundDirectionHeader
        let threshold = priceThreshold ?? findOptimalThreshold(text)

        // Check if we have alternating pattern (name+volume, then price)
        let justNumberPattern = #"^\d+\.?\d*$"#  // Just a number (check against trimmed)
        let justNumberLines = dataLines.filter { item in
            item.trimmed.range(of: justNumberPattern, options: .regularExpression) != nil
        }

        // Check for THREE-line format: Name, Volume, Price on separate lines
        // This happens when iOS Safari copies the LocalVolts table
        // Pattern: ~2/3 of lines are just numbers (volume and price lines)
        if justNumberLines.count > dataLines.count / 2 {
            // Three-line format: Name, Volume, Price
            var i = 0
            while i < dataLines.count {
                let item1 = dataLines[i]      // Should be Name

                // Check if this line is a number (skip stray number lines)
                let item1IsNumber = item1.trimmed.range(of: justNumberPattern, options: .regularExpression) != nil
                if item1IsNumber {
                    i += 1
                    continue
                }

                // Check if we have two more lines and they're both numbers
                if i + 2 < dataLines.count {
                    let item2 = dataLines[i + 1]  // Should be Volume
                    let item3 = dataLines[i + 2]  // Should be Price

                    let item2IsNumber = item2.trimmed.range(of: justNumberPattern, options: .regularExpression) != nil
                    let item3IsNumber = item3.trimmed.range(of: justNumberPattern, options: .regularExpression) != nil

                    if item2IsNumber && item3IsNumber {
                        // Three-line format: Name, Volume, Price
                        if let row = parseThreeLineTradeRow(
                            nameLine: item1.trimmed,
                            volumeLine: item2.trimmed,
                            priceLine: item3.trimmed,
                            direction: item1.direction
                        ) {
                            trades.append(row)
                        }
                        i += 3
                        continue
                    }
                }

                // Fallback: try two-line format if next line is a number
                if i + 1 < dataLines.count {
                    let item2 = dataLines[i + 1]
                    let item2IsNumber = item2.trimmed.range(of: justNumberPattern, options: .regularExpression) != nil

                    if item2IsNumber {
                        // But DON'T use parseMultiLineTradeRow for names with digits
                        // because it extracts the first number from the name as volume
                        // Just skip this malformed entry
                        i += 2
                        continue
                    }
                }

                // Skip unrecognized line
                i += 1
            }
        } else if justNumberLines.count > dataLines.count / 3 {
            // Two-line format: Name+Volume, then Price
            var i = 0
            while i < dataLines.count - 1 {
                let item1 = dataLines[i]
                let item2 = dataLines[i + 1]

                if item2.trimmed.range(of: justNumberPattern, options: .regularExpression) != nil {
                    if let row = parseMultiLineTradeRow(
                        nameLine: item1.trimmed,
                        priceLine: item2.original,
                        direction: item1.direction,
                        useThreshold: useThreshold,
                        threshold: threshold
                    ) {
                        trades.append(row)
                    }
                    i += 2
                } else {
                    if let row = parseSingleLineTradeRow(item1.trimmed, direction: item1.direction) {
                        trades.append(row)
                    }
                    i += 1
                }
            }

            if i < dataLines.count {
                if let row = parseSingleLineTradeRow(dataLines[i].trimmed, direction: dataLines[i].direction) {
                    trades.append(row)
                }
            }
        } else {
            // Single-line format - check if it's tab-separated columnar format
            // LocalVolts counterparty table format: Name | Volume | Sell | Buy
            // - Direction determined by which price column is populated
            // - Only ONE of Sell/Buy has a value per row

            // First check if this looks like tab-separated columnar data
            let hasTabSeparatedData = dataLines.contains { $0.original.contains("\t") }

            for item in dataLines {
                if hasTabSeparatedData {
                    // Tab-separated format: try columnar parsing first
                    if let row = parseColumnarTradeRow(item.original) {
                        trades.append(row)
                    } else if let row = parseSingleLineTradeRow(item.trimmed, direction: item.direction) {
                        trades.append(row)
                    }
                } else {
                    // Space-separated or other format - try to detect direction from 2-number pattern
                    if let row = parseCounterpartySummaryRow(item.trimmed, fallbackDirection: item.direction).first {
                        trades.append(row)
                    } else if let row = parseSingleLineTradeRow(item.trimmed, direction: item.direction) {
                        trades.append(row)
                    }
                }
            }
        }
        
        return trades
    }
    
    private func parseMultiLineTradeRow(nameLine: String, priceLine: String, direction: P2PTradeDirection, useThreshold: Bool = false, threshold: Double = 12.0) -> P2PMobileTradeRow? {
        // nameLine: "Alexander Hawkins    0.2" or with tabs
        // priceLine: "30        " (Sell with trailing whitespace) or "    6.4627" (Buy with leading whitespace)

        // Extract price from priceLine
        let trimmedPrice = priceLine.trimmingCharacters(in: .whitespaces)
        guard let price = Double(trimmedPrice) else {
            return nil
        }

        // Extract name and volume from nameLine
        // Look for a number at the END of the line that's preceded by whitespace
        // This avoids extracting "4" from names like "Lismore 4X4 Accessories"
        let volumeAtEndPattern = #"\s(\d+\.?\d*)\s*$"#
        guard let volumeRegex = try? NSRegularExpression(pattern: volumeAtEndPattern, options: []) else { return nil }
        let nsLine = nameLine as NSString
        let matches = volumeRegex.matches(in: nameLine, options: [], range: NSRange(location: 0, length: nsLine.length))

        guard let lastMatch = matches.last else { return nil }

        // The volume is in capture group 1
        guard lastMatch.numberOfRanges >= 2 else { return nil }
        let volumeRange = lastMatch.range(at: 1)
        let volumeStr = nsLine.substring(with: volumeRange)
        guard let volume = Double(volumeStr) else { return nil }

        // Name is everything before the whitespace preceding the volume
        let nameEndIndex = lastMatch.range.location
        let name = nsLine.substring(to: nameEndIndex).trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty, volume >= 0, price > 0 else { return nil }

        // Skip zero volume entries
        guard volume > 0 else { return nil }

        // Determine direction:
        // - If useThreshold is true (no Sell/Buy headers found), use price-based classification
        // - Otherwise use the passed direction (from headers or default)
        let finalDirection: P2PTradeDirection
        if useThreshold {
            // Low prices = buying cheap solar, high prices = selling at peak
            finalDirection = price < threshold ? .buy : .sell
        } else {
            finalDirection = direction
        }

        return P2PMobileTradeRow(
            counterparty: name,
            volumeKwh: volume,
            priceCents: price,
            direction: finalDirection
        )
    }

    /// Parse three-line format: Name on line 1, Volume on line 2, Price on line 3
    /// This is the format when iOS Safari copies LocalVolts "My Trades" table
    private func parseThreeLineTradeRow(nameLine: String, volumeLine: String, priceLine: String, direction: P2PTradeDirection) -> P2PMobileTradeRow? {
        let name = nameLine.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // Skip if name looks like a header
        let nameLower = name.lowercased()
        if nameLower.contains("counterparty") || nameLower.contains("volume") || nameLower.contains("c/kwh") {
            return nil
        }

        guard let volume = Double(volumeLine.trimmingCharacters(in: .whitespaces)) else { return nil }
        guard let price = Double(priceLine.trimmingCharacters(in: .whitespaces)) else { return nil }

        // Skip zero volume entries (but allow zero price which shouldn't happen)
        guard volume > 0, price > 0 else { return nil }

        return P2PMobileTradeRow(
            counterparty: name,
            volumeKwh: volume,
            priceCents: price,
            direction: direction
        )
    }

    /// Parse a tab-separated columnar row from LocalVolts counterparty table
    /// Format: Name | Volume | [empty cols...] | Sell Price | Buy Price
    /// Direction is determined by which price column is populated (not both)
    /// LocalVolts may have extra empty columns from sparkline charts between Volume and prices
    private func parseColumnarTradeRow(_ line: String) -> P2PMobileTradeRow? {
        // Split by tabs - LocalVolts table copies with tab separators
        let columns = line.components(separatedBy: "\t")

        // We expect at least 3 columns: Name, Volume, and at least one price
        guard columns.count >= 3 else { return nil }

        let name = columns[0].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }

        // Skip header row
        let nameLower = name.lowercased()
        if nameLower.contains("counterparty") || nameLower.contains("volume") || nameLower == "name" {
            return nil
        }

        // Parse volume from column 1
        let volumeStr = columns[1].trimmingCharacters(in: .whitespaces)
        guard let volume = Double(volumeStr) else { return nil }

        // Skip zero volume entries (no actual trade happened)
        guard volume > 0 else { return nil }

        // Scan all columns after volume to find price values
        // LocalVolts format may have empty columns (from sparklines) between volume and prices
        // The last two non-empty numeric columns should be Sell and Buy prices
        // But only ONE will have a value per row
        var priceColumns: [(index: Int, value: Double)] = []

        for i in 2..<columns.count {
            let str = columns[i].trimmingCharacters(in: .whitespaces)
            if !str.isEmpty, let price = Double(str), price > 0 {
                priceColumns.append((index: i, value: price))
            }
        }

        // Should have exactly one price value per row
        guard priceColumns.count >= 1 else { return nil }

        // If we have one price, determine direction by its position
        // Earlier column = Sell, Later column = Buy
        // Find the expected Sell and Buy column positions by looking at all columns
        // Typically: Name(0) | Vol(1) | [empty...] | Sell | Buy
        // The last two potential price positions are Sell and Buy

        if priceColumns.count == 1 {
            let priceInfo = priceColumns[0]
            // Count total meaningful columns to determine if this is Sell or Buy position
            // If the price is in an earlier position relative to total columns, it's likely Sell
            // If it's in a later position, it's likely Buy
            //
            // Heuristic: Look at the column index relative to the end
            // If there are empty columns AFTER this price, it's Sell (Buy column is empty)
            // If there are no columns or empty columns BEFORE this price (after volume), it's Buy

            let columnsAfterPrice = columns.count - 1 - priceInfo.index
            let columnsBeforePrice = priceInfo.index - 2  // columns between volume and this price

            // Check if there's a meaningful empty column after this price (suggests Buy column exists but is empty = this is Sell)
            var hasEmptyAfter = false
            for j in (priceInfo.index + 1)..<columns.count {
                let afterStr = columns[j].trimmingCharacters(in: .whitespaces)
                // If there's an empty column that could hold a price, this price is in the Sell position
                if afterStr.isEmpty || afterStr == "(c/kWh)" {
                    hasEmptyAfter = true
                    break
                }
            }

            // Check if there are empty columns between volume and this price (suggests Sell column is empty = this is Buy)
            var hasEmptyBefore = false
            for j in 2..<priceInfo.index {
                let beforeStr = columns[j].trimmingCharacters(in: .whitespaces)
                if beforeStr.isEmpty {
                    hasEmptyBefore = true
                }
            }

            // Decision logic:
            // - If there are empty columns before AND empty columns after, use position heuristic
            // - If mostly empty before, this is likely Buy (Sell column was skipped)
            // - If mostly empty after, this is likely Sell (Buy column is empty)
            let direction: P2PTradeDirection
            if hasEmptyBefore && !hasEmptyAfter {
                // Empty before, content at end = Buy
                direction = .buy
            } else if !hasEmptyBefore && hasEmptyAfter {
                // Content early, empty after = Sell
                direction = .sell
            } else if hasEmptyBefore && hasEmptyAfter {
                // Both have empties - use position relative to total columns
                // Sell tends to be in earlier position, Buy in later
                let relativePosition = Double(priceInfo.index) / Double(max(1, columns.count - 1))
                direction = relativePosition > 0.6 ? .buy : .sell
            } else {
                // No empty columns - shouldn't happen with LocalVolts format, default to sell
                direction = .sell
            }

            return P2PMobileTradeRow(
                counterparty: name,
                volumeKwh: volume,
                priceCents: priceInfo.value,
                direction: direction
            )
        } else if priceColumns.count >= 2 {
            // Multiple prices found - first is Sell, last is Buy (shouldn't happen per row, but handle it)
            let sellPrice = priceColumns.first!.value
            return P2PMobileTradeRow(
                counterparty: name,
                volumeKwh: volume,
                priceCents: sellPrice,
                direction: .sell
            )
        }

        // No valid price found
        return nil
    }

    private func parseSingleLineTradeRow(_ line: String, direction: P2PTradeDirection) -> P2PMobileTradeRow? {
        // Find all decimal numbers in the line
        let numberPattern = #"(\d+\.?\d*)"#
        let regex = try? NSRegularExpression(pattern: numberPattern, options: [])
        let nsLine = line as NSString
        let matches = regex?.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length)) ?? []

        // We need at least 2 numbers (volume and price)
        guard matches.count >= 2 else { return nil }

        // Extract numbers
        var numbers: [Double] = []
        for match in matches {
            let numStr = nsLine.substring(with: match.range)
            if let num = Double(numStr) {
                numbers.append(num)
            }
        }

        guard numbers.count >= 2 else { return nil }

        // Extract counterparty name (everything before the first number)
        let firstNumberMatch = matches[0]
        let nameEndIndex = firstNumberMatch.range.location
        let name = nsLine.substring(to: nameEndIndex).trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty else { return nil }

        // First number is volume, second is price
        let volume = numbers[0]
        let price = numbers[1]

        // Skip if volume is 0 or price seems invalid
        guard volume > 0, price > 0 else { return nil }

        // Use the user-specified direction from the direction picker
        return P2PMobileTradeRow(
            counterparty: name,
            volumeKwh: volume,
            priceCents: price,
            direction: direction
        )
    }

    /// Parse a counterparty summary row that may have both sell and buy data
    /// Handles various formats:
    /// - 4 numbers: Sell Vol | Buy Vol | Sell Price | Buy Price
    /// - 3 numbers: Could be (0, BuyVol, BuyPrice) or (SellVol, 0, SellPrice) or (SellVol, SellPrice, BuyPrice with missing vol)
    /// - 2 numbers with first=0: Likely (0, BuyVol) - buy-only counterparty
    /// - 2 numbers: Uses fallbackDirection since we can't distinguish (SellVol, SellPrice) from (BuyVol, BuyPrice)
    /// Returns up to 2 trades (one sell, one buy) if both have non-zero volume
    private func parseCounterpartySummaryRow(_ line: String, fallbackDirection: P2PTradeDirection = .sell) -> [P2PMobileTradeRow] {
        var trades: [P2PMobileTradeRow] = []

        // Find all decimal numbers in the line
        let numberPattern = #"(\d+\.?\d*)"#
        let regex = try? NSRegularExpression(pattern: numberPattern, options: [])
        let nsLine = line as NSString
        let matches = regex?.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length)) ?? []

        guard !matches.isEmpty else { return trades }

        // Extract numbers
        var numbers: [Double] = []
        for match in matches {
            let numStr = nsLine.substring(with: match.range)
            if let num = Double(numStr) {
                numbers.append(num)
            }
        }

        guard !numbers.isEmpty else { return trades }

        // Extract counterparty name (everything before the first number)
        let firstNumberMatch = matches[0]
        let nameEndIndex = firstNumberMatch.range.location
        let name = nsLine.substring(to: nameEndIndex).trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty else { return trades }

        // Handle different number counts
        if numbers.count >= 4 {
            // Full format: Sell Vol, Buy Vol, Sell Price, Buy Price
            let sellVolume = numbers[0]
            let buyVolume = numbers[1]
            let sellPrice = numbers[2]
            let buyPrice = numbers[3]

            if sellVolume > 0 && sellPrice > 0 {
                trades.append(P2PMobileTradeRow(
                    counterparty: name,
                    volumeKwh: sellVolume,
                    priceCents: sellPrice,
                    direction: .sell
                ))
            }

            if buyVolume > 0 && buyPrice > 0 {
                trades.append(P2PMobileTradeRow(
                    counterparty: name,
                    volumeKwh: buyVolume,
                    priceCents: buyPrice,
                    direction: .buy
                ))
            }
        } else if numbers.count == 3 {
            // Could be: (0, BuyVol, BuyPrice) or (SellVol, 0, SellPrice) or (SellVol, SellPrice, 0)
            let n0 = numbers[0]
            let n1 = numbers[1]
            let n2 = numbers[2]

            if n0 == 0 && n1 > 0 && n2 > 0 {
                // Format: 0, BuyVol, BuyPrice (sell vol is 0, this is a buy-only row)
                trades.append(P2PMobileTradeRow(
                    counterparty: name,
                    volumeKwh: n1,
                    priceCents: n2,
                    direction: .buy
                ))
            } else if n0 > 0 && n1 == 0 && n2 > 0 {
                // Format: SellVol, 0, SellPrice (buy vol is 0, this is a sell-only row)
                trades.append(P2PMobileTradeRow(
                    counterparty: name,
                    volumeKwh: n0,
                    priceCents: n2,
                    direction: .sell
                ))
            } else if n0 > 0 && n1 > 0 {
                // Ambiguous 3-number row - could be:
                // (SellVol, SellPrice, ???) or (BuyVol, BuyPrice, ???)
                // Use heuristics: if n1 looks like a price (5-50 range), create trade with fallback direction
                // Otherwise skip (data might be malformed)
                if n1 >= 3 && n1 <= 60 {
                    trades.append(P2PMobileTradeRow(
                        counterparty: name,
                        volumeKwh: n0,
                        priceCents: n1,
                        direction: fallbackDirection
                    ))
                }
            }
        } else if numbers.count == 2 {
            let n0 = numbers[0]
            let n1 = numbers[1]

            if n0 == 0 && n1 > 0 {
                // First number is 0 - this is a buy-only counterparty (SellVol=0)
                // n1 is the BuyVol - we're missing BuyPrice
                // Since we can't determine price, skip this row
                // It will fall back to single-line parser with user's direction
            } else if n0 > 0 && n1 > 0 {
                // With only 2 numbers, we can't reliably determine if this is:
                // - (SellVol, SellPrice) - sell-only counterparty
                // - (BuyVol, BuyPrice) - buy-only counterparty
                // - (SellVol, BuyVol) - both volumes, no prices
                // Price threshold heuristic is unreliable since P2P prices vary widely.
                // Use the user's selected direction (fallbackDirection) as the most reliable signal.
                trades.append(P2PMobileTradeRow(
                    counterparty: name,
                    volumeKwh: n0,
                    priceCents: n1,
                    direction: fallbackDirection
                ))
            }
        }

        return trades
    }

    func summarizeMobileTrades(_ trades: [P2PMobileTradeRow]) -> P2PMobileSummary {
        var byPricePoint: [Double: (count: Int, totalKwh: Double, totalRevenue: Double)] = [:]

        for trade in trades {
            // Round price to nearest cent for grouping
            let roundedPrice = (trade.priceCents * 10).rounded() / 10

            var existing = byPricePoint[roundedPrice] ?? (count: 0, totalKwh: 0, totalRevenue: 0)
            existing.count += 1
            existing.totalKwh += trade.volumeKwh
            existing.totalRevenue += trade.volumeKwh * trade.priceCents / 100.0
            byPricePoint[roundedPrice] = existing
        }

        return P2PMobileSummary(
            trades: trades,
            byPricePoint: byPricePoint,
            counterpartyCount: trades.count
        )
    }

    // MARK: - Format Detection and Concatenated Format Parsing

    /// Detected paste format
    enum PasteFormat {
        case tabSeparated      // Has tabs between columns - can determine direction from column position
        case concatenated      // No tabs - name+volume stuck together, price on next line, needs threshold
        case unknown
    }

    /// Detect whether the pasted text is tab-separated or concatenated format
    func detectFormat(_ text: String) -> PasteFormat {
        let lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard !lines.isEmpty else { return .unknown }

        // Check if any data lines have tabs
        let hasTabsInData = lines.contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces).lowercased()
            // Skip header-like lines
            if trimmed.contains("counterparty") || trimmed.contains("volume") || trimmed.contains("c/kwh") {
                return false
            }
            return line.contains("\t")
        }

        if hasTabsInData {
            return .tabSeparated
        }

        // Check for concatenated/split-line pattern:
        // - Lines with name ending in a number (with or without space): "Name 0.48" or "Name0.48"
        // - Lines that are just a number (price): "3.5206"
        let justNumberPattern = #"^\d+\.?\d*$"#
        var hasNameVolumeLine = false
        var hasJustPriceLine = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip header lines
            let lower = trimmed.lowercased()
            if lower.contains("counterparty") || lower.contains("volume") || lower.contains("c/kwh") || lower.contains("(kwh)") {
                continue
            }
            // Check for name ending in number (with optional space before number)
            // Pattern: text followed by optional space, then a decimal number at end
            if trimmed.range(of: #"[A-Za-z].*\s*\d+\.?\d*$"#, options: .regularExpression) != nil {
                hasNameVolumeLine = true
            }
            // Check for line that's just a number (price)
            if trimmed.range(of: justNumberPattern, options: .regularExpression) != nil {
                hasJustPriceLine = true
            }
        }

        if hasNameVolumeLine && hasJustPriceLine {
            return .concatenated
        }

        return .unknown
    }

    /// Parse concatenated format where name+volume are stuck together and price is on next line
    /// Direction is determined by price threshold: < threshold = Buy, >= threshold = Sell
    func parseConcatenatedTrades(_ text: String, priceThreshold: Double) -> [P2PMobileTradeRow] {
        var trades: [P2PMobileTradeRow] = []

        let lines = text.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            // Skip empty lines and header lines
            if line.isEmpty ||
               line.lowercased().contains("counterparty") ||
               line.lowercased().contains("volume") ||
               line.lowercased().contains("c/kwh") ||
               line.lowercased().contains("(kwh)") {
                i += 1
                continue
            }

            // Try to parse as name+volume line (text ending in a number)
            // Pattern handles both: "Some Name Here0.39" and "Name With Spaces 0.48"
            // Use greedy match for name, then optional whitespace, then number at end
            let nameVolumePattern = #"^(.+?)\s*(\d+\.?\d*)$"#
            if let regex = try? NSRegularExpression(pattern: nameVolumePattern, options: []),
               let match = regex.firstMatch(in: line, options: [], range: NSRange(location: 0, length: line.utf16.count)) {

                let nameRange = Range(match.range(at: 1), in: line)!
                let volumeRange = Range(match.range(at: 2), in: line)!

                var name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
                let volumeStr = String(line[volumeRange])

                // Clean up name - remove trailing numbers that might be part of the name accidentally captured
                // But keep valid business name suffixes like "24/7" or "365"
                name = name.trimmingCharacters(in: .whitespaces)

                guard let volume = Double(volumeStr), !name.isEmpty else {
                    i += 1
                    continue
                }

                // Look for price on subsequent lines (skip empty lines)
                var priceFound = false
                var j = i + 1
                while j < lines.count && j < i + 5 {  // Look up to 4 lines ahead
                    let priceLine = lines[j].trimmingCharacters(in: .whitespaces)
                    if priceLine.isEmpty {
                        j += 1
                        continue
                    }

                    // Check if this line is just a number (the price)
                    if let price = Double(priceLine), price > 0 {
                        // Determine direction based on threshold
                        let direction: P2PTradeDirection = price < priceThreshold ? .buy : .sell

                        // Only add if volume > 0
                        if volume > 0 {
                            trades.append(P2PMobileTradeRow(
                                counterparty: name,
                                volumeKwh: volume,
                                priceCents: price,
                                direction: direction
                            ))
                        }
                        priceFound = true
                        i = j + 1  // Continue after the price line
                        break
                    } else {
                        // This line isn't a price, might be next name+volume
                        break
                    }
                }

                if !priceFound {
                    i += 1
                }
            } else {
                i += 1
            }
        }

        return trades
    }

    /// Analyze prices in the text and find an optimal threshold (gap between buy and sell prices)
    func findOptimalThreshold(_ text: String) -> Double {
        var prices: [Double] = []

        // Extract all standalone numbers that look like prices (0-100 range)
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let price = Double(trimmed), price > 0, price < 100 {
                prices.append(price)
            }
        }

        guard prices.count >= 2 else { return 12.0 }  // Default

        // Sort prices and find the largest gap
        let sorted = prices.sorted()
        var maxGap: Double = 0
        var gapMidpoint: Double = 12.0

        for i in 0..<(sorted.count - 1) {
            let gap = sorted[i + 1] - sorted[i]
            if gap > maxGap {
                maxGap = gap
                gapMidpoint = (sorted[i] + sorted[i + 1]) / 2
            }
        }

        // Only use the detected gap if it's significant (> 5¢)
        if maxGap > 5 {
            return gapMidpoint
        }

        return 12.0  // Default fallback
    }
}

// MARK: - View

struct P2PTradeImportView: View {
    @EnvironmentObject var api: PowstonAPI
    @Environment(\.dismiss) var dismiss
    @StateObject private var lvService = LocalVoltsService.shared

    @State private var pastedText: String = ""
    @State private var mobileSummary: P2PMobileSummary?
    @State private var parseError: String?
    @State private var isProcessing = false
    @State private var selectedStartDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var selectedEndDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var savedRecord: P2PTradeRecord?
    @State private var overlappingRecords: [P2PTradeRecord] = []
    @State private var linkedContracts: [P2PContract] = []  // Can have both sell and buy contracts

    // LocalVolts sync state
    @State private var isLVSyncing = false
    @State private var lvSyncError: String?
    @State private var lvSyncSuccess: String?

    // Selected date P2P data
    @State private var selectedDateSellKwh: Double = 0
    @State private var selectedDateSellRevenue: Double = 0
    @State private var selectedDateBuyKwh: Double = 0
    @State private var selectedDateBuyCost: Double = 0

    // Calendar state - separate buy/sell tracking with provisional status
    @State private var sellDates: Set<Date> = []
    @State private var buyDates: Set<Date> = []
    @State private var sellProvisionalDates: Set<Date> = []
    @State private var buyProvisionalDates: Set<Date> = []
    @State private var lvSyncedDates: Set<Date> = []  // Dates synced from LocalVolts API
    @State private var contractDates: Set<Date> = []
    @State private var existingRecordsInRange: [P2PTradeRecord] = []
    @State private var displayedMonth: Date = Date()
    @State private var showDeleteConfirmation = false
    @State private var recordToDelete: P2PTradeRecord?
    @State private var showDeleteLVConfirmation = false  // Confirm delete LV trades for date
    @State private var dateToDeleteLV: Date?  // Date to delete LV trades for
    @State private var isProvisional = false  // Mark as forecast/estimate data
    @State private var dailyExportKwh: [Date: Double] = [:]  // Daily export values for calendar display
    @State private var provisionalRecordsNeedingUpdate: [P2PTradeRecord] = []  // Records with actual data now available
    @State private var scrollToPasteInput: Bool = false  // Trigger scroll to paste input
    @State private var isSelectingRangeEnd = false  // For two-tap range selection

    // Concatenated format handling (when iOS doesn't preserve tabs)
    @State private var usedConcatenatedFormat = false
    @State private var priceThreshold: Double = 12.0  // Default threshold: < 12¢ = Buy, >= 12¢ = Sell

    // Instructions expansion state (persisted)
    @AppStorage("p2p_import_instructions_expanded") private var instructionsExpanded = true

    private let parser = P2PTradeParser()

    private var hasResults: Bool {
        mobileSummary != nil
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    VStack(spacing: 20) {
                        // Provisional data update reminder
                        if !provisionalRecordsNeedingUpdate.isEmpty {
                            provisionalDataReminderBanner
                        }

                        dateRangePicker

                        instructionsCard
                        pasteInputCard
                            .id("pasteInputCard")

                        if isProcessing {
                            ProgressView("Processing...")
                                .padding()
                        } else if let error = parseError {
                            errorCard(error)
                        } else if let summary = mobileSummary {
                            mobileResultsView(summary)
                                .id("resultsSection")
                        }
                    }
                    .padding()
                }
                .onChange(of: mobileSummary != nil) { oldValue, newValue in
                    if newValue {
                        withAnimation {
                            scrollProxy.scrollTo("resultsSection", anchor: .top)
                        }
                    }
                }
                .onChange(of: savedRecord != nil) { oldValue, newValue in
                    if newValue {
                        withAnimation {
                            scrollProxy.scrollTo("doneButton", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: scrollToPasteInput) { oldValue, newValue in
                    if newValue {
                        withAnimation {
                            scrollProxy.scrollTo("pasteInputCard", anchor: .top)
                        }
                        // Reset the trigger
                        scrollToPasteInput = false
                    }
                }
            }
            .navigationTitle("Import P2P Trades")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // Refresh data availability before loading dates
                await api.refreshLatestCompleteDataDate()
                loadImportedDates()
            }
            .alert("Delete Import?", isPresented: $showDeleteConfirmation, presenting: recordToDelete) { record in
                Button("Cancel", role: .cancel) {
                    recordToDelete = nil
                }
                Button("Delete", role: .destructive) {
                    deleteRecord(record)
                }
            } message: { record in
                Text("Delete P2P import for \(formatDateRange(record.startDate, record.endDate))? This will also remove associated counterparty data.")
            }
            .alert("Delete LV Trades?", isPresented: $showDeleteLVConfirmation, presenting: dateToDeleteLV) { date in
                Button("Cancel", role: .cancel) {
                    dateToDeleteLV = nil
                }
                Button("Delete", role: .destructive) {
                    if let siteId = api.selectedSiteId {
                        let deleted = PowstonDataStore.shared.deleteLVTrades(siteId: siteId, for: date)
                        if deleted > 0 {
                            loadImportedDates()  // Refresh calendar
                        }
                    }
                    dateToDeleteLV = nil
                }
            } message: { date in
                Text("Delete all LocalVolts trades for \(formatDate(date))?")
            }
        }
    }

    // MARK: - Data Loading

    private func loadImportedDates() {
        guard let siteId = api.selectedSiteId else { return }
        let datesByDirection = PowstonDataStore.shared.getP2PImportedDatesByDirection(siteId: siteId)
        sellDates = datesByDirection.sell
        buyDates = datesByDirection.buy
        sellProvisionalDates = datesByDirection.sellProvisional
        buyProvisionalDates = datesByDirection.buyProvisional
        lvSyncedDates = datesByDirection.lvSyncedDates
        contractDates = PowstonDataStore.shared.getP2PContractDates(siteId: siteId)
        updateExistingRecordsInRange()
        loadDailyExports()

        // Check for provisional records that now have finalized data available
        if let latestCompleteDate = api.latestCompleteDataDate {
            provisionalRecordsNeedingUpdate = PowstonDataStore.shared.getProvisionalRecordsNeedingUpdate(
                siteId: siteId,
                latestCompleteDataDate: latestCompleteDate
            )
        } else {
            provisionalRecordsNeedingUpdate = []
        }
    }

    // MARK: - LocalVolts Sync

    private func syncSelectedDatesFromLV() {
        guard let siteId = api.selectedSiteId else { return }

        isLVSyncing = true
        lvSyncError = nil
        lvSyncSuccess = nil

        Task {
            do {
                // Sync the selected date range
                var calendar = Calendar.current
                calendar.timeZone = TimeZone(identifier: "Australia/Brisbane") ?? .current
                let startOfDay = calendar.startOfDay(for: selectedStartDate)
                let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: selectedEndDate))!.addingTimeInterval(-1)

                let trades = try await lvService.fetchTrades(siteId: siteId, from: startOfDay, to: endOfDay)

                await MainActor.run {
                    isLVSyncing = false
                    if trades.isEmpty {
                        lvSyncError = "No P2P trades found for selected dates"
                    } else {
                        lvSyncSuccess = "Synced \(trades.count) trades from LocalVolts"
                        loadImportedDates()  // Refresh calendar
                    }

                    // Clear success message after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        lvSyncSuccess = nil
                    }
                }
            } catch {
                await MainActor.run {
                    isLVSyncing = false
                    lvSyncError = error.localizedDescription
                }
            }
        }
    }

    private func loadDailyExports() {
        guard let siteId = api.selectedSiteId else { return }

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        // Get range for displayed month + buffer
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: displayedMonth)),
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) else { return }

        // Get meter records for this range
        let records = PowstonDataStore.shared.getMeterRecordsLocal(siteId: siteId, from: monthStart, to: monthEnd)

        // Aggregate exports by day
        var exports: [Date: Double] = [:]
        for record in records {
            let dayStart = calendar.startOfDay(for: record.intervalTime)
            let exportKwh = record.energyExport ?? 0
            exports[dayStart, default: 0] += exportKwh
        }

        dailyExportKwh = exports
    }

    private func updateExistingRecordsInRange() {
        guard let siteId = api.selectedSiteId else {
            existingRecordsInRange = []
            return
        }

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        let normalizedStart = calendar.startOfDay(for: selectedStartDate)
        let normalizedEnd = calendar.startOfDay(for: selectedEndDate)

        existingRecordsInRange = PowstonDataStore.shared.getOverlappingP2PRecords(
            siteId: siteId,
            start: normalizedStart,
            end: normalizedEnd
        )
    }

    private func deleteRecord(_ record: P2PTradeRecord) {
        // Delete counterparty trades first
        let _ = PowstonDataStore.shared.deleteP2PCounterpartyTrades(forTradeRecord: record.id)
        // Then delete the trade record
        let _ = PowstonDataStore.shared.deleteP2PTradeRecord(record)
        // Refresh the calendar
        loadImportedDates()
        recordToDelete = nil
        // Notify other views that P2P data changed
        NotificationCenter.default.post(name: .p2pDataDidChange, object: nil)
    }

    // MARK: - Provisional Data Reminder Banner

    private var provisionalDataReminderBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Update Available")
                    .font(.headline)
                Spacer()
            }

            // Group records by date range (same date range may have both buy and sell)
            let groupedByDateRange = groupRecordsByDateRange(provisionalRecordsNeedingUpdate)
            // Count days from grouped ranges to avoid double-counting when both buy & sell exist
            let daysCount = groupedByDateRange.reduce(0) { $0 + $1.dayCount }
            Text("\(daysCount) day\(daysCount == 1 ? "" : "s") of P2P data have estimated values that can now be updated with actual data from LocalVolts.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            ForEach(groupedByDateRange, id: \.dateKey) { group in
                HStack {
                    Text(formatDateRange(group.startDate, group.endDate))
                        .font(.caption)
                    Spacer()
                    // Show direction: Buy, Sell, or Buy & Sell
                    Text(group.directionLabel)
                        .font(.caption)
                        .foregroundColor(group.directionColor)
                    Button {
                        // Select this date range for update
                        selectedStartDate = group.startDate
                        selectedEndDate = group.endDate
                        isProvisional = false  // This will be actual data
                        // Clear any existing results
                        mobileSummary = nil
                        parseError = nil
                        pastedText = ""
                        // Trigger scroll to paste input
                        scrollToPasteInput = true
                    } label: {
                        Text("Update")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(12)
    }

    /// Groups provisional records by date range, combining buy and sell for same dates
    private func groupRecordsByDateRange(_ records: [P2PTradeRecord]) -> [DateRangeGroup] {
        var groups: [String: DateRangeGroup] = [:]

        for record in records {
            let key = "\(record.startDate.timeIntervalSince1970)-\(record.endDate.timeIntervalSince1970)"
            if var existing = groups[key] {
                // Add this direction to existing group
                if record.direction == .sell {
                    existing.hasSell = true
                } else {
                    existing.hasBuy = true
                }
                groups[key] = existing
            } else {
                // Create new group
                groups[key] = DateRangeGroup(
                    dateKey: key,
                    startDate: record.startDate,
                    endDate: record.endDate,
                    hasSell: record.direction == .sell,
                    hasBuy: record.direction == .buy
                )
            }
        }

        return groups.values.sorted { $0.startDate < $1.startDate }
    }

    private struct DateRangeGroup {
        let dateKey: String
        let startDate: Date
        let endDate: Date
        var hasSell: Bool
        var hasBuy: Bool

        var directionLabel: String {
            if hasSell && hasBuy { return "Buy & Sell" }
            if hasSell { return "Sell" }
            return "Buy"
        }

        var directionColor: Color {
            if hasSell && hasBuy { return .purple }
            if hasSell { return .green }
            return .blue
        }

        var dayCount: Int {
            let calendar = Calendar.current
            let days = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0
            return days + 1  // Include both start and end dates
        }
    }


    // MARK: - Date Range Picker with Calendar

    private var dateRangePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "calendar")
                    .foregroundColor(.orange)
                Text("Select Date")
                    .font(.headline)
                Spacer()
                Text(formatDateRange(selectedStartDate, selectedEndDate))
                    .font(.subheadline)
                    .foregroundColor(.orange)
                    .fontWeight(.semibold)
            }

            // Month navigation
            HStack {
                Button(action: previousMonth) {
                    Image(systemName: "chevron.left")
                        .font(.title3)
                        .foregroundColor(.primary)
                }

                Spacer()

                Text(monthYearString(displayedMonth))
                    .font(.headline)

                Spacer()

                Button(action: nextMonth) {
                    Image(systemName: "chevron.right")
                        .font(.title3)
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 4)

            // Day of week headers (respects locale)
            HStack(spacing: 0) {
                ForEach(localizedWeekdaySymbols(), id: \.self) { day in
                    Text(day)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }

            // Calendar grid
            let days = calendarDays(for: displayedMonth)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { day in
                    calendarDayView(day)
                }
            }

            // Selected range display
            HStack {
                if Calendar.current.isDate(selectedStartDate, inSameDayAs: selectedEndDate) {
                    Text("Selected: \(formatShortDate(selectedStartDate))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if isSelectingRangeEnd {
                        Text("(tap another day for range)")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                } else {
                    let days = Calendar.current.dateComponents([.day], from: selectedStartDate, to: selectedEndDate).day ?? 0
                    Text("Selected: \(formatShortDate(selectedStartDate)) - \(formatShortDate(selectedEndDate)) (\(days + 1) days)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Quick range buttons
            HStack(spacing: 8) {
                quickRangeButton("7 days", days: 7)
                quickRangeButton("14 days", days: 14)
                quickRangeButton("30 days", days: 30)
                quickRangeButton("This month", days: nil)
            }
            .padding(.vertical, 4)

            // LocalVolts sync button (if credentials configured)
            if lvService.hasCredentials {
                VStack(spacing: 8) {
                    if isLVSyncing {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Syncing from LocalVolts...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button(action: syncSelectedDatesFromLV) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption)
                                Text("Sync from LocalVolts")
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundColor(.green)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(8)
                        }
                    }

                    if let error = lvSyncError {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                    }

                    if let success = lvSyncSuccess {
                        Text(success)
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }

            // Selected date P2P data summary
            if selectedDateSellKwh > 0 || selectedDateBuyKwh > 0 {
                VStack(spacing: 6) {
                    Divider()

                    HStack(spacing: 20) {
                        if selectedDateSellKwh > 0 {
                            VStack(spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.up")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.orange)
                                    Text("Sold")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(String(format: "%.2f kWh", selectedDateSellKwh))
                                    .font(.caption.weight(.medium))
                                Text(String(format: "$%.2f", selectedDateSellRevenue))
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }

                        if selectedDateBuyKwh > 0 {
                            VStack(spacing: 2) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.blue)
                                    Text("Bought")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Text(String(format: "%.2f kWh", selectedDateBuyKwh))
                                    .font(.caption.weight(.medium))
                                Text(String(format: "$%.2f", selectedDateBuyCost))
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                    }

                    Divider()
                }
            }

            // Legend - two rows for clarity
            VStack(spacing: 6) {
                HStack(spacing: 16) {
                    // Sell indicator
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.orange)
                        Text("Sell")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    // Buy indicator
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.blue)
                        Text("Buy")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    // Forecast (yellow)
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.yellow)
                        Text("Forecast")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 16) {
                    // LV synced (green)
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.green.opacity(0.12))
                            .frame(width: 16, height: 16)
                        Text("LV API")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    // Future LV (gold)
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.yellow.opacity(0.15))
                            .frame(width: 16, height: 16)
                        Text("Future")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    // Contract background
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.purple.opacity(0.15))
                            .frame(width: 16, height: 16)
                        Text("Contract")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 16) {
                    // Selected background
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.orange.opacity(0.3))
                            .frame(width: 16, height: 16)
                        Text("Selected")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    // Long-press hint
                    HStack(spacing: 4) {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Text("Hold to delete")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Existing records in selected range
            if !existingRecordsInRange.isEmpty {
                existingRecordsSection
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private var existingRecordsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            HStack {
                Image(systemName: "doc.fill")
                    .foregroundColor(.cyan)
                Text("Existing imports for \(formatDateRange(selectedStartDate, selectedEndDate)):")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            ForEach(existingRecordsInRange) { record in
                HStack {
                    // Direction indicator
                    Image(systemName: record.direction == .sell ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                        .foregroundColor(record.direction == .sell ? .orange : .blue)
                        .font(.caption)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(record.direction == .sell ? "Sell" : "Buy")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(record.direction == .sell ? .orange : .blue)
                            Text(formatDateRange(record.startDate, record.endDate))
                                .font(.caption)
                                .fontWeight(.medium)
                            if record.isProvisional {
                                Text("(Forecast)")
                                    .font(.caption2)
                                    .foregroundColor(.yellow)
                            }
                        }
                        Text("\(String(format: "%.1f", record.p2pKwh)) kWh • \(formatCurrency(record.p2pRevenue))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Button(action: {
                        recordToDelete = record
                        showDeleteConfirmation = true
                    }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(record.isProvisional ? Color.orange.opacity(0.1) : Color(.tertiarySystemBackground))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Calendar Helpers

    @ViewBuilder
    private func calendarDayView(_ day: Date?) -> some View {
        if let day = day {
            let calendar = Calendar.current
            let dayStart = calendar.startOfDay(for: day)
            let isSelected = isDateInSelectedRange(day)
            let hasSellData = sellDates.contains(dayStart)
            let hasBuyData = buyDates.contains(dayStart)
            let isSellProvisional = sellProvisionalDates.contains(dayStart)
            let isBuyProvisional = buyProvisionalDates.contains(dayStart)
            let hasLVData = lvSyncedDates.contains(dayStart)
            let hasContract = contractDates.contains(dayStart)
            let isToday = calendar.isDateInToday(day)
            let isFuture = day > Date()

            Button(action: {
                handleDayTap(day)
            }) {
                ZStack {
                    // Background for contract dates (lowest layer)
                    if hasContract {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.purple.opacity(0.15))
                    }

                    // Background for LV synced dates (green for past, gold for future)
                    if hasLVData {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isFuture ? Color.yellow.opacity(0.15) : Color.green.opacity(0.12))
                    }

                    // Background for selected dates (overlays others)
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.orange.opacity(0.3))
                    }

                    // Today indicator
                    if isToday {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.orange, lineWidth: 1)
                    }

                    VStack(spacing: 1) {
                        Text("\(calendar.component(.day, from: day))")
                            .font(.system(.callout, design: .rounded))
                            .fontWeight(isToday ? .bold : .regular)
                            .foregroundColor(isFuture ? .secondary.opacity(0.5) : .primary)

                        // P2P direction indicators
                        // Export (sell) = orange ↑ (yellow if provisional, green if from LV API, gold if future LV)
                        // Import (buy) = blue ↓ (yellow if provisional, green if from LV API, gold if future LV)
                        HStack(spacing: 1) {
                            let sellColor: Color = hasSellData
                                ? (isSellProvisional ? .yellow : (hasLVData ? (isFuture ? .yellow : .green) : .orange))
                                : .secondary.opacity(0.25)
                            let buyColor: Color = hasBuyData
                                ? (isBuyProvisional ? .yellow : (hasLVData ? (isFuture ? .yellow : .green) : .blue))
                                : .secondary.opacity(0.25)
                            Image(systemName: "arrow.up")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(sellColor)
                            Image(systemName: "arrow.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(buyColor)
                        }
                    }
                }
                .frame(height: 44)
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        // Long press to delete LV trades for this date
                        if hasLVData {
                            dateToDeleteLV = dayStart
                            showDeleteLVConfirmation = true
                        }
                    }
            )
            // Allow future days for forecast data entry
        } else {
            // Empty cell for padding
            Color.clear
                .frame(height: 44)
        }
    }

    private func isDateInSelectedRange(_ date: Date) -> Bool {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let dayStart = calendar.startOfDay(for: date)
        let rangeStart = calendar.startOfDay(for: selectedStartDate)
        let rangeEnd = calendar.startOfDay(for: selectedEndDate)
        return dayStart >= rangeStart && dayStart <= rangeEnd
    }

    private func handleDayTap(_ day: Date) {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let dayStart = calendar.startOfDay(for: day)

        // Range selection: first tap sets start, second tap sets end (or resets if same day)
        if isSelectingRangeEnd && dayStart != selectedStartDate {
            // Second tap - set end date (ensure start < end)
            if dayStart < selectedStartDate {
                selectedEndDate = selectedStartDate
                selectedStartDate = dayStart
            } else {
                selectedEndDate = dayStart
            }
            isSelectingRangeEnd = false
        } else {
            // First tap - set start date, prepare for range selection
            selectedStartDate = dayStart
            selectedEndDate = dayStart
            isSelectingRangeEnd = true
        }

        // Auto-enable provisional toggle for today or future dates (incomplete data)
        let today = calendar.startOfDay(for: Date())
        isProvisional = selectedEndDate >= today

        updateExistingRecordsInRange()
        loadSelectedDateP2PData()
    }

    private func quickRangeButton(_ label: String, days: Int?) -> some View {
        Button(action: {
            var calendar = Calendar.current
            calendar.timeZone = powstonTimezone()
            let today = calendar.startOfDay(for: Date())

            if let days = days {
                // N days ending yesterday (avoid today's incomplete data)
                let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
                let startDate = calendar.date(byAdding: .day, value: -(days - 1), to: yesterday)!
                selectedStartDate = startDate
                selectedEndDate = yesterday
            } else {
                // "This month" - from 1st to yesterday
                let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!
                let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
                selectedStartDate = monthStart
                selectedEndDate = max(monthStart, yesterday)
            }
            isSelectingRangeEnd = false
            updateExistingRecordsInRange()
            loadSelectedDateP2PData()
        }) {
            Text(label)
                .font(.caption2)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func loadSelectedDateP2PData() {
        guard let siteId = api.selectedSiteId else {
            selectedDateSellKwh = 0
            selectedDateSellRevenue = 0
            selectedDateBuyKwh = 0
            selectedDateBuyCost = 0
            return
        }

        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        let rangeStart = calendar.startOfDay(for: selectedStartDate)
        let rangeEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: selectedEndDate))!.addingTimeInterval(-1)

        // Get all trades for the selected range (from both CSV and LV)
        let trades = PowstonDataStore.shared.getP2PCounterpartyTrades(siteId: siteId, from: rangeStart, to: rangeEnd)

        // Aggregate by direction
        var sellKwh: Double = 0
        var sellRevenue: Double = 0
        var buyKwh: Double = 0
        var buyCost: Double = 0

        for trade in trades {
            if trade.direction == .sell {
                sellKwh += trade.volumeKwh
                sellRevenue += trade.revenue
            } else {
                buyKwh += trade.volumeKwh
                buyCost += trade.revenue
            }
        }

        selectedDateSellKwh = sellKwh
        selectedDateSellRevenue = sellRevenue
        selectedDateBuyKwh = buyKwh
        selectedDateBuyCost = buyCost
    }

    private func calendarDays(for month: Date) -> [Date?] {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        // Use locale's first weekday preference (Sunday=1, Monday=2, etc.)

        guard let monthInterval = calendar.dateInterval(of: .month, for: month),
              let monthFirstWeek = calendar.dateInterval(of: .weekOfMonth, for: monthInterval.start) else {
            return []
        }

        var days: [Date?] = []
        var currentDate = monthFirstWeek.start

        // Build 6 weeks of days (42 cells max)
        for _ in 0..<42 {
            if calendar.isDate(currentDate, equalTo: month, toGranularity: .month) {
                days.append(currentDate)
            } else if days.isEmpty || (days.last != nil) {
                // Add nil for padding at start, or continue adding if we're still in valid range
                if calendar.compare(currentDate, to: monthInterval.start, toGranularity: .day) == .orderedAscending {
                    days.append(nil)
                } else if calendar.compare(currentDate, to: monthInterval.end, toGranularity: .day) == .orderedDescending {
                    // We've passed the end of the month
                    if days.count % 7 != 0 {
                        days.append(nil)
                    } else {
                        break
                    }
                }
            }
            currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate) ?? currentDate
        }

        // Ensure we complete the last week
        while days.count % 7 != 0 {
            days.append(nil)
        }

        return days
    }

    /// Returns localized single-letter weekday symbols starting from the user's locale first weekday
    private func localizedWeekdaySymbols() -> [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortWeekdaySymbols  // ["S", "M", "T", "W", "T", "F", "S"] for en_US

        // Reorder based on firstWeekday (1=Sunday, 2=Monday, etc.)
        let firstWeekday = calendar.firstWeekday
        let reordered = Array(symbols[(firstWeekday - 1)...]) + Array(symbols[..<(firstWeekday - 1)])
        return reordered
    }

    private func previousMonth() {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        displayedMonth = calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
        loadDailyExports()
    }

    private func nextMonth() {
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()
        displayedMonth = calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
        loadDailyExports()
    }

    private func monthYearString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }

    private func formatShortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }
    
    // MARK: - Instructions
    
    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Link to LocalVolts - always visible
            Link(destination: URL(string: "https://market.localvolts.com/dashboard.html#/dashboard")!) {
                HStack {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.blue)
                    Text("Open LocalVolts Dashboard")
                        .fontWeight(.medium)
                    Spacer()
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }

            // Expandable instructions
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    instructionsExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: instructionsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    Text("How to import")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if instructionsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    instructionRow(number: 1, text: "Navigate to **My Trades** tab")
                    instructionRow(number: 2, text: "Select a single date")
                    instructionRow(number: 3, text: "Long-press on **Counterparty**")
                    instructionRow(number: 4, text: "Drag selection handle to bottom-right of last price")
                    instructionRow(number: 5, text: "Tap **Copy**, return here, tap below to paste")

                    // AEST timezone note
                    HStack(spacing: 6) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.caption2)
                        Text("LocalVolts uses AEST year-round (no daylight saving)")
                            .font(.caption)
                    }
                    .foregroundColor(.orange)
                    .padding(.top, 4)
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.leading, 20)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .fontWeight(.medium)
                .frame(width: 20)
            Text(LocalizedStringKey(text))  // Enables markdown rendering
        }
    }
    
    // MARK: - Paste Input
    
    private var pasteInputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "rectangle.and.pencil.and.ellipsis")
                    .foregroundColor(.purple)
                Text("Paste Trade Data")
                    .font(.headline)
                Spacer()

                if !pastedText.isEmpty {
                    Button(action: { pastedText = ""; mobileSummary = nil; parseError = nil }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Paste-only view (no keyboard) - entire area is tappable
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.tertiarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(pastedText.isEmpty ? Color.purple.opacity(0.5) : Color.gray.opacity(0.3), lineWidth: pastedText.isEmpty ? 2 : 1)
                    )

                if pastedText.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.largeTitle)
                            .foregroundColor(.purple.opacity(0.6))

                        Text("Tap to Paste")
                            .font(.headline)
                            .foregroundColor(.purple)

                        Text("Copy data from LocalVolts first")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    ScrollView {
                        Text(pastedText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
            }
            .frame(minHeight: 150, maxHeight: 200)
            .contentShape(Rectangle())
            .onTapGesture {
                if pastedText.isEmpty {
                    pasteFromClipboard()
                }
            }
            
            Button(action: processInput) {
                Label("Process Trades", systemImage: "arrow.right.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(hasResults || pastedText.isEmpty ? Color.gray : Color.purple)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .disabled(pastedText.isEmpty || isProcessing || hasResults)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func pasteFromClipboard() {
        if let clipboardString = UIPasteboard.general.string {
            pastedText = clipboardString
        }
    }
    
    // MARK: - Error Card
    
    private func errorCard(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundColor(.orange)
            
            Text("Parse Error")
                .font(.headline)
            
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    // MARK: - Results View
    
    private func mobileResultsView(_ summary: P2PMobileSummary) -> some View {
        VStack(spacing: 16) {
            mobileHeaderCard(summary)

            // Show threshold slider when concatenated format was detected
            if usedConcatenatedFormat {
                thresholdSliderCard(summary)
            }

            mobilePriceBreakdownCard(summary)
            mobileCounterpartyCard(summary)
            mobileSaveCard(summary)
        }
    }

    // MARK: - Threshold Slider Card

    private func thresholdSliderCard(_ summary: P2PMobileSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.orange)
                Text("Price Threshold")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.1f¢", priceThreshold))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
            }

            // Explanation
            Text("Trades below this price are classified as **buys** (cheap solar). Trades above are **sells** (peak demand).")
                .font(.caption)
                .foregroundColor(.secondary)

            // Slider
            HStack {
                Text("5¢")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Slider(value: $priceThreshold, in: 5...25, step: 0.5)
                    .onChange(of: priceThreshold) { _, _ in
                        reparseWithThreshold()
                    }
                Text("25¢")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // Visual indicator of classification
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                    Text("Buy: <\(String(format: "%.1f", priceThreshold))¢")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Sell: ≥\(String(format: "%.1f", priceThreshold))¢")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            // Format notice
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.caption)
                    .foregroundColor(.blue)
                Text("Paste format detected as concatenated. Adjust threshold if buy/sell classification is wrong.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(6)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func mobileSaveCard(_ summary: P2PMobileSummary) -> some View {
        VStack(spacing: 12) {
            if let savedRecord = savedRecord {
                // Show saved confirmation header
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Saved to P2P history")
                        .font(.headline)
                    Spacer()
                }

                Text("Date: \(formatDateRange(savedRecord.startDate, savedRecord.endDate))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Divider()

                // Summary of what was saved
                VStack(alignment: .leading, spacing: 8) {
                    if summary.sellKwh > 0 {
                        HStack {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundColor(.green)
                            Text("Sells:")
                                .font(.caption.bold())
                            Spacer()
                            Text(String(format: "%.1f kWh", summary.sellKwh))
                                .font(.caption)
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(formatCurrency(summary.sellRevenue))
                                .font(.caption.bold())
                                .foregroundColor(.green)
                            Text("•")
                                .foregroundColor(.secondary)
                            Text("\(summary.sellTrades.count) trades")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if summary.buyKwh > 0 {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.blue)
                            Text("Buys:")
                                .font(.caption.bold())
                            Spacer()
                            Text(String(format: "%.1f kWh", summary.buyKwh))
                                .font(.caption)
                            Text("•")
                                .foregroundColor(.secondary)
                            Text(formatCurrency(summary.buyCost))
                                .font(.caption.bold())
                                .foregroundColor(.blue)
                            Text("•")
                                .foregroundColor(.secondary)
                            Text("\(summary.buyTrades.count) trades")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Show linked contracts if found
                if !linkedContracts.isEmpty {
                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "link.circle.fill")
                                .foregroundColor(.purple)
                            Text("Updating \(linkedContracts.count) contract\(linkedContracts.count == 1 ? "" : "s")")
                                .font(.caption.bold())
                                .foregroundColor(.purple)
                        }

                        ForEach(linkedContracts) { contract in
                            HStack(spacing: 6) {
                                Image(systemName: contract.direction == .sell ? "arrow.up.circle" : "arrow.down.circle")
                                    .font(.caption2)
                                    .foregroundColor(contract.direction == .sell ? .green : .blue)
                                Text(contract.direction == .sell ? "Sell" : "Buy")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(contract.dateRangeString)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("•")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text(String(format: "%.0f kWh", contract.totalVolumeKwh))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.leading, 20)
                        }
                    }
                    .padding(8)
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(8)
                }

                // Bidirectional counterparties - negotiation opportunity
                if !summary.bidirectionalCounterparties.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.yellow)
                            Text("Direct Negotiation Opportunity")
                                .font(.caption.bold())
                        }
                        Text("You trade with \(summary.bidirectionalCounterparties.count) counterpart\(summary.bidirectionalCounterparties.count == 1 ? "y" : "ies") in both directions:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(Array(summary.bidirectionalCounterparties).sorted().joined(separator: " • "))
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.yellow.opacity(0.1))
                    .cornerRadius(8)
                }

                // Show counterparty save confirmation
                HStack(spacing: 8) {
                    Image(systemName: "person.2.fill")
                        .foregroundColor(.cyan)
                    Text("\(summary.counterpartyCount) counterparties saved for tracking")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .id("doneButton")

            } else if !overlappingRecords.isEmpty {
                // Show overlap warning
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Overlapping Records")
                        .font(.headline)
                    Spacer()
                }
                
                Text("Data already exists for \(overlappingRecords.count) overlapping date(s). Replace existing data?")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 12) {
                    Button("Cancel") {
                        overlappingRecords = []
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Replace") {
                        saveTradeRecord(replaceOverlaps: true)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                
            } else {
                // Provisional toggle
                Toggle(isOn: $isProvisional) {
                    HStack {
                        Image(systemName: isProvisional ? "clock.badge.questionmark" : "checkmark.seal")
                            .foregroundColor(isProvisional ? .orange : .green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(isProvisional ? "Forecast / Estimate" : "Actual Data")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(isProvisional ? "Can be replaced with actual data later" : "Confirmed trade data from LocalVolts")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .tint(.orange)
                .padding(.vertical, 4)

                // Show save button
                Button(action: { saveTradeRecord(replaceOverlaps: false) }) {
                    Label(isProvisional ? "Save as Forecast" : "Save to P2P History", systemImage: "square.and.arrow.down.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isProvisional ? Color.orange : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }

                Text("Saves to local database and syncs via iCloud")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func saveTradeRecord(replaceOverlaps: Bool) {
        guard let summary = mobileSummary, let siteId = api.selectedSiteId else { return }

        // Normalize dates to AEST day boundaries
        var calendar = Calendar.current
        calendar.timeZone = powstonTimezone()

        let normalizedStart = calendar.startOfDay(for: selectedStartDate)
        let normalizedEnd = calendar.startOfDay(for: selectedEndDate)
            .addingTimeInterval(86400 - 1)  // End of day (23:59:59)

        var allOverlaps: [P2PTradeRecord] = []
        var anySaved = false

        // Save separate records for sell and buy trades
        if !summary.sellTrades.isEmpty {
            let sellRecord = P2PTradeRecord(
                id: UUID(),
                siteId: siteId,
                startDate: normalizedStart,
                endDate: normalizedEnd,
                p2pKwh: summary.sellKwh,
                p2pRevenue: summary.sellRevenue,
                counterpartyCount: Set(summary.sellTrades.map { $0.counterparty }).count,
                importedAt: Date(),
                source: "mobile",
                isProvisional: isProvisional,
                direction: .sell
            )

            let sellResult = PowstonDataStore.shared.saveP2PTradeRecord(sellRecord, replaceOverlaps: replaceOverlaps)

            if sellResult.success {
                anySaved = true
                savedRecord = sellRecord

                // Save sell counterparty trades
                let sellCounterpartyTrades = summary.sellTrades.map { trade in
                    P2PCounterpartyTrade(
                        id: UUID(),
                        tradeRecordId: sellRecord.id,
                        siteId: siteId,
                        counterpartyName: trade.counterparty,
                        volumeKwh: trade.volumeKwh,
                        priceCents: trade.priceCents,
                        tradeDate: normalizedStart,
                        importedAt: Date(),
                        direction: .sell,
                        facility: nil
                    )
                }
                let _ = PowstonDataStore.shared.saveP2PCounterpartyTrades(
                    sellCounterpartyTrades,
                    forTradeRecord: sellRecord.id
                )
            } else {
                allOverlaps.append(contentsOf: sellResult.overlaps)
            }
        }

        if !summary.buyTrades.isEmpty {
            let buyRecord = P2PTradeRecord(
                id: UUID(),
                siteId: siteId,
                startDate: normalizedStart,
                endDate: normalizedEnd,
                p2pKwh: summary.buyKwh,
                p2pRevenue: summary.buyCost,
                counterpartyCount: Set(summary.buyTrades.map { $0.counterparty }).count,
                importedAt: Date(),
                source: "mobile",
                isProvisional: isProvisional,
                direction: .buy
            )

            let buyResult = PowstonDataStore.shared.saveP2PTradeRecord(buyRecord, replaceOverlaps: replaceOverlaps)

            if buyResult.success {
                anySaved = true
                if savedRecord == nil {
                    savedRecord = buyRecord
                }

                // Save buy counterparty trades
                let buyCounterpartyTrades = summary.buyTrades.map { trade in
                    P2PCounterpartyTrade(
                        id: UUID(),
                        tradeRecordId: buyRecord.id,
                        siteId: siteId,
                        counterpartyName: trade.counterparty,
                        volumeKwh: trade.volumeKwh,
                        priceCents: trade.priceCents,
                        tradeDate: normalizedStart,
                        importedAt: Date(),
                        direction: .buy,
                        facility: nil
                    )
                }
                let _ = PowstonDataStore.shared.saveP2PCounterpartyTrades(
                    buyCounterpartyTrades,
                    forTradeRecord: buyRecord.id
                )
            } else {
                allOverlaps.append(contentsOf: buyResult.overlaps)
            }
        }

        if anySaved {
            // Clean up any orphaned counterparty trades (e.g., from replaced forecasts)
            let orphansDeleted = PowstonDataStore.shared.cleanupOrphanedCounterpartyTrades(siteId: siteId)
            if orphansDeleted > 0 {
                print("🧹 Cleaned up \(orphansDeleted) orphaned counterparty trades after import")
            }

            // Auto-detect linked contracts by date overlap (both sell and buy)
            let allContracts = PowstonDataStore.shared.getP2PContracts(siteId: siteId)
            var calendar = Calendar.current
            calendar.timeZone = powstonTimezone()

            linkedContracts = allContracts.filter { contract in
                let contractStart = calendar.startOfDay(for: contract.startDate)
                let contractEnd = calendar.startOfDay(for: contract.endDate)
                return contractStart <= normalizedEnd && contractEnd >= normalizedStart
            }

            // Refresh calendar data after successful save
            loadImportedDates()

            // Notify other views that P2P data changed
            NotificationCenter.default.post(name: .p2pDataDidChange, object: nil)
        }

        if !allOverlaps.isEmpty {
            overlappingRecords = allOverlaps
        }
    }
    
    private func formatDateRange(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.timeZone = powstonTimezone()

        if Calendar.current.isDate(start, inSameDayAs: end) {
            return formatter.string(from: start)
        } else {
            return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        formatter.timeZone = powstonTimezone()
        return formatter.string(from: date)
    }

    private func mobileHeaderCard(_ summary: P2PMobileSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
                Text("P2P Trades Summary")
                    .font(.headline)
                Spacer()
            }

            // Trade classification summary
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("\(summary.sellTrades.count) sells")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                    Text("\(summary.buyTrades.count) buys")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(Color(.tertiarySystemBackground))
            .cornerRadius(6)

            Divider()

            // Sell subtotal
            if summary.sellKwh > 0 {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(.green)
                    Text("Sold")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text(String(format: "%.2f kWh", summary.sellKwh))
                        .font(.subheadline)
                    Text("@")
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f¢", summary.sellAvgPrice))
                        .foregroundColor(.green)
                    Text("=")
                        .foregroundColor(.secondary)
                    Text(formatCurrency(summary.sellRevenue))
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                }
            }

            // Buy subtotal
            if summary.buyKwh > 0 {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.orange)
                    Text("Bought")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text(String(format: "%.2f kWh", summary.buyKwh))
                        .font(.subheadline)
                    Text("@")
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f¢", summary.buyAvgPrice))
                        .foregroundColor(.orange)
                    Text("=")
                        .foregroundColor(.secondary)
                    Text(formatCurrency(summary.buyCost))
                        .fontWeight(.semibold)
                        .foregroundColor(.orange)
                }
            }

            // Net (if both buy and sell exist)
            if summary.sellKwh > 0 && summary.buyKwh > 0 {
                Divider()
                HStack {
                    Text("Net")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(formatCurrency(summary.netRevenue))
                        .font(.title3.bold())
                        .foregroundColor(summary.netRevenue >= 0 ? .green : .red)
                }
            } else if summary.sellKwh > 0 {
                // Only sells
                Divider()
                HStack {
                    Text("Total Revenue")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(formatCurrency(summary.sellRevenue))
                        .font(.title3.bold())
                        .foregroundColor(.green)
                }
            } else if summary.buyKwh > 0 {
                // Only buys
                Divider()
                HStack {
                    Text("Total Cost")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(formatCurrency(summary.buyCost))
                        .font(.title3.bold())
                        .foregroundColor(.orange)
                }
            }

            // Counterparty counts
            HStack(spacing: 12) {
                if summary.sellTrades.count > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill")
                            .foregroundColor(.green)
                        Text("\(Set(summary.sellTrades.map { $0.counterparty }).count) buyers")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                if summary.buyTrades.count > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "person.fill")
                            .foregroundColor(.orange)
                        Text("\(Set(summary.buyTrades.map { $0.counterparty }).count) sellers")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.top, 4)

            // Bidirectional counterparties - negotiation opportunity
            if !summary.bidirectionalCounterparties.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundColor(.yellow)
                        Text("Direct Negotiation Opportunity")
                            .font(.caption.bold())
                            .foregroundColor(.primary)
                    }

                    Text("You're buying AND selling with \(summary.bidirectionalCounterparties.count) counterpart\(summary.bidirectionalCounterparties.count == 1 ? "y" : "ies"). Consider reaching out to negotiate a direct P2P arrangement.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // List the counterparties (wrap manually)
                    let names = Array(summary.bidirectionalCounterparties).sorted()
                    Text(names.joined(separator: " • "))
                        .font(.caption2.bold())
                        .foregroundColor(.primary)
                }
                .padding(10)
                .background(Color.yellow.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func mobilePriceBreakdownCard(_ summary: P2PMobileSummary) -> some View {
        let sortedPrices = summary.byPricePoint.keys.sorted(by: >)
        
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.purple)
                Text("By Price Point")
                    .font(.headline)
                Spacer()
            }
            
            Divider()
            
            // Header
            HStack {
                Text("Price")
                    .frame(width: 60, alignment: .leading)
                Text("Trades")
                    .frame(width: 50, alignment: .trailing)
                Text("kWh")
                    .frame(width: 60, alignment: .trailing)
                Text("Revenue")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
            
            ForEach(sortedPrices, id: \.self) { price in
                if let data = summary.byPricePoint[price] {
                    HStack {
                        Text(String(format: "%.1f¢", price))
                            .frame(width: 60, alignment: .leading)
                            .foregroundColor(price >= 20 ? .green : .orange)
                        Text("\(data.count)")
                            .frame(width: 50, alignment: .trailing)
                        Text(String(format: "%.2f", data.totalKwh))
                            .frame(width: 60, alignment: .trailing)
                        Text(formatCurrency(data.totalRevenue))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .foregroundColor(.green)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
    
    private func mobileCounterpartyCard(_ summary: P2PMobileSummary) -> some View {
        // Sort by volume descending within each direction
        let topBuyers = summary.sellTrades.sorted { $0.volumeKwh > $1.volumeKwh }.prefix(5)
        let topSellers = summary.buyTrades.sorted { $0.volumeKwh > $1.volumeKwh }.prefix(5)

        return VStack(alignment: .leading, spacing: 12) {
            // Buyers (people who bought from us - our sell trades)
            if !summary.sellTrades.isEmpty {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundColor(.green)
                    Text("Top Buyers")
                        .font(.headline)
                    Spacer()
                    Text("\(Set(summary.sellTrades.map { $0.counterparty }).count) total")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(Array(topBuyers)) { trade in
                    counterpartyRow(trade)
                }
            }

            // Sellers (people who sold to us - our buy trades)
            if !summary.buyTrades.isEmpty {
                if !summary.sellTrades.isEmpty {
                    Divider()
                }

                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.orange)
                    Text("Top Sellers")
                        .font(.headline)
                    Spacer()
                    Text("\(Set(summary.buyTrades.map { $0.counterparty }).count) total")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ForEach(Array(topSellers)) { trade in
                    counterpartyRow(trade)
                }
            }

            // Bidirectional counterparties
            if !summary.bidirectionalCounterparties.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right")
                        .foregroundColor(.purple)
                    Text("\(summary.bidirectionalCounterparties.count) trade both ways:")
                        .font(.caption)
                        .foregroundColor(.purple)
                    Text(summary.bidirectionalCounterparties.prefix(3).joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if summary.bidirectionalCounterparties.count > 3 {
                        Text("...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func counterpartyRow(_ trade: P2PMobileTradeRow) -> some View {
        HStack {
            Text(trade.counterparty)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Text(String(format: "%.2f kWh", trade.volumeKwh))
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            Text(String(format: "%.1f¢", trade.priceCents))
                .font(.caption.monospacedDigit())
                .frame(width: 45, alignment: .trailing)
                .foregroundColor(trade.direction == .sell ? .green : .orange)
        }
    }
    
    // MARK: - Processing

    private func processInput() {
        isProcessing = true
        parseError = nil
        mobileSummary = nil

        Task {
            await processMobileData()
            isProcessing = false
        }
    }
    
    @MainActor
    private func processMobileData() async {
        // Detect format first
        let format = parser.detectFormat(pastedText)

        let trades: [P2PMobileTradeRow]

        // Check if data has direction headers (Sell/Buy sections)
        let lower = pastedText.lowercased()
        let hasDirectionHeaders = lower.contains("sell trades") || lower.contains("buy trades") ||
            lower.range(of: #"(?m)^sell\s*$"#, options: .regularExpression) != nil ||
            lower.range(of: #"(?m)^buy\s*$"#, options: .regularExpression) != nil

        // Check for multi-line format (prices on separate lines)
        let lines = pastedText.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let justNumberLines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.range(of: #"^\d+\.?\d*$"#, options: .regularExpression) != nil
        }
        let isMultiLineFormat = justNumberLines.count > lines.count / 4

        // Use threshold mode when: multi-line format AND no explicit direction headers
        let needsThresholdMode = isMultiLineFormat && !hasDirectionHeaders

        switch format {
        case .concatenated:
            // iOS didn't preserve tabs - use concatenated parser with threshold
            usedConcatenatedFormat = true
            // Find optimal threshold based on price gap in the data
            let optimalThreshold = parser.findOptimalThreshold(pastedText)
            priceThreshold = optimalThreshold
            trades = parser.parseConcatenatedTrades(pastedText, priceThreshold: priceThreshold)

        case .tabSeparated, .unknown:
            // Check if we need threshold mode for direction classification
            if needsThresholdMode {
                usedConcatenatedFormat = true  // Show the slider
                let optimalThreshold = parser.findOptimalThreshold(pastedText)
                priceThreshold = optimalThreshold
                trades = parser.parseMobileTrades(pastedText, defaultDirection: .sell, priceThreshold: priceThreshold)
            } else {
                usedConcatenatedFormat = false
                trades = parser.parseMobileTrades(pastedText, defaultDirection: .sell)
            }
        }

        guard !trades.isEmpty else {
            parseError = "No trades found. Make sure you copied the counterparty table including names, volumes, and prices."
            return
        }

        // Summarize trades (direction already set by parser based on column position or threshold)
        mobileSummary = parser.summarizeMobileTrades(trades)
    }

    /// Re-parse with updated threshold (called when slider changes)
    @MainActor
    private func reparseWithThreshold() {
        guard usedConcatenatedFormat else { return }

        // Try concatenated parser first
        var trades = parser.parseConcatenatedTrades(pastedText, priceThreshold: priceThreshold)

        // If that didn't work well, try mobile trades parser with threshold
        if trades.isEmpty {
            trades = parser.parseMobileTrades(pastedText, defaultDirection: .sell, priceThreshold: priceThreshold)
        }

        if !trades.isEmpty {
            mobileSummary = parser.summarizeMobileTrades(trades)
        }
    }
    
    // MARK: - Helpers

    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencySymbol = "$"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
}

// MARK: - Preview

#Preview {
    P2PTradeImportView()
        .environmentObject(PowstonAPI())
}

