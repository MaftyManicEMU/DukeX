import Darwin
import Foundation
import GameController
import SwiftUI

@main
struct DukeXApp: App {
    @StateObject private var store = EmulatorFileStore()

    init() {
        MetalDiagnostics.configurePerformanceHUD()
        resolveHandle()
        _ = GameControllerBootstrap.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .task {
                    await store.prepareAndRefresh()
                }
        }
    }
}
