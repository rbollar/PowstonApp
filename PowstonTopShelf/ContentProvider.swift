//
//  ContentProvider.swift
//  PowstonTopShelf
//
//  TV Top Shelf Extension - displays cached data from main app
//  (Top Shelf extensions have limited network access)
//

import TVServices
import Foundation

class ContentProvider: TVTopShelfContentProvider {
    
    private let appGroupID = "group.com.bollar.powston"
    
    override func loadTopShelfContent() async -> TVTopShelfContent? {
        // Only use cached data - network requests often fail in Top Shelf extensions
        if let cached = loadCachedData() {
            return createContent(from: cached)
        }
        return createPlaceholderContent()
    }
    
    private func createContent(from data: TopShelfData) -> TVTopShelfContent {
        var items: [TVTopShelfSectionedItem] = []
        
        let item = TVTopShelfSectionedItem(identifier: "main")
        item.title = "SOC: \(Int(data.soc))% | Buy: \(formatPrice(data.buyPrice)) | Sell: \(formatPrice(data.sellPrice)) | \(data.action.capitalized)"
        items.append(item)
        
        let section = TVTopShelfItemCollection(items: items)
        section.title = "Powston"
        
        return TVTopShelfSectionedContent(sections: [section])
    }
    
    private func createPlaceholderContent() -> TVTopShelfContent {
        let item = TVTopShelfSectionedItem(identifier: "placeholder")
        item.title = "Open app to load data"
        
        let section = TVTopShelfItemCollection(items: [item])
        section.title = "Powston"
        
        return TVTopShelfSectionedContent(sections: [section])
    }
    
    private func loadCachedData() -> TopShelfData? {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return nil }
        
        let cachedTime = defaults.double(forKey: "topshelf_cached_time")
        guard cachedTime > 0 else { return nil }
        
        // Allow older cache since we can't refresh via network
        let age = Date().timeIntervalSince1970 - cachedTime
        guard age < 3600 else { return nil } // 1 hour cache
        
        return TopShelfData(
            soc: defaults.double(forKey: "topshelf_cached_soc"),
            buyPrice: defaults.double(forKey: "topshelf_cached_buy"),
            sellPrice: defaults.double(forKey: "topshelf_cached_sell"),
            action: defaults.string(forKey: "topshelf_cached_action") ?? "auto"
        )
    }
    
    private func formatPrice(_ cents: Double) -> String {
        if abs(cents) >= 100 {
            return String(format: "$%.2f", cents / 100)
        }
        return String(format: "%.1f¢", cents)
    }
}

struct TopShelfData {
    let soc: Double
    let buyPrice: Double
    let sellPrice: Double
    let action: String
}
