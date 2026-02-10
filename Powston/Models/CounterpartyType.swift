//
//  P2PCounterpartyClassifier.swift
//  Powston
//
//  Three-layer counterparty classification:
//  1. Manual overrides (user corrections, highest priority)
//  2. Improved heuristics (pattern matching)
//  3. Apple Intelligence fallback (async, for uncertain cases)
//

import Foundation
import SwiftUI
import FoundationModels
import Combine

// MARK: - Classification Result

enum CounterpartyType: String, Codable {
    case commercial
    case residential
    case unknown
}

struct ClassificationResult {
    let type: CounterpartyType
    let confidence: Double  // 0.0 - 1.0
    let source: ClassificationSource
}

enum ClassificationSource: String {
    case manualOverride = "Manual"
    case heuristic = "Heuristic"
    case appleIntelligence = "AI"
    case unknown = "Unknown"
}

// MARK: - Classifier

@MainActor
class P2PCounterpartyClassifier: ObservableObject {
    
    static let shared = P2PCounterpartyClassifier()
    
    // Manual overrides stored in iCloud KVS
    private let overridesKey = "p2p_counterparty_type_overrides_v1"
    @Published private(set) var manualOverrides: [String: CounterpartyType] = [:]
    
    // AI availability
    @Published private(set) var isAIAvailable = false
    
    // AI classification cache (in-memory, persisted to UserDefaults)
    private let aiCacheKey = "p2p_counterparty_ai_cache_v1"
    private var aiCache: [String: CounterpartyType] = [:]
    
    // Pending AI classifications to avoid duplicate requests
    private var pendingClassifications: Set<String> = []
    
    private init() {
        loadOverrides()
        loadAICache()
        checkAIAvailability()
    }
    
