//
//  SavingsAnalysisCalculator.swift
//  Powston
//
//  Calculates hypothetical costs under different scenarios:
//  - Grid only (no solar, no battery)
//  - Solar only (no battery)
//  - Dumb battery (self-consumption only, no price awareness)
//  - Actual (what Powston achieved)
//
//  The difference between dumb battery and actual IS the Powston value.
//

import Foundation

struct SavingsAnalysis {
    let gridOnlyCost: Double       // Cost if no solar, no battery
    let solarOnlyCost: Double      // Cost with solar but no battery
    let dumbBatteryCost: Double    // Cost with solar + dumb self-consumption battery
    let actualCost: Double         // What actually happened (from meterrecords or API)
    let supplyCost: Double         // Fixed daily charges for the period
    let hasCompleteData: Bool
    let dataCompleteness: Double
    
    // Flat rate comparison
    let flatRateCost: Double
    let flatBuyRate: Double
    let flatSellRate: Double
    
    // Data quality indicator
    let usedDerivedData: Bool
    
    // P2P trading (from imported LocalVolts data)
    // P2P premium is NOT included in Powston API earnings — it is added by the calculator
    let p2pRevenue: Double         // Total P2P revenue
    let p2pSpotEquivalent: Double  // What P2P kWh would have earned at spot rates
    let p2pPremium: Double         // p2pRevenue - p2pSpotEquivalent (can be negative)

    // Separate P2P sell and buy for memo lines
    let p2pSellRevenue: Double           // Revenue from P2P selling
    let p2pSellKwh: Double               // Volume sold via P2P
    let p2pSellSpotEquivalent: Double    // What sell kWh would have earned at spot
    let p2pBuyCost: Double               // Cost from P2P buying
    let p2pBuyKwh: Double                // Volume bought via P2P
    let p2pBuySpotEquivalent: Double     // What buy kWh would have cost at spot
    let p2pNTB: Double                   // NTB (Needed to Balance) — DLF/MLF adjustment
    let powstonAPINetCost: Double?       // Original Powston API net cost (before LV override), nil if not available

    // Derived savings (each tier measures incremental value)
    var solarSavings: Double { gridOnlyCost - solarOnlyCost }
    var batterySavings: Double { solarOnlyCost - dumbBatteryCost }
    var powstonSavings: Double { dumbBatteryCost - actualCost }  // Value of smart scheduling
    var totalSavings: Double { gridOnlyCost - actualCost }
    var flatRateSavings: Double { flatRateCost - actualCost }

    // P2P helpers
    var hasP2PData: Bool { p2pRevenue > 0.001 || p2pBuyCost > 0.001 }  // Show if any P2P data exists
    var hasP2PSellData: Bool { p2pSellRevenue > 0.001 }
    var hasP2PBuyData: Bool { p2pBuyCost > 0.001 }
    var p2pSellPremium: Double { p2pSellRevenue - p2pSellSpotEquivalent }
    var p2pBuySavings: Double { p2pBuySpotEquivalent - p2pBuyCost }  // Positive if bought cheaper than spot

    /// Return a copy with actualCost overridden (e.g., from LV settlement data)
    func withActualCost(_ newActualCost: Double) -> SavingsAnalysis {
        SavingsAnalysis(
            gridOnlyCost: gridOnlyCost, solarOnlyCost: solarOnlyCost,
            dumbBatteryCost: dumbBatteryCost, actualCost: newActualCost,
            supplyCost: supplyCost, hasCompleteData: hasCompleteData,
            dataCompleteness: dataCompleteness, flatRateCost: flatRateCost,
            flatBuyRate: flatBuyRate, flatSellRate: flatSellRate,
            usedDerivedData: usedDerivedData, p2pRevenue: p2pRevenue,
            p2pSpotEquivalent: p2pSpotEquivalent, p2pPremium: p2pPremium,
            p2pSellRevenue: p2pSellRevenue, p2pSellKwh: p2pSellKwh,
            p2pSellSpotEquivalent: p2pSellSpotEquivalent,
            p2pBuyCost: p2pBuyCost, p2pBuyKwh: p2pBuyKwh,
            p2pBuySpotEquivalent: p2pBuySpotEquivalent, p2pNTB: p2pNTB,
            powstonAPINetCost: powstonAPINetCost  // Keep original Powston API value
        )
    }
}

