import AVFoundation
import Foundation
import GameController
import ObjectiveC
import QuartzCore
import UIKit

enum NativeGameplayTouchPhase: Int32 {
    case began = 0
    case moved = 1
    case ended = 2
    case cancelled = 3
}

final class NativeMetalPresenterHost {
    private static weak var activeHost: NativeMetalPresenterHost?
    private static weak var connectedExternalDisplayRootController: NativeMetalExternalDisplayViewController?
    private static weak var connectedExternalDisplayWindow: UIWindow?
    private static let usesEmbeddedApplicationWindowPresenter = false
    private static let usesEmbeddedWindowSubviewPresenter = false
    private static let usesRootTouchCapture = false
    private static let usesTransparentSDLTouchBridge = false
    private static let usesManualWindowFrameNormalization = true
    private static let usesTouchRoutingRefresh = false
    private static let usesTouchProbeGesture = false
    private static let usesGlobalTouchRouter = false
    private static let usesHitTestFallback = true
    private static let usesTouchRecognizerRefresh = false
    private static let usesManicSkinRemountAfterRotation = false
    private static let usesSeparateTouchOverlayWindow = false
    fileprivate static let usesPresenterWindowEventBridge = false
    private static var isStatusBarHiddenForced = false
    private static var statusBarHiddenOverrideClasses: Set<ObjectIdentifier> = []

    private var window: UIWindow?
    private var externalDisplayWindow: UIWindow?
    private var externalDisplayRootController: NativeMetalExternalDisplayViewController?
    private var touchOverlayWindow: NativeMetalTouchOverlayWindow?
    private var touchOverlayRootController: NativeMetalTouchOverlayViewController?
    private var rootController: NativeMetalPresenterViewController?
    private var presenterView: NativeMetalPresenterView?
    private var manicSkinControlsView: ManicSkinTouchControlsView?
    private var exitOverlayView: GameplayExitOverlayView?
    private var exitMenuTapGesture: UITapGestureRecognizer?
    private var controllerInputPollTimer: Timer?
    private var controllerPolledInputs: Set<NativePresenterControllerInput> = []
    private var touchProbeGesture: NativeMetalTouchProbeGestureRecognizer?
    private var presenterLayoutConstraints: [NSLayoutConstraint] = []
    private var manicSkinLayoutConstraints: [NSLayoutConstraint] = []
    private var exitOverlayLayoutConstraints: [NSLayoutConstraint] = []
    private var activePresenterViewportFrame: CGRect?
    private var geometryDisplayLink: CADisplayLink?
    private var lastLoggedGeometry: CGSize = .zero
    private var isSyncingGeometry = false
    private var pendingManicSkinLayoutRefresh = false
    private var lastObservedTouchEventTime: CFTimeInterval = 0
    private var lastNonProbeTouchEventTime: CFTimeInterval = 0
    private var preRoutedWindowTouchEvents: [ObjectIdentifier: CFTimeInterval] = [:]
    private var lastHitTestFallbackPoint: CGPoint?
    private var lastHitTestFallbackScheduleTime: CFTimeInterval = 0
    private var lastThumbstickHitTestFallbackSamples: [Int64: (point: CGPoint, time: CFTimeInterval)] = [:]
    private var hitTestFallbackSequence: Int64 = 0
    private var hitTestFallbackReleaseSequence: Int64 = 0
    private var hitTestFallbackReleaseTokens: [Int64: Int64] = [:]
    private var runLoopTimers: [Timer] = []
    private var windowRemountSequence: Int64 = 0
    private var lastWindowRemountTime: CFTimeInterval = 0
    private var lastObservedSceneBounds: CGRect = .zero
    private var lastTransitionStartTime: CFTimeInterval = 0
    private var transitionGeometryDeferUntil: CFTimeInterval = 0
    private var isDeferredTransitionRefreshScheduled = false
    private var touchRoutingRefreshSequence: Int64 = 0
    private var lastTouchRoutingRefreshTime: CFTimeInterval = 0
    private var touchRecognizerRefreshSequence: Int64 = 0
    private var manicSkinRemountSequence: Int64 = 0
    private var externalDisplayCompatibilityCheckSequence: Int64 = 0
    private var lastManicSkinRemountTime: CFTimeInterval = 0
    private var isEmbeddedPresentation = false
    private var isEmbeddedWindowSubviewPresentation = false
    private weak var embeddedPresentingController: UIViewController?
    private var externalScreenObserverTokens: [NSObjectProtocol] = []

    func start(
        session: NativeMetalPresenterSession,
        onExitRequested: @escaping () -> Void,
        onRestartRequested: @escaping () -> Bool
    ) -> UnsafeMutableRawPointer? {
        guard let scene = Self.activeWindowScene() else {
            NSLog("Native Metal presenter could not find a foreground UIWindowScene")
            return nil
        }
        NativeMetalDiagnostics.start(session: session)
        NativeMetalDiagnostics.log(
            "HOST_START",
            "scene=\(NativeMetalDiagnostics.objectID(scene)) bounds=\(NativeMetalDiagnostics.rect(scene.coordinateSpace.bounds)) orientation=\(scene.interfaceOrientation.rawValue)"
        )
        Self.setStatusBarHiddenForced(true, reason: "host-start")
        lastObservedSceneBounds = scene.coordinateSpace.bounds
        NativeMetalDiagnostics.logWindowSnapshot("before-presenter-start")

        let rootController = NativeMetalPresenterViewController()
        let rootView = NativeMetalPresenterRootView(frame: scene.coordinateSpace.bounds)
        rootView.presenterHost = self
        rootView.onGeometryChanged = { [weak self] reason in
            self?.schedulePresenterLayout(
                reason: "root-\(reason)",
                refreshManicSkinLayout: reason.contains("safe-area")
            )
        }
        rootView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        rootView.isMultipleTouchEnabled = true
        rootView.clipsToBounds = true
        rootController.view = rootView
        rootController.modalPresentationStyle = .fullScreen
        rootController.modalPresentationCapturesStatusBarAppearance = true
        rootController.view.backgroundColor = .black
        rootController.onGeometryChanged = { [weak self] reason in
            self?.handleGeometryChange(reason: reason)
        }

        let presenterView = NativeMetalPresenterView(frame: scene.coordinateSpace.bounds)
        presenterView.translatesAutoresizingMaskIntoConstraints = false
        let tapGesture = UITapGestureRecognizer()
        tapGesture.cancelsTouchesInView = false
        tapGesture.delaysTouchesBegan = false
        tapGesture.delaysTouchesEnded = false
        self.rootController = rootController
        self.presenterView = presenterView
        self.exitMenuTapGesture = tapGesture
        if let externalRootController = Self.connectedExternalDisplayRootController,
           let externalWindow = Self.connectedExternalDisplayWindow {
            activateExternalGameplayDisplay(
                rootController: externalRootController,
                window: externalWindow,
                reason: "start-external-scene"
            )
        } else if let externalScreen = Self.activeExternalGameplayScreen() {
            activateExternalGameplayDisplay(on: externalScreen, reason: "start")
        } else {
            attachPresenterViewToDeviceRoot(reason: "start")
        }
        if Self.usesTouchProbeGesture {
            let touchProbeGesture = NativeMetalTouchProbeGestureRecognizer { [weak self] phase, touches in
                self?.handleTouchProbeGesture(phase: phase, touches: touches)
            }
            touchProbeGesture.cancelsTouchesInView = false
            touchProbeGesture.delaysTouchesBegan = false
            touchProbeGesture.delaysTouchesEnded = false
            touchProbeGesture.requiresExclusiveTouchType = false
            rootController.view.addGestureRecognizer(touchProbeGesture)
            self.touchProbeGesture = touchProbeGesture
        } else {
            NativeMetalDiagnostics.log("TOUCH_PROBE_DISABLED", "reason=direct-uikit-touch-test")
        }
        applyPresenterViewport(nil)

        let portraitSkin = session.manicSkinPortraitURL.flatMap { ManicSkin(baseURL: $0) }
        let landscapeSkin = session.manicSkinLandscapeURL.flatMap { ManicSkin(baseURL: $0) }
        let selectedSkin = portraitSkin ?? landscapeSkin ?? ManicSkin.bundledDefault()
        if let manicSkinControlsView = ManicSkinTouchControlsView(
            skin: selectedSkin,
            portraitSkin: portraitSkin,
            landscapeSkin: landscapeSkin
        ) {
            manicSkinControlsView.translatesAutoresizingMaskIntoConstraints = false
            manicSkinControlsView.onTouchControlsModeChanged = { [weak self] _ in
                self?.handleManicSkinViewportChange(reason: "manicskin-mode")
            }
            manicSkinControlsView.onGameViewportFrameChanged = { [weak self] _ in
                self?.handleManicSkinViewportChange(reason: "manicskin-viewport")
            }
            rootController.view.addSubview(manicSkinControlsView)
            manicSkinLayoutConstraints = [
                manicSkinControlsView.leadingAnchor.constraint(equalTo: rootController.view.leadingAnchor),
                manicSkinControlsView.trailingAnchor.constraint(equalTo: rootController.view.trailingAnchor),
                manicSkinControlsView.topAnchor.constraint(equalTo: rootController.view.topAnchor),
                manicSkinControlsView.bottomAnchor.constraint(equalTo: rootController.view.bottomAnchor),
            ]
            NSLayoutConstraint.activate(manicSkinLayoutConstraints)
            self.manicSkinControlsView = manicSkinControlsView
        }

        let exitOverlayView = GameplayExitOverlayView(
            session: session,
            onExitRequested: onExitRequested,
            onRestartRequested: onRestartRequested
        )
        exitOverlayView.translatesAutoresizingMaskIntoConstraints = false
        rootController.view.addSubview(exitOverlayView)
        exitOverlayLayoutConstraints = [
            exitOverlayView.leadingAnchor.constraint(equalTo: rootController.view.leadingAnchor),
            exitOverlayView.trailingAnchor.constraint(equalTo: rootController.view.trailingAnchor),
            exitOverlayView.topAnchor.constraint(equalTo: rootController.view.topAnchor),
            exitOverlayView.bottomAnchor.constraint(equalTo: rootController.view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(exitOverlayLayoutConstraints)
        tapGesture.addTarget(exitOverlayView, action: #selector(GameplayExitOverlayView.show))
        manicSkinControlsView?.onMenuRequested = { [weak exitOverlayView] in
            exitOverlayView?.show()
        }
        startControllerInputPolling()

        let attachedWindow: UIWindow
        if Self.usesEmbeddedApplicationWindowPresenter,
           let appWindow = attachPresenterToApplicationWindow(
                scene: scene,
                rootController: rootController
           ) {
            attachedWindow = appWindow
            NativeMetalDiagnostics.logWindowSnapshot("after-embedded-presenter", hostWindow: appWindow)
        } else {
            let presenterWindow = NativeMetalPresenterWindow(windowScene: scene)
            presenterWindow.windowLevel = UIWindow.Level(UIWindow.Level.normal.rawValue + 1)
            presenterWindow.backgroundColor = .black
            presenterWindow.rootViewController = rootController
            presenterWindow.presenterHost = self
            presenterWindow.exitOverlayView = exitOverlayView
            presenterWindow.onGeometryChanged = { [weak self] reason in
                self?.schedulePresenterLayout(
                    reason: reason,
                    refreshManicSkinLayout: reason.contains("safe-area")
                )
            }
            presenterWindow.makeKeyAndVisible()
            attachedWindow = presenterWindow
            isEmbeddedPresentation = false
            NativeMetalDiagnostics.log(
                "PRESENTER_ATTACH",
                "mode=separate-window window=\(NativeMetalDiagnostics.objectID(presenterWindow))"
            )
            NativeMetalDiagnostics.logWindowSnapshot("after-make-key", hostWindow: presenterWindow)
        }

        rootController.view.setNeedsLayout()
        rootController.view.layoutIfNeeded()

        self.window = attachedWindow
        self.exitOverlayView = exitOverlayView
        installTouchOverlayWindowIfNeeded(scene: scene, presenterWindow: attachedWindow)
        Self.activeHost = self
        installExternalScreenObservers()
        logExternalDisplayState(reason: "presenter-start")
        scheduleExternalDisplayCompatibilityCheck(reason: "presenter-start")
        if Self.usesGlobalTouchRouter {
            NativeMetalGlobalTouchRouter.shared.activate(host: self)
        } else {
            NativeMetalDiagnostics.log("GLOBAL_ROUTER", "disabled reason=direct-uikit-touch-test")
        }
        startGeometryDisplayLink()
        forcePresenterLayout(reason: "start")

        let layer = presenterView.metalLayer
        NSLog(
            "Native Metal presenter layer=0x%llx drawable=%.0fx%.0f bounds=%.0fx%.0f scale=%.2f device=%@",
            UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())),
            layer.drawableSize.width,
            layer.drawableSize.height,
            layer.bounds.width,
            layer.bounds.height,
            layer.contentsScale,
            layer.device?.name ?? "(nil)"
        )
        return Unmanaged.passUnretained(layer).toOpaque()
    }

    static func handleGameplayTouch(
        phaseRaw: Int32,
        touchID: Int64,
        normalizedX: Float,
        normalizedY: Float
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                Self.handleGameplayTouch(
                    phaseRaw: phaseRaw,
                    touchID: touchID,
                    normalizedX: normalizedX,
                    normalizedY: normalizedY
                )
            }
            return
        }

