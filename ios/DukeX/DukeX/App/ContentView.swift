//
//  ContentView.swift
//  DukeX
//
//  Created by Stossy11 on 19/5/2026.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: EmulatorFileStore
    @StateObject private var runtime = EmulatorCoreRuntime()
    
    var body: some View {
        switch store.playingState {
        case .none:
            MainTabView(runtime: runtime)
        case .running(let plan):
            MetalPresenterView(plan: plan, runtime: runtime) {
                store.playingState = .none
            }
        }
    }
}
