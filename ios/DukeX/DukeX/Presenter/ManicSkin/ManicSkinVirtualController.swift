import Darwin
import Foundation
import GameController
import UIKit

enum ManicSkinInputMapper {
    static let menuInput = "menu"
    static let toggleAnalogInput = "toggleAnalog"
    static let xboxLeftThumbstick = "xboxLeftThumbstick"
    static let xboxRightThumbstick = "xboxRightThumbstick"

    enum TriggerAxis {
        case left
        case right
    }

    enum CoreButton {
        static let a: UInt32 = 1 << 0
        static let b: UInt32 = 1 << 1
        static let x: UInt32 = 1 << 2
        static let y: UInt32 = 1 << 3
        static let dpadLeft: UInt32 = 1 << 4
        static let dpadUp: UInt32 = 1 << 5
        static let dpadRight: UInt32 = 1 << 6
        static let dpadDown: UInt32 = 1 << 7
        static let back: UInt32 = 1 << 8
        static let start: UInt32 = 1 << 9
        static let white: UInt32 = 1 << 10
        static let black: UInt32 = 1 << 11
        static let leftThumb: UInt32 = 1 << 12
        static let rightThumb: UInt32 = 1 << 13
    }

    private static let buttonMasks: [String: UInt32] = [
        "a": CoreButton.a,
        "b": CoreButton.b,
        "x": CoreButton.x,
        "y": CoreButton.y,
        "l1": CoreButton.white,
        "r1": CoreButton.black,
        "l3": CoreButton.leftThumb,
        "r3": CoreButton.rightThumb,
        "start": CoreButton.start,
        "select": CoreButton.back
    ]

    private static let triggerAxes: [String: TriggerAxis] = [
        "l2": .left,
        "r2": .right
    ]

    private static let digitalDirections: Set<String> = ["up", "down", "left", "right"]

    static func buttonMask(for input: String) -> UInt32? {
        buttonMasks[input]
    }

    static func triggerAxis(for input: String) -> TriggerAxis? {
        triggerAxes[input]
    }

    static func isDigitalDirection(_ input: String) -> Bool {
        digitalDirections.contains(input)
    }

    static func isSpecialLocalInput(_ input: String) -> Bool {
        input == menuInput || input == toggleAnalogInput
    }

    static func thumbstickElement(for inputs: [String: String]) -> String {
        inputs.values.contains { $0.hasPrefix("rightThumbstick") } ?
            xboxRightThumbstick :
            xboxLeftThumbstick
    }
}

final class ManicSkinVirtualControllerBridge {
    private typealias SetTouchControllerState = @convention(c) (
        CInt,
        UInt32,
        Int16,
        Int16,
        Int16,
        Int16,
        Int16,
        Int16
    ) -> Void

    private var setTouchControllerState: SetTouchControllerState?
    private var setTouchControllerStateGeneration: UInt64?
    private var activeDigitalDirections = Set<String>()
    private var activeButtonInputs = Set<String>()
    private var touchControlsActive = false
    private var leftTrigger: Int16 = 0
    private var rightTrigger: Int16 = 0
    private var leftThumbstick = CGPoint.zero
    private var rightThumbstick = CGPoint.zero
    private var didLogMissingCoreSymbol = false
    private let publishesToCore: Bool

    init(publishesToCore: Bool = true) {
        self.publishesToCore = publishesToCore
    }

    func setTouchControlsActive(_ active: Bool) {
        NativeMetalDiagnostics.log("TOUCH_BRIDGE_ACTIVE", "active=\(active ? 1 : 0)")
        touchControlsActive = active
        if !active {
            resetLocalState()
        }
        publishState()
    }

    func hasPhysicalControllerConnected() -> Bool {
        GCController.controllers().contains { controller in
            if isVirtualController(controller) {
                return false
            }
            return controller.extendedGamepad != nil || controller.microGamepad != nil
        }
    }

    func isManagedVirtualController(_ controller: GCController) -> Bool {
        false
    }

    func setButtonInput(_ input: String, pressed: Bool) {
        if ManicSkinInputMapper.isSpecialLocalInput(input) {
            return
        }

        if ManicSkinInputMapper.isDigitalDirection(input) {
            setDigitalDirection(input, pressed: pressed)
            return
        }

        if let triggerAxis = ManicSkinInputMapper.triggerAxis(for: input) {
            setTrigger(triggerAxis, pressed: pressed)
            return
        }

        guard ManicSkinInputMapper.buttonMask(for: input) != nil else {
            return
        }

        if pressed {
            activeButtonInputs.insert(input)
        } else {
            activeButtonInputs.remove(input)
        }
        publishState()
    }