        activeHost?.handleGameplayTouch(
            phaseRaw: phaseRaw,
            touchID: touchID,
            normalizedX: normalizedX,
            normalizedY: normalizedY
        )
    }

    static func connectExternalDisplayScene(
        rootController: NativeMetalExternalDisplayViewController,
        window: UIWindow,
        reason: String
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                Self.connectExternalDisplayScene(
                    rootController: rootController,
                    window: window,
                    reason: reason
                )
            }
            return
        }

        connectedExternalDisplayRootController = rootController
        connectedExternalDisplayWindow = window
        NSLog(
            "DukeX external display scene connected: %@ window=%@ bounds=%@",
            reason,
            NativeMetalDiagnostics.objectID(window),
            NativeMetalDiagnostics.rect(window.windowScene?.coordinateSpace.bounds ?? window.bounds)
        )
        activeHost?.activateExternalGameplayDisplay(
            rootController: rootController,
            window: window,
            reason: reason
        )
    }

    static func disconnectExternalDisplayScene(
        rootController: NativeMetalExternalDisplayViewController,
        window: UIWindow,
        reason: String
    ) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                Self.disconnectExternalDisplayScene(
                    rootController: rootController,
                    window: window,
                    reason: reason
                )
            }
            return
        }

        if connectedExternalDisplayRootController === rootController {
            connectedExternalDisplayRootController = nil
        }
        if connectedExternalDisplayWindow === window {
            connectedExternalDisplayWindow = nil
        }
        NSLog("DukeX external display scene disconnected: %@", reason)
        activeHost?.deactivateExternalGameplayDisplay(
            rootController: rootController,
            window: window,
            reason: reason
        )
    }

    private func installExternalScreenObservers() {
        guard externalScreenObserverTokens.isEmpty else {
            return
        }

        let center = NotificationCenter.default
        externalScreenObserverTokens.append(
            center.addObserver(
                forName: UIScreen.didConnectNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let screen = notification.object as? UIScreen else {
                    return
                }
                self?.logExternalDisplayState(reason: "screen-connect")
                guard Self.connectedExternalDisplayWindow == nil else {
                    return
                }
                guard Self.canUseScreenForDedicatedExternalDisplay(screen) else {
                    NSLog(
                        "DukeX AirPlay display fallback: mirrored external screen detected; keeping local renderer for system mirroring. %@",
                        Self.screenDiagnosticDescription(screen)
                    )
                    return
                }
                self?.activateExternalGameplayDisplay(on: screen, reason: "screen-connect")
            }
        )
        externalScreenObserverTokens.append(
            center.addObserver(
                forName: UIScreen.didDisconnectNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let screen = notification.object as? UIScreen,
                      self.externalDisplayWindow?.screen === screen else {
                    return
                }
                self.logExternalDisplayState(reason: "screen-disconnect")
                self.deactivateExternalGameplayDisplay(reason: "screen-disconnect")
            }
        )
        externalScreenObserverTokens.append(
            center.addObserver(
                forName: UIScreen.capturedDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.logExternalDisplayState(reason: "screen-captured-change")
                self?.scheduleExternalDisplayCompatibilityCheck(reason: "screen-captured-change")
            }
        )
        externalScreenObserverTokens.append(
            center.addObserver(
                forName: UIScreen.modeDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.logExternalDisplayState(reason: "screen-mode-change")
                self?.scheduleExternalDisplayCompatibilityCheck(reason: "screen-mode-change")
            }
        )
        externalScreenObserverTokens.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleAudioRouteChange(notification)
            }
        )
    }

    private func removeExternalScreenObservers() {
        let center = NotificationCenter.default
        externalScreenObserverTokens.forEach(center.removeObserver)
        externalScreenObserverTokens.removeAll()
    }

    private static func activeExternalGameplayScreen() -> UIScreen? {
        UIScreen.screens.first { canUseScreenForDedicatedExternalDisplay($0) }
    }

    private static func canUseScreenForDedicatedExternalDisplay(_ screen: UIScreen) -> Bool {
        screen !== UIScreen.main && screen.mirrored == nil
    }

    private var isUsingExternalGameplayDisplay: Bool {
        externalDisplayWindow != nil
    }

    private var presenterContainerView: UIView? {
        externalDisplayRootController?.view ?? rootController?.view
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        let reason = Self.audioRouteChangeReasonDescription(notification)
        let previousRoute = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
            .flatMap { $0 as? AVAudioSessionRouteDescription }
            .map(Self.audioRouteDiagnosticDescription) ?? "none"
        NSLog(
            "DukeX audio route changed: %@ current=[%@] previous=[%@]",
            reason,
            Self.audioRouteDiagnosticDescription(AVAudioSession.sharedInstance().currentRoute),
            previousRoute
        )
        logExternalDisplayState(reason: "audio-route-\(reason)")
        scheduleExternalDisplayCompatibilityCheck(reason: "audio-route-\(reason)")
    }

    private func scheduleExternalDisplayCompatibilityCheck(reason: String) {
        externalDisplayCompatibilityCheckSequence += 1
        let sequence = externalDisplayCompatibilityCheckSequence
        for delay in [0.35, 1.25] {
            scheduleMainRunLoopTimer(
                label: "external-display-compat-\(reason)-\(String(format: "%.2f", delay))",
                delay: delay
            ) { [weak self] in
                guard let self,
                      sequence == self.externalDisplayCompatibilityCheckSequence else {
                    return
                }
                self.evaluateExternalDisplayCompatibility(reason: "\(reason)-settled")
            }
        }
    }

    private func evaluateExternalDisplayCompatibility(reason: String) {
        let route = AVAudioSession.sharedInstance().currentRoute
        let airPlayAudioActive = Self.isAirPlayAudioRouteActive(route)
        let usableScreen = Self.activeExternalGameplayScreen()
        let mirroredScreens = UIScreen.screens.filter {
            $0 !== UIScreen.main && $0.mirrored != nil
        }

        logExternalDisplayState(reason: "compat-\(reason)")
        guard airPlayAudioActive else {
            return
        }
        if externalDisplayWindow != nil || Self.connectedExternalDisplayWindow != nil {
            return
        }
        if let usableScreen {
            activateExternalGameplayDisplay(on: usableScreen, reason: "airplay-compat-\(reason)")
            return
        }
        if mirroredScreens.isEmpty == false {
            NSLog(
                "DukeX AirPlay display fallback active: audio route is AirPlay and only mirrored screens are available; keeping local renderer visible for system mirroring."
            )
            return
        }

        NSLog(
            "DukeX AirPlay display warning: audio route is AirPlay but UIKit has not exposed an external display scene or screen. route=[%@] screens=[%@]",
            Self.audioRouteDiagnosticDescription(route),
            Self.screenSnapshotDescription()
        )
    }

    private func logExternalDisplayState(reason: String) {
        let route = AVAudioSession.sharedInstance().currentRoute
        let message =
            "reason=\(reason) airPlayAudio=\(Self.isAirPlayAudioRouteActive(route) ? 1 : 0) " +
            "connectedSceneWindow=\(NativeMetalDiagnostics.objectID(Self.connectedExternalDisplayWindow)) " +
            "activeExternalWindow=\(NativeMetalDiagnostics.objectID(externalDisplayWindow)) " +
            "route=[\(Self.audioRouteDiagnosticDescription(route))] screens=[\(Self.screenSnapshotDescription())]"
        NativeMetalDiagnostics.log("AIRPLAY_DISPLAY", message)
        NSLog("DukeX AirPlay/display state: %@", message)
    }

    private static func audioRouteChangeReasonDescription(_ notification: Notification) -> String {
        guard let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
            return "unknown"
        }

        switch reason {
        case .unknown:
            return "unknown"
        case .newDeviceAvailable:
            return "new-device"
        case .oldDeviceUnavailable:
            return "old-device"
        case .categoryChange:
            return "category-change"
        case .override:
            return "override"
        case .wakeFromSleep:
            return "wake-from-sleep"
        case .noSuitableRouteForCategory:
            return "no-suitable-route"
        case .routeConfigurationChange:
            return "route-config-change"
        @unknown default:
            return "unknown-\(rawReason)"
        }
    }

    private static func isAirPlayAudioRouteActive(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.outputs.contains { output in
            output.portType == .airPlay ||
                output.portName.localizedCaseInsensitiveContains("AirPlay")
        }
    }

    private static func audioRouteDiagnosticDescription(_ route: AVAudioSessionRouteDescription) -> String {
        let inputDescription = route.inputs.map(Self.audioPortDiagnosticDescription).joined(separator: ",")
        let outputDescription = route.outputs.map(Self.audioPortDiagnosticDescription).joined(separator: ",")
        return "inputs={\(inputDescription.isEmpty ? "none" : inputDescription)} outputs={\(outputDescription.isEmpty ? "none" : outputDescription)}"
    }

    private static func audioPortDiagnosticDescription(_ port: AVAudioSessionPortDescription) -> String {
        "\(port.portType.rawValue):\(port.portName)"
    }

    private static func screenSnapshotDescription() -> String {
        UIScreen.screens.enumerated().map { index, screen in
            "s\(index){\(screenDiagnosticDescription(screen))}"
        }.joined(separator: " ")
    }

    private static func screenDiagnosticDescription(_ screen: UIScreen) -> String {
        let mirroredScreen = screen.mirrored.map { mirrored in
            mirrored === UIScreen.main ? "main" : NativeMetalDiagnostics.objectID(mirrored)
        } ?? "nil"
        let currentMode = screen.currentMode.map(Self.screenModeDescription) ?? "nil"
        let preferredMode = screen.preferredMode.map(Self.screenModeDescription) ?? "nil"
        return
            "id=\(NativeMetalDiagnostics.objectID(screen)) " +
            "main=\(screen === UIScreen.main ? 1 : 0) captured=\(screen.isCaptured ? 1 : 0) " +
            "mirrored=\(mirroredScreen) bounds=\(NativeMetalDiagnostics.rect(screen.bounds)) " +
            "native=\(NativeMetalDiagnostics.rect(screen.nativeBounds)) " +
            "scale=\(String(format: "%.2f", screen.scale)) " +
            "nativeScale=\(String(format: "%.2f", screen.nativeScale)) " +
            "maxFPS=\(screen.maximumFramesPerSecond) " +
            "currentMode=\(currentMode) preferredMode=\(preferredMode)"
    }

    private static func screenModeDescription(_ mode: UIScreenMode) -> String {
        String(format: "%.0fx%.0f", mode.size.width, mode.size.height)
    }

    private func moveExitMenuTapGesture(to view: UIView?) {
        guard let exitMenuTapGesture else {
            return
        }
        guard exitMenuTapGesture.view !== view else {
            return
        }

        exitMenuTapGesture.view?.removeGestureRecognizer(exitMenuTapGesture)
        view?.addGestureRecognizer(exitMenuTapGesture)
    }

    private func startControllerInputPolling() {
        guard controllerInputPollTimer == nil else {
            return
        }

        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.pollControllerInput()
        }
        controllerInputPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func pollControllerInput() {
        guard let exitOverlayView else {
            controllerPolledInputs.removeAll()
            return
        }

        let controllers = GCController.controllers().filter(Self.isPhysicalGameControllerForPresenter)
        controllers.forEach(configureRecordButtonSystemGestures)

        let currentInputs = Set(controllers.flatMap(controllerInputsPressed))
        let newlyPressedInputs = currentInputs.subtracting(controllerPolledInputs)
        guard !newlyPressedInputs.isEmpty else {
            controllerPolledInputs = currentInputs
            return
        }

        for input in NativePresenterControllerInput.actionOrder where newlyPressedInputs.contains(input) {
            handleControllerInput(input, exitOverlayView: exitOverlayView)
        }

        controllerPolledInputs = currentInputs
    }

    private func handleControllerInput(
        _ input: NativePresenterControllerInput,
        exitOverlayView: GameplayExitOverlayView
    ) {
        switch input {
        case .exitMenu:
            NativeMetalDiagnostics.log("EXIT_CONTROLLER", "input=exitMenu")
            exitOverlayView.show()
        case .select:
            if exitOverlayView.isMenuVisible {
                NativeMetalDiagnostics.log("EXIT_CONTROLLER", "input=select")
                exitOverlayView.handleControllerInput(.select)
            }
        case .cancel:
            if exitOverlayView.isMenuVisible {
                NativeMetalDiagnostics.log("EXIT_CONTROLLER", "input=cancel")
                exitOverlayView.handleControllerInput(.cancel)
            }
        case .up:
            if exitOverlayView.isMenuVisible {
                exitOverlayView.handleControllerInput(.up)
            }
        case .down:
            if exitOverlayView.isMenuVisible {
                exitOverlayView.handleControllerInput(.down)
            }
        case .left:
            if exitOverlayView.isMenuVisible {
                exitOverlayView.handleControllerInput(.left)
            }
        case .right:
            if exitOverlayView.isMenuVisible {
                exitOverlayView.handleControllerInput(.right)
            }
        }
    }

    private func controllerInputsPressed(on controller: GCController) -> Set<NativePresenterControllerInput> {
        var inputs: Set<NativePresenterControllerInput> = []

        if let gamepad = controller.extendedGamepad {
            if gamepad.buttonA.isPressed || gamepad.buttonA.value >= 0.5 {
                inputs.insert(.select)
            }
            if gamepad.buttonB.isPressed || gamepad.buttonB.value >= 0.5 {
                inputs.insert(.cancel)
            }
            if gamepad.dpad.up.isPressed || gamepad.leftThumbstick.yAxis.value >= 0.65 {
                inputs.insert(.up)
            }
            if gamepad.dpad.down.isPressed || gamepad.leftThumbstick.yAxis.value <= -0.65 {
                inputs.insert(.down)
            }
            if gamepad.dpad.left.isPressed || gamepad.leftThumbstick.xAxis.value <= -0.65 {
                inputs.insert(.left)
            }
            if gamepad.dpad.right.isPressed || gamepad.leftThumbstick.xAxis.value >= 0.65 {
                inputs.insert(.right)
            }
        }

        if let microGamepad = controller.microGamepad {
            if microGamepad.buttonA.isPressed || microGamepad.buttonA.value >= 0.5 {
                inputs.insert(.select)
            }
            if microGamepad.buttonX.isPressed || microGamepad.buttonX.value >= 0.5 {
                inputs.insert(.cancel)
            }
            if microGamepad.dpad.up.isPressed {
                inputs.insert(.up)
            }
            if microGamepad.dpad.down.isPressed {
                inputs.insert(.down)
            }
            if microGamepad.dpad.left.isPressed {
                inputs.insert(.left)
            }
            if microGamepad.dpad.right.isPressed {
                inputs.insert(.right)
            }
        }

        if recordButtonPressed(on: controller) {
            inputs.insert(.exitMenu)
        }

        return inputs
    }

    private func recordButtonPressed(on controller: GCController) -> Bool {
        if let button = controller.physicalInputProfile.buttons[GCInputButtonShare],
           Self.isPressed(button) {
            return true
        }

        return controller.physicalInputProfile.buttons.contains { name, button in
            Self.isRecordButtonCandidate(name: name, button: button) && Self.isPressed(button)
        }
    }

    private func configureRecordButtonSystemGestures(on controller: GCController) {
        if let button = controller.physicalInputProfile.buttons[GCInputButtonShare] {
            button.preferredSystemGestureState = .disabled
        }

        for (name, button) in controller.physicalInputProfile.buttons where Self.isRecordButtonCandidate(name: name, button: button) {
            button.preferredSystemGestureState = .disabled
        }
    }

    private static func isRecordButtonCandidate(name: String, button: GCControllerButtonInput) -> Bool {
        let descriptors = [
            name,
            button.localizedName,
            button.unmappedLocalizedName,
            button.sfSymbolsName,
            button.unmappedSfSymbolsName
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")

        return descriptors.contains("share") ||
            descriptors.contains("record") ||
            descriptors.contains("capture")
    }

    private static func isPressed(_ button: GCControllerButtonInput?) -> Bool {
        guard let button else {
            return false
        }
        return button.isPressed || button.value >= 0.5
    }

    private static func isPhysicalGameControllerForPresenter(_ controller: GCController) -> Bool {
        guard !isVirtualControllerForPresenter(controller) else {
            return false
        }
        return controller.extendedGamepad != nil || controller.microGamepad != nil
    }

    private static func isVirtualControllerForPresenter(_ controller: GCController) -> Bool {
        let vendorName = controller.vendorName ?? ""
        return vendorName.localizedCaseInsensitiveContains("virtual") ||
            controller.productCategory.localizedCaseInsensitiveContains("virtual")
    }

    private func attachPresenterViewToDeviceRoot(reason: String) {
        guard let rootView = rootController?.view,
              let presenterView else {
            return
        }

        NSLayoutConstraint.deactivate(presenterLayoutConstraints)
        presenterLayoutConstraints.removeAll()
        if presenterView.superview !== rootView {
            presenterView.removeFromSuperview()
            rootView.insertSubview(presenterView, at: 0)
        }
        moveExitMenuTapGesture(to: presenterView)
        activePresenterViewportFrame = nil
        NativeMetalDiagnostics.log(
            "EXTERNAL_DISPLAY_DETACH",
            "reason=\(reason) presenter=main root=\(NativeMetalDiagnostics.rect(rootView.bounds))"
        )
    }

    private func activateExternalGameplayDisplay(on screen: UIScreen, reason: String) {
        guard Self.connectedExternalDisplayWindow == nil else {
            return
        }
        guard screen !== UIScreen.main else {
            return
        }
        if externalDisplayWindow?.screen === screen {
            layoutExternalDisplayWindowIfNeeded(reason: reason)
            return
        }

        let externalRootController = NativeMetalExternalDisplayViewController()
        externalRootController.view.frame = screen.bounds
        externalRootController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let externalWindow = UIWindow(frame: screen.bounds)
        externalWindow.screen = screen
        externalWindow.backgroundColor = .black
        externalWindow.rootViewController = externalRootController
        externalWindow.windowLevel = .normal

        activateExternalGameplayDisplay(
            rootController: externalRootController,
            window: externalWindow,
            reason: reason
        )
    }

    private func activateExternalGameplayDisplay(
        rootController externalRootController: NativeMetalExternalDisplayViewController,
        window externalWindow: UIWindow,
        reason: String
    ) {
        guard let presenterView,
              let rootView = rootController?.view else {
            return
        }
        if externalDisplayWindow === externalWindow,
           externalDisplayRootController === externalRootController,
           presenterView.superview === externalRootController.view {
            layoutExternalDisplayWindowIfNeeded(reason: reason)
            presenterView.refreshDrawableSize()
            return
        }

        NSLayoutConstraint.deactivate(presenterLayoutConstraints)
        presenterLayoutConstraints.removeAll()
        presenterView.removeFromSuperview()

        if let currentExternalWindow = externalDisplayWindow,
           currentExternalWindow !== externalWindow {
            currentExternalWindow.isHidden = true
            currentExternalWindow.rootViewController = nil
        }

        externalRootController.view.addSubview(presenterView)
        externalRootController.setGameplayActive(true)
        externalDisplayRootController = externalRootController
        externalDisplayWindow = externalWindow
        moveExitMenuTapGesture(to: rootView)
        activePresenterViewportFrame = nil

        externalWindow.isHidden = false
        applyPresenterViewport(nil)
        layoutExternalDisplayWindowIfNeeded(reason: reason)
        pendingManicSkinLayoutRefresh = true
        manicSkinControlsView?.refreshLayoutForGeometryChange(forceRebuild: true)
        presenterView.refreshDrawableSize()

        NativeMetalDiagnostics.log(
            "EXTERNAL_DISPLAY_ATTACH",
            "reason=\(reason) screen=\(NativeMetalDiagnostics.rect(externalWindow.windowScene?.coordinateSpace.bounds ?? externalWindow.screen.bounds)) scale=\(String(format: "%.2f", externalWindow.screen.scale)) window=\(NativeMetalDiagnostics.objectID(externalWindow)) scene=\(NativeMetalDiagnostics.objectID(externalWindow.windowScene))"
        )
        NSLog(
            "DukeX external gameplay display attached: %@ window=%@ scene=%@",
            reason,
            NativeMetalDiagnostics.objectID(externalWindow),
            NativeMetalDiagnostics.objectID(externalWindow.windowScene)
        )
    }

    private func deactivateExternalGameplayDisplay(reason: String) {
        guard externalDisplayWindow != nil else {
            return
        }

        let oldWindow = externalDisplayWindow
        let isConnectedSceneWindow = oldWindow != nil && Self.connectedExternalDisplayWindow === oldWindow
        oldWindow?.isHidden = isConnectedSceneWindow ? false : true
        if isConnectedSceneWindow == false {
            oldWindow?.rootViewController = nil
        } else if let externalDisplayRootController {
            externalDisplayRootController.setGameplayActive(false)
        }
        externalDisplayRootController = nil
        externalDisplayWindow = nil

        attachPresenterViewToDeviceRoot(reason: reason)
        refreshPresenterViewportForManicSkin(reason: "external-\(reason)")
        forcePresenterLayout(reason: "external-\(reason)")
    }

    private func deactivateExternalGameplayDisplay(
        rootController externalRootController: NativeMetalExternalDisplayViewController,
        window externalWindow: UIWindow,
        reason: String
    ) {
        guard externalDisplayWindow === externalWindow ||
              externalDisplayRootController === externalRootController else {
            return
        }

        deactivateExternalGameplayDisplay(reason: reason)
    }

    private func layoutExternalDisplayWindowIfNeeded(reason: String) {
        guard let externalDisplayWindow,
              let externalRootView = externalDisplayRootController?.view else {
            return
        }

        let screenBounds = externalDisplayWindow.windowScene?.coordinateSpace.bounds ??
            externalDisplayWindow.screen.bounds
        UIView.performWithoutAnimation {
            externalDisplayWindow.frame = screenBounds
            externalDisplayWindow.bounds = CGRect(origin: .zero, size: screenBounds.size)
            externalRootView.frame = externalDisplayWindow.bounds
            externalRootView.bounds = externalDisplayWindow.bounds
            externalDisplayWindow.setNeedsLayout()
            externalRootView.setNeedsLayout()
            externalDisplayWindow.layoutIfNeeded()
            externalRootView.layoutIfNeeded()
        }
        NativeMetalDiagnostics.log(
            "EXTERNAL_DISPLAY_LAYOUT",
            "reason=\(reason) frame=\(NativeMetalDiagnostics.rect(externalDisplayWindow.frame)) root=\(NativeMetalDiagnostics.rect(externalRootView.bounds))"
        )
    }

    private func startGeometryDisplayLink() {
        guard geometryDisplayLink == nil else {
            return
        }

        let displayLink = CADisplayLink(target: self, selector: #selector(handleGeometryDisplayLink(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 2, maximum: 10, preferred: 5)
        displayLink.add(to: .main, forMode: .common)
        geometryDisplayLink = displayLink
    }

    @objc private func handleGeometryDisplayLink(_ displayLink: CADisplayLink) {
        NativeMetalDiagnostics.logHeartbeat(host: self)
        syncPresenterGeometry(reason: "display-link")
    }

    private func handleGeometryChange(reason: String) {
        NativeMetalDiagnostics.log(
            "GEOMETRY_CHANGE",
            "reason=\(reason) root=\(NativeMetalDiagnostics.rect(rootController?.view.bounds ?? .zero)) window=\(NativeMetalDiagnostics.rect(window?.bounds ?? .zero))"
        )
        switch reason {
        case "transition-start":
            lastTransitionStartTime = CACurrentMediaTime()
            scheduleDeferredTransitionGeometryRefresh(reason: reason, extendDeferral: true)
            scheduleTouchRecognizerRefresh(reason: reason, delay: 0.34)
        case "transition-end", "safe-area":
            schedulePresenterLayout(reason: reason, refreshManicSkinLayout: true)
            if reason == "transition-end" {
                NativeMetalDiagnostics.log(
                    "WINDOW_REMOUNT_SUPPRESSED",
                    "reason=\(reason) action=in-place-geometry-sync"
                )
                scheduleMainRunLoopTimer(label: "\(reason)-in-place-geometry", delay: 0.08) { [weak self] in
                    self?.forcePresenterLayout(reason: "\(reason)-in-place-geometry")
                }
                scheduleTouchRoutingRefresh(reason: reason, delay: 0.14)
            }
        default:
            syncPresenterGeometry(reason: reason)
        }
    }

    private func schedulePresenterWindowRemount(reason: String, delay: TimeInterval) {
        let now = CACurrentMediaTime()
        guard now - lastWindowRemountTime > 0.75 else {
            NativeMetalDiagnostics.log(
                "WINDOW_REMOUNT_SKIP",
                "reason=\(reason) cooldown=\(String(format: "%.3f", now - lastWindowRemountTime))"
            )
            return
        }

        windowRemountSequence += 1
        let sequence = windowRemountSequence
        lastWindowRemountTime = now
        NativeMetalDiagnostics.log(
            "WINDOW_REMOUNT_SCHEDULE",
            "id=\(sequence) reason=\(reason) delay=\(String(format: "%.3f", delay)) window=\(NativeMetalDiagnostics.objectID(window))"
        )
        scheduleMainRunLoopTimer(label: "window-remount-\(sequence)", delay: delay) { [weak self] in
            self?.remountPresenterWindow(reason: reason, sequence: sequence)
        }
    }

    private func remountPresenterWindow(reason: String, sequence: Int64) {
        guard let oldWindow = window as? NativeMetalPresenterWindow,
              let scene = oldWindow.windowScene,
              let rootController else {
            NativeMetalDiagnostics.log(
                "WINDOW_REMOUNT_CANCEL",
                "id=\(sequence) reason=\(reason) oldWindow=\(NativeMetalDiagnostics.objectID(window)) root=\(rootController == nil ? 0 : 1)"
            )
            return
        }

        let sceneBounds = scene.coordinateSpace.bounds
        NativeMetalDiagnostics.log(
            "WINDOW_REMOUNT_START",
            "id=\(sequence) reason=\(reason) old=\(NativeMetalDiagnostics.objectID(oldWindow)) frame=\(NativeMetalDiagnostics.rect(oldWindow.frame)) bounds=\(NativeMetalDiagnostics.rect(oldWindow.bounds)) scene=\(NativeMetalDiagnostics.rect(sceneBounds))"
        )

        oldWindow.onGeometryChanged = nil
        oldWindow.presenterHost = nil
        oldWindow.exitOverlayView = nil

        let newWindow = NativeMetalPresenterWindow(windowScene: scene)
        newWindow.windowLevel = oldWindow.windowLevel
        newWindow.backgroundColor = oldWindow.backgroundColor
        newWindow.frame = sceneBounds
        newWindow.bounds = CGRect(origin: .zero, size: sceneBounds.size)
        newWindow.presenterHost = self
        newWindow.exitOverlayView = exitOverlayView
        newWindow.onGeometryChanged = { [weak self] reason in
            self?.schedulePresenterLayout(
                reason: "remount-\(reason)",
                refreshManicSkinLayout: reason.contains("safe-area")
            )
        }

        oldWindow.isHidden = true
        oldWindow.rootViewController = nil
        newWindow.rootViewController = rootController
        window = newWindow
        newWindow.makeKeyAndVisible()
        pendingManicSkinLayoutRefresh = true
        forcePresenterLayout(reason: "window-remount-\(reason)")
        NativeMetalDiagnostics.logWindowSnapshot("after-window-remount-\(sequence)", hostWindow: newWindow)
        NativeMetalDiagnostics.log(
            "WINDOW_REMOUNT_END",
            "id=\(sequence) new=\(NativeMetalDiagnostics.objectID(newWindow)) key=\(newWindow.isKeyWindow ? 1 : 0) frame=\(NativeMetalDiagnostics.rect(newWindow.frame)) bounds=\(NativeMetalDiagnostics.rect(newWindow.bounds))"
        )
    }

    private func attachPresenterToApplicationWindow(
        scene: UIWindowScene,
        rootController: NativeMetalPresenterViewController
    ) -> UIWindow? {
        let hostWindow = scene.windows.first { candidateWindow in
            candidateWindow.isKeyWindow && Self.isApplicationHostWindow(candidateWindow)
        } ?? scene.windows.first { candidateWindow in
            !candidateWindow.isHidden && Self.isApplicationHostWindow(candidateWindow)
        } ?? scene.windows.first { candidateWindow in
            Self.isApplicationHostWindow(candidateWindow)
        }

        guard let hostWindow,
              let rootHostController = hostWindow.rootViewController else {
            NativeMetalDiagnostics.log(
                "PRESENTER_ATTACH_FAIL",
                "mode=embedded reason=no-application-window windows=\(scene.windows.count)"
            )
            return nil
        }

        let presentingController = Self.topMostViewController(from: rootHostController)
        isEmbeddedPresentation = true
        embeddedPresentingController = presentingController
        window = hostWindow
        if Self.installStatusBarHiddenOverrideIfNeeded(for: rootHostController) {
            NativeMetalDiagnostics.log(
                "STATUS_BAR_OWNER_OVERRIDE",
                "reason=embedded-root controller=\(type(of: rootHostController))"
            )
        }
        if presentingController !== rootHostController,
           Self.installStatusBarHiddenOverrideIfNeeded(for: presentingController) {
            NativeMetalDiagnostics.log(
                "STATUS_BAR_OWNER_OVERRIDE",
                "reason=embedded-presenter controller=\(type(of: presentingController))"
            )
        }
        rootHostController.setNeedsStatusBarAppearanceUpdate()
        presentingController.setNeedsStatusBarAppearanceUpdate()
        hostWindow.makeKeyAndVisible()
        if Self.usesEmbeddedWindowSubviewPresenter {
            isEmbeddedWindowSubviewPresentation = true
            rootController.view.frame = hostWindow.bounds
            rootController.view.bounds = CGRect(origin: .zero, size: hostWindow.bounds.size)
            rootController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            rootController.view.isUserInteractionEnabled = true
            rootController.view.accessibilityViewIsModal = true
            hostWindow.addSubview(rootController.view)
            hostWindow.bringSubviewToFront(rootController.view)
            NativeMetalDiagnostics.log(
                "PRESENTER_ATTACH",
                "mode=embedded-window-subview window=\(NativeMetalDiagnostics.objectID(hostWindow)) root=\(type(of: rootHostController)) presenter=\(type(of: presentingController)) frame=\(NativeMetalDiagnostics.rect(rootController.view.frame))"
            )
            rootController.view.setNeedsLayout()
            rootController.view.layoutIfNeeded()
            forcePresenterLayout(reason: "embedded-window-subview-attach")
            NativeMetalDiagnostics.logWindowSnapshot("embedded-window-subview-attach", hostWindow: hostWindow)
            return hostWindow
        }
        NativeMetalDiagnostics.log(
            "PRESENTER_ATTACH",
            "mode=embedded window=\(NativeMetalDiagnostics.objectID(hostWindow)) root=\(type(of: rootHostController)) presenter=\(type(of: presentingController))"
        )
        presentingController.present(rootController, animated: false) { [weak self, weak hostWindow] in
            guard let self else {
                return
            }
            NativeMetalDiagnostics.log(
                "PRESENTER_ATTACH_COMPLETE",
                "mode=embedded window=\(NativeMetalDiagnostics.objectID(hostWindow)) root=\(NativeMetalDiagnostics.rect(rootController.view.bounds))"
            )
            self.forcePresenterLayout(reason: "embedded-present-complete")
            if let hostWindow {
                NativeMetalDiagnostics.logWindowSnapshot("embedded-present-complete", hostWindow: hostWindow)
            }
        }

        return hostWindow
    }

    private static func isApplicationHostWindow(_ window: UIWindow) -> Bool {
        let rootName = window.rootViewController.map { String(describing: type(of: $0)) } ?? "nil"
        return !rootName.contains("SDL_uikitviewcontroller") &&
            !rootName.contains("NativeMetalPresenterViewController")
    }

    private static func topMostViewController(from rootController: UIViewController) -> UIViewController {
        var currentController = rootController
        while let presentedController = currentController.presentedViewController {
            currentController = presentedController
        }
        return currentController
    }

    private func schedulePresenterLayout(
        reason: String,
        refreshManicSkinLayout: Bool = false
    ) {
        if shouldDeferTransitionGeometry(reason: reason) {
            if refreshManicSkinLayout {
                pendingManicSkinLayoutRefresh = true
            }
            NativeMetalDiagnostics.log(
                "SCHEDULE_LAYOUT_DEFERRED_BY_TRANSITION",
                "reason=\(reason) refreshSkin=\(refreshManicSkinLayout ? 1 : 0) until=\(String(format: "%.3f", transitionGeometryDeferUntil))"
            )
            scheduleDeferredTransitionGeometryRefresh(reason: "coalesced-\(reason)", extendDeferral: false)
            return
        }

        NativeMetalDiagnostics.log(
            "SCHEDULE_LAYOUT",
            "reason=\(reason) refreshSkin=\(refreshManicSkinLayout ? 1 : 0) syncing=\(isSyncingGeometry ? 1 : 0) pendingSkin=\(pendingManicSkinLayoutRefresh ? 1 : 0)"
        )
        if refreshManicSkinLayout {
            pendingManicSkinLayoutRefresh = true
        }

        guard !isSyncingGeometry else {
            return
        }

        forcePresenterLayout(reason: reason)
        scheduleMainRunLoopTimer(label: "\(reason)-async", delay: 0.001) { [weak self] in
            self?.forcePresenterLayout(reason: "\(reason)-async")
        }
        scheduleMainRunLoopTimer(label: "\(reason)-settled", delay: 0.15) { [weak self] in
            self?.forcePresenterLayout(reason: "\(reason)-settled")
        }
    }

    private func shouldDeferTransitionGeometry(reason: String) -> Bool {
        guard !reason.hasPrefix("deferred-transition") else {
            return false
        }

        return reason == "transition-start" || CACurrentMediaTime() < transitionGeometryDeferUntil
    }

    private func scheduleDeferredTransitionGeometryRefresh(
        reason: String,
        extendDeferral: Bool
    ) {
        let now = CACurrentMediaTime()
        if extendDeferral || transitionGeometryDeferUntil <= now {
            transitionGeometryDeferUntil = max(transitionGeometryDeferUntil, now + 0.24)
        }
        pendingManicSkinLayoutRefresh = true
        NativeMetalDiagnostics.log(
            "TRANSITION_GEOMETRY_DEFER",
            "reason=\(reason) extend=\(extendDeferral ? 1 : 0) scheduled=\(isDeferredTransitionRefreshScheduled ? 1 : 0) until=\(String(format: "%.3f", transitionGeometryDeferUntil)) window=\(NativeMetalDiagnostics.objectID(window))"
        )

        guard !isDeferredTransitionRefreshScheduled else {
            return
        }

        isDeferredTransitionRefreshScheduled = true
        scheduleMainRunLoopTimer(label: "deferred-transition-layout", delay: 0.24) { [weak self] in
            self?.forcePresenterLayout(reason: "deferred-transition-layout")
        }
        scheduleTouchRoutingRefresh(reason: "deferred-transition", delay: 0.30)
        scheduleMainRunLoopTimer(label: "deferred-transition-settled", delay: 0.42) { [weak self] in
            self?.isDeferredTransitionRefreshScheduled = false
            self?.transitionGeometryDeferUntil = 0
            self?.forcePresenterLayout(reason: "deferred-transition-settled")
            self?.remountManicSkinTouchViewIfEnabled(reason: "deferred-transition-settled")
        }
    }

    private func scheduleTouchRoutingRefresh(reason: String, delay: TimeInterval) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.scheduleTouchRoutingRefresh(reason: reason, delay: delay)
            }
            return
        }

        guard Self.usesTouchRoutingRefresh else {
            NativeMetalDiagnostics.log(
                "TOUCH_ROUTING_REFRESH_SKIP",
                "reason=\(reason) mode=diagnostic-disabled"
            )
            return
        }

        if isEmbeddedPresentation {
            NativeMetalDiagnostics.log(
                "TOUCH_ROUTING_REFRESH_SKIP",
                "reason=\(reason) mode=embedded action=in-place-layout"
            )
            scheduleMainRunLoopTimer(label: "embedded-touch-routing-\(reason)", delay: delay) { [weak self] in
                self?.forcePresenterLayout(reason: "embedded-touch-routing-\(reason)")
            }
            return
        }

        let now = CACurrentMediaTime()
        guard now - lastTouchRoutingRefreshTime > 0.22 else {
            NativeMetalDiagnostics.log(
                "TOUCH_ROUTING_REFRESH_SKIP",
                "reason=\(reason) cooldown=\(String(format: "%.3f", now - lastTouchRoutingRefreshTime))"
            )
            return
        }

        lastTouchRoutingRefreshTime = now
        touchRoutingRefreshSequence += 1
        let sequence = touchRoutingRefreshSequence
        NativeMetalDiagnostics.log(
            "TOUCH_ROUTING_REFRESH_SCHEDULE",
            "id=\(sequence) reason=\(reason) delay=\(String(format: "%.3f", delay)) window=\(NativeMetalDiagnostics.objectID(window))"
        )
        scheduleMainRunLoopTimer(label: "touch-routing-refresh-\(sequence)", delay: delay) { [weak self] in
            self?.refreshPresenterWindowTouchRouting(reason: reason, sequence: sequence)
        }
    }

    private func refreshPresenterWindowTouchRouting(reason: String, sequence: Int64) {
        guard let window,
              let rootController else {
            NativeMetalDiagnostics.log(
                "TOUCH_ROUTING_REFRESH_CANCEL",
                "id=\(sequence) reason=\(reason) window=\(NativeMetalDiagnostics.objectID(window)) root=\(rootController == nil ? 0 : 1)"
            )
            return
        }

        let rootView = rootController.view
        let previousWindowInteraction = window.isUserInteractionEnabled
        let previousRootInteraction = rootView?.isUserInteractionEnabled ?? true
        NativeMetalDiagnostics.log(
            "TOUCH_ROUTING_REFRESH_START",
            "id=\(sequence) reason=\(reason) key=\(window.isKeyWindow ? 1 : 0) hidden=\(window.isHidden ? 1 : 0) windowInteractive=\(previousWindowInteraction ? 1 : 0) rootInteractive=\(previousRootInteraction ? 1 : 0) frame=\(NativeMetalDiagnostics.rect(window.frame)) bounds=\(NativeMetalDiagnostics.rect(window.bounds)) root=\(NativeMetalDiagnostics.rect(rootView?.bounds ?? .zero)) skin=\(manicSkinControlsView?.isTouchSkinActive == true ? 1 : 0)"
        )

        UIView.performWithoutAnimation {
            window.isUserInteractionEnabled = false
            rootView?.isUserInteractionEnabled = false
            window.setNeedsLayout()
            rootView?.setNeedsLayout()
            window.layoutIfNeeded()
            rootView?.layoutIfNeeded()
        }

        scheduleMainRunLoopTimer(label: "touch-routing-refresh-\(sequence)-restore", delay: 0.001) { [weak self, weak window, weak rootView] in
            guard let self,
                  let window else {
                NativeMetalDiagnostics.log(
                    "TOUCH_ROUTING_REFRESH_CANCEL",
                    "id=\(sequence) reason=\(reason) phase=restore window=0"
                )
                return
            }

            UIView.performWithoutAnimation {
                rootView?.isUserInteractionEnabled = previousRootInteraction
                window.isUserInteractionEnabled = previousWindowInteraction
                window.makeKeyAndVisible()
                window.setNeedsLayout()
                rootView?.setNeedsLayout()
                window.layoutIfNeeded()
                rootView?.layoutIfNeeded()
            }
            self.forcePresenterLayout(reason: "touch-routing-refresh-\(sequence)-\(reason)")
            NativeMetalDiagnostics.log(
                "TOUCH_ROUTING_REFRESH_END",
                "id=\(sequence) reason=\(reason) key=\(window.isKeyWindow ? 1 : 0) hidden=\(window.isHidden ? 1 : 0) windowInteractive=\(window.isUserInteractionEnabled ? 1 : 0) rootInteractive=\(rootView?.isUserInteractionEnabled == true ? 1 : 0) frame=\(NativeMetalDiagnostics.rect(window.frame)) bounds=\(NativeMetalDiagnostics.rect(window.bounds)) root=\(NativeMetalDiagnostics.rect(rootView?.bounds ?? .zero))"
            )
            NativeMetalDiagnostics.logWindowSnapshot("after-touch-routing-refresh-\(sequence)", hostWindow: window)
        }
    }

    private func scheduleTouchRecognizerRefresh(reason: String, delay: TimeInterval) {
        guard Self.usesTouchRecognizerRefresh else {
            NativeMetalDiagnostics.log(
                "TOUCH_RECOGNIZER_REFRESH_SKIP",
                "reason=\(reason) mode=diagnostic-disabled"
            )
            return
        }

        touchRecognizerRefreshSequence += 1
        let sequence = touchRecognizerRefreshSequence
        NativeMetalDiagnostics.log(
            "TOUCH_RECOGNIZER_REFRESH_SCHEDULE",
            "id=\(sequence) reason=\(reason) delay=\(String(format: "%.3f", delay))"
        )
        scheduleMainRunLoopTimer(label: "touch-recognizer-refresh-\(sequence)", delay: delay) { [weak self] in
            self?.refreshTouchRecognizers(reason: reason, sequence: sequence)
        }
    }

    private func refreshTouchRecognizers(reason: String, sequence: Int64) {
        let probeWasEnabled = touchProbeGesture?.isEnabled == true
        let tapWasEnabled = exitMenuTapGesture?.isEnabled == true

        touchProbeGesture?.isEnabled = false
        touchProbeGesture?.isEnabled = probeWasEnabled
        exitMenuTapGesture?.isEnabled = false
        exitMenuTapGesture?.isEnabled = tapWasEnabled

        rootController?.view.isMultipleTouchEnabled = false
        rootController?.view.isMultipleTouchEnabled = true
        manicSkinControlsView?.isMultipleTouchEnabled = false
        manicSkinControlsView?.isMultipleTouchEnabled = true

        NativeMetalDiagnostics.log(
            "TOUCH_RECOGNIZER_REFRESH",
            "id=\(sequence) reason=\(reason) probe=\(probeWasEnabled ? 1 : 0) tap=\(tapWasEnabled ? 1 : 0) root=\(NativeMetalDiagnostics.rect(rootController?.view.bounds ?? .zero)) skinActive=\(manicSkinControlsView?.isTouchSkinActive == true ? 1 : 0)"
        )
    }

    private func remountManicSkinTouchView(reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.remountManicSkinTouchView(reason: reason)
            }
            return
        }

        let now = CACurrentMediaTime()
        guard now - lastManicSkinRemountTime > 0.30 else {
            NativeMetalDiagnostics.log(
                "MANICSKIN_REMOUNT_SKIP",
                "reason=\(reason) cooldown=\(String(format: "%.3f", now - lastManicSkinRemountTime))"
            )
            return
        }

        guard let rootView = rootController?.view,
              let presenterView,
              let manicSkinControlsView else {
            NativeMetalDiagnostics.log(
                "MANICSKIN_REMOUNT_SKIP",
                "reason=\(reason) root=\(rootController?.view == nil ? 0 : 1) presenter=\(self.presenterView == nil ? 0 : 1) skin=\(self.manicSkinControlsView == nil ? 0 : 1)"
            )
            return
        }

        lastManicSkinRemountTime = now
        manicSkinRemountSequence += 1
        let sequence = manicSkinRemountSequence
        NativeMetalDiagnostics.log(
            "MANICSKIN_REMOUNT_START",
            "id=\(sequence) reason=\(reason) skinWindow=\(NativeMetalDiagnostics.objectID(manicSkinControlsView.window)) root=\(NativeMetalDiagnostics.rect(rootView.bounds)) skin=\(NativeMetalDiagnostics.rect(manicSkinControlsView.bounds))"
        )

        UIView.performWithoutAnimation {
            NSLayoutConstraint.deactivate(manicSkinLayoutConstraints)
            manicSkinLayoutConstraints.removeAll()
            manicSkinControlsView.removeFromSuperview()
            if presenterView.superview === rootView {
                rootView.insertSubview(manicSkinControlsView, aboveSubview: presenterView)
            } else {
                rootView.addSubview(manicSkinControlsView)
            }
            if let exitOverlayView {
                rootView.bringSubviewToFront(exitOverlayView)
            }
            manicSkinLayoutConstraints = [
                manicSkinControlsView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                manicSkinControlsView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                manicSkinControlsView.topAnchor.constraint(equalTo: rootView.topAnchor),
                manicSkinControlsView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            ]
            NSLayoutConstraint.activate(manicSkinLayoutConstraints)
            manicSkinControlsView.isMultipleTouchEnabled = false
            manicSkinControlsView.isMultipleTouchEnabled = true
            manicSkinControlsView.setNeedsLayout()
            rootView.setNeedsLayout()
            rootView.layoutIfNeeded()
        }

        manicSkinControlsView.refreshLayoutForGeometryChange(forceRebuild: true)
        refreshPresenterViewportForManicSkin(reason: "manicskin-remount-\(reason)")
        NativeMetalDiagnostics.log(
            "MANICSKIN_REMOUNT_END",
            "id=\(sequence) reason=\(reason) skinWindow=\(NativeMetalDiagnostics.objectID(manicSkinControlsView.window)) root=\(NativeMetalDiagnostics.rect(rootView.bounds)) skin=\(NativeMetalDiagnostics.rect(manicSkinControlsView.bounds)) active=\(manicSkinControlsView.isTouchSkinActive ? 1 : 0)"
        )
    }

    private func remountManicSkinTouchViewIfEnabled(reason: String) {
        guard Self.usesManicSkinRemountAfterRotation else {
            NativeMetalDiagnostics.log(
                "MANICSKIN_REMOUNT_SKIP",
                "reason=\(reason) mode=diagnostic-disabled"
            )
            return
        }

        remountManicSkinTouchView(reason: reason)
    }

    private func installTouchOverlayWindowIfNeeded(scene: UIWindowScene, presenterWindow: UIWindow) {
        guard Self.usesSeparateTouchOverlayWindow else {
            NativeMetalDiagnostics.log("TOUCH_OVERLAY_WINDOW_SKIP", "reason=disabled")
            return
        }

        guard let manicSkinControlsView,
              let exitOverlayView else {
            NativeMetalDiagnostics.log(
                "TOUCH_OVERLAY_WINDOW_SKIP",
                "reason=missing-views skin=\(manicSkinControlsView == nil ? 0 : 1) overlay=\(exitOverlayView == nil ? 0 : 1)"
            )
            return
        }

        let overlayRootView = NativeMetalTouchOverlayRootView(frame: scene.coordinateSpace.bounds)
        overlayRootView.backgroundColor = .clear
        overlayRootView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayRootView.isMultipleTouchEnabled = true
        overlayRootView.onGeometryChanged = { [weak self] reason in
            self?.schedulePresenterLayout(
                reason: "touch-overlay-\(reason)",
                refreshManicSkinLayout: reason.contains("safe-area")
            )
        }

        let overlayController = NativeMetalTouchOverlayViewController()
        overlayController.view = overlayRootView
        overlayController.modalPresentationStyle = .fullScreen
        overlayController.modalPresentationCapturesStatusBarAppearance = true

        let overlayWindow = NativeMetalTouchOverlayWindow(windowScene: scene)
        overlayWindow.windowLevel = UIWindow.Level(presenterWindow.windowLevel.rawValue + 1)
        overlayWindow.backgroundColor = .clear
        overlayWindow.rootViewController = overlayController
        overlayWindow.onGeometryChanged = { [weak self] reason in
            self?.schedulePresenterLayout(
                reason: "touch-overlay-window-\(reason)",
                refreshManicSkinLayout: reason.contains("safe-area")
            )
        }

        NSLayoutConstraint.deactivate(manicSkinLayoutConstraints)
        manicSkinLayoutConstraints.removeAll()
        NSLayoutConstraint.deactivate(exitOverlayLayoutConstraints)
        exitOverlayLayoutConstraints.removeAll()

        manicSkinControlsView.removeFromSuperview()
        exitOverlayView.removeFromSuperview()
        overlayRootView.addSubview(manicSkinControlsView)
        overlayRootView.addSubview(exitOverlayView)
        overlayRootView.bringSubviewToFront(exitOverlayView)

        manicSkinLayoutConstraints = [
            manicSkinControlsView.leadingAnchor.constraint(equalTo: overlayRootView.leadingAnchor),
            manicSkinControlsView.trailingAnchor.constraint(equalTo: overlayRootView.trailingAnchor),
            manicSkinControlsView.topAnchor.constraint(equalTo: overlayRootView.topAnchor),
            manicSkinControlsView.bottomAnchor.constraint(equalTo: overlayRootView.bottomAnchor),
        ]
        exitOverlayLayoutConstraints = [
            exitOverlayView.leadingAnchor.constraint(equalTo: overlayRootView.leadingAnchor),
            exitOverlayView.trailingAnchor.constraint(equalTo: overlayRootView.trailingAnchor),
            exitOverlayView.topAnchor.constraint(equalTo: overlayRootView.topAnchor),
            exitOverlayView.bottomAnchor.constraint(equalTo: overlayRootView.bottomAnchor),
        ]
        NSLayoutConstraint.activate(manicSkinLayoutConstraints + exitOverlayLayoutConstraints)

        touchOverlayRootController = overlayController
        touchOverlayWindow = overlayWindow
        overlayWindow.makeKeyAndVisible()
        overlayRootView.setNeedsLayout()
        overlayRootView.layoutIfNeeded()
        manicSkinControlsView.refreshLayoutForGeometryChange(forceRebuild: true)
        refreshPresenterViewportForManicSkin(reason: "touch-overlay-window")
        NativeMetalDiagnostics.log(
            "TOUCH_OVERLAY_WINDOW_ATTACH",
            "window=\(NativeMetalDiagnostics.objectID(overlayWindow)) presenter=\(NativeMetalDiagnostics.objectID(presenterWindow)) key=\(overlayWindow.isKeyWindow ? 1 : 0) level=\(String(format: "%.1f", overlayWindow.windowLevel.rawValue)) frame=\(NativeMetalDiagnostics.rect(overlayWindow.frame)) bounds=\(NativeMetalDiagnostics.rect(overlayWindow.bounds)) root=\(NativeMetalDiagnostics.rect(overlayRootView.bounds))"
        )
        NativeMetalDiagnostics.logWindowSnapshot("after-touch-overlay-attach", hostWindow: presenterWindow)
    }

    private func removeTouchOverlayWindowForRebuild(reason: String) {
        guard let touchOverlayWindow else {
            return
        }

        NativeMetalDiagnostics.log(
            "TOUCH_OVERLAY_WINDOW_DETACH",
            "reason=\(reason) window=\(NativeMetalDiagnostics.objectID(touchOverlayWindow)) key=\(touchOverlayWindow.isKeyWindow ? 1 : 0) frame=\(NativeMetalDiagnostics.rect(touchOverlayWindow.frame)) bounds=\(NativeMetalDiagnostics.rect(touchOverlayWindow.bounds))"
        )

        NSLayoutConstraint.deactivate(manicSkinLayoutConstraints)
        manicSkinLayoutConstraints.removeAll()
        NSLayoutConstraint.deactivate(exitOverlayLayoutConstraints)
        exitOverlayLayoutConstraints.removeAll()
        manicSkinControlsView?.removeFromSuperview()
        exitOverlayView?.removeFromSuperview()
        touchOverlayWindow.isHidden = true
        touchOverlayWindow.onGeometryChanged = nil
        touchOverlayWindow.rootViewController = nil
        touchOverlayRootController = nil
        self.touchOverlayWindow = nil
    }

    private func rebuildTouchOverlayWindow(reason: String) {
        guard Self.usesSeparateTouchOverlayWindow else {
            NativeMetalDiagnostics.log(
                "TOUCH_OVERLAY_WINDOW_REBUILD_SKIP",
                "reason=\(reason) mode=disabled"
            )
            return
        }

        guard let presenterWindow = window,
              let scene = presenterWindow.windowScene else {
            NativeMetalDiagnostics.log(
                "TOUCH_OVERLAY_WINDOW_REBUILD_SKIP",
                "reason=\(reason) presenter-window=missing"
            )
            return
        }

        NativeMetalDiagnostics.log(
            "TOUCH_OVERLAY_WINDOW_REBUILD_START",
            "reason=\(reason) old=\(NativeMetalDiagnostics.objectID(touchOverlayWindow)) presenter=\(NativeMetalDiagnostics.objectID(presenterWindow)) scene=\(NativeMetalDiagnostics.rect(scene.coordinateSpace.bounds))"
        )
        removeTouchOverlayWindowForRebuild(reason: reason)
        installTouchOverlayWindowIfNeeded(scene: scene, presenterWindow: presenterWindow)
        ensureTouchOverlayWindowIsKey(reason: "touch-overlay-rebuild-\(reason)")
        forcePresenterLayout(reason: "touch-overlay-window-rebuild-\(reason)")
        NativeMetalDiagnostics.log(
            "TOUCH_OVERLAY_WINDOW_REBUILD_END",
            "reason=\(reason) new=\(NativeMetalDiagnostics.objectID(touchOverlayWindow)) key=\(touchOverlayWindow?.isKeyWindow == true ? 1 : 0)"
        )
    }

    private func layoutTouchOverlayWindowIfNeeded(reason: String) {
        guard let touchOverlayWindow,
              let overlayRootView = touchOverlayRootController?.view else {
            return
        }

        touchOverlayWindow.setNeedsLayout()
        touchOverlayWindow.layoutIfNeeded()
        overlayRootView.setNeedsLayout()
        overlayRootView.layoutIfNeeded()
        NativeMetalDiagnostics.log(
            "TOUCH_OVERLAY_LAYOUT",
            "reason=\(reason) key=\(touchOverlayWindow.isKeyWindow ? 1 : 0) frame=\(NativeMetalDiagnostics.rect(touchOverlayWindow.frame)) bounds=\(NativeMetalDiagnostics.rect(touchOverlayWindow.bounds)) root=\(NativeMetalDiagnostics.rect(overlayRootView.bounds))"
        )
    }

    private func ensureTouchOverlayWindowIsKey(reason: String) {
        guard let touchOverlayWindow,
              !touchOverlayWindow.isHidden else {
            return
        }

        guard !touchOverlayWindow.isKeyWindow else {
            return
        }

        NativeMetalDiagnostics.log(
            "TOUCH_OVERLAY_REKEY",
            "reason=\(reason) window=\(NativeMetalDiagnostics.objectID(touchOverlayWindow))"
        )
        touchOverlayWindow.makeKeyAndVisible()
    }

    private func scheduleMainRunLoopTimer(
        label: String,
        delay: TimeInterval,
        _ block: @escaping () -> Void
    ) {
        guard Thread.isMainThread else {
            NativeMetalDiagnostics.log(
                "RUNLOOP_TIMER_DEFER",
                "label=\(label) delay=\(String(format: "%.3f", delay))"
            )
            DispatchQueue.main.async { [weak self] in
                self?.scheduleMainRunLoopTimer(label: label, delay: delay, block)
            }
            return
        }

        var timer: Timer?
        timer = Timer(timeInterval: max(0.001, delay), repeats: false) { [weak self] firedTimer in
            guard let self else {
                NativeMetalDiagnostics.log("RUNLOOP_TIMER_FIRE", "label=\(label) owner=dead")
                return
            }
            self.runLoopTimers.removeAll { $0 === firedTimer }
            NativeMetalDiagnostics.log(
                "RUNLOOP_TIMER_FIRE",
                "label=\(label) delay=\(String(format: "%.3f", delay))"
            )
            block()
        }

        guard let timer else {
            return
        }

        runLoopTimers.append(timer)
        RunLoop.main.add(timer, forMode: .common)
        NativeMetalDiagnostics.log(
            "RUNLOOP_TIMER_SCHEDULE",
            "label=\(label) delay=\(String(format: "%.3f", delay)) active=\(runLoopTimers.count)"
        )
    }

    private func forcePresenterLayout(reason: String) {
        if shouldDeferTransitionGeometry(reason: reason) {
            NativeMetalDiagnostics.log(
                "FORCE_LAYOUT_DEFERRED_BY_TRANSITION",
                "reason=\(reason) until=\(String(format: "%.3f", transitionGeometryDeferUntil))"
            )
            scheduleDeferredTransitionGeometryRefresh(reason: "coalesced-\(reason)", extendDeferral: false)
            return
        }

        guard !isSyncingGeometry else {
            return
        }

        isSyncingGeometry = true
        defer {
            isSyncingGeometry = false
        }

        normalizeEmbeddedPresenterRootFrame(reason: reason)
        rootController?.view.setNeedsLayout()
        rootController?.view.layoutIfNeeded()
        syncPresenterGeometryLocked(reason: reason)
    }

    private func syncPresenterGeometry(reason: String) {
        if shouldDeferTransitionGeometry(reason: reason) {
            NativeMetalDiagnostics.log(
                "SYNC_LAYOUT_DEFERRED_BY_TRANSITION",
                "reason=\(reason) until=\(String(format: "%.3f", transitionGeometryDeferUntil))"
            )
            scheduleDeferredTransitionGeometryRefresh(reason: "coalesced-\(reason)", extendDeferral: false)
            return
        }

        guard !isSyncingGeometry else {
            return
        }

        isSyncingGeometry = true
        defer {
            isSyncingGeometry = false
        }

        syncPresenterGeometryLocked(reason: reason)
    }

    private func syncPresenterGeometryLocked(reason: String) {
        guard let window,
              let presenterView else {
            return
        }

        normalizeEmbeddedPresenterRootFrame(reason: reason)
        let sceneBounds = window.windowScene?.coordinateSpace.bounds
        NativeMetalDiagnostics.log(
            "SYNC_LAYOUT",
            "reason=\(reason) mode=\(isEmbeddedPresentation ? "embedded" : "window") key=\(window.isKeyWindow ? 1 : 0) hidden=\(window.isHidden ? 1 : 0) frame=\(NativeMetalDiagnostics.rect(window.frame)) bounds=\(NativeMetalDiagnostics.rect(window.bounds)) sceneBounds=\(NativeMetalDiagnostics.rect(sceneBounds ?? .zero)) root=\(NativeMetalDiagnostics.rect(rootController?.view.bounds ?? .zero))"
        )
        if let sceneBounds {
            observeSceneBoundsForWindowRemount(sceneBounds, reason: reason)
        }
        if let sceneBounds,
           sceneBounds.width > 1,
           sceneBounds.height > 1,
           !window.frame.isSameFrame(as: sceneBounds) {
            let shouldCorrectFrame = Self.usesManualWindowFrameNormalization
            NativeMetalDiagnostics.log(
                "WINDOW_FRAME_MISMATCH",
                "reason=\(reason) frame=\(NativeMetalDiagnostics.rect(window.frame)) sceneBounds=\(NativeMetalDiagnostics.rect(sceneBounds)) action=\(shouldCorrectFrame ? "correct" : "observe-only")"
            )
            if shouldCorrectFrame {
                UIView.performWithoutAnimation {
                    window.frame = sceneBounds
                    window.bounds = CGRect(origin: .zero, size: sceneBounds.size)
                    rootController?.view.frame = window.bounds
                    rootController?.view.setNeedsLayout()
                    rootController?.view.layoutIfNeeded()
                }
                pendingManicSkinLayoutRefresh = true
                NativeMetalDiagnostics.log(
                    "WINDOW_FRAME_CORRECTED",
                    "reason=\(reason) frame=\(NativeMetalDiagnostics.rect(window.frame)) bounds=\(NativeMetalDiagnostics.rect(window.bounds)) root=\(NativeMetalDiagnostics.rect(rootController?.view.bounds ?? .zero))"
                )
            }
        }
        if window.isHidden {
            NativeMetalDiagnostics.log(
                "WINDOW_REKEY",
                "reason=\(reason) hidden=1 key=\(window.isKeyWindow ? 1 : 0)"
            )
            window.makeKeyAndVisible()
        } else if !window.isKeyWindow {
            if isEmbeddedPresentation {
                NativeMetalDiagnostics.log(
                    "WINDOW_NOT_KEY",
                    "reason=\(reason) hidden=0 mode=embedded action=make-key"
                )
                window.makeKeyAndVisible()
            }
        }

        normalizeSceneWindowFrames(reason: reason)
        layoutExternalDisplayWindowIfNeeded(reason: reason)
        layoutTouchOverlayWindowIfNeeded(reason: reason)
        quarantineSDLUIKitWindows(reason: reason)
        ensureTouchOverlayWindowIsKey(reason: "sync-\(reason)")
        window.setNeedsLayout()
        window.layoutIfNeeded()
        rootController?.view.setNeedsLayout()
        rootController?.view.layoutIfNeeded()
        layoutTouchOverlayWindowIfNeeded(reason: "\(reason)-post-presenter-layout")
        let shouldRefreshManicSkinLayout = pendingManicSkinLayoutRefresh
        pendingManicSkinLayoutRefresh = false
        manicSkinControlsView?.refreshLayoutForGeometryChange(
            forceRebuild: shouldRefreshManicSkinLayout
        )
        refreshPresenterViewportForManicSkin(reason: reason)
        rootController?.view.setNeedsLayout()
        rootController?.view.layoutIfNeeded()
        presenterView.refreshDrawableSize()
        exitOverlayView?.refreshLayoutForGeometryChange()

        let layer = presenterView.metalLayer
        let geometry = CGSize(width: layer.bounds.width, height: layer.bounds.height)
        guard !geometry.isSameSize(as: lastLoggedGeometry) else {
            return
        }

        lastLoggedGeometry = geometry
        NSLog(
            "Native Metal presenter geometry %@ window=%.0fx%.0f root=%.0fx%.0f layer=%.0fx%.0f drawable=%.0fx%.0f scale=%.2f viewport=%@",
            reason,
            window.bounds.width,
            window.bounds.height,
            rootController?.view.bounds.width ?? 0,
            rootController?.view.bounds.height ?? 0,
            layer.bounds.width,
            layer.bounds.height,
            layer.drawableSize.width,
            layer.drawableSize.height,
            layer.contentsScale,
            NSCoder.string(for: activePresenterViewportFrame ?? .zero)
        )
        NativeMetalDiagnostics.logWindowSnapshot("geometry-\(reason)", hostWindow: window)
    }

    private func normalizeEmbeddedPresenterRootFrame(reason: String) {
        guard isEmbeddedPresentation,
              let rootView = rootController?.view else {
            return
        }

        let sceneBounds = window?.windowScene?.coordinateSpace.bounds
        let containerBounds: CGRect
        if let sceneBounds,
           sceneBounds.width > 1,
           sceneBounds.height > 1 {
            containerBounds = CGRect(origin: .zero, size: sceneBounds.size)
        } else {
            containerBounds = rootView.superview?.bounds ?? window?.bounds ?? .zero
        }
        guard containerBounds.width > 1,
              containerBounds.height > 1 else {
            NativeMetalDiagnostics.log(
                "EMBEDDED_ROOT_ALIGN_SKIP",
                "reason=\(reason) container=\(NativeMetalDiagnostics.rect(containerBounds))"
            )
            return
        }

        let targetFrame = CGRect(origin: .zero, size: containerBounds.size)
        let needsFrameCorrection =
            !rootView.frame.isSameFrame(as: targetFrame) ||
            rootView.bounds.origin != .zero ||
            !rootView.bounds.size.isSameSize(as: targetFrame.size)

        guard needsFrameCorrection else {
            return
        }

        UIView.performWithoutAnimation {
            rootView.frame = targetFrame
            rootView.bounds = targetFrame
            rootView.center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
            rootView.setNeedsLayout()
            rootView.layoutIfNeeded()
        }
        pendingManicSkinLayoutRefresh = true
        NativeMetalDiagnostics.log(
            "EMBEDDED_ROOT_ALIGN",
            "reason=\(reason) source=\(sceneBounds == nil ? "container" : "scene") container=\(NativeMetalDiagnostics.rect(containerBounds)) frame=\(NativeMetalDiagnostics.rect(rootView.frame)) bounds=\(NativeMetalDiagnostics.rect(rootView.bounds))"
        )
    }

    private func observeSceneBoundsForWindowRemount(_ sceneBounds: CGRect, reason: String) {
        guard sceneBounds.width > 1, sceneBounds.height > 1,
              !lastObservedSceneBounds.isSameFrame(as: sceneBounds) else {
            return
        }

        let oldBounds = lastObservedSceneBounds
        lastObservedSceneBounds = sceneBounds
        NativeMetalDiagnostics.log(
            "SCENE_BOUNDS_CHANGE",
            "reason=\(reason) old=\(NativeMetalDiagnostics.rect(oldBounds)) new=\(NativeMetalDiagnostics.rect(sceneBounds))"
        )

        guard oldBounds.width > 1, oldBounds.height > 1 else {
            return
        }

        pendingManicSkinLayoutRefresh = true
        if isEmbeddedPresentation {
            NativeMetalDiagnostics.log(
                "EMBEDDED_SCENE_BOUNDS_CHANGE",
                "reason=scene-bounds-\(reason) action=in-place-geometry-sync"
            )
            scheduleMainRunLoopTimer(label: "embedded-scene-bounds-\(reason)-layout", delay: 0.05) { [weak self] in
                self?.forcePresenterLayout(reason: "embedded-scene-bounds-\(reason)-layout")
            }
            scheduleMainRunLoopTimer(label: "embedded-scene-bounds-\(reason)-settled", delay: 0.28) { [weak self] in
                self?.forcePresenterLayout(reason: "embedded-scene-bounds-\(reason)-settled")
                self?.remountManicSkinTouchViewIfEnabled(reason: "embedded-scene-bounds-\(reason)-settled")
            }
            return
        }

        NativeMetalDiagnostics.log(
            "WINDOW_REMOUNT_SUPPRESSED",
            "reason=scene-bounds-\(reason) action=in-place-geometry-sync"
        )
        scheduleMainRunLoopTimer(label: "scene-bounds-\(reason)-in-place-geometry", delay: 0.05) { [weak self] in
            self?.forcePresenterLayout(reason: "scene-bounds-\(reason)-in-place-geometry")
        }
        scheduleMainRunLoopTimer(label: "scene-bounds-\(reason)-settled", delay: 0.28) { [weak self] in
            self?.forcePresenterLayout(reason: "scene-bounds-\(reason)-settled")
            self?.remountManicSkinTouchViewIfEnabled(reason: "scene-bounds-\(reason)-settled")
        }
    }

    private func normalizeSceneWindowFrames(reason: String) {
        guard let window,
              let scene = window.windowScene else {
            return
        }

        let sceneBounds = scene.coordinateSpace.bounds
        guard sceneBounds.width > 1,
              sceneBounds.height > 1 else {
            NativeMetalDiagnostics.log(
                "SCENE_WINDOW_FRAME_SKIP",
                "reason=\(reason) sceneBounds=\(NativeMetalDiagnostics.rect(sceneBounds))"
            )
            return
        }

        guard Self.usesManualWindowFrameNormalization else {
            let mismatches = scene.windows.compactMap { candidateWindow -> String? in
                let needsFrameCorrection =
                    !candidateWindow.frame.isSameFrame(as: sceneBounds) ||
                    candidateWindow.bounds.origin != .zero ||
                    !candidateWindow.bounds.size.isSameSize(as: sceneBounds.size)
                guard needsFrameCorrection else {
                    return nil
                }
                let rootName = candidateWindow.rootViewController.map {
                    String(describing: type(of: $0))
                } ?? "nil"
                return "window=\(NativeMetalDiagnostics.objectID(candidateWindow)) host=\(candidateWindow === window ? 1 : 0) key=\(candidateWindow.isKeyWindow ? 1 : 0) hidden=\(candidateWindow.isHidden ? 1 : 0) root=\(rootName) frame=\(NativeMetalDiagnostics.rect(candidateWindow.frame)) bounds=\(NativeMetalDiagnostics.rect(candidateWindow.bounds))"
            }
            if mismatches.isEmpty == false {
                NativeMetalDiagnostics.log(
                    "SCENE_WINDOW_FRAME_OBSERVE_ONLY",
                    "reason=\(reason) sceneBounds=\(NativeMetalDiagnostics.rect(sceneBounds)) mismatches=[\(mismatches.joined(separator: " | "))]"
                )
            }
            return
        }

        var didNormalize = false
        for candidateWindow in scene.windows {
            let rootName = candidateWindow.rootViewController.map {
                String(describing: type(of: $0))
            } ?? "nil"
            let needsFrameCorrection =
                !candidateWindow.frame.isSameFrame(as: sceneBounds) ||
                candidateWindow.bounds.origin != .zero ||
                !candidateWindow.bounds.size.isSameSize(as: sceneBounds.size)
            guard needsFrameCorrection else {
                continue
            }

            UIView.performWithoutAnimation {
                candidateWindow.frame = sceneBounds
                candidateWindow.bounds = CGRect(origin: .zero, size: sceneBounds.size)
                candidateWindow.rootViewController?.view.frame = candidateWindow.bounds
                candidateWindow.rootViewController?.view.setNeedsLayout()
                candidateWindow.rootViewController?.view.layoutIfNeeded()
                candidateWindow.setNeedsLayout()
                candidateWindow.layoutIfNeeded()
            }
            didNormalize = true
            NativeMetalDiagnostics.log(
                "SCENE_WINDOW_FRAME_CORRECTED",
                "reason=\(reason) window=\(NativeMetalDiagnostics.objectID(candidateWindow)) host=\(candidateWindow === window ? 1 : 0) key=\(candidateWindow.isKeyWindow ? 1 : 0) hidden=\(candidateWindow.isHidden ? 1 : 0) root=\(rootName) frame=\(NativeMetalDiagnostics.rect(candidateWindow.frame)) bounds=\(NativeMetalDiagnostics.rect(candidateWindow.bounds)) sceneBounds=\(NativeMetalDiagnostics.rect(sceneBounds))"
            )
        }

        if didNormalize {
            NativeMetalDiagnostics.logWindowSnapshot(
                "after-scene-window-normalize-\(reason)",
                hostWindow: window
            )
        }
    }

    private func quarantineSDLUIKitWindows(reason: String) {
        guard let window,
              let scene = window.windowScene else {
            return
        }

        var didQuarantine = false
        let quarantineLevel = UIWindow.Level(UIWindow.Level.normal.rawValue - 1)
        for candidateWindow in scene.windows where candidateWindow !== window {
            let rootName = candidateWindow.rootViewController.map {
                String(describing: type(of: $0))
            } ?? "nil"
            guard rootName.contains("SDL_uikitviewcontroller") else {
                continue
            }

            NativeMetalDiagnostics.log(
                "SDL_WINDOW_FOUND",
                "reason=\(reason) window=\(NativeMetalDiagnostics.objectID(candidateWindow)) key=\(candidateWindow.isKeyWindow ? 1 : 0) hidden=\(candidateWindow.isHidden ? 1 : 0) interactive=\(candidateWindow.isUserInteractionEnabled ? 1 : 0) level=\(String(format: "%.1f", candidateWindow.windowLevel.rawValue)) frame=\(NativeMetalDiagnostics.rect(candidateWindow.frame)) bounds=\(NativeMetalDiagnostics.rect(candidateWindow.bounds)) root=\(rootName)"
            )

            var actions: [String] = []
            if let sdlRootController = candidateWindow.rootViewController,
               Self.installStatusBarHiddenOverrideIfNeeded(for: sdlRootController) {
                actions.append("statusBarOverride=1")
            }
            candidateWindow.rootViewController?.modalPresentationCapturesStatusBarAppearance = true
            candidateWindow.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            rootController?.setNeedsStatusBarAppearanceUpdate()
            embeddedPresentingController?.setNeedsStatusBarAppearanceUpdate()

            if Self.usesTransparentSDLTouchBridge,
               manicSkinControlsView?.isTouchSkinActive == true {
                let bridgeLevel = UIWindow.Level(window.windowLevel.rawValue + 1)
                if candidateWindow.isHidden {
                    candidateWindow.isHidden = false
                    actions.append("hidden=0")
                }
                if !candidateWindow.isUserInteractionEnabled {
                    candidateWindow.isUserInteractionEnabled = true
                    actions.append("interaction=1")
                }
                if abs(candidateWindow.windowLevel.rawValue - bridgeLevel.rawValue) > 0.001 {
                    candidateWindow.windowLevel = bridgeLevel
                    actions.append("level=\(String(format: "%.1f", bridgeLevel.rawValue))")
                }
                if abs(candidateWindow.alpha - 0.02) > 0.001 {
                    candidateWindow.alpha = 0.02
                    actions.append("alpha=0.02")
                }
                candidateWindow.isMultipleTouchEnabled = true
                candidateWindow.backgroundColor = .clear
                candidateWindow.rootViewController?.view.isMultipleTouchEnabled = true
                candidateWindow.rootViewController?.view.backgroundColor = .clear
                if actions.isEmpty {
                    actions.append("already-bridged")
                }

                didQuarantine = true
                NativeMetalDiagnostics.log(
                    "SDL_WINDOW_TOUCH_BRIDGE",
                    "reason=\(reason) window=\(NativeMetalDiagnostics.objectID(candidateWindow)) actions=\(actions.joined(separator: ",")) key=\(candidateWindow.isKeyWindow ? 1 : 0) hidden=\(candidateWindow.isHidden ? 1 : 0) interactive=\(candidateWindow.isUserInteractionEnabled ? 1 : 0) level=\(String(format: "%.1f", candidateWindow.windowLevel.rawValue)) alpha=\(String(format: "%.2f", candidateWindow.alpha))"
                )
                continue
            }

            if abs(candidateWindow.alpha - 1) > 0.001 {
                candidateWindow.alpha = 1
                actions.append("alpha=1.00")
            }
            if !candidateWindow.isHidden {
                candidateWindow.isHidden = true
                actions.append("hidden=1")
            }
            if candidateWindow.isUserInteractionEnabled {
                candidateWindow.isUserInteractionEnabled = false
                actions.append("interaction=0")
            }
            if candidateWindow.windowLevel.rawValue >= UIWindow.Level.normal.rawValue {
                candidateWindow.windowLevel = quarantineLevel
                actions.append("level=\(String(format: "%.1f", quarantineLevel.rawValue))")
            }
            if actions.isEmpty {
                actions.append("already-quarantined")
            }

            didQuarantine = true
            NativeMetalDiagnostics.log(
                "SDL_WINDOW_QUARANTINE",
                "reason=\(reason) window=\(NativeMetalDiagnostics.objectID(candidateWindow)) actions=\(actions.joined(separator: ",")) key=\(candidateWindow.isKeyWindow ? 1 : 0) hidden=\(candidateWindow.isHidden ? 1 : 0) interactive=\(candidateWindow.isUserInteractionEnabled ? 1 : 0) level=\(String(format: "%.1f", candidateWindow.windowLevel.rawValue))"
            )
        }

        if didQuarantine {
            if window.isHidden {
                NativeMetalDiagnostics.log(
                    "WINDOW_REKEY_AFTER_SDL_QUARANTINE",
                    "reason=\(reason) hidden=\(window.isHidden ? 1 : 0) key=\(window.isKeyWindow ? 1 : 0)"
                )
                window.makeKeyAndVisible()
            }
            if let touchOverlayWindow,
               !touchOverlayWindow.isHidden {
                ensureTouchOverlayWindowIsKey(reason: "sdl-quarantine-\(reason)")
            } else if !window.isKeyWindow {
                NativeMetalDiagnostics.log(
                    "WINDOW_REKEY_AFTER_SDL_QUARANTINE",
                    "reason=\(reason) hidden=\(window.isHidden ? 1 : 0) key=\(window.isKeyWindow ? 1 : 0)"
                )
                window.makeKeyAndVisible()
            }
            NativeMetalDiagnostics.logWindowSnapshot("after-sdl-quarantine-\(reason)", hostWindow: window)
        }
    }

    private static func installStatusBarHiddenOverrideIfNeeded(for controller: UIViewController) -> Bool {
        let controllerName = String(describing: type(of: controller))
        let controllerClass: AnyClass = type(of: controller)
        let classID = ObjectIdentifier(controllerClass)
        guard !statusBarHiddenOverrideClasses.contains(classID) else {
            controller.setNeedsStatusBarAppearanceUpdate()
            return true
        }

        let selector = #selector(getter: UIViewController.prefersStatusBarHidden)
        let block: @convention(block) (AnyObject) -> Bool = { _ in
            NativeMetalPresenterHost.isStatusBarHiddenForced
        }
        let implementation = imp_implementationWithBlock(block)
        if let method = class_getInstanceMethod(controllerClass, selector) {
            method_setImplementation(method, implementation)
        } else {
            class_addMethod(controllerClass, selector, implementation, "B@:")
        }
        statusBarHiddenOverrideClasses.insert(classID)
        controller.setNeedsStatusBarAppearanceUpdate()
        NativeMetalDiagnostics.log(
            "STATUS_BAR_OVERRIDE",
            "controller=\(controllerName) class=\(controllerClass)"
        )
        return true
    }

    private static func setStatusBarHiddenForced(_ forced: Bool, reason: String) {
        guard isStatusBarHiddenForced != forced else {
            return
        }

        isStatusBarHiddenForced = forced
        NativeMetalDiagnostics.log(
            "STATUS_BAR_FORCE",
            "hidden=\(forced ? 1 : 0) reason=\(reason)"
        )
    }

    private func handleManicSkinViewportChange(reason: String) {
        refreshPresenterViewportForManicSkin(reason: reason)
        guard !isSyncingGeometry else {
            return
        }

        scheduleMainRunLoopTimer(label: "\(reason)-viewport", delay: 0.001) { [weak self] in
            self?.forcePresenterLayout(reason: reason)
        }
    }

    private func refreshPresenterViewportForManicSkin(reason: String) {
        let touchSkinActive = manicSkinControlsView?.isTouchSkinActive == true
        exitMenuTapGesture?.isEnabled = !touchSkinActive
        NativeMetalDiagnostics.log(
            "VIEWPORT_REFRESH",
            "reason=\(reason) skinActive=\(touchSkinActive ? 1 : 0) skinViewport=\(NativeMetalDiagnostics.rect(manicSkinControlsView?.activeGameViewportFrame ?? .zero))"
        )
        applyPresenterViewport(touchSkinActive ? manicSkinControlsView?.activeGameViewportFrame : nil)
    }

    private func applyPresenterViewport(_ viewport: CGRect?) {
        guard let rootView = presenterContainerView,
              let presenterView else {
            return
        }

        let normalizedFrame = isUsingExternalGameplayDisplay ? nil : viewport?.roundedForLayout
        if presenterLayoutConstraints.isEmpty == false {
            if let activePresenterViewportFrame,
               let normalizedFrame,
               activePresenterViewportFrame.isSameFrame(as: normalizedFrame) {
                return
            }
            if activePresenterViewportFrame == nil, normalizedFrame == nil {
                return
            }
        }

        NSLayoutConstraint.deactivate(presenterLayoutConstraints)
        if let normalizedFrame,
           normalizedFrame.width > 1,
           normalizedFrame.height > 1 {
            presenterLayoutConstraints = [
                presenterView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: normalizedFrame.minX),
                presenterView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: normalizedFrame.minY),
                presenterView.widthAnchor.constraint(equalToConstant: normalizedFrame.width),
                presenterView.heightAnchor.constraint(equalToConstant: normalizedFrame.height),
            ]
            activePresenterViewportFrame = normalizedFrame
        } else {
            presenterLayoutConstraints = [
                presenterView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                presenterView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                presenterView.topAnchor.constraint(equalTo: rootView.topAnchor),
                presenterView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            ]
            activePresenterViewportFrame = nil
        }

        NSLayoutConstraint.activate(presenterLayoutConstraints)
        rootView.setNeedsLayout()
        presenterView.setNeedsLayout()
        NativeMetalDiagnostics.log(
            "VIEWPORT_APPLY",
            "viewport=\(NativeMetalDiagnostics.rect(normalizedFrame ?? .zero)) full=\(normalizedFrame == nil ? 1 : 0) external=\(isUsingExternalGameplayDisplay ? 1 : 0)"
        )
    }

    @discardableResult
    fileprivate func handleRawWindowTouchEvent(_ event: UIEvent) -> Bool {
        guard event.type == .touches,
              let touches = event.allTouches else {
            return false
        }
        NativeMetalDiagnostics.log(
            "RAW_WINDOW_TOUCH_OBSERVED",
            "count=\(touches.count) overlay=\(exitOverlayView?.isMenuVisible == true ? 1 : 0) skin=\(manicSkinControlsView?.isTouchSkinActive == true ? 1 : 0) touches=\(touches.map { NativeMetalDiagnostics.touch($0, in: manicSkinControlsView ?? rootController?.view) }.joined(separator: " | "))"
        )

        if let exitOverlayView,
           exitOverlayView.isMenuVisible {
            var handled = false
            for touch in touches where touch.phase == .ended {
                let point = touch.location(in: exitOverlayView)
                handled = exitOverlayView.handleBridgedTouchEnded(at: point) || handled
            }
            NativeMetalDiagnostics.log("RAW_WINDOW_OVERLAY", "handled=\(handled ? 1 : 0)")
            return handled
        }

        if manicSkinControlsView?.isTouchSkinActive == true {
            NativeMetalDiagnostics.log("RAW_WINDOW_SKIN_SKIP", "reason=direct-uikit-touch-path")
        }
        return false
    }

    fileprivate func handleApplicationSendEvent(
        _ event: UIEvent,
        stage: NativeMetalWindowSendEventStage
    ) {
        guard event.type == .touches,
              let touches = event.allTouches,
              window != nil else {
            return
        }

        NativeMetalDiagnostics.log(
            stage == .beforeOriginal ? "APP_TOUCH_PRE" : "APP_TOUCH_POST",
            "count=\(touches.count) hostWindow=\(NativeMetalDiagnostics.objectID(window)) touchWindow=\(NativeMetalDiagnostics.objectID(touchOverlayWindow)) overlay=\(exitOverlayView?.isMenuVisible == true ? 1 : 0) skin=\(manicSkinControlsView?.isTouchSkinActive == true ? 1 : 0) touches=\(touches.map { NativeMetalDiagnostics.touch($0, in: rootController?.view) }.joined(separator: " | "))"
        )

        guard stage == .afterOriginal else {
            return
        }

        noteTouchEventDelivery(reason: "application-sendEvent-post")

        if let manicSkinControlsView,
           manicSkinControlsView.isTouchSkinActive {
            let directTouchAge = CACurrentMediaTime() - manicSkinControlsView.lastDirectTouchDeliveryTime
            guard manicSkinControlsView.lastDirectTouchDeliveryTime <= 0 || directTouchAge > 0.035 else {
                NativeMetalDiagnostics.log(
                    "APP_TOUCH_BRIDGE_SKIP",
                    "reason=direct-uikit age=\(String(format: "%.3f", directTouchAge))"
                )
                return
            }
        } else if exitOverlayView?.isMenuVisible != true {
            NativeMetalDiagnostics.log("APP_TOUCH_BRIDGE_SKIP", "reason=no-touch-target")
            return
        }

        var handled = false
        for touch in touches {
            handled = handleExternalTouch(touch) || handled
        }
        NativeMetalDiagnostics.log(
            "APP_TOUCH_BRIDGE",
            "handled=\(handled ? 1 : 0) count=\(touches.count)"
        )
    }

    fileprivate func handleWindowSendEvent(
        _ event: UIEvent,
        sourceWindow: UIWindow,
        stage: NativeMetalWindowSendEventStage
    ) {
        guard event.type == .touches,
              let touches = event.allTouches,
              sourceWindow === window else {
            return
        }

        let eventID = ObjectIdentifier(event)
        let now = CACurrentMediaTime()
        preRoutedWindowTouchEvents = preRoutedWindowTouchEvents.filter { now - $0.value < 0.6 }
        NativeMetalDiagnostics.log(
            stage == .beforeOriginal ? "WINDOW_SEND_EVENT_PRE" : "WINDOW_SEND_EVENT_POST",
            "window=\(NativeMetalDiagnostics.objectID(sourceWindow)) count=\(touches.count) overlay=\(exitOverlayView?.isMenuVisible == true ? 1 : 0) skin=\(manicSkinControlsView?.isTouchSkinActive == true ? 1 : 0) preRouted=\(preRoutedWindowTouchEvents[eventID] == nil ? 0 : 1) touches=\(touches.map { NativeMetalDiagnostics.touch($0, in: rootController?.view) }.joined(separator: " | "))"
        )

        if let manicSkinControlsView,
           manicSkinControlsView.isTouchSkinActive {
            if stage == .beforeOriginal {
                let appEventAge = now - lastObservedTouchEventTime
                guard lastObservedTouchEventTime <= 0 || appEventAge > 0.06 else {
                    NativeMetalDiagnostics.log(
                        "WINDOW_SEND_EVENT_SKIN_SKIP",
                        "stage=pre reason=application-observed age=\(String(format: "%.3f", appEventAge))"
                    )
                    return
                }

                noteTouchEventDelivery(reason: "window-sendEvent-pre")
                let handled = bridgeWindowTouchesToManicSkin(touches, manicSkinControlsView: manicSkinControlsView)
                if handled {
                    preRoutedWindowTouchEvents[eventID] = now
                }
                NativeMetalDiagnostics.log(
                    "WINDOW_SEND_EVENT_SKIN_BRIDGE",
                    "stage=pre handled=\(handled ? 1 : 0) activeTouches=\(touches.count)"
                )
                return
            }

            guard preRoutedWindowTouchEvents[eventID] == nil else {
                NativeMetalDiagnostics.log("WINDOW_SEND_EVENT_SKIN_SKIP", "stage=post reason=pre-routed")
                return
            }

            let directTouchAge = CACurrentMediaTime() - manicSkinControlsView.lastDirectTouchDeliveryTime
            guard manicSkinControlsView.lastDirectTouchDeliveryTime <= 0 || directTouchAge > 0.06 else {
                NativeMetalDiagnostics.log(
                    "WINDOW_SEND_EVENT_SKIN_SKIP",
                    "stage=post reason=direct-uikit age=\(String(format: "%.3f", directTouchAge))"
                )
                return
            }

            let handled = bridgeWindowTouchesToManicSkin(touches, manicSkinControlsView: manicSkinControlsView)
            NativeMetalDiagnostics.log(
                "WINDOW_SEND_EVENT_SKIN_BRIDGE",
                "stage=post handled=\(handled ? 1 : 0) activeTouches=\(touches.count)"
            )
            return
        }

        guard stage == .afterOriginal else {
            return
        }

        if exitOverlayView?.isMenuVisible == true {
            NativeMetalDiagnostics.log("WINDOW_SEND_EVENT_OVERLAY_SKIP", "reason=overlay-visible")
            return
        }

        guard touches.contains(where: { $0.phase == .ended }) else {
            return
        }

        exitOverlayView?.show()
        NativeMetalDiagnostics.log("WINDOW_SEND_EVENT_SHOW_OVERLAY", "reason=ended-touch")
    }

    private func bridgeWindowTouchesToManicSkin(
        _ touches: Set<UITouch>,
        manicSkinControlsView: ManicSkinTouchControlsView
    ) -> Bool {
        var handled = false
        for touch in touches {
            guard let point = point(for: touch, in: manicSkinControlsView) else {
                continue
            }
            handled = manicSkinControlsView.handleExternalTouch(touch, at: point) || handled
        }
        return handled
    }

    fileprivate func noteTouchEventDelivery(reason: String) {
        lastObservedTouchEventTime = CACurrentMediaTime()
        if reason != "touch-probe" {
            lastNonProbeTouchEventTime = lastObservedTouchEventTime
        }
        NativeMetalDiagnostics.log(
            "TOUCH_EVENT_DELIVERY",
            "reason=\(reason) t=\(String(format: "%.6f", lastObservedTouchEventTime))"
        )
    }

    private func handleTouchProbeGesture(phase: NativeGameplayTouchPhase, touches: Set<UITouch>) {
        guard touches.isEmpty == false else {
            return
        }

        let now = CACurrentMediaTime()
        let nonProbeAge = lastNonProbeTouchEventTime > 0 ? now - lastNonProbeTouchEventTime : .infinity
        let directAge = manicSkinControlsView?.lastDirectTouchDeliveryTime ?? 0
        let directTouchAge = directAge > 0 ? now - directAge : .infinity
        let touchDescription = touches.map {
            NativeMetalDiagnostics.touch($0, in: manicSkinControlsView ?? rootController?.view)
        }.joined(separator: " | ")
        NativeMetalDiagnostics.log(
            "TOUCH_PROBE_EVENT",
            "phase=\(NativeMetalDiagnostics.gameplayPhaseName(phase)) count=\(touches.count) overlay=\(exitOverlayView?.isMenuVisible == true ? 1 : 0) skin=\(manicSkinControlsView?.isTouchSkinActive == true ? 1 : 0) nonProbeAge=\(NativeMetalDiagnostics.age(nonProbeAge)) directAge=\(NativeMetalDiagnostics.age(directTouchAge)) touches=\(touchDescription)"
        )

        guard exitOverlayView?.isMenuVisible != true else {
            NativeMetalDiagnostics.log(
                "TOUCH_PROBE_SKIP",
                "phase=\(NativeMetalDiagnostics.gameplayPhaseName(phase)) reason=overlay-visible"
            )
            return
        }

        guard let manicSkinControlsView,
              manicSkinControlsView.isTouchSkinActive else {
            NativeMetalDiagnostics.log(
                "TOUCH_PROBE_SKIP",
                "phase=\(NativeMetalDiagnostics.gameplayPhaseName(phase)) reason=skin-inactive"
            )
            return
        }

        guard lastNonProbeTouchEventTime <= 0 || nonProbeAge > 0.08 else {
            NativeMetalDiagnostics.log(
                "TOUCH_PROBE_SKIP",
                "phase=\(NativeMetalDiagnostics.gameplayPhaseName(phase)) reason=recent-non-probe age=\(NativeMetalDiagnostics.age(nonProbeAge))"
            )
            return
        }

        guard manicSkinControlsView.lastDirectTouchDeliveryTime <= 0 || directTouchAge > 0.08 else {
            NativeMetalDiagnostics.log(
                "TOUCH_PROBE_SKIP",
                "phase=\(NativeMetalDiagnostics.gameplayPhaseName(phase)) reason=recent-direct age=\(NativeMetalDiagnostics.age(directTouchAge))"
            )
            return
        }

        noteTouchEventDelivery(reason: "touch-probe")
        var handled = false
        for touch in touches {
            guard let point = point(for: touch, in: manicSkinControlsView) else {
                continue
            }
            handled = manicSkinControlsView.handleExternalTouch(touch, at: point) || handled
        }
        NativeMetalDiagnostics.log(
            "TOUCH_PROBE_BRIDGE",
            "phase=\(NativeMetalDiagnostics.gameplayPhaseName(phase)) handled=\(handled ? 1 : 0) count=\(touches.count)"
        )
    }

    fileprivate func shouldCaptureRootTouch(at windowPoint: CGPoint, originalResult: UIView?) -> Bool {
        guard Self.usesRootTouchCapture,
              exitOverlayView?.isMenuVisible != true,
              let manicSkinControlsView,
              manicSkinControlsView.isTouchSkinActive,
              let window else {
            return false
        }

        let skinPoint = manicSkinControlsView.convert(windowPoint, from: window)
        guard let target = manicSkinControlsView.fallbackTarget(at: skinPoint) else {
            return false
        }

        NativeMetalDiagnostics.log(
            "ROOT_CAPTURE_HIT",
            "target=\(target.description) windowPoint=\(NativeMetalDiagnostics.point(windowPoint)) skinPoint=\(NativeMetalDiagnostics.point(skinPoint)) original=\(originalResult.map { "\(type(of: $0))#\(NativeMetalDiagnostics.objectID($0))" } ?? "nil")"
        )
        return true
    }

    @discardableResult
    fileprivate func handleRootCapturedTouches(
        phase: NativeGameplayTouchPhase,
        touches: Set<UITouch>,
        rootView: UIView
    ) -> Bool {
        guard touches.isEmpty == false else {
            return false
        }

        if let exitOverlayView,
           exitOverlayView.isMenuVisible {
            guard phase == .ended else {
                NativeMetalDiagnostics.log(
                    "ROOT_CAPTURE_OVERLAY_SKIP",
                    "phase=\(NativeMetalDiagnostics.gameplayPhaseName(phase))"
                )
                return false
            }

            var handled = false
            for touch in touches {
                let point = touch.location(in: exitOverlayView)
                handled = exitOverlayView.handleBridgedTouchEnded(at: point) || handled
            }
            NativeMetalDiagnostics.log(
                "ROOT_CAPTURE_OVERLAY",
                "handled=\(handled ? 1 : 0) count=\(touches.count)"
            )
            return handled
        }

        guard let manicSkinControlsView,
              manicSkinControlsView.isTouchSkinActive else {
            NativeMetalDiagnostics.log(
                "ROOT_CAPTURE_SKIP",
                "phase=\(NativeMetalDiagnostics.gameplayPhaseName(phase)) reason=skin-inactive"
            )
            return false
        }

        noteTouchEventDelivery(reason: "root-capture-\(NativeMetalDiagnostics.gameplayPhaseName(phase))")
        var handled = false
        for touch in touches {
            let point = touch.location(in: manicSkinControlsView)
            handled = manicSkinControlsView.handleExternalTouch(touch, at: point) || handled
        }
        NativeMetalDiagnostics.log(
            "ROOT_CAPTURE_BRIDGE",
            "phase=\(NativeMetalDiagnostics.gameplayPhaseName(phase)) handled=\(handled ? 1 : 0) count=\(touches.count) touches=\(touches.map { NativeMetalDiagnostics.touch($0, in: rootView) }.joined(separator: " | "))"
        )
        return handled
    }

    fileprivate func observePresenterHitTest(point: CGPoint, result: UIView?, event: UIEvent?) {
        guard event?.type == .touches,
              let window else {
            return
        }

        guard Self.usesHitTestFallback else {
            NativeMetalDiagnostics.log(
                "HITTEST_FALLBACK_DISABLED",
                "point=\(NativeMetalDiagnostics.point(point)) result=\(result.map { "\(type(of: $0))#\(NativeMetalDiagnostics.objectID($0))" } ?? "nil") window=\(NativeMetalDiagnostics.objectID(window))"
            )
            return
        }

        if let exitOverlayView,
           exitOverlayView.isMenuVisible,
           let result,
           result.isDescendant(of: exitOverlayView) {
            scheduleExitOverlayHitTestFallback(
                point: point,
                result: result,
                event: event,
                window: window,
                exitOverlayView: exitOverlayView
            )
            return
        }

        if exitOverlayView?.isMenuVisible != true,
           manicSkinControlsView?.isTouchSkinActive != true,
           let result,
           let presenterView,
           result === presenterView || result.isDescendant(of: presenterView) {
            scheduleExitOverlayShowHitTestFallback(
                point: point,
                event: event,
                window: window
            )
            return
        }

        guard let manicSkinControlsView,
              manicSkinControlsView.isTouchSkinActive,
              result === manicSkinControlsView else {
            return
        }

        let touches = event?.allTouches
        if let touches,
           touches.isEmpty == false,
           touches.contains(where: { $0.phase == .began }) == false {
            NativeMetalDiagnostics.log(
                "HITTEST_FALLBACK_SKIP",
                "reason=no-began point=\(NativeMetalDiagnostics.point(point)) touches=\(touches.map { NativeMetalDiagnostics.touch($0, in: manicSkinControlsView) }.joined(separator: " | "))"
            )
            return
        }

        let now = CACurrentMediaTime()
        let skinPoint = manicSkinControlsView.convert(point, from: window)
        guard let target = manicSkinControlsView.fallbackTarget(at: skinPoint) else {
            NativeMetalDiagnostics.log(
                "HITTEST_FALLBACK_SKIP",
                "reason=no-target point=\(NativeMetalDiagnostics.point(point)) skinPoint=\(NativeMetalDiagnostics.point(skinPoint))"
            )
            return
        }

        let syntheticID = target.isThumbstick ?
            (-9_100_000_000 - Int64(target.itemID)) :
            (-9_000_000_000 - (hitTestFallbackSequence + 1))
        let isDegradedPostTransition = target.isThumbstick && isPostTransitionTouchDeliveryDegraded(now: now)
        let duplicateDistance: CGFloat = target.isThumbstick ? (isDegradedPostTransition ? 0.25 : 0.75) : 2
        let duplicateWindow: CFTimeInterval = target.isThumbstick ? (isDegradedPostTransition ? 0.012 : 0.035) : 0.1
        if target.isThumbstick {
            if let lastSample = lastThumbstickHitTestFallbackSamples[syntheticID],
               hypot(lastSample.point.x - skinPoint.x, lastSample.point.y - skinPoint.y) < duplicateDistance,
               now - lastSample.time < duplicateWindow {
                NativeMetalDiagnostics.log(
                    "HITTEST_FALLBACK_SKIP",
                    "reason=thumbstick-duplicate synthetic=\(syntheticID) point=\(NativeMetalDiagnostics.point(point)) degraded=\(isDegradedPostTransition ? 1 : 0)"
                )
                return
            }
        } else if let lastPoint = lastHitTestFallbackPoint,
                  hypot(lastPoint.x - point.x, lastPoint.y - point.y) < duplicateDistance,
                  now - lastHitTestFallbackScheduleTime < duplicateWindow {
            NativeMetalDiagnostics.log(
                "HITTEST_FALLBACK_SKIP",
                "reason=duplicate point=\(NativeMetalDiagnostics.point(point))"
            )
            return
        }

        hitTestFallbackSequence += 1
        let sequence = hitTestFallbackSequence
        let scheduledAt = now
        lastHitTestFallbackPoint = point
        lastHitTestFallbackScheduleTime = scheduledAt
        if target.isThumbstick {
            lastThumbstickHitTestFallbackSamples[syntheticID] = (skinPoint, scheduledAt)
        }
        NativeMetalDiagnostics.log(
            "HITTEST_FALLBACK_SCHEDULE",
            "id=\(sequence) synthetic=\(syntheticID) target=\(target.description) thumbstick=\(target.isThumbstick ? 1 : 0) degraded=\(isDegradedPostTransition ? 1 : 0) windowPoint=\(NativeMetalDiagnostics.point(point)) skinPoint=\(NativeMetalDiagnostics.point(skinPoint)) touches=\(touches?.map { NativeMetalDiagnostics.touch($0, in: manicSkinControlsView) }.joined(separator: " | ") ?? "none")"
        )

        if isDegradedPostTransition {
            let fallbackPoint =
                manicSkinControlsView.boostedFallbackThumbstickPoint(
                    for: target.itemID,
                    at: skinPoint,
                    minimumNormalizedDistance: 0.45
                ) ?? skinPoint
            let phase: NativeGameplayTouchPhase = manicSkinControlsView.hasActiveBridgedTouch(id: syntheticID) ? .moved : .began
            let handled = manicSkinControlsView.handleBridgedTouch(
                phase: phase,
                id: syntheticID,
                point: fallbackPoint
            )
            NativeMetalDiagnostics.log(
                phase == .began ? "HITTEST_FALLBACK_BEGIN" : "HITTEST_FALLBACK_MOVE",
                "id=\(sequence) synthetic=\(syntheticID) mode=post-transition-immediate target=\(target.description) rawPoint=\(NativeMetalDiagnostics.point(skinPoint)) point=\(NativeMetalDiagnostics.point(fallbackPoint)) handled=\(handled ? 1 : 0)"
            )

            if handled {
                scheduleSkinHitTestFallbackRelease(
                    sequence: sequence,
                    syntheticID: syntheticID,
                    point: fallbackPoint,
                    delay: 0.95,
                    manicSkinControlsView: manicSkinControlsView
                )
            }
            return
        }

        scheduleMainRunLoopTimer(label: "hittest-fallback-\(sequence)", delay: target.isThumbstick ? 0.001 : 0.035) { [weak self, weak manicSkinControlsView] in
            guard let self,
                  let manicSkinControlsView,
                  manicSkinControlsView.window === self.window,
                  manicSkinControlsView.isTouchSkinActive else {
                NativeMetalDiagnostics.log("HITTEST_FALLBACK_CANCEL", "id=\(sequence) reason=inactive")
                return
            }

            let directSkinDeliveryTime = manicSkinControlsView.lastDirectTouchDeliveryTime
            if max(self.lastObservedTouchEventTime, directSkinDeliveryTime) >= scheduledAt {
                NativeMetalDiagnostics.log(
                    "HITTEST_FALLBACK_CANCEL",
                    "id=\(sequence) reason=real-event-observed scheduled=\(String(format: "%.6f", scheduledAt)) delivered=\(String(format: "%.6f", self.lastObservedTouchEventTime)) skinDelivered=\(String(format: "%.6f", directSkinDeliveryTime))"
                )
                return
            }

            let fallbackPoint = target.isThumbstick ?
                (manicSkinControlsView.boostedFallbackThumbstickPoint(for: target.itemID, at: skinPoint) ?? skinPoint) :
                skinPoint
            let phase: NativeGameplayTouchPhase = manicSkinControlsView.hasActiveBridgedTouch(id: syntheticID) ? .moved : .began
            let handled = manicSkinControlsView.handleBridgedTouch(
                phase: phase,
                id: syntheticID,
                point: fallbackPoint
            )
            NativeMetalDiagnostics.log(
                phase == .began ? "HITTEST_FALLBACK_BEGIN" : "HITTEST_FALLBACK_MOVE",
                "id=\(sequence) synthetic=\(syntheticID) target=\(target.description) rawPoint=\(NativeMetalDiagnostics.point(skinPoint)) point=\(NativeMetalDiagnostics.point(fallbackPoint)) handled=\(handled ? 1 : 0)"
            )

            guard handled else {
                return
            }

            if target.isThumbstick {
                self.scheduleSkinHitTestFallbackRelease(
                    sequence: sequence,
                    syntheticID: syntheticID,
                    point: fallbackPoint,
                    delay: 1.20,
                    manicSkinControlsView: manicSkinControlsView
                )
                return
            }

            self.scheduleMainRunLoopTimer(label: "hittest-fallback-\(sequence)-end", delay: 0.14) { [weak manicSkinControlsView] in
                let ended = manicSkinControlsView?.handleBridgedTouch(
                    phase: .ended,
                    id: syntheticID,
                    point: skinPoint
                ) ?? false
                NativeMetalDiagnostics.log(
                    "HITTEST_FALLBACK_END",
                    "id=\(sequence) synthetic=\(syntheticID) handled=\(ended ? 1 : 0)"
                )
            }
        }
    }

    private func isPostTransitionTouchDeliveryDegraded(now: CFTimeInterval) -> Bool {
        guard lastTransitionStartTime > 0,
              now - lastTransitionStartTime > 0.30 else {
            return false
        }
        let directSkinDeliveryTime = manicSkinControlsView?.lastDirectTouchDeliveryTime ?? 0
        return max(lastObservedTouchEventTime, directSkinDeliveryTime) < lastTransitionStartTime
    }

    private func scheduleExitOverlayShowHitTestFallback(
        point: CGPoint,
        event: UIEvent?,
        window: UIWindow
    ) {
        let touches = event?.allTouches
        if let touches,
           touches.isEmpty == false,
           touches.contains(where: { $0.phase == .began }) == false {
            NativeMetalDiagnostics.log(
                "EXIT_SHOW_HITTEST_FALLBACK_SKIP",
                "reason=no-began point=\(NativeMetalDiagnostics.point(point)) touches=\(touches.map { NativeMetalDiagnostics.touch($0, in: rootController?.view) }.joined(separator: " | "))"
            )
            return
        }

        let now = CACurrentMediaTime()
        if let lastPoint = lastHitTestFallbackPoint,
           hypot(lastPoint.x - point.x, lastPoint.y - point.y) < 2,
           now - lastHitTestFallbackScheduleTime < 0.1 {
            NativeMetalDiagnostics.log(
                "EXIT_SHOW_HITTEST_FALLBACK_SKIP",
                "reason=duplicate point=\(NativeMetalDiagnostics.point(point))"
            )
            return
        }

        hitTestFallbackSequence += 1
        let sequence = hitTestFallbackSequence
        let scheduledAt = now
        lastHitTestFallbackPoint = point
        lastHitTestFallbackScheduleTime = scheduledAt
        NativeMetalDiagnostics.log(
            "EXIT_SHOW_HITTEST_FALLBACK_SCHEDULE",
            "id=\(sequence) window=\(NativeMetalDiagnostics.objectID(window)) point=\(NativeMetalDiagnostics.point(point)) touches=\(touches?.map { NativeMetalDiagnostics.touch($0, in: rootController?.view) }.joined(separator: " | ") ?? "none")"
        )

        scheduleMainRunLoopTimer(label: "exit-show-hittest-fallback-\(sequence)", delay: 0.035) { [weak self] in
            guard let self else {
                return
            }

            if self.lastObservedTouchEventTime >= scheduledAt {
                NativeMetalDiagnostics.log(
                    "EXIT_SHOW_HITTEST_FALLBACK_CANCEL",
                    "id=\(sequence) reason=real-event-observed scheduled=\(String(format: "%.6f", scheduledAt)) delivered=\(String(format: "%.6f", self.lastObservedTouchEventTime))"
                )
                return
            }

            guard self.exitOverlayView?.isMenuVisible != true,
                  self.manicSkinControlsView?.isTouchSkinActive != true else {
                NativeMetalDiagnostics.log(
                    "EXIT_SHOW_HITTEST_FALLBACK_CANCEL",
                    "id=\(sequence) reason=state-changed overlay=\(self.exitOverlayView?.isMenuVisible == true ? 1 : 0) skin=\(self.manicSkinControlsView?.isTouchSkinActive == true ? 1 : 0)"
                )
                return
            }

            self.exitOverlayView?.show()
            NativeMetalDiagnostics.log("EXIT_SHOW_HITTEST_FALLBACK_FIRE", "id=\(sequence)")
        }
    }

    private func scheduleSkinHitTestFallbackRelease(
        sequence: Int64,
        syntheticID: Int64,
        point: CGPoint,
        delay: TimeInterval,
        manicSkinControlsView: ManicSkinTouchControlsView
    ) {
        hitTestFallbackReleaseSequence += 1
        let releaseToken = hitTestFallbackReleaseSequence
        hitTestFallbackReleaseTokens[syntheticID] = releaseToken
        NativeMetalDiagnostics.log(
            "HITTEST_FALLBACK_RELEASE_SCHEDULE",
            "id=\(sequence) synthetic=\(syntheticID) token=\(releaseToken) delay=\(String(format: "%.3f", delay))"
        )

        scheduleMainRunLoopTimer(label: "hittest-fallback-\(sequence)-release", delay: delay) { [weak self, weak manicSkinControlsView] in
            guard let self else {
                return
            }

            guard self.hitTestFallbackReleaseTokens[syntheticID] == releaseToken else {
                NativeMetalDiagnostics.log(
                    "HITTEST_FALLBACK_RELEASE_SKIP",
                    "id=\(sequence) synthetic=\(syntheticID) token=\(releaseToken) reason=stale"
                )
                return
            }

            self.hitTestFallbackReleaseTokens.removeValue(forKey: syntheticID)
            let ended = manicSkinControlsView?.handleBridgedTouch(
                phase: .ended,
                id: syntheticID,
                point: point
            ) ?? false
            NativeMetalDiagnostics.log(
                "HITTEST_FALLBACK_END",
                "id=\(sequence) synthetic=\(syntheticID) token=\(releaseToken) handled=\(ended ? 1 : 0)"
            )
        }
    }

    private func scheduleExitOverlayHitTestFallback(
        point: CGPoint,
        result: UIView,
        event: UIEvent?,
        window: UIWindow,
        exitOverlayView: GameplayExitOverlayView
    ) {
        let touches = event?.allTouches
        if let touches,
           touches.isEmpty == false,
           touches.contains(where: { $0.phase == .began }) == false {
            NativeMetalDiagnostics.log(
                "EXIT_HITTEST_FALLBACK_SKIP",
                "reason=no-began point=\(NativeMetalDiagnostics.point(point)) touches=\(touches.map { NativeMetalDiagnostics.touch($0, in: exitOverlayView) }.joined(separator: " | "))"
            )
            return
        }

        let now = CACurrentMediaTime()
        if let lastPoint = lastHitTestFallbackPoint,
           hypot(lastPoint.x - point.x, lastPoint.y - point.y) < 2,
           now - lastHitTestFallbackScheduleTime < 0.1 {
            NativeMetalDiagnostics.log(
                "EXIT_HITTEST_FALLBACK_SKIP",
                "reason=duplicate point=\(NativeMetalDiagnostics.point(point))"
            )
            return
        }

        hitTestFallbackSequence += 1
        let sequence = hitTestFallbackSequence
        let scheduledAt = now
        let overlayPoint = exitOverlayView.convert(point, from: window)
        lastHitTestFallbackPoint = point
        lastHitTestFallbackScheduleTime = scheduledAt
        NativeMetalDiagnostics.log(
            "EXIT_HITTEST_FALLBACK_SCHEDULE",
            "id=\(sequence) result=\(type(of: result))#\(NativeMetalDiagnostics.objectID(result)) windowPoint=\(NativeMetalDiagnostics.point(point)) overlayPoint=\(NativeMetalDiagnostics.point(overlayPoint)) touches=\(touches?.map { NativeMetalDiagnostics.touch($0, in: exitOverlayView) }.joined(separator: " | ") ?? "none")"
        )

        scheduleMainRunLoopTimer(label: "exit-hittest-fallback-\(sequence)", delay: 0.035) { [weak self, weak exitOverlayView] in
            guard let self,
                  let exitOverlayView,
                  exitOverlayView.window === self.window,
                  exitOverlayView.isMenuVisible else {
                NativeMetalDiagnostics.log("EXIT_HITTEST_FALLBACK_CANCEL", "id=\(sequence) reason=inactive")
                return
            }

            if self.lastObservedTouchEventTime >= scheduledAt {
                NativeMetalDiagnostics.log(
                    "EXIT_HITTEST_FALLBACK_CANCEL",
                    "id=\(sequence) reason=real-event-observed scheduled=\(String(format: "%.6f", scheduledAt)) delivered=\(String(format: "%.6f", self.lastObservedTouchEventTime))"
                )
                return
            }

            let handled = exitOverlayView.handleBridgedTouchEnded(at: overlayPoint)
            NativeMetalDiagnostics.log(
                "EXIT_HITTEST_FALLBACK_FIRE",
                "id=\(sequence) point=\(NativeMetalDiagnostics.point(overlayPoint)) handled=\(handled ? 1 : 0)"
            )
        }
    }

    @discardableResult
    private func handleExternalTouch(_ touch: UITouch) -> Bool {
        if let exitOverlayView,
           exitOverlayView.isMenuVisible {
            guard touch.phase == .ended,
                  let point = point(for: touch, in: exitOverlayView) else {
                NativeMetalDiagnostics.log(
                    "EXTERNAL_OVERLAY_SKIP",
                    "touch=\(NativeMetalDiagnostics.touch(touch, in: exitOverlayView))"
                )
                return false
            }
            let handled = exitOverlayView.handleBridgedTouchEnded(at: point)
            NativeMetalDiagnostics.log(
                "EXTERNAL_OVERLAY",
                "point=\(NativeMetalDiagnostics.point(point)) handled=\(handled ? 1 : 0)"
            )
            return handled
        }

        if let manicSkinControlsView,
           manicSkinControlsView.isTouchSkinActive,
           let point = point(for: touch, in: manicSkinControlsView) {
            let handled = manicSkinControlsView.handleExternalTouch(touch, at: point)
            if touch.phase != .moved || !handled {
                NativeMetalDiagnostics.log(
                    "EXTERNAL_SKIN",
                    "converted=\(NativeMetalDiagnostics.point(point)) handled=\(handled ? 1 : 0) bounds=\(NativeMetalDiagnostics.rect(manicSkinControlsView.bounds))"
                )
            }
            return handled
        }

        if touch.phase == .ended {
            exitOverlayView?.show()
            NativeMetalDiagnostics.log(
                "EXTERNAL_SHOW_OVERLAY",
                "touch=\(NativeMetalDiagnostics.touch(touch, in: rootController?.view))"
            )
            return true
        }

        NativeMetalDiagnostics.log(
            "EXTERNAL_UNHANDLED",
            "touch=\(NativeMetalDiagnostics.touch(touch, in: rootController?.view)) skinActive=\(manicSkinControlsView?.isTouchSkinActive == true ? 1 : 0)"
        )
        return false
    }

    private func point(for touch: UITouch, in destinationView: UIView) -> CGPoint? {
        if let sourceWindow = touch.window {
            let windowPoint = touch.location(in: sourceWindow)
            let converted = destinationView.convert(windowPoint, from: sourceWindow)
            if touch.phase != .moved {
                NativeMetalDiagnostics.log(
                    "POINT_CONVERT",
                    "sourceWindow=\(NativeMetalDiagnostics.objectID(sourceWindow)) source=\(NativeMetalDiagnostics.point(windowPoint)) destView=\(type(of: destinationView)) dest=\(NativeMetalDiagnostics.point(converted)) destBounds=\(NativeMetalDiagnostics.rect(destinationView.bounds))"
                )
            }
            return converted
        }

        return touch.location(in: destinationView)
    }

    private func handleGameplayTouch(
        phaseRaw: Int32,
        touchID: Int64,
        normalizedX: Float,
        normalizedY: Float
    ) {
        guard let phase = NativeGameplayTouchPhase(rawValue: phaseRaw),
              let rootView = rootController?.view else {
            NativeMetalDiagnostics.log(
                "GAMEPLAY_TOUCH_DROP",
                "phaseRaw=\(phaseRaw) root=\(rootController?.view == nil ? 0 : 1)"
            )
            return
        }

        let normalizedPoint = CGPoint(
            x: CGFloat(max(0, min(1, normalizedX))),
            y: CGFloat(max(0, min(1, normalizedY)))
        )
        let point = CGPoint(
            x: normalizedPoint.x * rootView.bounds.width,
            y: normalizedPoint.y * rootView.bounds.height
        )
        NativeMetalDiagnostics.log(
            "GAMEPLAY_TOUCH",
            "phase=\(phase) id=\(touchID) normalized=\(NativeMetalDiagnostics.point(normalizedPoint)) point=\(NativeMetalDiagnostics.point(point)) root=\(NativeMetalDiagnostics.rect(rootView.bounds)) overlay=\(exitOverlayView?.isMenuVisible == true ? 1 : 0) skin=\(manicSkinControlsView?.isTouchSkinActive == true ? 1 : 0)"
        )

        if let exitOverlayView,
           exitOverlayView.isMenuVisible {
            if phase == .ended {
                _ = exitOverlayView.handleBridgedTouchEnded(at: point)
            }
            return
        }

        if let manicSkinControlsView,
           manicSkinControlsView.isTouchSkinActive {
            let skinPoint = manicSkinControlsView.convert(point, from: rootView)
            let handled = manicSkinControlsView.handleBridgedTouch(
                phase: phase,
                id: touchID,
                point: skinPoint
            )
            NativeMetalDiagnostics.log(
                "GAMEPLAY_TOUCH_SKIN_BRIDGE",
                "phase=\(NativeMetalDiagnostics.gameplayPhaseName(phase)) id=\(touchID) point=\(NativeMetalDiagnostics.point(point)) skinPoint=\(NativeMetalDiagnostics.point(skinPoint)) handled=\(handled ? 1 : 0)"
            )
            return
        }

        if phase == .ended {
            exitOverlayView?.show()
        }
    }

    func stop() {
        geometryDisplayLink?.invalidate()
        geometryDisplayLink = nil
        controllerInputPollTimer?.invalidate()
        controllerInputPollTimer = nil
        controllerPolledInputs.removeAll()
        removeExternalScreenObservers()
        runLoopTimers.forEach { $0.invalidate() }
        runLoopTimers.removeAll()
        hitTestFallbackReleaseTokens.removeAll()
        NativeMetalDiagnostics.logWindowSnapshot("stop-before-hide", hostWindow: window)
        NativeMetalGlobalTouchRouter.shared.deactivate(host: self)
        if Self.activeHost === self {
            Self.activeHost = nil
        }
        Self.setStatusBarHiddenForced(false, reason: "host-stop")
        if isEmbeddedPresentation {
            if isEmbeddedWindowSubviewPresentation {
                rootController?.view.removeFromSuperview()
            } else {
                rootController?.dismiss(animated: false)
            }
            window?.rootViewController?.setNeedsStatusBarAppearanceUpdate()
            embeddedPresentingController?.setNeedsStatusBarAppearanceUpdate()
            embeddedPresentingController = nil
        } else if let presenterWindow = window as? NativeMetalPresenterWindow {
            presenterWindow.isHidden = true
            presenterWindow.onGeometryChanged = nil
            presenterWindow.presenterHost = nil
            presenterWindow.exitOverlayView = nil
        }
        if let touchOverlayWindow {
            touchOverlayWindow.isHidden = true
            touchOverlayWindow.onGeometryChanged = nil
            touchOverlayWindow.rootViewController = nil
        }
        if let externalDisplayWindow {
            let isConnectedSceneWindow = Self.connectedExternalDisplayWindow === externalDisplayWindow
            externalDisplayWindow.isHidden = isConnectedSceneWindow ? false : true
            if isConnectedSceneWindow == false {
                externalDisplayWindow.rootViewController = nil
            } else if let externalDisplayRootController {
                externalDisplayRootController.setGameplayActive(false)
            }
        }
        if let rootView = rootController?.view as? NativeMetalPresenterRootView {
            rootView.presenterHost = nil
            rootView.onGeometryChanged = nil
        }
        NSLayoutConstraint.deactivate(presenterLayoutConstraints)
        presenterLayoutConstraints.removeAll()
        NSLayoutConstraint.deactivate(manicSkinLayoutConstraints)
        manicSkinLayoutConstraints.removeAll()
        NSLayoutConstraint.deactivate(exitOverlayLayoutConstraints)
        exitOverlayLayoutConstraints.removeAll()
        activePresenterViewportFrame = nil
        exitMenuTapGesture = nil
        touchProbeGesture = nil
        exitOverlayView?.removeFromSuperview()
        exitOverlayView = nil
        manicSkinControlsView?.removeFromSuperview()
        manicSkinControlsView = nil
        presenterView?.removeFromSuperview()
        presenterView = nil
        touchOverlayRootController = nil
        touchOverlayWindow = nil
        externalDisplayRootController = nil
        externalDisplayWindow = nil
        rootController = nil
        window = nil
        isEmbeddedPresentation = false
        isEmbeddedWindowSubviewPresentation = false
        NSLog("Native Metal presenter stopped")
        NativeMetalDiagnostics.stop()
    }

    fileprivate var diagnosticSummary: String {
        "mode=\(isEmbeddedPresentation ? "embedded" : "window") window=\(NativeMetalDiagnostics.objectID(window)) key=\(window?.isKeyWindow == true ? 1 : 0) hidden=\(window?.isHidden == true ? 1 : 0) externalWindow=\(NativeMetalDiagnostics.objectID(externalDisplayWindow)) externalHidden=\(externalDisplayWindow?.isHidden == true ? 1 : 0) touchWindow=\(NativeMetalDiagnostics.objectID(touchOverlayWindow)) touchKey=\(touchOverlayWindow?.isKeyWindow == true ? 1 : 0) touchHidden=\(touchOverlayWindow?.isHidden == true ? 1 : 0) root=\(NativeMetalDiagnostics.rect(rootController?.view.bounds ?? .zero)) skin=\(manicSkinControlsView?.isTouchSkinActive == true ? 1 : 0) overlay=\(exitOverlayView?.isMenuVisible == true ? 1 : 0) viewport=\(NativeMetalDiagnostics.rect(activePresenterViewportFrame ?? .zero))"
    }

    private static func activeWindowScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ??
            scenes.first { $0.activationState == .foregroundInactive } ??
            scenes.first
    }

}