struct SavingsAnalysisCalculator {
    
    private let chargeEfficiency: Double = 0.949      // √0.90 ≈ 0.949
    private let dischargeEfficiency: Double = 0.949
    
    /// Calculate savings analysis from meter records
    /// - Parameters:
    ///   - records: Array of MeterRecord with 5-minute interval data
    ///   - pricesByInterval: Lookup of buy/sell prices by interval time string
    ///   - batteryCapacityKwh: Total usable battery capacity in kWh
    ///   - supplyCost: Fixed supply costs for the period
    ///   - flatBuyRate: Flat tariff buy rate for comparison (c/kWh)
    ///   - flatSellRate: Flat tariff sell rate for comparison (c/kWh)
    ///   - inverterLimitKw: Max inverter power (used for dumb battery simulation)
    ///   - p2pRevenue: P2P revenue for the period (NOT included in Powston API earnings)
    ///   - p2pSpotEquivalent: What P2P kWh would have earned at spot
    ///   - p2pSellRevenue: Revenue from P2P selling
    ///   - p2pSellKwh: Volume sold via P2P
    ///   - p2pSellSpotEquivalent: What sell kWh would have earned at spot
    ///   - p2pBuyCost: Cost from P2P buying
    ///   - p2pBuyKwh: Volume bought via P2P
    ///   - p2pBuySpotEquivalent: What buy kWh would have cost at spot
    /// - Returns: SavingsAnalysis if sufficient data, nil otherwise
    func calculate(
            records: [MeterRecord],
            pricesByInterval: [String: (buy: Double, sell: Double)] = [:],
            batteryCapacityKwh: Double,
            supplyCost: Double,
            totalImportKwh: Double,
            totalExportKwh: Double,
            flatBuyRate: Double = 33.0,
            flatSellRate: Double = 5.0,
            inverterLimitKw: Double = 10.0,
            p2pRevenue: Double = 0,
            p2pSpotEquivalent: Double = 0,
            p2pSellRevenue: Double = 0,
            p2pSellKwh: Double = 0,
            p2pSellSpotEquivalent: Double = 0,
            p2pBuyCost: Double = 0,
            p2pBuyKwh: Double = 0,
            p2pBuySpotEquivalent: Double = 0,
            p2pNTB: Double = 0
        ) -> SavingsAnalysis? {

        guard !records.isEmpty else { return nil }
        guard batteryCapacityKwh > 0 else { return nil }
        
        var priceHits = 0
        var priceMisses = 0

        // Check data completeness
        let validIntervals = records.filter { record in
            let hasInverterData = record.ppvGeneration != nil && record.houseConsumption != nil && (record.houseConsumption ?? 0) > 0
            let hasMeterData = record.effectiveImport > 0.001 || record.effectiveExport > 0.001
            return hasInverterData || hasMeterData
        }
        
        let completeness = Double(validIntervals.count) / Double(records.count)
        guard completeness >= 0.90 else { return nil }
        
        // Determine if site has valid inverter data (ppvGeneration + houseConsumption)
        let hasValidInverterData = records.contains { record in
            if let pv = record.ppvGeneration, pv > 0,
               let consumption = record.houseConsumption, consumption > 0 {
                return true
            }
            return false
        }
        
        // Get starting SOC for dumb battery simulation
        let startingSocFraction = (records.first?.startBatterySoc ?? 50.0) / 100.0
        var dumbVirtualSoc = startingSocFraction * batteryCapacityKwh
        
        // Accumulators (in cents)
        var gridOnlyCost: Double = 0
        var solarOnlyNet: Double = 0      // Positive = earnings, negative = costs
        var dumbBatteryNet: Double = 0    // Positive = earnings, negative = costs
        var actualNet: Double = 0         // From meterrecords: earnings - costs

            // totalImportKwh and totalExportKwh now passed in from API summaries
            
        let intervalHours = 5.0 / 60.0
        let maxIntervalEnergy = inverterLimitKw * intervalHours
        
        for record in records {
            let importKwh = record.effectiveImport
            let exportKwh = record.effectiveExport
            let costs = record.costs ?? 0
            let earnings = record.earnings ?? 0
            
            // === Actual === (from meterrecords)
            actualNet += earnings - costs
            
            // Get prices for this interval
            let batteryBuyPrice: Double
            let batterySellPrice: Double
            
            let normalizedIntervalTime = record.intervalTime.replacingOccurrences(of: "+00:00", with: "Z")
            
            if let prices = pricesByInterval[normalizedIntervalTime] {
                batteryBuyPrice = prices.buy
                batterySellPrice = prices.sell
                priceHits += 1
            } else {
                batteryBuyPrice = flatBuyRate
                batterySellPrice = flatSellRate
                priceMisses += 1
            }
                        
            // Determine consumption and PV for this interval
            let consumptionKwh: Double
            let pvKwh: Double
            
            if hasValidInverterData {
                // Use inverter data directly
                if let consumption = record.houseConsumption, consumption > 0 {
                    consumptionKwh = consumption / 1000.0 * intervalHours
                } else {
                    continue  // Skip intervals with no consumption data
                }
                
                if let pv = record.ppvGeneration, pv >= 0 {
                    pvKwh = pv / 1000.0 * intervalHours
                } else {
                    pvKwh = 0
                }
            } else {
                // Estimate from grid flows (fallback for sites without inverter data)
                if importKwh < 0.001 && exportKwh < 0.001 {
                    continue
                }
                
                let estimatedSelfConsumptionRatio = 0.3
                
                if exportKwh > 0.001 {
                    let estimatedPvGeneration = exportKwh / (1.0 - estimatedSelfConsumptionRatio)
                    let estimatedPvConsumed = estimatedPvGeneration * estimatedSelfConsumptionRatio
                    consumptionKwh = importKwh + estimatedPvConsumed
                    pvKwh = estimatedPvGeneration
                } else {
                    consumptionKwh = importKwh
                    pvKwh = 0
                }
            }
            
            // === Grid Only ===
            // All consumption comes from grid at buy price
            gridOnlyCost += consumptionKwh * batteryBuyPrice
            
            // === Solar Only ===
            // Solar covers what it can, excess exported, deficit imported
            let solarBalance = pvKwh - consumptionKwh
            if solarBalance >= 0 {
                // Surplus solar exported
                solarOnlyNet += solarBalance * batterySellPrice
            } else {
                // Deficit imported from grid
                solarOnlyNet -= abs(solarBalance) * batteryBuyPrice
            }
            
            // === Dumb Battery ===
            // Self-consumption priority: PV → house, excess → battery, remainder → export
            // Deficit: battery → grid
            let dumbBalance = pvKwh - consumptionKwh
            if dumbBalance >= 0 {
                // Excess solar: charge battery first, then export
                let excess = dumbBalance
                let roomInBattery = batteryCapacityKwh - dumbVirtualSoc
                let maxCharge = min(excess * chargeEfficiency, roomInBattery, maxIntervalEnergy * chargeEfficiency)
                dumbVirtualSoc += maxCharge
                
                let exportable = excess - (maxCharge / chargeEfficiency)
                if exportable > 0.001 {
                    dumbBatteryNet += exportable * batterySellPrice
                }
            } else {
                // Deficit: discharge battery first, then import
                let deficit = abs(dumbBalance)
                let availableFromBattery = dumbVirtualSoc * dischargeEfficiency
                let maxDischarge = min(deficit, availableFromBattery, maxIntervalEnergy)
                dumbVirtualSoc -= maxDischarge / dischargeEfficiency
                
                let mustImport = deficit - maxDischarge
                if mustImport > 0.001 {
                    dumbBatteryNet -= mustImport * batteryBuyPrice
                }
            }
        }

        // P2P premium is NOT included in Powston API earnings — add it here
        // P2P values are in dollars, actualNet is in cents, so convert
        let p2pSellPremiumCents = (p2pSellRevenue - p2pSellSpotEquivalent) * 100
        let p2pBuySavingsCents = (p2pBuySpotEquivalent - p2pBuyCost) * 100
        actualNet += p2pSellPremiumCents + p2pBuySavingsCents

        print("   price lookups: \(priceHits) hits, \(priceMisses) misses")

        // Convert cents to dollars (net values: positive = credit, negative = cost)
        // We want costs as positive numbers, so negate the net values
        let gridOnlyTotal = gridOnlyCost / 100.0
        let solarOnlyTotal = -solarOnlyNet / 100.0
        let dumbBatteryTotal = -dumbBatteryNet / 100.0
        let actualTotal = -actualNet / 100.0
        
        // Flat rate cost using actual import/export volumes
        let flatRateCostCents = (totalImportKwh * flatBuyRate) - (totalExportKwh * flatSellRate)
        let flatRateTotal = flatRateCostCents / 100.0 + supplyCost
        
        let usedDerivedData = !hasValidInverterData
        
       
        return SavingsAnalysis(
            gridOnlyCost: gridOnlyTotal + supplyCost,
            solarOnlyCost: solarOnlyTotal + supplyCost,
            dumbBatteryCost: dumbBatteryTotal + supplyCost,
            actualCost: actualTotal + supplyCost,  // Include supply cost for consistency
            supplyCost: supplyCost,
            hasCompleteData: true,
            dataCompleteness: completeness,
            flatRateCost: flatRateTotal,
            flatBuyRate: flatBuyRate,
            flatSellRate: flatSellRate,
            usedDerivedData: usedDerivedData,
            p2pRevenue: p2pRevenue,
            p2pSpotEquivalent: p2pSpotEquivalent,
            p2pPremium: p2pRevenue - p2pSpotEquivalent,
            p2pSellRevenue: p2pSellRevenue,
            p2pSellKwh: p2pSellKwh,
            p2pSellSpotEquivalent: p2pSellSpotEquivalent,
            p2pBuyCost: p2pBuyCost,
            p2pBuyKwh: p2pBuyKwh,
            p2pBuySpotEquivalent: p2pBuySpotEquivalent,
            p2pNTB: p2pNTB,
            powstonAPINetCost: nil
        )
    }

