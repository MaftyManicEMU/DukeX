//
//  XboxController.swift
//  DukeX
//
//  Created by Stossy11 on 16/5/2026.
//

import Foundation
import UIKit
import Melo_Controller
import Darwin

private var xemuHandle: UnsafeMutableRawPointer?

private let _xemu_ios_touch_controller_set_button: (@convention(c) (Int32, Int32) -> Void)? = {
    guard let sym = dlsym(xemuHandle, "xemu_ios_touch_controller_set_button") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (Int32, Int32) -> Void).self)
}()

private let _xemu_ios_touch_controller_set_axis: (@convention(c) (Int32, Int32) -> Void)? = {
    guard let sym = dlsym(xemuHandle, "xemu_ios_touch_controller_set_axis") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) (Int32, Int32) -> Void).self)
}()

private let _xemu_ios_touch_controller_reset: (@convention(c) () -> Void)? = {
    guard let sym = dlsym(xemuHandle, "xemu_ios_touch_controller_reset") else { return nil }
    return unsafeBitCast(sym, to: (@convention(c) () -> Void).self)
}()

private func xemu_ios_touch_controller_set_button(_ mask: Int32, _ pressed: Int32) {
    _xemu_ios_touch_controller_set_button?(mask, pressed)
}

private func xemu_ios_touch_controller_set_axis(_ axis: Int32, _ value: Int32) {
    _xemu_ios_touch_controller_set_axis?(axis, value)
}

private func xemu_ios_touch_controller_reset() {
    _xemu_ios_touch_controller_reset?()
}

private extension VirtualControllerButton {
    var buttonMask: Int32? {
        switch id {
        case "A":              return 1 << 0
        case "B":              return 1 << 1
        case "X":              return 1 << 2
        case "Y":              return 1 << 3
        case "dPadLeft":       return 1 << 4
        case "dPadUp":         return 1 << 5
        case "dPadRight":      return 1 << 6
        case "dPadDown":       return 1 << 7
        case "back":           return 1 << 8
        case "start":          return 1 << 9
        case "leftShoulder":   return 1 << 10  // white
        case "rightShoulder":  return 1 << 11  // black
        case "leftStick":      return 1 << 12
        case "rightStick":     return 1 << 13
        default:               return nil
        }
    }

    var triggerAxisIndex: Int32? {
        switch id {
        case "leftTrigger":  return 0
        case "rightTrigger": return 1
        default:             return nil
        }
    }
}

private enum XboxAxis {
    static let leftX:  Int32 = 2
    static let leftY:  Int32 = 3
    static let rightX: Int32 = 4
    static let rightY: Int32 = 5
}


func resolveHandle() {
    guard let frameworksURL = Bundle.main.privateFrameworksURL else {
        return
    }

    let coreURL = frameworksURL.appendingPathComponent("libxemu-ios-core.dylib")
    guard let handle = dlopen(coreURL.path, RTLD_NOW | RTLD_LOCAL) else {
        return
    }

    xemuHandle = handle
}

final class XboxController: Controller {
    func reset() {
        xemu_ios_touch_controller_reset()
    }

    func buttonPressed(_ button: VirtualControllerButton) {
        if let mask = button.buttonMask {
            xemu_ios_touch_controller_set_button(mask, 1)
        } else if let axis = button.triggerAxisIndex {
            xemu_ios_touch_controller_set_axis(axis, 32_767)
        }
    }

    func buttonReleased(_ button: VirtualControllerButton) {
        if let mask = button.buttonMask {
            xemu_ios_touch_controller_set_button(mask, 0)
        } else if let axis = button.triggerAxisIndex {
            xemu_ios_touch_controller_set_axis(axis, 0)
        }
    }

    func joystickMoved(position: CGPoint, right: Bool) {
        let xValue = Int32((position.x * 32_767).clamped(to: -32_767...32_767))
        let yValue = Int32((-position.y * 32_767).clamped(to: -32_767...32_767))

        if right {
            xemu_ios_touch_controller_set_axis(XboxAxis.rightX, xValue)
            xemu_ios_touch_controller_set_axis(XboxAxis.rightY, yValue)
        } else {
            xemu_ios_touch_controller_set_axis(XboxAxis.leftX, xValue)
            xemu_ios_touch_controller_set_axis(XboxAxis.leftY, yValue)
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.max(range.lowerBound, Swift.min(range.upperBound, self))
    }
}