private enum NativeMetalWindowSendEventStage {
    case beforeOriginal
    case afterOriginal
}

final class NativeMetalExternalDisplayViewController: UIViewController {
    private let idleLogoView: UIImageView = {
        let imageView = UIImageView(image: UIImage(named: "DukeXLogo"))
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit
        imageView.alpha = 0.72
        imageView.accessibilityLabel = "DukeX"
        return imageView
    }()

    override func loadView() {
        let rootView = UIView()
        rootView.backgroundColor = .black
        rootView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view = rootView
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(idleLogoView)
        let widthConstraint = idleLogoView.widthAnchor.constraint(equalToConstant: 420)
        widthConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            idleLogoView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            idleLogoView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            idleLogoView.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.55),
            idleLogoView.heightAnchor.constraint(lessThanOrEqualToConstant: 96),
            widthConstraint
        ])
    }

    func setGameplayActive(_ isActive: Bool) {
        idleLogoView.isHidden = isActive
    }

    override var prefersStatusBarHidden: Bool {
        true
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        true
    }
}

private final class NativeMetalGlobalTouchRouter {
    static let shared = NativeMetalGlobalTouchRouter()

    private weak var host: NativeMetalPresenterHost?
    private var isInstalled = false

    func activate(host: NativeMetalPresenterHost) {
        installIfNeeded()
        self.host = host
        NativeMetalDiagnostics.log("GLOBAL_ROUTER", "activated host=\(NativeMetalDiagnostics.objectID(host))")
    }

