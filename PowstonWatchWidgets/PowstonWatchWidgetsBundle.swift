//
//  PowstonWatchWidgetsBundle.swift
//  PowstonWatchWidgets
//
//  Created by Rick Bollar on 1/1/26.
//

import WidgetKit
import SwiftUI

@main
struct PowstonWatchWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PowstonWatchWidgets()
        PowstonWatchWidgetsControl()
    }
}
