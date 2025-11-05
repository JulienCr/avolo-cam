//
//  AvoCamApp.swift
//  AvoCam
//
//  Main application entry point
//

import SwiftUI
import UIKit

// App delegate to handle orientation locking
class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock = UIInterfaceOrientationMask.portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }
}

@main
struct AvoCamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .onAppear {
                    coordinator.start()
                    // Ensure portrait orientation
                    lockOrientation(.portrait)
                }
                .onDisappear {
                    coordinator.stop()
                }
        }
    }

    private func lockOrientation(_ orientation: UIInterfaceOrientationMask) {
        AppDelegate.orientationLock = orientation
    }
}