    func deactivate(host: NativeMetalPresenterHost) {
        guard self.host === host else {
            return
        }

        self.host = nil
        NativeMetalDiagnostics.log("GLOBAL_ROUTER", "deactivated host=\(NativeMetalDiagnostics.objectID(host))")
    }

    func handle(event: UIEvent, stage: NativeMetalWindowSendEventStage) {
        guard let host else {
            return
        }

        if event.type == .touches {
            NativeMetalDiagnostics.log(
                "APP_SEND_EVENT_HOOK",
                "stage=\(stage == .beforeOriginal ? "pre" : "post") host=\(NativeMetalDiagnostics.objectID(host)) route=diagnostic-bridge"
            )
        }
        host.handleApplicationSendEvent(event, stage: stage)
    }

    func handle(window: UIWindow, event: UIEvent, stage: NativeMetalWindowSendEventStage) {
        guard let host else {
            return
        }

        if event.type == .touches {
            NativeMetalDiagnostics.log(
                "WINDOW_SEND_EVENT_HOOK",
                "stage=\(stage == .beforeOriginal ? "pre" : "post") host=\(NativeMetalDiagnostics.objectID(host)) window=\(NativeMetalDiagnostics.objectID(window))"
            )
        }
        host.handleWindowSendEvent(event, sourceWindow: window, stage: stage)
    }