    private func checkAIAvailability() {
        if #available(iOS 26.0, macOS 26.0, *) {
            Task {
                await checkFoundationModelsAvailability()
            }
        }
    }
    
    @available(iOS 26.0, macOS 26.0, *)
    private func checkFoundationModelsAvailability() async {
        do {
            let session = LanguageModelSession()
            _ = try await session.respond(to: "test")
            await MainActor.run {
                self.isAIAvailable = true
            }
        } catch {
            await MainActor.run {
                self.isAIAvailable = false
            }
        }
    }
    
    // MARK: - Public API
    
    /// Classify a counterparty (synchronous, uses cached/heuristic results)
    func classify(_ name: String) -> ClassificationResult {
        // Layer 1: Manual override (highest priority)
        if let override = manualOverrides[name] {
            return ClassificationResult(
                type: override,
                confidence: 1.0,
                source: .manualOverride
            )
        }
        
        // Layer 2: Heuristics
        let heuristicResult = classifyWithHeuristics(name)
        if heuristicResult.confidence >= 0.7 {
            return heuristicResult
        }
        
        // Layer 3: Check AI cache
        if let cachedType = aiCache[name] {
            return ClassificationResult(
                type: cachedType,
                confidence: 0.85,
                source: .appleIntelligence
            )
        }
        
        // Return heuristic result even if low confidence
        // (AI classification happens async in background)
        return heuristicResult
    }
    
    /// Check if a counterparty is commercial (convenience method)
    func isCommercial(_ name: String) -> Bool {
        classify(name).type == .commercial
    }
    
    /// Request AI classification for uncertain counterparties (async, background)
    func requestAIClassificationIfNeeded(_ names: [String]) {
        // Skip if AI not available
        guard isAIAvailable else { return }
        
        let candidatesForAI = names.filter { name in
            // Skip if we have manual override
            guard manualOverrides[name] == nil else { return false }
            // Skip if already cached
            guard aiCache[name] == nil else { return false }
            // Skip if already pending
            guard !pendingClassifications.contains(name) else { return false }
            // Only request AI for uncertain heuristic results
            let heuristic = classifyWithHeuristics(name)
            return heuristic.confidence < 0.7
        }
        
        guard !candidatesForAI.isEmpty else { return }
        
        // Mark as pending
        for name in candidatesForAI {
            pendingClassifications.insert(name)
        }
        
        // Batch classify with AI
        Task {
            await classifyWithAppleIntelligence(candidatesForAI)
        }
    }
    
    // MARK: - Manual Overrides
    
    /// Set a manual override for a counterparty
    func setManualOverride(_ name: String, type: CounterpartyType) {
        manualOverrides[name] = type
        saveOverrides()
        objectWillChange.send()
    }
    
    /// Remove manual override (revert to heuristic/AI)
    func removeManualOverride(_ name: String) {
        manualOverrides.removeValue(forKey: name)
        saveOverrides()
        objectWillChange.send()
    }
    
    /// Check if a counterparty has a manual override
    func hasManualOverride(_ name: String) -> Bool {
        manualOverrides[name] != nil
    }
    
    // MARK: - Layer 2: Heuristics
    
    private func classifyWithHeuristics(_ name: String) -> ClassificationResult {
        let lower = name.lowercased()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        
        // High confidence commercial patterns
        let definiteCommercialSuffixes = [
            "pty ltd", "pty. ltd", "pty ltd.", " ltd", " inc", " corp",
            "holdings", "group pty", "services pty", "solutions pty"
        ]
        
        for suffix in definiteCommercialSuffixes {
            if lower.contains(suffix) {
                return ClassificationResult(type: .commercial, confidence: 0.95, source: .heuristic)
            }
        }
        
        // Food/hospitality business words (high confidence)
        let foodBusinessWords = [
            "cafe", "café", "coffee", "restaurant", "bistro", "bar", "pub",
            "grill", "kitchen", "bakery", "pizzeria", "pizza", "burger",
            "chicken", "fish", "chips", "sushi", "thai", "indian", "chinese",
            "mexican", "italian", "mania", "house", "diner", "eatery",
            "takeaway", "takeout", "catering", "foods", "meats", "butcher",
            "grocer", "market", "mart", "store", "shop"
        ]
        
        for word in foodBusinessWords {
            if lower.contains(word) {
                return ClassificationResult(type: .commercial, confidence: 0.85, source: .heuristic)
            }
        }
        
        // Service/industry words (high confidence)
        let serviceWords = [
            "services", "solutions", "systems", "consulting", "agency",
            "studio", "design", "digital", "tech", "software", "hardware",
            "electrical", "plumbing", "construction", "building", "property",
            "real estate", "realty", "insurance", "finance", "accounting",
            "legal", "law", "medical", "dental", "health", "fitness", "gym",
            "salon", "spa", "beauty", "auto", "motors", "mechanical",
            "transport", "logistics", "freight", "shipping", "warehouse",
            "manufacturing", "industries", "enterprises", "ventures",
            "partners", "associates", "group", "corporation", "company",
            "hotel", "motel", "inn", "resort", "accommodation", "rentals",
            "hire", "leasing", "training", "education", "school", "academy",
            "institute", "centre", "center", "clinic", "pharmacy", "chemist"
        ]
        
        for word in serviceWords {
            if lower.contains(word) {
                return ClassificationResult(type: .commercial, confidence: 0.85, source: .heuristic)
            }
        }
        
        // ALL CAPS pattern (often franchises/businesses)
        if trimmed == trimmed.uppercased() && trimmed.count > 3 && !trimmed.contains(" ") {
            return ClassificationResult(type: .commercial, confidence: 0.7, source: .heuristic)
        }
        
        // Names with numbers at the end (store locations like "Store 123")
        let numberPattern = #".*\d{2,}$"#
        if let _ = trimmed.range(of: numberPattern, options: .regularExpression) {
            return ClassificationResult(type: .commercial, confidence: 0.75, source: .heuristic)
        }
        
        // Check for typical person name patterns (residential indicators)
        let residentialPatterns = isLikelyPersonName(name)
        if residentialPatterns {
            return ClassificationResult(type: .residential, confidence: 0.7, source: .heuristic)
        }
        
        // Uncertain - needs AI classification
        return ClassificationResult(type: .unknown, confidence: 0.3, source: .heuristic)
    }
    
    /// Check if name looks like a person's name
    private func isLikelyPersonName(_ name: String) -> Bool {
        let components = name.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")
            .filter { !$0.isEmpty }
        
        // Two or three capitalized words is typical name pattern
        guard components.count >= 2 && components.count <= 3 else {
            return false
        }
        
        // Each component should be capitalized (Title Case)
        let allTitleCase = components.allSatisfy { word in
            guard let first = word.first else { return false }
            return first.isUppercase && word.dropFirst().allSatisfy { $0.isLowercase || $0 == "'" || $0 == "-" }
        }
        
        if !allTitleCase {
            return false
        }
        
        // Check for common name patterns (first name + surname)
        // Exclude if contains business-like words
        let lower = name.lowercased()
        let businessIndicators = ["the ", " and ", "&", "trading", "trust"]
        for indicator in businessIndicators {
            if lower.contains(indicator) {
                return false
            }
        }
        
        return true
    }
    
    // MARK: - Layer 3: Apple Intelligence
    
    private func classifyWithAppleIntelligence(_ names: [String]) async {
        // Process in small batches to avoid overwhelming the API
        let batchSize = 10
        
        for batch in names.chunked(into: batchSize) {
            await classifyBatchWithAI(batch)
        }
    }
    
    private func classifyBatchWithAI(_ names: [String]) async {
        // Build a concise prompt for batch classification
        let nameList = names.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        
        let prompt = """
        Classify each name as either a BUSINESS or PERSON name. Consider Australian business naming patterns.
        Reply with ONLY the number and classification, one per line. Example: "1. BUSINESS" or "2. PERSON"
        
        Names:
        \(nameList)
        """
        
        do {
            // Use the existing Apple Intelligence infrastructure
            let response = try await queryAppleIntelligence(prompt: prompt)
            
            // Parse response
            let lines = response.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                
                // Parse "1. BUSINESS" format
                let parts = trimmed.components(separatedBy: ".")
                guard parts.count >= 2,
                      let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                      index >= 1 && index <= names.count else {
                    continue
                }
                
                let classification = parts[1].trimmingCharacters(in: .whitespaces).uppercased()
                let name = names[index - 1]
                
                let type: CounterpartyType
                if classification.contains("BUSINESS") || classification.contains("COMMERCIAL") {
                    type = .commercial
                } else if classification.contains("PERSON") || classification.contains("RESIDENTIAL") {
                    type = .residential
                } else {
                    continue
                }
                
                // Update cache
                await MainActor.run {
                    self.aiCache[name] = type
                    self.pendingClassifications.remove(name)
                    self.objectWillChange.send()
                }
            }
            
            // Save updated cache
            await MainActor.run {
                self.saveAICache()
            }
            
        } catch {
            print("❌ AI classification failed: \(error)")
            // Remove from pending so we can retry later
            await MainActor.run {
                for name in names {
                    self.pendingClassifications.remove(name)
                }
            }
        }
    }
    
    /// Query Apple Intelligence using Foundation Models
    private func queryAppleIntelligence(prompt: String) async throws -> String {
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw ClassificationError.aiNotAvailable
        }
        
        return try await queryWithFoundationModels(prompt: prompt)
    }
    
    @available(iOS 26.0, macOS 26.0, *)
    private func queryWithFoundationModels(prompt: String) async throws -> String {
        let session = LanguageModelSession(instructions: classificationInstructions)
        let response = try await session.respond(to: prompt)
        return response.content
    }
    
    private let classificationInstructions = """
    You classify names as BUSINESS or PERSON. Consider Australian naming patterns.
    
    BUSINESS indicators:
    - Company suffixes: Pty Ltd, Ltd, Inc, Corp
    - Food/retail words: Cafe, Kitchen, Grill, Pizza, Chicken, Mania, Foods
    - Service words: Services, Solutions, Consulting, Agency
    - Industry words: Industries, Enterprises, Group, Holdings
    - ALL CAPS names (franchises)
    - Names with numbers (store locations)
    
    PERSON indicators:
    - Two or three capitalized words (First Last or First Middle Last)
    - Common first name + surname pattern
    
    Reply with ONLY the number and classification, one per line.
    Example: "1. BUSINESS" or "2. PERSON"
    """
    
    enum ClassificationError: Error {
        case aiNotAvailable
        case invalidResponse
    }
    
    // MARK: - Persistence
    
    private func loadOverrides() {
        if let data = NSUbiquitousKeyValueStore.default.data(forKey: overridesKey),
           let decoded = try? JSONDecoder().decode([String: CounterpartyType].self, from: data) {
            manualOverrides = decoded
        }
    }
    
    private func saveOverrides() {
        if let data = try? JSONEncoder().encode(manualOverrides) {
            NSUbiquitousKeyValueStore.default.set(data, forKey: overridesKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }
    
    private func loadAICache() {
        if let data = UserDefaults.standard.data(forKey: aiCacheKey),
           let decoded = try? JSONDecoder().decode([String: CounterpartyType].self, from: data) {
            aiCache = decoded
        }
    }
    
    private func saveAICache() {
        if let data = try? JSONEncoder().encode(aiCache) {
            UserDefaults.standard.set(data, forKey: aiCacheKey)
        }
    }
}

// MARK: - Array Extension for Chunking

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