    /// Calculate for a period, using API-sourced actual for accuracy
    /// The API's netProfit already includes supply costs, so we use it directly.
    func calculateForPeriod(
            records: [MeterRecord],
            pricesByInterval: [String: (buy: Double, sell: Double)] = [:],
            batteryCapacityKwh: Double,
            supplyCost: Double,
            totalImportKwh: Double,
            totalExportKwh: Double,
            actualNetFromAPI: Double,
            flatBuyRate: Double = 33.0,
            flatSellRate: Double = 5.0,
            inverterLimitKw: Double = 10.0,
            p2pRevenue: Double = 0,
            p2pSpotEquivalent: Double = 0,
            p2pSellRevenue: Double = 0,
            p2pSellKwh: Double = 0,
            p2pSellSpotEquivalent: Double = 0,
            p2pBuyCost: Double = 0,
            p2pBuyKwh: Double = 0,
            p2pBuySpotEquivalent: Double = 0,
            p2pNTB: Double = 0
        ) -> SavingsAnalysis? {

            guard let analysis = calculate(
                        records: records,
                        pricesByInterval: pricesByInterval,
                        batteryCapacityKwh: batteryCapacityKwh,
                        supplyCost: supplyCost,
                        totalImportKwh: totalImportKwh,
                        totalExportKwh: totalExportKwh,
                        flatBuyRate: flatBuyRate,
                        flatSellRate: flatSellRate,
                        inverterLimitKw: inverterLimitKw,
                        p2pRevenue: p2pRevenue,
                        p2pSpotEquivalent: p2pSpotEquivalent,
                        p2pSellRevenue: p2pSellRevenue,
                        p2pSellKwh: p2pSellKwh,
                        p2pSellSpotEquivalent: p2pSellSpotEquivalent,
                        p2pBuyCost: p2pBuyCost,
                        p2pBuyKwh: p2pBuyKwh,
                        p2pBuySpotEquivalent: p2pBuySpotEquivalent,
                        p2pNTB: p2pNTB
                    ) else { return nil }

        // actualNetFromAPI is net profit (earnings - costs) including supply
        // Convert to cost: negative of net profit
        // P2P premium is NOT included in Powston API earnings — adjust here
        let p2pAdjustment = (p2pSellRevenue - p2pSellSpotEquivalent) + (p2pBuySpotEquivalent - p2pBuyCost)
        let actualCostFromAPI = -actualNetFromAPI - p2pAdjustment

        return SavingsAnalysis(
            gridOnlyCost: analysis.gridOnlyCost,
            solarOnlyCost: analysis.solarOnlyCost,
            dumbBatteryCost: analysis.dumbBatteryCost,
            actualCost: actualCostFromAPI,
            supplyCost: supplyCost,
            hasCompleteData: analysis.hasCompleteData,
            dataCompleteness: analysis.dataCompleteness,
            flatRateCost: analysis.flatRateCost,
            flatBuyRate: flatBuyRate,
            flatSellRate: flatSellRate,
            usedDerivedData: analysis.usedDerivedData,
            p2pRevenue: p2pRevenue,
            p2pSpotEquivalent: p2pSpotEquivalent,
            p2pPremium: p2pRevenue - p2pSpotEquivalent,
            p2pSellRevenue: p2pSellRevenue,
            p2pSellKwh: p2pSellKwh,
            p2pSellSpotEquivalent: p2pSellSpotEquivalent,
            p2pBuyCost: p2pBuyCost,
            p2pBuyKwh: p2pBuyKwh,
            p2pBuySpotEquivalent: p2pBuySpotEquivalent,
            p2pNTB: p2pNTB,
            powstonAPINetCost: -actualNetFromAPI  // Powston API reported net cost (positive=cost, negative=profit)
        )
    }