    private func installIfNeeded() {
        guard !isInstalled else {
            return
        }

        guard let originalApplicationSendEvent = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.sendEvent(_:))),
              let replacementApplicationSendEvent = class_getInstanceMethod(UIApplication.self, #selector(UIApplication.dukex_sendEvent(_:))) else {
            NSLog("Native Metal global touch router could not install sendEvent hook")
            return
        }

        method_exchangeImplementations(originalApplicationSendEvent, replacementApplicationSendEvent)
        if let originalWindowSendEvent = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
           let replacementWindowSendEvent = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.dukex_windowSendEvent(_:))) {
            method_exchangeImplementations(originalWindowSendEvent, replacementWindowSendEvent)
            NativeMetalDiagnostics.log("GLOBAL_ROUTER", "window sendEvent swizzle installed")
        } else {
            NSLog("Native Metal global touch router could not install window sendEvent hook")
            NativeMetalDiagnostics.log("GLOBAL_ROUTER", "window sendEvent swizzle failed")
        }
        isInstalled = true
        NSLog("Native Metal global touch router installed")
        NativeMetalDiagnostics.log("GLOBAL_ROUTER", "sendEvent swizzle installed")
    }
}

private extension UIApplication {
    @objc(dukex_sendEvent:)
    func dukex_sendEvent(_ event: UIEvent) {
        NativeMetalGlobalTouchRouter.shared.handle(event: event, stage: .beforeOriginal)
        dukex_sendEvent(event)
        NativeMetalGlobalTouchRouter.shared.handle(event: event, stage: .afterOriginal)
    }
}

