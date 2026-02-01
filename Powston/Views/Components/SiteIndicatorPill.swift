//
//  SiteIndicatorPill.swift
//  Powston
//
//  Tappable pill that shows current site and allows switching between sites
//  Only visible when single site mode is OFF and multiple sites exist
//

import SwiftUI

struct SiteIndicatorPill: View {
    @EnvironmentObject var api: PowstonAPI
    @AppStorage("single_site_mode") private var singleSiteMode: Bool = false
    @State private var showingSitePicker = false
    
    var body: some View {
        // Only show if multi-site mode is active (not single site mode AND has multiple sites)
        if !singleSiteMode && api.sites.count > 1, let site = api.selectedSite {
            Button(action: { showingSitePicker = true }) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                    Text(site.displayName ?? site.name)
                        .font(.caption)
                        .fontWeight(.medium)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.15))
                .foregroundColor(.blue)
                .cornerRadius(12)
            }
            .confirmationDialog("Select Site", isPresented: $showingSitePicker, titleVisibility: .visible) {
                ForEach(api.sites) { s in
                    Button(s.displayName ?? s.name) {
                        switchToSite(s)
                    }
                }
                Button("Cancel", role: .cancel) { }
            }
        }
    }
    
    private func switchToSite(_ site: Site) {
        // Don't switch if already on this site
        guard site.id != api.selectedSite?.id else { return }
        
        // Find lead inverter for this site (primary or first available)
        let siteInverters = api.inverters.filter { $0.siteId == site.id }
        let leadInverter = siteInverters.first(where: { $0.id == site.primaryInverterId }) 
            ?? siteInverters.first
        
        guard let inverter = leadInverter else { return }
        
        // Update selection
        api.selectedInverterId = inverter.id
        api.clearMeterRecordsCache()
        
        // Notify views to refresh their data
        NotificationCenter.default.post(name: .siteDidChange, object: site.id)
        
        // Fetch fresh data for new site
        Task {
            await api.fetchData()
        }
    }
}
