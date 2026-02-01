//
//  SavingsAnalysis.swift
//  Powston
//
//  Created by Rick Bollar on 1/24/26.
//


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

import Foundation

struct SavingsAnalysis {
    let gridOnlyCost: Double       // All consumption at import prices
    let solarOnlyCost: Double      // Export surplus at FiT, import deficit
    let dumbBatteryCost: Double    // Self-consumption battery, no strategic export
    let actualCost: Double         // What actually happened (costs - earnings)
    let supplyCost: Double         // Fixed daily supply charge
    let hasCompleteData: Bool
    let dataCompleteness: Double   // Percentage of intervals with required data
    
    // Derived savings (positive = money saved)
    var solarSavings: Double { gridOnlyCost - solarOnlyCost }
    var batterySavings: Double { solarOnlyCost - dumbBatteryCost }
    var powstonSavings: Double { dumbBatteryCost - actualCost }
    var totalSavings: Double { gridOnlyCost - actualCost }
}

struct SavingsAnalysisCalculator {
    
    private let chargeEfficiency: Double = 0.949      // √0.90 ≈ 0.949
    private let dischargeEfficiency: Double = 0.949
    
    /// Calculate savings analysis from meter records
    /// - Parameters:
    ///   - records: Array of MeterRecord with 5-minute interval data
    ///   - batteryCapacityKwh: Total usable battery capacity in kWh
    ///   - supplyCost: Fixed supply costs for the period (to subtract from all scenarios)
    /// - Returns: SavingsAnalysis if sufficient data, nil otherwise
    func calculate(
        records: [MeterRecord],
        batteryCapacityKwh: Double,
        supplyCost: Double
    ) -> SavingsAnalysis? {
        
        guard !records.isEmpty else { return nil }
        guard batteryCapacityKwh > 0 else { return nil }
        
        // Check data completeness
        let validIntervals = records.filter { record in
            record.ppvGeneration != nil && record.houseConsumption != nil
        }
        
        let completeness = Double(validIntervals.count) / Double(records.count)
        guard completeness >= 0.90 else { return nil }
        
        // Get starting SOC from first record (as fraction 0-1)
        let startingSocFraction = (records.first?.startBatterySoc ?? 50.0) / 100.0
        var virtualSoc = startingSocFraction * batteryCapacityKwh  // kWh
        
        // Accumulators (in cents)
        var gridOnlyCost: Double = 0
        var solarOnlyNet: Double = 0      // earnings - costs
        var dumbBatteryNet: Double = 0    // earnings - costs
        var actualNet: Double = 0         // earnings - costs
        
        for record in records {
            // Get values, skip if missing critical data
            guard let pvKwh = record.ppvGeneration,
                  let consumptionKwh = record.houseConsumption else {
                continue
            }
            
            // Get actual costs/earnings from this interval
            let importKwh = record.effectiveImport
            let exportKwh = record.effectiveExport
            let costs = record.costs ?? 0        // cents
            let earnings = record.earnings ?? 0  // cents
            
            // Calculate effective prices for this interval
            let buyPrice: Double
            if importKwh > 0.001 {
                buyPrice = costs / importKwh  // cents/kWh
            } else if let rrp = record.rrp {
                buyPrice = rrp
            } else {
                buyPrice = 30.0  // Fallback
            }
            
            let sellPrice: Double
            if exportKwh > 0.001 {
                sellPrice = earnings / exportKwh  // cents/kWh
            } else if let rrp = record.rrp {
                sellPrice = max(0, rrp * 0.9)
            } else {
                sellPrice = 10.0  // Fallback
            }
            
            // === Grid Only ===
            gridOnlyCost += consumptionKwh * buyPrice
            
            // === Solar Only ===
            let solarBalance = pvKwh - consumptionKwh
            if solarBalance >= 0 {
                solarOnlyNet += solarBalance * sellPrice
            } else {
                solarOnlyNet -= abs(solarBalance) * buyPrice
            }
            
            // === Dumb Battery (self-consumption) ===
            let dumbBalance = pvKwh - consumptionKwh
            if dumbBalance >= 0 {
                // Excess PV: charge battery first
                let excess = dumbBalance
                let roomInBattery = batteryCapacityKwh - virtualSoc
                let chargeAmount = min(excess * chargeEfficiency, roomInBattery)
                virtualSoc += chargeAmount
                
                // Export only what doesn't fit
                let exportable = excess - (chargeAmount / chargeEfficiency)
                if exportable > 0.001 {
                    dumbBatteryNet += exportable * sellPrice
                }
            } else {
                // Deficit: discharge battery first
                let deficit = abs(dumbBalance)
                let availableFromBattery = virtualSoc * dischargeEfficiency
                let dischargeAmount = min(deficit, availableFromBattery)
                virtualSoc -= dischargeAmount / dischargeEfficiency
                
                // Import only what battery can't cover
                let mustImport = deficit - dischargeAmount
                if mustImport > 0.001 {
                    dumbBatteryNet -= mustImport * buyPrice
                }
            }
            
            // === Actual ===
            actualNet += earnings - costs
        }
        
        // Convert cents to dollars, net to cost (negative net = cost)
        let gridOnlyTotal = gridOnlyCost / 100.0
        let solarOnlyTotal = -solarOnlyNet / 100.0
        let dumbBatteryTotal = -dumbBatteryNet / 100.0
        let actualTotal = -actualNet / 100.0
        
        return SavingsAnalysis(
            gridOnlyCost: gridOnlyTotal + supplyCost,
            solarOnlyCost: solarOnlyTotal + supplyCost,
            dumbBatteryCost: dumbBatteryTotal + supplyCost,
            actualCost: actualTotal + supplyCost,
            supplyCost: supplyCost,
            hasCompleteData: true,
            dataCompleteness: completeness
        )
    }
    
    /// Calculate for a period, using API-sourced actual for accuracy
    func calculateForPeriod(
        records: [MeterRecord],
        batteryCapacityKwh: Double,
        supplyCost: Double,
        actualNetFromAPI: Double
    ) -> SavingsAnalysis? {
        
        guard let analysis = calculate(
            records: records,
            batteryCapacityKwh: batteryCapacityKwh,
            supplyCost: supplyCost
        ) else { return nil }
        
        // Override actual with API value for billing accuracy
        return SavingsAnalysis(
            gridOnlyCost: analysis.gridOnlyCost,
            solarOnlyCost: analysis.solarOnlyCost,
            dumbBatteryCost: analysis.dumbBatteryCost,
            actualCost: -actualNetFromAPI,
            supplyCost: supplyCost,
            hasCompleteData: analysis.hasCompleteData,
            dataCompleteness: analysis.dataCompleteness
        )
    }
}