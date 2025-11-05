//
//  AvoCamApp.swift
//  AvoCam
//
//  Main application entry point
//

import SwiftUI

@main
struct AvoCamApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .onAppear {
                    coordinator.start()
                }
                .onDisappear {
                    coordinator.stop()
                }
        }
    }
}
