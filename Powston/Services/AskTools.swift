//
//  AskTools.swift
//  Powston
//
//  Read-only tools for the "Ask" chat. They mirror the read tools of Powston's
//  MCP server but answer from the app's own API client and local database.
//  None of them change anything on a site.
//
//  Every tool returns plain text with units spelled out. Prices are cents per kWh,
//  money is dollars, energy is kWh, power is kW.
//

import Foundation
import FoundationModels
import os

// MARK: - Tool set

@available(iOS 26.0, *)
enum AskTools {
    /// Everything, for Private Cloud Compute
    static func all(api: PowstonAPI) -> [any Tool] {
        [
            ListSitesTool(api: api),
            SiteSnapshotTool(api: api),
            PriceForecastTool(api: api),
            UpcomingActionsTool(api: api),
            InverterStatusTool(api: api),
            TodaySummaryTool(api: api),
            CommandHistoryTool(api: api),
            DailyHistoryTool(api: api),
            IntervalDetailTool(api: api),
            TariffInfoTool(api: api),
            ROITool(api: api),
            BillToDateTool(api: api)
        ]
    }

    /// A small set for the on-device model, whose context is much smaller
    static func limited(api: PowstonAPI) -> [any Tool] {
        [
            SiteSnapshotTool(api: api),
            PriceForecastTool(api: api),
            TodaySummaryTool(api: api),
            DailyHistoryTool(api: api)
        ]
    }
}

// MARK: - Time limit

nonisolated private let askToolLog = Logger(subsystem: "com.bollar.Powston", category: "Ask")

/// Runs a lookup with a time limit. A slow Powston API call otherwise holds up
/// the whole answer until the model gives up on it.
nonisolated func askLookup(_ tool: String, limit seconds: Double = 15, _ work: @escaping @Sendable () async -> String) async -> String {
    let start = Date()
    let done = OSAllocatedUnfairLock(initialState: false)
    let result: String = await withCheckedContinuation { continuation in
        func finish(_ value: String) {
            let first = done.withLock { claimed -> Bool in
                if claimed { return false }
                claimed = true
                return true
            }
            if first { continuation.resume(returning: value) }
        }
        Task { finish(await work()) }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            finish("TIMED_OUT")
        }
    }
    let elapsed = Date().timeIntervalSince(start)
    if result == "TIMED_OUT" {
        askToolLog.error("\(tool, privacy: .public) timed out after \(elapsed, format: .fixed(precision: 1), privacy: .public)s")
        return "This lookup took too long, so there's no answer from it right now. Tell the user it timed out and suggest asking again in a moment."
    }
    askToolLog.info("\(tool, privacy: .public) took \(elapsed, format: .fixed(precision: 1), privacy: .public)s")
    return result
}

// MARK: - Shared helpers

@MainActor
private enum AskData {
    static let demoNote = "Demo mode: these are sample figures, not a real site."

    /// Resolves an optional site name to a site. Nil name means the selected site.
    static func site(named name: String?, api: PowstonAPI) -> Result<Site, AskToolError> {
        let wanted = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if wanted.isEmpty {
            guard let site = api.selectedSite else { return .failure(.message("No site is selected in the app.")) }
            return .success(site)
        }
        let lower = wanted.lowercased()
        func names(_ site: Site) -> [String] { [site.name.lowercased(), (site.displayName ?? site.name).lowercased()] }
        let exact = api.sites.first { names($0).contains(lower) }
        let partial = api.sites.first { site in names(site).contains { $0.contains(lower) } }
        let match = exact ?? partial
        guard let match else {
            let names = api.sites.map { $0.displayName ?? $0.name }.joined(separator: ", ")
            return .failure(.message("There's no site called \"\(wanted)\". Sites: \(names)."))
        }
        return .success(match)
    }

    /// For tools that only work on the selected site
    static func selectedSiteOnly(_ name: String?, api: PowstonAPI) -> Result<Site, AskToolError> {
        switch site(named: name, api: api) {
        case .failure(let error):
            return .failure(error)
        case .success(let site):
            if site.id != api.selectedSiteId {
                let selected = api.selectedSite.map { $0.displayName ?? $0.name } ?? "another site"
                return .failure(.message("This is only available for the site selected in the app (\(selected)). The user can switch sites on the Dashboard."))
            }
            return .success(site)
        }
    }