private extension UIWindow {
    @objc(dukex_windowSendEvent:)
    func dukex_windowSendEvent(_ event: UIEvent) {
        NativeMetalGlobalTouchRouter.shared.handle(window: self, event: event, stage: .beforeOriginal)
        dukex_windowSendEvent(event)
        NativeMetalGlobalTouchRouter.shared.handle(window: self, event: event, stage: .afterOriginal)
    }
}

private final class NativeMetalTouchProbeGestureRecognizer: UIGestureRecognizer {
    private let onTouches: (NativeGameplayTouchPhase, Set<UITouch>) -> Void
    private var activeTouchCount = 0

    init(onTouches: @escaping (NativeGameplayTouchPhase, Set<UITouch>) -> Void) {
        self.onTouches = onTouches
        super.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouchCount += touches.count
        moveToActiveState()
        onTouches(.began, touches)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        moveToActiveState()
        onTouches(.moved, touches)
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouches(.ended, touches)
        activeTouchCount = max(0, activeTouchCount - touches.count)
        state = activeTouchCount == 0 ? .ended : .changed
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouches(.cancelled, touches)
        activeTouchCount = max(0, activeTouchCount - touches.count)
        state = activeTouchCount == 0 ? .cancelled : .changed
        super.touchesCancelled(touches, with: event)
    }

