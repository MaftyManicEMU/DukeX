//
//  ExitOverlayView.swift
//  DukeX
//
//  Created by Stossy11 on 19/5/2026.
//

import SwiftUI

extension NativeMetalPresenterSession {
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "the running game" : trimmed
    }
}

struct GameplayExitOverlayView: View {
    let session: NativeMetalPresenterSession
    let onExitRequested: () -> Void
    
    @Binding var isPresented: Bool
    
    @State private var exitHasBeenRequested = false
    
    private var titleText: String {
        if exitHasBeenRequested { return "Exiting..." }
        return session.isDashboard ? "Exit Dashboard?" : "Exit Gameplay?"
    }
    
    private var messageText: String {
        if exitHasBeenRequested {
            return session.isDashboard
            ? "Stopping the dashboard and returning to Games."
            : "Stopping \(session.displayTitle) and returning to Games."
        }
        return session.isDashboard
        ? "DukeX will stop the dashboard and return to the Games tab."
        : "DukeX will stop \(session.displayTitle) and return to the Games tab. Unsaved progress may be lost."
    }
    
    private var exitButtonTitle: String {
        if exitHasBeenRequested { return "Exiting" }
        return session.isDashboard ? "Exit Dashboard" : "Exit Game"
    }
    
    private var accessibilityLabel: String {
        session.isDashboard ? "Exit Dashboard Menu" : "Exit Gameplay Menu"
    }
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture { hide() }
            
            panel
                .padding(.horizontal, 18)
                .frame(maxWidth: 390)
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isModal)
        .transition(.opacity)
    }
    
    
    private var panel: some View {
        VStack(spacing: 12) {
            Text(titleText)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .animation(.default, value: titleText)
            
            Text(messageText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .animation(.default, value: messageText)
            
            exitButtonView
            
            Button(action: hide) {
                Text("Cancel")
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(exitHasBeenRequested)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
    
    @ViewBuilder
    private var exitButtonView: some View {
        Button(action: confirmExit) {
            Text(exitButtonTitle)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
        }
        .buttonStyle(PrimaryButtonStyle(color: exitHasBeenRequested ? .systemGray : .systemRed))
        .disabled(exitHasBeenRequested)
        .animation(.default, value: exitHasBeenRequested)
    }
    
    private func hide() {
        guard !exitHasBeenRequested else { return }
        withAnimation(.easeIn(duration: 0.16)) {
            isPresented = false
        }
    }
    
    private func confirmExit() {
        guard !exitHasBeenRequested else { return }
        exitHasBeenRequested = true
        onExitRequested()
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    let color: UIColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .background(
                Color(color).opacity(configuration.isPressed ? 0.8 : 1),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(.white)
            .background(
                Color.white.opacity(configuration.isPressed ? 0.12 : 0.18),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

extension View {
    func gameplayExitOverlay(
        isPresented: Binding<Bool>,
        session: NativeMetalPresenterSession,
        onExitRequested: @escaping () -> Void
    ) -> some View {
        ZStack {
            self
            if isPresented.wrappedValue {
                GameplayExitOverlayView(
                    session: session,
                    onExitRequested: onExitRequested,
                    isPresented: isPresented
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.18), value: isPresented.wrappedValue)
    }
}