    func setThumbstick(element: String, position: CGPoint) {
        if element == ManicSkinInputMapper.xboxLeftThumbstick {
            leftThumbstick = position
        } else {
            rightThumbstick = position
        }
        publishState()
    }

    func resetThumbstick(element: String) {
        setThumbstick(element: element, position: .zero)
    }

    func releaseAllInputs() {
        resetLocalState()
        publishState()
    }

    private func setDigitalDirection(_ input: String, pressed: Bool) {
        if pressed {
            activeDigitalDirections.insert(input)
        } else {
            activeDigitalDirections.remove(input)
        }
        publishState()
    }

    private func setTrigger(_ triggerAxis: ManicSkinInputMapper.TriggerAxis, pressed: Bool) {
        let value: Int16 = pressed ? 32767 : 0
        switch triggerAxis {
        case .left:
            leftTrigger = value
        case .right:
            rightTrigger = value
        }
        publishState()
    }

    private func resetLocalState() {
        activeButtonInputs.removeAll()
        activeDigitalDirections.removeAll()
        leftTrigger = 0
        rightTrigger = 0
        leftThumbstick = .zero
        rightThumbstick = .zero
    }

    private func publishState() {
        guard publishesToCore else {
            return
        }

        guard let setter = resolveSetTouchControllerState() else {
            return
        }

        let buttons = currentButtons
        let leftX = axisValue(leftThumbstick.x)
        let leftY = axisValue(leftThumbstick.y)
        let rightX = axisValue(rightThumbstick.x)
        let rightY = axisValue(rightThumbstick.y)
        NativeMetalDiagnostics.log(
            "TOUCH_BRIDGE_STATE",
            "active=\(touchControlsActive ? 1 : 0) buttons=0x\(String(buttons, radix: 16)) lt=\(leftTrigger) rt=\(rightTrigger) lx=\(leftX) ly=\(leftY) rx=\(rightX) ry=\(rightY)"
        )
        setter(
            touchControlsActive ? 1 : 0,
            buttons,
            leftTrigger,
            rightTrigger,
            leftX,
            leftY,
            rightX,
            rightY
        )
    }

    private var currentButtons: UInt32 {
        var buttons: UInt32 = 0
        for input in activeButtonInputs {
            buttons |= ManicSkinInputMapper.buttonMask(for: input) ?? 0
        }
        if activeDigitalDirections.contains("left") {
            buttons |= ManicSkinInputMapper.CoreButton.dpadLeft
        }
        if activeDigitalDirections.contains("up") {
            buttons |= ManicSkinInputMapper.CoreButton.dpadUp
        }
        if activeDigitalDirections.contains("right") {
            buttons |= ManicSkinInputMapper.CoreButton.dpadRight
        }
        if activeDigitalDirections.contains("down") {
            buttons |= ManicSkinInputMapper.CoreButton.dpadDown
        }
        return buttons
    }

    private func axisValue(_ value: CGFloat) -> Int16 {
        let clamped = max(-1, min(1, value))
        let scaled = clamped >= 0 ? clamped * 32767 : clamped * 32768
        let rounded = Int(scaled.rounded())
        return Int16(max(-32768, min(32767, rounded)))
    }

    private func resolveSetTouchControllerState() -> SetTouchControllerState? {
        let currentGeneration = XemuCoreRuntimeSymbolResolver.shared.currentGeneration()
        if let setTouchControllerState,
           setTouchControllerStateGeneration == currentGeneration {
            return setTouchControllerState
        }

        setTouchControllerState = nil
        setTouchControllerStateGeneration = nil

        guard let resolved = XemuCoreRuntimeSymbolResolver.shared.resolve("xemu_ios_set_touch_controller_state") else {
            logMissingCoreSymbol("xemu_ios_set_touch_controller_state is unavailable")
            return nil
        }

        let setter = unsafeBitCast(resolved.symbol, to: SetTouchControllerState.self)
        setTouchControllerState = setter
        setTouchControllerStateGeneration = resolved.generation
        didLogMissingCoreSymbol = false
        NativeMetalDiagnostics.log(
            "TOUCH_BRIDGE_SYMBOL",
            "resolved=1 generation=\(resolved.generation)"
        )
        return setter
    }

    private func logMissingCoreSymbol(_ message: String) {
        guard !didLogMissingCoreSymbol else {
            return
        }

        didLogMissingCoreSymbol = true
        NSLog("Manic skin core input bridge unavailable: %@", message)
        NativeMetalDiagnostics.log("TOUCH_BRIDGE_SYMBOL", "resolved=0 message=\(message)")
    }

    private func isVirtualController(_ controller: GCController) -> Bool {
        let vendorName = controller.vendorName ?? ""
        return vendorName.localizedCaseInsensitiveContains("virtual") ||
            controller.productCategory.localizedCaseInsensitiveContains("virtual")
    }
}