    override func reset() {
        activeTouchCount = 0
        super.reset()
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    private func moveToActiveState() {
        switch state {
        case .possible:
            state = .began
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }
}

private final class NativeMetalPresenterRootView: UIView {
    var onGeometryChanged: ((String) -> Void)?
    weak var presenterHost: NativeMetalPresenterHost?

    override func layoutSubviews() {
        super.layoutSubviews()
        onGeometryChanged?("layout")
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onGeometryChanged?("safe-area")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if event?.type == .touches {
            let resultName = result.map { "\(type(of: $0))#\(NativeMetalDiagnostics.objectID($0))" } ?? "nil"
            let windowPoint = window.map { convert(point, to: $0) } ?? point
            NativeMetalDiagnostics.log(
                "PRESENTER_ROOT_HIT_TEST",
                "point=\(NativeMetalDiagnostics.point(point)) windowPoint=\(NativeMetalDiagnostics.point(windowPoint)) result=\(resultName) bounds=\(NativeMetalDiagnostics.rect(bounds)) touches=\(event?.allTouches?.map { NativeMetalDiagnostics.touch($0, in: self) }.joined(separator: " | ") ?? "none")"
            )
            presenterHost?.observePresenterHitTest(point: windowPoint, result: result, event: event)
            if presenterHost?.shouldCaptureRootTouch(at: windowPoint, originalResult: result) == true {
                NativeMetalDiagnostics.log(
                    "PRESENTER_ROOT_CAPTURE_RETURN",
                    "point=\(NativeMetalDiagnostics.point(point)) windowPoint=\(NativeMetalDiagnostics.point(windowPoint)) original=\(resultName)"
                )
                return self
            }
        }
        return result
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if presenterHost?.handleRootCapturedTouches(phase: .began, touches: touches, rootView: self) == true {
            return
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if presenterHost?.handleRootCapturedTouches(phase: .moved, touches: touches, rootView: self) == true {
            return
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if presenterHost?.handleRootCapturedTouches(phase: .ended, touches: touches, rootView: self) == true {
            return
        }
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if presenterHost?.handleRootCapturedTouches(phase: .cancelled, touches: touches, rootView: self) == true {
            return
        }
        super.touchesCancelled(touches, with: event)
    }
}

private enum NativePresenterControllerInput: Hashable {
    case exitMenu
    case select
    case cancel
    case up
    case down
    case left
    case right

    static let actionOrder: [NativePresenterControllerInput] = [
        .exitMenu,
        .cancel,
        .select,
        .up,
        .down,
        .left,
        .right
    ]
}

private final class NativeMetalPresenterWindow: UIWindow {
    var onGeometryChanged: ((String) -> Void)?
    weak var presenterHost: NativeMetalPresenterHost?
    weak var exitOverlayView: GameplayExitOverlayView?

    override func layoutSubviews() {
        super.layoutSubviews()
        onGeometryChanged?("window-layout")
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onGeometryChanged?("window-safe-area")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if event?.type == .touches {
            let resultName = result.map { "\(type(of: $0))#\(NativeMetalDiagnostics.objectID($0))" } ?? "nil"
            NativeMetalDiagnostics.log(
                "PRESENTER_WINDOW_HIT_TEST",
                "point=\(NativeMetalDiagnostics.point(point)) result=\(resultName) key=\(isKeyWindow ? 1 : 0) bounds=\(NativeMetalDiagnostics.rect(bounds)) touches=\(event?.allTouches?.map { NativeMetalDiagnostics.touch($0, in: rootViewController?.view) }.joined(separator: " | ") ?? "none")"
            )
            presenterHost?.observePresenterHitTest(point: point, result: result, event: event)
        }
        return result
    }

    override func sendEvent(_ event: UIEvent) {
        guard NativeMetalPresenterHost.usesPresenterWindowEventBridge else {
            super.sendEvent(event)
            return
        }

        if event.type == .touches {
            presenterHost?.noteTouchEventDelivery(reason: "presenter-window-sendEvent")
            NativeMetalDiagnostics.log(
                "PRESENTER_WINDOW_SEND_EVENT",
                "before-super window=\(NativeMetalDiagnostics.objectID(self)) key=\(isKeyWindow ? 1 : 0) touches=\(event.allTouches?.map { NativeMetalDiagnostics.touch($0, in: rootViewController?.view) }.joined(separator: " | ") ?? "none")"
            )
        }
        super.sendEvent(event)

        guard event.type == .touches else {
            return
        }

        _ = presenterHost?.handleRawWindowTouchEvent(event)
    }
}

private final class NativeMetalTouchOverlayViewController: UIViewController {
    override var prefersStatusBarHidden: Bool {
        true
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .all
    }
}

private final class NativeMetalTouchOverlayRootView: UIView {
    var onGeometryChanged: ((String) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onGeometryChanged?("layout")
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onGeometryChanged?("safe-area")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if event?.type == .touches {
            let resultName = result.map { "\(type(of: $0))#\(NativeMetalDiagnostics.objectID($0))" } ?? "nil"
            NativeMetalDiagnostics.log(
                "TOUCH_OVERLAY_ROOT_HIT_TEST",
                "point=\(NativeMetalDiagnostics.point(point)) result=\(resultName) bounds=\(NativeMetalDiagnostics.rect(bounds)) touches=\(event?.allTouches?.map { NativeMetalDiagnostics.touch($0, in: self) }.joined(separator: " | ") ?? "none")"
            )
        }

        return result === self ? nil : result
    }
}

private final class NativeMetalTouchOverlayWindow: UIWindow {
    var onGeometryChanged: ((String) -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onGeometryChanged?("window-layout")
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onGeometryChanged?("window-safe-area")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if event?.type == .touches {
            let resultName = result.map { "\(type(of: $0))#\(NativeMetalDiagnostics.objectID($0))" } ?? "nil"
            NativeMetalDiagnostics.log(
                "TOUCH_OVERLAY_WINDOW_HIT_TEST",
                "point=\(NativeMetalDiagnostics.point(point)) result=\(resultName) key=\(isKeyWindow ? 1 : 0) bounds=\(NativeMetalDiagnostics.rect(bounds)) touches=\(event?.allTouches?.map { NativeMetalDiagnostics.touch($0, in: rootViewController?.view) }.joined(separator: " | ") ?? "none")"
            )
        }
        return result
    }

    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches {
            NativeMetalDiagnostics.log(
                "TOUCH_OVERLAY_WINDOW_SEND_EVENT",
                "before-super window=\(NativeMetalDiagnostics.objectID(self)) key=\(isKeyWindow ? 1 : 0) touches=\(event.allTouches?.map { NativeMetalDiagnostics.touch($0, in: rootViewController?.view) }.joined(separator: " | ") ?? "none")"
            )
        }
        super.sendEvent(event)
    }
}

enum NativeMetalDiagnostics {
    private static let isEnabled = false
    private static let lock = NSLock()
    private static var fileHandle: FileHandle?
    private static var logURL: URL?
    private static var lineCount = 0
    private static var lastHeartbeat: CFTimeInterval = 0

    static var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fileHandle != nil
    }

    static func start(session: NativeMetalPresenterSession) {
        guard isEnabled else {
            return
        }

        lock.lock()
        fileHandle?.closeFile()
        fileHandle = nil
        logURL = nil
        lineCount = 0
        lastHeartbeat = 0
        lock.unlock()

        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            NSLog("DukeX touch diagnostics could not resolve Documents directory")
            return
        }

        let directoryURL = documentsURL.appendingPathComponent("DukeXDiagnostics", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let fileURL = directoryURL.appendingPathComponent("rotation-touch-\(formatter.string(from: Date())).log")
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: fileURL)
            lock.lock()
            fileHandle = handle
            logURL = fileURL
            lock.unlock()
            NSLog("DukeX touch diagnostics log: %@", fileURL.path)
            log("SESSION", "started title=\(session.displayTitle) dashboard=\(session.isDashboard ? 1 : 0) appState=\(appStateName(UIApplication.shared.applicationState))")
        } catch {
            NSLog("DukeX touch diagnostics failed to open log: %@", error.localizedDescription)
        }
    }