    /// Calculate savings analysis from LV settlement interval data
    /// Used for historical dates where Powston API has no meter records
    func calculateFromLVSettlement(
        intervals: [LVSettlementRecord],
        cashflow: LVCashflowSummary,
        batteryCapacityKwh: Double,
        flatBuyRate: Double = 33.0,
        flatSellRate: Double = 5.0,
        inverterLimitKw: Double = 10.0
    ) -> SavingsAnalysis? {
        guard !intervals.isEmpty, batteryCapacityKwh > 0 else { return nil }

        let basis = intervals.first?.basis ?? 48
        let intervalMinutes = 24.0 * 60.0 / Double(basis)
        let intervalHours = intervalMinutes / 60.0
        let maxIntervalEnergy = inverterLimitKw * intervalHours

        // Group by period to merge Import + Export for each interval
        let byPeriod = Dictionary(grouping: intervals) { $0.period }

        // Sort by period for battery simulation ordering
        let periods = byPeriod.keys.sorted()

        var gridOnlyCost: Double = 0
        var solarOnlyNet: Double = 0
        var dumbBatteryNet: Double = 0
        var actualNet: Double = 0

        let startingSocFraction = 0.5  // Assume 50% SOC start without inverter data
        var dumbVirtualSoc = startingSocFraction * batteryCapacityKwh

        for period in periods {
            let records = byPeriod[period] ?? []
            let importRec = records.first { $0.isImport }
            let exportRec = records.first { $0.isExport }

            let importKwh = importRec?.volume ?? 0
            let exportKwh = exportRec?.volume ?? 0

            // Actual: settlement earnings and costs (in dollars, convert to cents for accumulator)
            // settle is spot, matchAmount is P2P — separate, additive components
            let expSettle: Double = exportRec?.settle ?? 0
            let expMatch: Double = exportRec?.matchAmount ?? 0
            let expFeedIn: Double = exportRec?.feedInTopUp ?? 0
            let exportRevenue = expSettle + expMatch + expFeedIn
            let impSettle: Double = importRec?.settle ?? 0
            let impNetwork: Double = importRec?.networkEnergy ?? 0
            let impCerts: Double = importRec?.certificateAmt ?? 0
            let impMatch: Double = importRec?.matchAmount ?? 0
            let importCost = impSettle + impNetwork + impCerts + impMatch
            actualNet += (exportRevenue - importCost) * 100  // Convert $ to cents

            // Use flat rates for hypotheticals (no action records for old dates)
            let buyPrice = flatBuyRate
            let sellPrice = flatSellRate

            // Estimate consumption and PV from grid flows (no inverter data)
            let consumptionKwh: Double
            let pvKwh: Double
            let estimatedSelfConsumptionRatio = 0.3

            if exportKwh > 0.001 {
                let estimatedPvGeneration = exportKwh / (1.0 - estimatedSelfConsumptionRatio)
                let estimatedPvConsumed = estimatedPvGeneration * estimatedSelfConsumptionRatio
                consumptionKwh = importKwh + estimatedPvConsumed
                pvKwh = estimatedPvGeneration
            } else if importKwh > 0.001 {
                consumptionKwh = importKwh
                pvKwh = 0
            } else {
                continue
            }

            // Grid only
            gridOnlyCost += consumptionKwh * buyPrice

            // Solar only
            let solarBalance = pvKwh - consumptionKwh
            if solarBalance >= 0 {
                solarOnlyNet += solarBalance * sellPrice
            } else {
                solarOnlyNet -= abs(solarBalance) * buyPrice
            }

            // Dumb battery
            let dumbBalance = pvKwh - consumptionKwh
            if dumbBalance >= 0 {
                let excess = dumbBalance
                let roomInBattery = batteryCapacityKwh - dumbVirtualSoc
                let maxCharge = min(excess * chargeEfficiency, roomInBattery, maxIntervalEnergy * chargeEfficiency)
                dumbVirtualSoc += maxCharge
                let exportable = excess - (maxCharge / chargeEfficiency)
                if exportable > 0.001 {
                    dumbBatteryNet += exportable * sellPrice
                }
            } else {
                let deficit = abs(dumbBalance)
                let availableFromBattery = dumbVirtualSoc * dischargeEfficiency
                let maxDischarge = min(deficit, availableFromBattery, maxIntervalEnergy)
                dumbVirtualSoc -= maxDischarge / dischargeEfficiency
                let mustImport = deficit - maxDischarge
                if mustImport > 0.001 {
                    dumbBatteryNet -= mustImport * buyPrice
                }
            }
        }

        // Supply cost from LV cashflow
        let supplyCost = cashflow.networkAccessCost + cashflow.localvoltsFee

        // Convert cents to dollars
        let gridOnlyTotal = gridOnlyCost / 100.0
        let solarOnlyTotal = -solarOnlyNet / 100.0
        let dumbBatteryTotal = -dumbBatteryNet / 100.0

        // Actual cost from LV cashflow (authoritative)
        let actualCost = cashflow.netCosts

        // Flat rate
        let totalImportKwh = cashflow.energyPurchasedKwh
        let totalExportKwh = cashflow.energySoldTotalKwh
        let flatRateCostCents = (totalImportKwh * flatBuyRate) - (totalExportKwh * flatSellRate)
        let flatRateTotal = flatRateCostCents / 100.0 + supplyCost

        // P2P from LV settlement: settle IS spot-only, matchAmount IS P2P (separate)
        let p2pSellRevenue = cashflow.p2pMatchedRevenue
        let p2pSellKwh = cashflow.energySoldP2PKwh
        let spotRate = cashflow.energySoldSpotKwh > 0.001 ? cashflow.spotEnergyRevenue / cashflow.energySoldSpotKwh : 0
        let p2pSellSpotEquivalent = spotRate * cashflow.energySoldP2PKwh
        let p2pBuyCost = intervals.filter { $0.isImport && $0.matchAmount > 0 }.reduce(0.0) { $0 + $1.matchAmount }
        let p2pBuyKwh = intervals.filter { $0.isImport && $0.matchEnergy > 0 }.reduce(0.0) { $0 + $1.matchEnergy }

        return SavingsAnalysis(
            gridOnlyCost: gridOnlyTotal + supplyCost,
            solarOnlyCost: solarOnlyTotal + supplyCost,
            dumbBatteryCost: dumbBatteryTotal + supplyCost,
            actualCost: actualCost,
            supplyCost: supplyCost,
            hasCompleteData: true,
            dataCompleteness: 1.0,
            flatRateCost: flatRateTotal,
            flatBuyRate: flatBuyRate,
            flatSellRate: flatSellRate,
            usedDerivedData: true,  // No inverter data, estimated from grid flows
            p2pRevenue: p2pSellRevenue,
            p2pSpotEquivalent: p2pSellSpotEquivalent,
            p2pPremium: p2pSellRevenue - p2pSellSpotEquivalent,
            p2pSellRevenue: p2pSellRevenue,
            p2pSellKwh: p2pSellKwh,
            p2pSellSpotEquivalent: p2pSellSpotEquivalent,
            p2pBuyCost: p2pBuyCost,
            p2pBuyKwh: p2pBuyKwh,
            p2pBuySpotEquivalent: 0,
            p2pNTB: 0,
            powstonAPINetCost: nil
        )
    }
}