    static func name(_ site: Site) -> String { site.displayName ?? site.name }

    static func calendar(for site: Site?) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = powstonTimezone(for: site)
        return calendar
    }

    static func inverterId(for site: Site, api: PowstonAPI) -> Int? {
        site.primaryInverterId ?? api.leadInverter(forSiteId: site.id)?.id
            ?? (site.id == api.selectedSiteId ? api.selectedInverterId : nil)
    }

    static func time(_ date: Date, site: Site?) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = powstonTimezone(for: site)
        return date.formatted(style)
    }

    static func day(_ date: Date, site: Site?) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted).weekday(.abbreviated)
        style.timeZone = powstonTimezone(for: site)
        return date.formatted(style)
    }

    static func cents(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.1f¢/kWh", value)
    }

    static func dollars(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return value < 0 ? String(format: "-$%.2f", -value) : String(format: "$%.2f", value)
    }

    static func kw(_ watts: Double?) -> String {
        guard let watts else { return "unknown" }
        return String(format: "%.1f kW", watts / 1000)
    }

    static func kwh(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.1f kWh", value)
    }
}

enum AskToolError: Error {
    case message(String)
    var text: String {
        switch self { case .message(let text): return text }
    }
}

// MARK: - Sites

@available(iOS 26.0, *)
nonisolated struct ListSitesTool: Tool {
    let api: PowstonAPI
    let name = "list_sites"
    let description = "Lists the user's sites and which one is selected in the app."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let api = api
        return await askLookup(name) { await Self.answer(api: api) }
    }

    @MainActor
    private static func answer(api: PowstonAPI) -> String {
        guard !api.sites.isEmpty else { return "No sites are loaded." }
        var lines = api.sites.map { site in
            var line = "- \(AskData.name(site))"
            if let state = site.state { line += " (\(state))" }
            if let battery = site.installedBattery { line += ", battery \(AskData.kwh(Double(battery) / 1000))" }
            if let solar = site.installedSolar { line += ", solar \(AskData.kw(Double(solar)))" }
            if site.id == api.selectedSiteId { line += " [selected]" }
            return line
        }
        if api.isDemoMode { lines.insert(AskData.demoNote, at: 0) }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Live snapshot

@available(iOS 26.0, *)
nonisolated struct SiteSnapshotTool: Tool {
    let api: PowstonAPI
    let name = "get_site_snapshot"
    let description = "Right now at the selected site: battery charge, solar, house use, grid flow, current buy and sell prices, and what the controller is doing and why."

    @Generable
    struct Arguments {
        @Guide(description: "Site name. Leave empty for the selected site.")
        var site: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let api = api, args = arguments
        return await askLookup(name) { await Self.answer(site: args.site, api: api) }
    }

    @MainActor
    private static func answer(site name: String?, api: PowstonAPI) -> String {
        let site: Site
        switch AskData.selectedSiteOnly(name, api: api) {
        case .failure(let error): return error.text
        case .success(let value): site = value
        }
        guard let data = api.data else { return "No live data has loaded yet for \(AskData.name(site))." }

        var lines: [String] = []
        if api.isDemoMode { lines.append(AskData.demoNote) }
        lines.append("Site: \(AskData.name(site))")
        if let fetched = api.lastFetchTime {
            lines.append("Updated: \(AskData.time(fetched, site: site))")
        }
        if let soc = data.batterySoc {
            var line = String(format: "Battery: %.0f%%", soc)
            if let capacity = data.totalBatteryCapacity { line += " of \(AskData.kwh(Double(capacity) / 1000))" }
            lines.append(line)
        }
        if let battery = data.totalBatteryPower {
            let state = battery < -50 ? "charging" : battery > 50 ? "discharging" : "idle"
            lines.append("Battery power: \(AskData.kw(abs(battery))) \(state)")
        }
        lines.append("Solar: \(AskData.kw(data.totalSolarPower))")
        lines.append("House use: \(AskData.kw(data.totalHousePower))")
        if let grid = data.totalGridPower {
            let direction = grid > 50 ? "exporting" : grid < -50 ? "importing" : "about zero"
            lines.append("Grid: \(AskData.kw(abs(grid))) \(direction)")
        }
        lines.append("Buy price now: \(AskData.cents(data.buyPrice))")
        lines.append("Sell price now: \(AskData.cents(data.sellPrice))")
        if let rrp = data.rrp { lines.append(String(format: "Wholesale price: $%.0f/MWh", rrp)) }
        lines.append("Controller action: \(data.currentAction)")
        if let reason = data.reason, !reason.isEmpty { lines.append("Controller's reason: \(reason)") }
        if let strategy = data.userCodeName, !strategy.isEmpty { lines.append("Strategy: \(strategy)") }
        if let override = api.overrideStatusText { lines.append("Manual override: \(override)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Price forecast

@available(iOS 26.0, *)
nonisolated struct PriceForecastTool: Tool {
    let api: PowstonAPI
    let name = "get_price_forecast"
    let description = "Forecast buy and sell prices for the selected site in 30-minute periods, with the cheapest and most expensive times."

    @Generable
    struct Arguments {
        @Guide(description: "How many hours ahead, from 1 to 24.", .range(1...24))
        var hours: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let api = api, args = arguments
        return await askLookup(name) { await Self.answer(hours: args.hours, api: api) }
    }

    @MainActor
    private static func answer(hours: Int, api: PowstonAPI) -> String {
        guard let data = api.data, let buy = data.buyForecast, !buy.isEmpty else {
            return "No price forecast is loaded."
        }
        let site = api.selectedSite
        let sell = data.sellForecast ?? []
        let now = Date()
        var periods: [(start: Date, buy: Double, sell: Double?)] = []
        for index in buy.indices {
            guard let start = data.absoluteTimeForPeriod(index) else { continue }
            // Skip periods that have already ended
            if start.addingTimeInterval(30 * 60) <= now { continue }
            periods.append((start, buy[index], index < sell.count ? sell[index] : nil))
            if periods.count >= max(1, min(hours, 24)) * 2 { break }
        }
        guard !periods.isEmpty else { return "The loaded forecast doesn't reach past now." }

        var lines: [String] = []
        if api.isDemoMode { lines.append(AskData.demoNote) }
        lines.append("Times are local to \(site.map(AskData.name) ?? "the site"). Prices in cents per kWh.")
        if let cheapest = periods.min(by: { $0.buy < $1.buy }) {
            lines.append("Cheapest to buy: \(AskData.cents(cheapest.buy)) at \(AskData.time(cheapest.start, site: site))")
        }
        if let dearest = periods.max(by: { $0.buy < $1.buy }) {
            lines.append("Most expensive to buy: \(AskData.cents(dearest.buy)) at \(AskData.time(dearest.start, site: site))")
        }
        if let best = periods.filter({ $0.sell != nil }).max(by: { $0.sell! < $1.sell! }) {
            lines.append("Best to sell: \(AskData.cents(best.sell)) at \(AskData.time(best.start, site: site))")
        }
        if periods.contains(where: { $0.buy < 0 }) {
            lines.append("Some periods have negative buy prices (paid to use power).")
        }
        lines.append("Periods (start: buy / sell):")
        for period in periods {
            lines.append("\(AskData.time(period.start, site: site)): \(String(format: "%.1f", period.buy)) / \(period.sell.map { String(format: "%.1f", $0) } ?? "?")")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Upcoming actions

@available(iOS 26.0, *)
nonisolated struct UpcomingActionsTool: Tool {
    let api: PowstonAPI
    let name = "get_upcoming_actions"
    let description = "Manual overrides that are running or scheduled at the selected site, and the controller's current action and strategy. The controller has no fixed plan: it decides every few minutes from prices and the battery."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let api = api
        return await askLookup(name) { await Self.answer(api: api) }
    }

    @MainActor
    private static func answer(api: PowstonAPI) -> String {
        let site = api.selectedSite
        var lines: [String] = []
        if api.isDemoMode { lines.append(AskData.demoNote) }
        if let data = api.data {
            lines.append("Current action: \(data.currentAction)")
            if let strategy = data.userCodeName, !strategy.isEmpty { lines.append("Strategy: \(strategy)") }
        }
        lines.append("The controller picks its action every few minutes from prices and the battery; there is no published schedule beyond manual overrides.")

        func describe(_ action: ManualAction) -> String {
            var line = "- \(action.action)"
            if let start = action.startDate { line += " from \(AskData.time(start, site: site))" }
            if let end = action.endDate { line += " until \(AskData.time(end, site: site))" }
            if let reason = action.reason, !reason.isEmpty { line += " (\(reason))" }
            return line
        }
        if api.currentOverrides.isEmpty && api.scheduledOverrides.isEmpty && api.pendingOverrides.isEmpty {
            lines.append("No manual overrides are running or scheduled.")
        } else {
            if !api.currentOverrides.isEmpty {
                lines.append("Running now:")
                lines += api.currentOverrides.map(describe)
            }
            if !api.scheduledOverrides.isEmpty {
                lines.append("Scheduled:")
                lines += api.scheduledOverrides.map(describe)
            }
            if !api.pendingOverrides.isEmpty {
                lines.append("\(api.pendingOverrides.count) override(s) waiting for the controller to confirm.")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Inverter status

@available(iOS 26.0, *)
nonisolated struct InverterStatusTool: Tool {
    let api: PowstonAPI
    let name = "get_inverter_status"
    let description = "The site's inverters (make, model, battery size) and Powston's check of whether each controller is reporting normally."

    @Generable
    struct Arguments {
        @Guide(description: "Site name. Leave empty for the selected site.")
        var site: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let api = api, args = arguments
        return await askLookup(name) { await Self.answer(site: args.site, api: api) }
    }

    @MainActor
    private static func answer(site name: String?, api: PowstonAPI) async -> String {
        let site: Site
        switch AskData.site(named: name, api: api) {
        case .failure(let error): return error.text
        case .success(let value): site = value
        }
        let inverters = api.inverters.filter { $0.siteId == site.id }
        var lines: [String] = []
        if api.isDemoMode {
            lines.append(AskData.demoNote)
            lines += inverters.map { "- \($0.manufacturer) \($0.productName): reporting normally" }
            return lines.joined(separator: "\n")
        }
        lines.append("Site: \(AskData.name(site))")
        if inverters.isEmpty { lines.append("No inverters are loaded for this site.") }
        for inverter in inverters {
            var line = "- \(inverter.manufacturer) \(inverter.productName)"
            if let capacity = inverter.batteryCapacity { line += ", battery \(AskData.kwh(Double(capacity) / 1000))" }
            if let diagnosis = await api.fetchRuntimeDiagnosis(inverterId: inverter.id) {
                line += ": \(diagnosis.headline ?? diagnosis.verdict)"
                if let steps = diagnosis.nextSteps, !steps.isEmpty {
                    line += ". Suggested: " + steps.joined(separator: "; ")
                }
            } else {
                line += ": status unavailable"
            }
            lines.append(line)
        }
        if let fetched = api.lastFetchTime, site.id == api.selectedSiteId {
            lines.append("Live data last updated \(AskData.time(fetched, site: site)).")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Today

@available(iOS 26.0, *)
nonisolated struct TodaySummaryTool: Tool {
    let api: PowstonAPI
    let name = "get_today_summary"
    let description = "So far today: energy bought and sold, money spent and earned on energy, and battery charge range. An estimate from inverter readings that excludes the daily supply charge."

    @Generable
    struct Arguments {
        @Guide(description: "Site name. Leave empty for the selected site.")
        var site: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let api = api, args = arguments
        return await askLookup(name) { await Self.answer(site: args.site, api: api) }
    }

    @MainActor
    private static func answer(site name: String?, api: PowstonAPI) async -> String {
        if api.isDemoMode {
            return """
            \(AskData.demoNote)
            Today so far (estimate, excludes supply charge): bought 6.2 kWh for $1.05, sold 14.8 kWh for $2.31, net $1.26 ahead. Battery ranged 22% to 96%.
            """
        }
        let site: Site
        switch AskData.site(named: name, api: api) {
        case .failure(let error): return error.text
        case .success(let value): site = value
        }
        guard let inverterId = AskData.inverterId(for: site, api: api) else { return "No inverter found for \(AskData.name(site))." }
        let records = await PowstonDataStore.shared.fetchActionsForDay(siteId: site.id, inverterId: inverterId, date: Date())
        guard !records.isEmpty else { return "No readings are stored for today at \(AskData.name(site)) yet." }

        let bought = records.compactMap(\.energyImport).reduce(0, +)
        let sold = records.compactMap(\.energyExport).reduce(0, +)
        let costs = records.compactMap(\.costs).reduce(0, +) / 100
        let earnings = records.compactMap(\.earnings).reduce(0, +) / 100
        let socs = records.compactMap(\.batterySoc)
        var lines = [
            "Site: \(AskData.name(site)). Today so far, up to \(AskData.time(records.map(\.intervalTime).max() ?? Date(), site: site)). Estimate from inverter readings; excludes the supply charge.",
            "Bought \(AskData.kwh(bought)) for \(AskData.dollars(costs))",
            "Sold \(AskData.kwh(sold)) for \(AskData.dollars(earnings))",
            "Net: \(AskData.dollars(earnings - costs)) (positive means ahead)"
        ]
        if let low = socs.min(), let high = socs.max() {
            lines.append(String(format: "Battery ranged %.0f%% to %.0f%%", low, high))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Command history

@available(iOS 26.0, *)
nonisolated struct CommandHistoryTool: Tool {
    let api: PowstonAPI
    let name = "get_command_history"
    let description = "What the controller did on a given day: each stretch of the same action, with times, average prices and battery charge."

    @Generable
    struct Arguments {
        @Guide(description: "Days ago: 0 is today, 1 is yesterday, up to 14.", .range(0...14))
        var daysAgo: Int
        @Guide(description: "Site name. Leave empty for the selected site.")
        var site: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let api = api, args = arguments
        return await askLookup(name) { await Self.answer(daysAgo: args.daysAgo, site: args.site, api: api) }
    }

    @MainActor
    private static func answer(daysAgo: Int, site name: String?, api: PowstonAPI) async -> String {
        if api.isDemoMode {
            return """
            \(AskData.demoNote)
            - 12:00 AM to 6:30 AM: auto, buy about 11¢, battery 60% to 35%
            - 6:30 AM to 9:30 AM: charge from solar, battery 35% to 70%
            - 9:30 AM to 3:00 PM: export, sell about 16¢, battery 70% to 96%
            - 3:00 PM to 8:30 PM: discharge, sell about 38¢, battery 96% to 30%
            - 8:30 PM to midnight: auto, battery 30% to 26%
            """
        }
        let site: Site
        switch AskData.site(named: name, api: api) {
        case .failure(let error): return error.text
        case .success(let value): site = value
        }
        guard let inverterId = AskData.inverterId(for: site, api: api) else { return "No inverter found for \(AskData.name(site))." }
        let calendar = AskData.calendar(for: site)
        let day = calendar.date(byAdding: .day, value: -max(0, min(daysAgo, 14)), to: Date()) ?? Date()
        let records = await PowstonDataStore.shared.fetchActionsForDay(siteId: site.id, inverterId: inverterId, date: day)
            .sorted { $0.intervalTime < $1.intervalTime }
        guard !records.isEmpty else { return "No controller history is stored for \(AskData.day(day, site: site))." }

        // Collapse 5-minute records into runs of the same action
        var runs: [[ActionRecord]] = []
        for record in records {
            if let last = runs.last?.last, last.action == record.action {
                runs[runs.count - 1].append(record)
            } else {
                runs.append([record])
            }
        }
        var lines = ["\(AskData.name(site)), \(AskData.day(day, site: site)):"]
        for run in runs.prefix(40) {
            guard let first = run.first, let last = run.last else { continue }
            let end = last.intervalTime.addingTimeInterval(5 * 60)
            var line = "- \(AskData.time(first.intervalTime, site: site)) to \(AskData.time(end, site: site)): \(first.action)"
            let buys = run.compactMap(\.buyPrice)
            let sells = run.compactMap(\.sellPrice)
            if !buys.isEmpty { line += String(format: ", buy avg %.1f¢", buys.reduce(0, +) / Double(buys.count)) }
            if !sells.isEmpty { line += String(format: ", sell avg %.1f¢", sells.reduce(0, +) / Double(sells.count)) }
            if let from = first.batterySoc, let to = last.batterySoc {
                line += String(format: ", battery %.0f%% to %.0f%%", from, to)
            }
            lines.append(line)
        }
        if runs.count > 40 { lines.append("(\(runs.count - 40) more changes not shown)") }
        if let reason = runs.last?.last?.reason, !reason.isEmpty {
            lines.append("Last recorded reason: \(reason)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Daily history

@available(iOS 26.0, *)
nonisolated struct DailyHistoryTool: Tool {
    let api: PowstonAPI
    let name = "get_daily_history"
    let description = "Day-by-day results for the selected site for recent complete days: energy bought and sold, costs, earnings and net result. Net includes the supply charge."

    @Generable
    struct Arguments {
        @Guide(description: "How many complete days to include, ending yesterday. From 1 to 31.", .range(1...31))
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let api = api, args = arguments
        return await askLookup(name) { await Self.answer(days: args.days, api: api) }
    }

    @MainActor
    private static func answer(days: Int, api: PowstonAPI) async -> String {
        if api.isDemoMode {
            return """
            \(AskData.demoNote)
            Yesterday: bought 7.4 kWh, sold 21.6 kWh, costs $2.10 (with supply), earnings $5.85, net $3.75 ahead.
            Day before: bought 9.1 kWh, sold 18.2 kWh, costs $2.64, earnings $4.12, net $1.48 ahead.
            """
        }
        guard let site = api.selectedSite else { return "No site is selected in the app." }
        let calendar = AskData.calendar(for: site)
        let today = calendar.startOfDay(for: Date())
        let count = max(1, min(days, 31))
        guard let end = calendar.date(byAdding: .day, value: -1, to: today),
              let start = calendar.date(byAdding: .day, value: -count, to: today) else { return "Couldn't work out the dates." }

        let summaries = await api.fetchDailyBreakdownCumulative(startDate: start, endDate: end)
            .sorted { $0.date < $1.date }
        guard !summaries.isEmpty else { return "No daily results are available for those days yet." }

        var lines = ["\(AskData.name(site)). Net: positive means ahead, negative means a cost. Includes the supply charge."]
        for day in summaries {
            lines.append("\(AskData.day(day.date, site: site)): bought \(AskData.kwh(day.totalImport)), sold \(AskData.kwh(day.totalExport)), costs \(AskData.dollars(day.totalCosts)), earnings \(AskData.dollars(day.totalEarnings)), net \(AskData.dollars(day.netProfit))")
        }
        if summaries.count > 1 {
            let net = summaries.map(\.netProfit).reduce(0, +)
            lines.append("Total over \(summaries.count) days: net \(AskData.dollars(net))")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Interval detail

@available(iOS 26.0, *)
nonisolated struct IntervalDetailTool: Tool {
    let api: PowstonAPI
    let name = "get_interval_detail"
    let description = "Hour-by-hour detail for one day from the site's meter readings: energy bought and sold, solar, house use, battery charge and money."

    @Generable
    struct Arguments {
        @Guide(description: "Days ago: 0 is today, 1 is yesterday, up to 2.", .range(0...2))
        var daysAgo: Int
        @Guide(description: "Site name. Leave empty for the selected site.")
        var site: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let api = api, args = arguments
        return await askLookup(name) { await Self.answer(daysAgo: args.daysAgo, site: args.site, api: api) }
    }

    @MainActor
    private static func answer(daysAgo: Int, site name: String?, api: PowstonAPI) async -> String {
        if api.isDemoMode {
            return "\(AskData.demoNote)\nHour-by-hour detail isn't part of the demo. Try today's summary or daily history."
        }
        let site: Site
        switch AskData.site(named: name, api: api) {
        case .failure(let error): return error.text
        case .success(let value): site = value
        }
        let calendar = AskData.calendar(for: site)
        let dayStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -max(0, min(daysAgo, 2)), to: Date()) ?? Date())
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return "Couldn't work out the dates." }

        let records = await api.fetchMeterRecords(
            siteId: site.id, fromDate: dayStart, toDate: dayEnd, limit: 288,
            forceRefresh: site.id != api.selectedSiteId
        )
        let dated = records.compactMap { record in record.date.map { ($0, record) } }
            .filter { $0.0 >= dayStart && $0.0 < dayEnd }
        guard !dated.isEmpty else { return "No meter readings for \(AskData.day(dayStart, site: site))." }

        let byHour = Dictionary(grouping: dated) { calendar.component(.hour, from: $0.0) }
        var lines = ["\(AskData.name(site)), \(AskData.day(dayStart, site: site)). Per hour: bought / sold / solar / house kWh, battery %, net $ (positive means ahead)."]
        for hour in byHour.keys.sorted() {
            let rows = byHour[hour]!.map(\.1)
            let bought = rows.map(\.effectiveImport).reduce(0, +)
            let sold = rows.map(\.effectiveExport).reduce(0, +)
            let solar = rows.compactMap(\.ppvGeneration).reduce(0, +)
            let house = rows.compactMap(\.houseConsumption).reduce(0, +)
            let net = (rows.compactMap(\.earnings).reduce(0, +) - rows.compactMap(\.costs).reduce(0, +)) / 100
            let soc = rows.last?.endBatterySoc.map { String(format: "%.0f%%", $0) } ?? "?"
            lines.append(String(format: "%02d:00: %.1f / %.1f / %.1f / %.1f, %@, %@", hour, bought, sold, solar, house, soc, AskData.dollars(net)))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Tariff

@available(iOS 26.0, *)
nonisolated struct TariffInfoTool: Tool {
    let api: PowstonAPI
    let name = "get_tariff_info"
    let description = "The selected site's tariff periods (such as peak, shoulder, off-peak) with their times and rates, and how the site did in each period over recent days."

    @Generable
    struct Arguments {
        @Guide(description: "How many recent complete days to total per period, from 1 to 30.", .range(1...30))
        var days: Int
    }

    func call(arguments: Arguments) async throws -> String {
        let api = api, args = arguments
        return await askLookup(name) { await Self.answer(days: args.days, api: api) }
    }

    @MainActor
    private static func answer(days: Int, api: PowstonAPI) async -> String {
        if api.isDemoMode {
            return "\(AskData.demoNote)\nTariff details aren't part of the demo."
        }
        guard let site = api.selectedSite else { return "No site is selected in the app." }
        let calendar = AskData.calendar(for: site)
        let today = calendar.startOfDay(for: Date())
        guard let end = calendar.date(byAdding: .day, value: -1, to: today),
              let start = calendar.date(byAdding: .day, value: -max(1, min(days, 30)), to: today) else { return "Couldn't work out the dates." }
        guard let tariff = await api.fetchTariffRates(startDate: start, endDate: end) else {
            return "Tariff details aren't available for \(AskData.name(site))."
        }
        var lines = ["\(AskData.name(site))"]
        if let code = site.tariff { lines.append("Tariff code: \(code)") }
        if !tariff.periodDefinitions.isEmpty {
            lines.append("Periods:")
            for period in tariff.periodDefinitions {
                lines.append("- \(period.periodName): \(period.startTime.prefix(5))–\(period.endTime.prefix(5)), \(AskData.cents(period.periodRate))")
            }
        }
        if !tariff.data.isEmpty {
            lines.append("Last \(days) days by period (bought, sold, net; positive net means ahead):")
            for period in tariff.data {
                lines.append("- \(period.periodName): \(AskData.kwh(period.energyImport)) at \(AskData.cents(period.buyRate)), \(AskData.kwh(period.energyExport)) at \(AskData.cents(period.sellRate)), net \(AskData.dollars(-period.expectedBill / 100))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - ROI

@available(iOS 26.0, *)
nonisolated struct ROITool: Tool {
    let api: PowstonAPI
    let name = "get_roi"
    let description = "What the battery earned over complete days: trading (buy low, sell high), shifting solar to sell later, and power the house used from the battery instead of buying it."

    @Generable
    struct Arguments {
        @Guide(description: "Days ending yesterday: 1, 7 or 30.", .anyOf(["1", "7", "30"]))
        var days: String
        @Guide(description: "Site name. Leave empty for the selected site.")
        var site: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let api = api, args = arguments
        return await askLookup(name) { await Self.answer(days: Int(args.days) ?? 7, site: args.site, api: api) }
    }

    @MainActor
    private static func answer(days: Int, site name: String?, api: PowstonAPI) async -> String {
        if api.isDemoMode {
            return """
            \(AskData.demoNote)
            Last 7 days: battery value $24.60 in total. Trading 38 kWh at a 21¢ spread, $8.00. Solar shifted 52 kWh sold at 24¢, $12.50. House ran on the battery for 27 kWh instead of buying at 15¢, $4.10.
            """
        }
        let site: Site
        switch AskData.site(named: name, api: api) {
        case .failure(let error): return error.text
        case .success(let value): site = value
        }
        guard let inverterId = AskData.inverterId(for: site, api: api) else { return "No inverter found for \(AskData.name(site))." }
        let calendar = AskData.calendar(for: site)
        let today = calendar.startOfDay(for: Date())
        let span = [1, 7, 30].contains(days) ? days : 7
        guard let end = calendar.date(byAdding: .day, value: -1, to: today),
              let start = calendar.date(byAdding: .day, value: -span, to: today) else { return "Couldn't work out the dates." }

        switch await api.fetchMarketROI(inverterId: inverterId, startDate: start, endDate: end) {
        case .noActivity:
            return "The battery had no activity in that window."
        case .failure(let message):
            return "Battery ROI isn't available right now (\(message))."
        case .success(let roi):
            var lines = ["\(AskData.name(site)), last \(span) complete day(s). Battery value: \(AskData.dollars(roi.totalDollars))"]
            if let a = roi.arbitrage {
                lines.append("Trading: \(AskData.kwh(a.kwh)) bought at \(AskData.cents(a.buyAvgCentsPerKwh)) and sold at \(AskData.cents(a.sellAvgCentsPerKwh)), \(AskData.dollars(a.netDollars))")
            }
            if let s = roi.solarShift {
                lines.append("Solar shifted: \(AskData.kwh(s.exportKwh)) sold later at \(AskData.cents(s.sellAvgCentsPerKwh)), \(AskData.dollars(s.revenueDollars))")
            }
            if let h = roi.selfSupply {
                lines.append("House from battery: \(AskData.kwh(h.batteryToHouseKwh)) instead of buying at \(AskData.cents(h.avoidedBuyAvgCentsPerKwh)), \(AskData.dollars(h.avoidedDollars))")
            }
            if let settled = roi.settledPct, settled < 100 {
                lines.append(String(format: "%.0f%% of this period is settled; the rest may change.", settled))
            }
            return lines.joined(separator: "\n")
        }
    }
}

// MARK: - Bill to date

@available(iOS 26.0, *)
nonisolated struct BillToDateTool: Tool {
    let api: PowstonAPI
    let name = "get_bill_to_date"
    let description = "Estimated electricity bill for the selected site this month, up to the last complete day, including the supply charge. Not the retailer's bill."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let api = api
        return await askLookup(name) { await Self.answer(api: api) }
    }

    @MainActor
    private static func answer(api: PowstonAPI) async -> String {
        if api.isDemoMode {
            return """
            \(AskData.demoNote)
            This month to yesterday (estimate): costs $38.20 including supply, earnings $71.45, net $33.25 in credit.
            """
        }
        guard let site = api.selectedSite else { return "No site is selected in the app." }
        guard let month = await api.fetchCurrentMonthSummary() else {
            return "This month's figures aren't available yet (the month may have no complete days)."
        }
        var lines = ["\(AskData.name(site)). Estimate from Powston's data, not the retailer's bill."]
        if let through = api.latestCompleteDataDate {
            lines.append("Covers the 1st to \(AskData.day(through, site: site)).")
        }
        lines.append("Costs: \(AskData.dollars(month.totalCosts / 100)) including \(AskData.dollars(month.dailyCosts / 100)) supply")
        lines.append("Earnings: \(AskData.dollars(month.totalEarnings / 100))")
        let bill = month.expectedBill / 100
        lines.append(bill > 0 ? "Owing: \(AskData.dollars(bill))" : "In credit: \(AskData.dollars(-bill))")
        lines.append("Bought \(AskData.kwh(month.totalEnergyImported)), sold \(AskData.kwh(month.totalEnergyExported))")
        return lines.joined(separator: "\n")
    }
}