    static func stop() {
        guard isEnabled else {
            return
        }

        log("SESSION", "stopping")
        lock.lock()
        let handle = fileHandle
        let fileURL = logURL
        fileHandle = nil
        logURL = nil
        lock.unlock()
        handle?.synchronizeFile()
        handle?.closeFile()
        if let fileURL {
            NSLog("DukeX touch diagnostics finalized: %@", fileURL.path)
        }
    }

    static func log(_ category: String, _ message: String) {
        guard isEnabled else {
            return
        }

        let uptime = CACurrentMediaTime()
        let thread = Thread.isMainThread ? "main" : "background"
        let safeMessage = message
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let line = String(format: "%.6f [%@] %@ %@\n", uptime, thread, category, safeMessage)

        lock.lock()
        defer { lock.unlock() }
        guard let fileHandle else {
            return
        }
        fileHandle.write(Data(line.utf8))
        lineCount += 1
        if lineCount % 8 == 0 {
            fileHandle.synchronizeFile()
        }
    }

    static func logHeartbeat(host: NativeMetalPresenterHost) {
        guard isEnabled else {
            return
        }

        let now = CACurrentMediaTime()
        guard now - lastHeartbeat >= 2 else {
            return
        }
        lastHeartbeat = now
        log("HEARTBEAT", host.diagnosticSummary)
    }

    static func logWindowSnapshot(_ label: String, hostWindow: UIWindow? = nil) {
        guard isEnabled else {
            return
        }

        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                logWindowSnapshot(label, hostWindow: hostWindow)
            }
            return
        }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let sceneDetails = scenes.enumerated().map { sceneIndex, scene in
            let windowDetails = scene.windows.enumerated().map { windowIndex, window in
                let rootName = window.rootViewController.map { String(describing: type(of: $0)) } ?? "nil"
                return "w\(windowIndex){id=\(objectID(window)) host=\(window === hostWindow ? 1 : 0) key=\(window.isKeyWindow ? 1 : 0) hidden=\(window.isHidden ? 1 : 0) level=\(String(format: "%.1f", window.windowLevel.rawValue)) frame=\(rect(window.frame)) bounds=\(rect(window.bounds)) root=\(rootName)}"
            }.joined(separator: " ")
            return "scene\(sceneIndex){id=\(objectID(scene)) active=\(scene.activationState.rawValue) orient=\(scene.interfaceOrientation.rawValue) bounds=\(rect(scene.coordinateSpace.bounds)) windows=[\(windowDetails)]}"
        }.joined(separator: " ")
        log("WINDOWS", "\(label) appState=\(appStateName(UIApplication.shared.applicationState)) scenes=[\(sceneDetails)]")
    }

    static func touch(_ touch: UITouch, in view: UIView?) -> String {
        let sourceWindow = touch.window
        let windowPoint = sourceWindow.map { point(touch.location(in: $0)) } ?? "nil"
        let viewPoint = view.map { point(touch.location(in: $0)) } ?? "nil"
        return "id=\(objectID(touch)) phase=\(phaseName(touch.phase)) taps=\(touch.tapCount) win=\(objectID(sourceWindow)) winPoint=\(windowPoint) viewPoint=\(viewPoint)"
    }

    static func objectID(_ object: AnyObject?) -> String {
        guard let object else {
            return "nil"
        }
        let pointer = Unmanaged.passUnretained(object).toOpaque()
        return String(format: "0x%llx", UInt64(UInt(bitPattern: pointer)))
    }

    static func point(_ point: CGPoint) -> String {
        String(format: "(%.1f,%.1f)", point.x, point.y)
    }

    static func age(_ age: CFTimeInterval) -> String {
        age.isFinite ? String(format: "%.3f", age) : "inf"
    }

    static func rect(_ rect: CGRect) -> String {
        String(format: "(%.1f,%.1f %.1fx%.1f)", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    static func insets(_ insets: UIEdgeInsets) -> String {
        String(format: "(t%.1f,l%.1f,b%.1f,r%.1f)", insets.top, insets.left, insets.bottom, insets.right)
    }

    static func phaseName(_ phase: UITouch.Phase) -> String {
        switch phase {
        case .began:
            return "began"
        case .moved:
            return "moved"
        case .stationary:
            return "stationary"
        case .ended:
            return "ended"
        case .cancelled:
            return "cancelled"
        case .regionEntered:
            return "regionEntered"
        case .regionMoved:
            return "regionMoved"
        case .regionExited:
            return "regionExited"
        @unknown default:
            return "unknown"
        }
    }

    static func gameplayPhaseName(_ phase: NativeGameplayTouchPhase) -> String {
        switch phase {
        case .began:
            return "began"
        case .moved:
            return "moved"
        case .ended:
            return "ended"
        case .cancelled:
            return "cancelled"
        }
    }

    private static func appStateName(_ state: UIApplication.State) -> String {
        switch state {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
}

private extension CGRect {
    func isSameFrame(as other: CGRect) -> Bool {
        abs(origin.x - other.origin.x) < 0.5 &&
            abs(origin.y - other.origin.y) < 0.5 &&
            size.isSameSize(as: other.size)
    }

    var roundedForLayout: CGRect {
        CGRect(
            x: origin.x.rounded(.toNearestOrAwayFromZero),
            y: origin.y.rounded(.toNearestOrAwayFromZero),
            width: size.width.rounded(.toNearestOrAwayFromZero),
            height: size.height.rounded(.toNearestOrAwayFromZero)
        )
    }
}

private extension CGSize {
    func isSameSize(as other: CGSize) -> Bool {
        abs(width - other.width) < 0.5 && abs(height - other.height) < 0.5
    }
}
