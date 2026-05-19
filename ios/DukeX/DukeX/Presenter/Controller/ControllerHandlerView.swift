//
//  ControllerHandler.swift
//  DukeX
//
//  Created by Stossy11 on 16/5/2026.
//

// T##((VirtualControllerButton) -> AnyView, (String, Bool, Binding<Bool>) -> AnyView, Bool) -> View

import SwiftUI
import Melo_Controller


struct XboxControllerView: View {
    let controller = XboxController()
    
    var body: some View {
        ControllerView(controller: controller, isEditing: false) { buttonView, joystickView, isPortrait in
            ControllerHandler(editableButton: buttonView, editableJoystick: joystickView, isPortrait: isPortrait)
        }
        .onAppear() {
            controller.reset()
        }
    }
}


struct ControllerHandler: View {
    var editableButton: (VirtualControllerButton) -> AnyView
    var editableJoystick: (String, Bool, Binding<Bool>) -> AnyView
    var isPortrait: Bool
    @AppStorage("On-ScreenControllerScale") private var controllerScale: Double = 1.0
    @State private var hideDpad = false
    @State private var hideABXY = false
    
    init(editableButton: @escaping (VirtualControllerButton) -> AnyView, editableJoystick: @escaping (String, Bool, Binding<Bool>) -> AnyView, isPortrait: Bool, hideDpad: Bool = false, hideABXY: Bool = false) {
        self.editableButton = editableButton
        self.editableJoystick = editableJoystick
        self.isPortrait = isPortrait
        self.hideDpad = hideDpad
        self.hideABXY = hideABXY
    }
    
    var body: some View {
        if isPortrait {
            portraitLayout
        } else {
            landscapeLayout
        }
    }
    
    private var portraitLayout: some View {
        VStack {
            Spacer()
            VStack(spacing: 20) {
                HStack(spacing: 30) {
                    VStack(spacing: 15) {
                        shoulderButtonsLeft
                        ZStack {
                            editableJoystick("leftJoystick", false, $hideDpad)

                            dpadView
                                .opacity(hideDpad ? 0 : 1)
                                .allowsHitTesting(!hideDpad)
                                .animation(.easeInOut(duration: 0.2), value: hideDpad)
                        }
                    }

                    VStack(spacing: 15) {
                        shoulderButtonsRight
                        ZStack {
                            editableJoystick("rightJoystick", true, $hideABXY)
                            
                            abxyView
                                .opacity(hideABXY ? 0 : 1)
                                .allowsHitTesting(!hideABXY)
                                .animation(.easeInOut(duration: 0.2), value: hideABXY)
                        }
                    }
                }

                HStack(spacing: 60) {
                    HStack {
                        editableButton(.leftStick).padding()
                        editableButton(.back)
                    }
                    HStack {
                        editableButton(.start)
                        editableButton(.rightStick).padding()
                    }
                }
            }
        }
    }

    private var landscapeLayout: some View {
        VStack {
            Spacer()
            HStack {
                VStack(spacing: 20) {
                    shoulderButtonsLeft
                    ZStack {
                        editableJoystick("leftJoystick", false, $hideDpad)
                        
                        dpadView
                            .opacity(hideDpad ? 0 : 1)
                            .allowsHitTesting(!hideDpad)
                            .animation(.easeInOut(duration: 0.2), value: hideDpad)

                    }
                }

                Spacer()
                centerButtons
                Spacer()

                VStack(spacing: 20) {
                    shoulderButtonsRight
                    ZStack {
                        editableJoystick("rightJoystick", true, $hideABXY)
                        abxyView
                            .opacity(hideABXY ? 0 : 1)
                            .allowsHitTesting(!hideABXY)
                            .animation(.easeInOut(duration: 0.2), value: hideABXY)
                    }
                }
            }
        }
    }

    private var centerButtons: some View {
        Group {
            HStack(spacing: 50) {
                editableButton(.back)
                Spacer()
                editableButton(.start)
            }
            .padding(.bottom, 20)
        }
    }

    private var shoulderButtonsLeft: some View {
        HStack(spacing: 20) {
            editableButton(.leftTrigger)
            editableButton(.leftShoulder)
        }
        .frame(width: 160 * CGFloat(controllerScale), height: 20 * CGFloat(controllerScale))
    }

    private var shoulderButtonsRight: some View {
        HStack(spacing: 20) {
            editableButton(.rightShoulder)
            editableButton(.rightTrigger)
        }
        .frame(width: 160 * CGFloat(controllerScale), height: 20 * CGFloat(controllerScale))
    }

    private var dpadView: some View {
        VStack(spacing: 7) {
            editableButton(.dPadUp)
            HStack(spacing: 22) {
                editableButton(.dPadLeft)
                Spacer(minLength: 22)
                editableButton(.dPadRight)
            }
            editableButton(.dPadDown)
        }
        .frame(width: 145 * CGFloat(controllerScale), height: 145 * CGFloat(controllerScale))
    }

    private var abxyView: some View {
        VStack(spacing: 7) {
            editableButton(.Y)
            HStack(spacing: 22) {
                editableButton(.X)
                Spacer(minLength: 22)
                editableButton(.B)
            }
            editableButton(.A)
        }
        .frame(width: 145 * CGFloat(controllerScale), height: 145 * CGFloat(controllerScale))
    }

}
