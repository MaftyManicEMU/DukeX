//
//  MetalPresenterView.swift
//  DukeX
//
//  Created by Stossy11 on 19/5/2026.
//

import SwiftUI

struct MetalPresenterView: View {
    @State var showingExitOverlay = false
    @ObservedObject var runtime: EmulatorCoreRuntime
    let session: NativeMetalPresenterSession
    let plan: XemuLaunchPlan
    let onExitRequest: () -> Void

    init(plan: XemuLaunchPlan, runtime: EmulatorCoreRuntime, onExitRequested: @escaping () -> Void) {
        self.session = NativeMetalPresenterSession(
            title: plan.gameName,
            isDashboard: plan.isDashboard
        )
        self.runtime = runtime
        self.plan = plan
        self.onExitRequest = onExitRequested
    }

    var body: some View {
        ZStack {
            NativeMetalPresenterViewRepresenable { layerPtr in
                self.runtime.launch(plan: plan, layer: layerPtr)
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    Button { showingExitOverlay = true } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 0.5))
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 2)
                    }
                    .padding(.leading, 14)
                    .padding(.top, 12)
                    Spacer()
                }
                Spacer()
            }
            .ignoresSafeArea(edges: .all)
            
            XboxControllerView()
        }
        .ignoresSafeArea()
        .onDisappear {
            
        }
        .gameplayExitOverlay(isPresented: $showingExitOverlay, session: session, onExitRequested: onExitRequest)
    }
}
