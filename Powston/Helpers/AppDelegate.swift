//
//  AppDelegate.swift
//  Powston
//

import UIKit

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.portrait
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}

// MARK: - Orientation Manager
class OrientationManager: ObservableObject {
    static let shared = OrientationManager()
    
    @Published var isLandscapeAllowed = false
    
    func allowLandscape() {
        isLandscapeAllowed = true
        AppDelegate.orientationLock = .allButUpsideDown
    }
    
    func lockToPortrait() {
        isLandscapeAllowed = false
        AppDelegate.orientationLock = .portrait
        
        // Force rotation back to portrait if currently in landscape
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
        }
    }
}
