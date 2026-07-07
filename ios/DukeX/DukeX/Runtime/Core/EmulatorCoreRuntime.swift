import Darwin
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers
import UIKit
import VideoToolbox

private typealias XboxCameraFrameProvider = @convention(c) (
    UnsafeMutablePointer<UInt8>?,
    Int,
    UnsafeMutablePointer<UInt32>?,
    UnsafeMutablePointer<UInt32>?,
    UnsafeMutablePointer<UInt64>?
) -> Int
private typealias XemuSetXboxCameraFrameProvider = @convention(c) (XboxCameraFrameProvider?) -> Void
private typealias XemuGameplayTouchCallback = @convention(c) (Int32, Int64, Float, Float) -> Void
private typealias XemuSetGameplayTouchCallback = @convention(c) (XemuGameplayTouchCallback?) -> Void
private typealias XemuInputDiagnosticCallback = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias XemuSetInputDiagnosticCallback = @convention(c) (XemuInputDiagnosticCallback?) -> Void

private let dukexXboxCameraFrameProvider: XboxCameraFrameProvider = { destination, capacity, width, height, sequence in
    XboxCameraFrameSource.shared.copyJPEGFrame(
        to: destination,
        capacity: capacity,
        width: width,
        height: height,
        sequence: sequence
    )
}

private let dukexGameplayTouchCallback: XemuGameplayTouchCallback = { phase, touchID, x, y in
    NativeMetalPresenterHost.handleGameplayTouch(
        phaseRaw: phase,
        touchID: touchID,
        normalizedX: x,
        normalizedY: y
    )
}

private let dukexInputDiagnosticCallback: XemuInputDiagnosticCallback = { message in
    guard let message else {
        return
    }

    NativeMetalDiagnostics.log("CORE_INPUT", String(cString: message))
}

final class XemuCoreRuntimeSymbolResolver {
    static let shared = XemuCoreRuntimeSymbolResolver()

    private let lock = NSLock()
    private var activeHandle: UnsafeMutableRawPointer?
    private var activeSlotIndex: Int?
    private var activeCoreURL: URL?
    private var generation: UInt64 = 0

    private init() {}

    func activate(handle: UnsafeMutableRawPointer?, slotIndex: Int, coreURL: URL) {
        lock.lock()
        defer { lock.unlock() }

        activeHandle = handle
        activeSlotIndex = slotIndex
        activeCoreURL = coreURL
        generation &+= 1
        NativeMetalDiagnostics.log(
            "CORE_SLOT_ACTIVE",
            "slot=\(slotIndex) url=\(coreURL.lastPathComponent) generation=\(generation)"
        )
    }

    func deactivate(handle: UnsafeMutableRawPointer?) {
        lock.lock()
        defer { lock.unlock() }

        guard activeHandle == handle else {
            return
        }

        activeHandle = nil
        activeSlotIndex = nil
        activeCoreURL = nil
        generation &+= 1
        NativeMetalDiagnostics.log("CORE_SLOT_ACTIVE", "slot=none generation=\(generation)")
    }

    func resolve(_ symbolName: String) -> (symbol: UnsafeMutableRawPointer, generation: UInt64)? {
        lock.lock()
        defer { lock.unlock() }

        guard let activeHandle,
              let symbol = dlsym(activeHandle, symbolName) else {
            return nil
        }
        return (symbol, generation)
    }

    func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }

        return generation
    }
}

@MainActor
final class EmulatorCoreRuntime: ObservableObject {
    enum RunState: Equatable {
        case unavailable(String)
        case ready(URL)
        case running(String)
        case exited(Int32)
        case failed(String)

        var canLaunch: Bool {
            switch self {
            case .ready, .exited:
                return true
            default:
                return false
            }
        }

        var isRunning: Bool {
            if case .running = self {
                return true
            }
            return false
        }
    }

    private typealias XemuMain = @convention(c) (
        Int32,
        UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> Int32
    private typealias XemuPrimeCoroutines = @convention(c) (CUnsignedInt) -> Void
    private typealias XemuSetExternalMetalLayer = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias XemuRequestShutdown = @convention(c) () -> Void
    private typealias QemuSystemResetRequest = @convention(c) (Int32) -> Void

    private static let qemuShutdownCauseGuestReset: Int32 = 7
    private static let coreSlotCount = 3

    @Published private(set) var state: RunState

    var isCoreSlotLimitReached: Bool {
        !coreSlots.isEmpty && reservedCoreSlotIndex == nil && nextCoreSlotIndex >= coreSlots.count
    }

    private struct CoreSlot {
        let index: Int
        let url: URL
        var handle: UnsafeMutableRawPointer?
        var entryPoint: XemuMain?
        var primeCoroutines: XemuPrimeCoroutines?
        var setExternalMetalLayer: XemuSetExternalMetalLayer?
        var requestShutdown: XemuRequestShutdown?
        var requestSystemReset: QemuSystemResetRequest?
        var setXboxCameraFrameProvider: XemuSetXboxCameraFrameProvider?
        var setGameplayTouchCallback: XemuSetGameplayTouchCallback?
        var setInputDiagnosticCallback: XemuSetInputDiagnosticCallback?
    }

    private var coreSlots: [CoreSlot]
    private var nextCoreSlotIndex = 0
    private var reservedCoreSlotIndex: Int?
    private var activeCoreSlotIndex: Int?

    init(bundle: Bundle = .main) {
        coreSlots = Self.resolveCoreSlotURLs(in: bundle).enumerated().map { index, url in
            CoreSlot(index: index, url: url)
        }
        state = coreSlots.first.map { RunState.ready($0.url) } ??
            .unavailable("libxemu-ios-core.dylib is not embedded.")
        NSLog("Xemu core runtime initialized: %@", String(describing: state))
    }

    func refresh(bundle: Bundle = .main) {
        guard !state.isRunning else {
            return
        }

        let slotURLs = Self.resolveCoreSlotURLs(in: bundle)
        if slotURLs.map(\.path) != coreSlots.map(\.url.path) {
            coreSlots = slotURLs.enumerated().map { index, url in
                CoreSlot(index: index, url: url)
            }
            nextCoreSlotIndex = 0
            reservedCoreSlotIndex = nil
            activeCoreSlotIndex = nil
        }

        state = coreSlots.first.map { RunState.ready($0.url) } ??
            .unavailable("libxemu-ios-core.dylib is not embedded.")
        NSLog("Xemu core runtime refreshed: %@", String(describing: state))
    }

    func launch(plan: XemuLaunchPlan) {
        guard !state.isRunning else {
            return
        }

        do {
            let coreSlotIndex = try reserveCoreSlotForNextLaunch()
            let entryPoint = try loadEntryPoint(forSlotAt: coreSlotIndex)
            let arguments = plan.arguments
            let jitMode = plan.jitMode
            let universalJITEnabled = plan.universalJITEnabled
            let xboxCameraEnabled = plan.xboxCameraEnabled
            let xboxHeadsetMicEnabled = plan.xboxHeadsetMicEnabled
            let setExternalMetalLayer = loadSetExternalMetalLayer(forSlotAt: coreSlotIndex)
            let requestShutdown = loadRequestShutdown(forSlotAt: coreSlotIndex)
            let requestSystemReset = loadRequestSystemReset(forSlotAt: coreSlotIndex)
            let setXboxCameraFrameProvider = loadSetXboxCameraFrameProvider(forSlotAt: coreSlotIndex)
            let setGameplayTouchCallback = loadSetGameplayTouchCallback(forSlotAt: coreSlotIndex)
            let setInputDiagnosticCallback: XemuSetInputDiagnosticCallback? = nil
            let coreSlot = coreSlots[coreSlotIndex]

            let logURL = Self.prepareRunLog(for: plan, arguments: arguments)
            let cameraLogURL = Self.prepareCameraDiagnosticLog(
                for: plan,
                arguments: arguments,
                runLogURL: logURL
            )
            XboxCameraDiagnosticLog.configure(cameraLogURL)
            Self.configureCameraDiagnosticEnvironment(
                cameraEnabled: xboxCameraEnabled,
                cameraLogURL: cameraLogURL
            )
            state = .running(plan.gameName)
            markCoreSlotLaunched(coreSlotIndex)
            NSLog(
                "Launching Xemu core slot %d for %@ from %@",
                coreSlot.index,
                plan.gameName,
                coreSlot.url.path
            )
            if let logURL {
                NSLog("Xemu run log: %@", logURL.path)
            }
            if let cameraLogURL {
                NSLog("Xbox camera diagnostic log: %@", cameraLogURL.path)
                XboxCameraDiagnosticLog.write("launch prepared target=\(plan.gameName)")
            }
            GameControllerBootstrap.shared.logSnapshot(reason: "before core launch")

            Task { @MainActor [self] in
                await XboxPeripheralPermissionPrimer.shared.prepareIfNeeded(
                    cameraEnabled: xboxCameraEnabled,
                    headsetMicEnabled: xboxHeadsetMicEnabled
                )
                if xboxCameraEnabled {
                    XboxCameraDiagnosticLog.write(
                        "registering frame provider available=\(setXboxCameraFrameProvider == nil ? 0 : 1)"
                    )
                    XboxCameraFrameSource.shared.start()
                    setXboxCameraFrameProvider?(dukexXboxCameraFrameProvider)
                    XboxCameraDiagnosticLog.write("frame provider registration requested")
                } else {
                    setXboxCameraFrameProvider?(nil)
                }
                defer {
                    XboxCameraDiagnosticLog.write("clearing frame provider after core return")
                    setXboxCameraFrameProvider?(nil)
                    if xboxCameraEnabled {
                        XboxCameraFrameSource.shared.stop()
                    }
                }
                let status = Self.invoke(
                    entryPoint,
                    arguments: arguments,
                    coreSlotIndex: coreSlot.index,
                    coreSlotURL: coreSlot.url,
                    coreHandle: coreSlot.handle,
                    jitMode: jitMode,
                    universalJITEnabled: universalJITEnabled,
                    xboxCameraEnabled: xboxCameraEnabled,
                    xboxHeadsetMicEnabled: xboxHeadsetMicEnabled,
                    cameraLogURL: cameraLogURL,
                    setExternalMetalLayer: setExternalMetalLayer,
                    setXboxCameraFrameProvider: setXboxCameraFrameProvider,
                    setGameplayTouchCallback: setGameplayTouchCallback,
                    setInputDiagnosticCallback: setInputDiagnosticCallback,
                    requestShutdown: requestShutdown,
                    requestSystemReset: requestSystemReset,
                    session: NativeMetalPresenterSession(
                        title: plan.gameName,
                        isDashboard: plan.isDashboard,
                        manicSkinPortraitURL: plan.manicSkinPortraitURL,
                        manicSkinLandscapeURL: plan.manicSkinLandscapeURL
                    )
                )

                Task { @MainActor [weak self] in
                    NSLog("Xemu core exited with status %d", status)
                    self?.clearActiveCoreSlot(coreSlotIndex)
                    self?.state = .exited(status)
                }
            }
        } catch {
            NSLog("Xemu core launch failed: %@", error.localizedDescription)
            state = .failed(error.localizedDescription)
        }
    }

    func prepareBeforeAutoJIT(coroutineReserve: CUnsignedInt = 640) throws {
        guard !state.isRunning else {
            return
        }

        guard coroutineReserve > 0 else {
            NSLog("Skipping pre-StikJIT coroutine prime")
            return
        }

        let coreSlotIndex = try reserveCoreSlotForNextLaunch()
        _ = try loadEntryPoint(forSlotAt: coreSlotIndex)
        let primeCoroutines = try loadPrimeCoroutines(forSlotAt: coreSlotIndex)
        NSLog("Pre-priming Xemu coroutine pool before StikJIT: %u", coroutineReserve)
        primeCoroutines(coroutineReserve)
    }

    private func reserveCoreSlotForNextLaunch() throws -> Int {
        guard !coreSlots.isEmpty else {
            throw RuntimeError.missingCore
        }

        if let reservedCoreSlotIndex {
            return reservedCoreSlotIndex
        }

        guard nextCoreSlotIndex < coreSlots.count else {
            throw RuntimeError.coreSlotsExhausted(limit: coreSlots.count)
        }

        let index = nextCoreSlotIndex
        reservedCoreSlotIndex = index
        return index
    }

    private func markCoreSlotLaunched(_ index: Int) {
        if reservedCoreSlotIndex == index {
            reservedCoreSlotIndex = nil
        }
        activeCoreSlotIndex = index
        nextCoreSlotIndex = index + 1
    }

    private func clearActiveCoreSlot(_ index: Int) {
        guard activeCoreSlotIndex == index else {
            return
        }

        let handle = coreSlots.indices.contains(index) ? coreSlots[index].handle : nil
        activeCoreSlotIndex = nil
        XemuCoreRuntimeSymbolResolver.shared.deactivate(handle: handle)
    }

    private func loadEntryPoint(forSlotAt index: Int) throws -> XemuMain {
        if let entryPoint = coreSlots[index].entryPoint {
            return entryPoint
        }

        let coreURL = coreSlots[index].url
        NSLog("Loading Xemu core dylib from %@", coreURL.path)
        let openFlags = RTLD_NOW | RTLD_LOCAL
        guard let handle = dlopen(coreURL.path, openFlags) else {
            throw RuntimeError.dynamicLoader(Self.dynamicLoaderError())
        }

        guard let symbol = dlsym(handle, "xemu_ios_main") else {
            throw RuntimeError.dynamicLoader(Self.dynamicLoaderError())
        }

        NSLog("Resolved xemu_ios_main")
        coreSlots[index].handle = handle
        let entryPoint = unsafeBitCast(symbol, to: XemuMain.self)
        coreSlots[index].entryPoint = entryPoint
        return entryPoint
    }

    private func loadPrimeCoroutines(forSlotAt index: Int) throws -> XemuPrimeCoroutines {
        if let primeCoroutines = coreSlots[index].primeCoroutines {
            return primeCoroutines
        }

        _ = try loadEntryPoint(forSlotAt: index)
        guard let handle = coreSlots[index].handle else {
            throw RuntimeError.missingCore
        }

        guard let symbol = dlsym(handle, "xemu_ios_coroutine_prime_global_pool") else {
            throw RuntimeError.dynamicLoader(Self.dynamicLoaderError())
        }

        NSLog("Resolved xemu_ios_coroutine_prime_global_pool")
        let primeCoroutines = unsafeBitCast(symbol, to: XemuPrimeCoroutines.self)
        coreSlots[index].primeCoroutines = primeCoroutines
        return primeCoroutines
    }

    private func loadSetExternalMetalLayer(forSlotAt index: Int) -> XemuSetExternalMetalLayer? {
        if let setExternalMetalLayer = coreSlots[index].setExternalMetalLayer {
            return setExternalMetalLayer
        }

        guard let handle = coreSlots[index].handle else {
            return nil
        }

        guard let symbol = dlsym(handle, "xemu_ios_set_external_metal_layer") else {
            NSLog("xemu_ios_set_external_metal_layer is not available; falling back to SDL Metal layer")
            return nil
        }

        NSLog("Resolved xemu_ios_set_external_metal_layer")
        let setter = unsafeBitCast(symbol, to: XemuSetExternalMetalLayer.self)
        coreSlots[index].setExternalMetalLayer = setter
        return setter
    }

    private func loadRequestShutdown(forSlotAt index: Int) -> XemuRequestShutdown? {
        if let requestShutdown = coreSlots[index].requestShutdown {
            return requestShutdown
        }

        guard let handle = coreSlots[index].handle else {
            return nil
        }

        guard let symbol = dlsym(handle, "xemu_ios_request_shutdown") else {
            NSLog("xemu_ios_request_shutdown is not available")
            return nil
        }

        NSLog("Resolved xemu_ios_request_shutdown")
        let requestShutdown = unsafeBitCast(symbol, to: XemuRequestShutdown.self)
        coreSlots[index].requestShutdown = requestShutdown
        return requestShutdown
    }

    private func loadRequestSystemReset(forSlotAt index: Int) -> QemuSystemResetRequest? {
        if let requestSystemReset = coreSlots[index].requestSystemReset {
            return requestSystemReset
        }

        guard let handle = coreSlots[index].handle else {
            return nil
        }

        guard let symbol = dlsym(handle, "qemu_system_reset_request") else {
            NSLog("qemu_system_reset_request is not available")
            return nil
        }

        NSLog("Resolved qemu_system_reset_request")
        let requestSystemReset = unsafeBitCast(symbol, to: QemuSystemResetRequest.self)
        coreSlots[index].requestSystemReset = requestSystemReset
        return requestSystemReset
    }

    private func loadSetXboxCameraFrameProvider(forSlotAt index: Int) -> XemuSetXboxCameraFrameProvider? {
        if let setXboxCameraFrameProvider = coreSlots[index].setXboxCameraFrameProvider {
            return setXboxCameraFrameProvider
        }

        guard let handle = coreSlots[index].handle else {
            return nil
        }

        guard let symbol = dlsym(handle, "xemu_ios_set_xbox_camera_frame_provider") else {
            NSLog("xemu_ios_set_xbox_camera_frame_provider is not available")
            return nil
        }

        NSLog("Resolved xemu_ios_set_xbox_camera_frame_provider")
        let setter = unsafeBitCast(symbol, to: XemuSetXboxCameraFrameProvider.self)
        coreSlots[index].setXboxCameraFrameProvider = setter
        return setter
    }

    private func loadSetGameplayTouchCallback(forSlotAt index: Int) -> XemuSetGameplayTouchCallback? {
        if let setGameplayTouchCallback = coreSlots[index].setGameplayTouchCallback {
            return setGameplayTouchCallback
        }

        guard let handle = coreSlots[index].handle else {
            return nil
        }

        guard let symbol = dlsym(handle, "xemu_ios_set_gameplay_touch_event_callback") else {
            NSLog("xemu_ios_set_gameplay_touch_event_callback is not available; native touch bridge disabled")
            return nil
        }

        NSLog("Resolved xemu_ios_set_gameplay_touch_event_callback")
        let setter = unsafeBitCast(symbol, to: XemuSetGameplayTouchCallback.self)
        coreSlots[index].setGameplayTouchCallback = setter
        return setter
    }

    private func loadSetInputDiagnosticCallback(forSlotAt index: Int) -> XemuSetInputDiagnosticCallback? {
        if let setInputDiagnosticCallback = coreSlots[index].setInputDiagnosticCallback {
            return setInputDiagnosticCallback
        }

        guard let handle = coreSlots[index].handle else {
            return nil
        }

        guard let symbol = dlsym(handle, "xemu_ios_set_input_diagnostic_callback") else {
            NSLog("xemu_ios_set_input_diagnostic_callback is not available")
            return nil
        }

        NSLog("Resolved xemu_ios_set_input_diagnostic_callback")
        let setter = unsafeBitCast(symbol, to: XemuSetInputDiagnosticCallback.self)
        coreSlots[index].setInputDiagnosticCallback = setter
        return setter
    }

    private static func prepareRunLog(
        for plan: XemuLaunchPlan,
        arguments: [String]
    ) -> URL? {
        do {
            let documentsURL = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let logDirectoryURL = documentsURL.appendingPathComponent(
                "DukeXLogs",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: logDirectoryURL,
                withIntermediateDirectories: true
            )

            let logURL = logDirectoryURL.appendingPathComponent("latest.log")
            let header = """

            === DukeX Launch ===
            Date: \(ISO8601DateFormatter().string(from: Date()))
            Target: \(plan.gameName)
            JIT Path: \(plan.jitMode.title)
            JIT Handoff: \(plan.requiresJITHandoff ? "required" : "not required")
            Universal.js JIT: \(plan.universalJITEnabled ? "enabled" : "disabled")
            Xbox Video Chat Camera: \(plan.xboxCameraEnabled ? "enabled" : "disabled")
            Xbox Live Communicator: \(plan.xboxHeadsetMicEnabled ? "enabled" : "disabled")
            Config: \(plan.configURL.path)
            Arguments: \(arguments.joined(separator: " "))

            """

            try header.write(to: logURL, atomically: true, encoding: .utf8)
            freopen(logURL.path, "a", stdout)
            freopen(logURL.path, "a", stderr)
            setbuf(stdout, nil)
            setbuf(stderr, nil)
            return logURL
        } catch {
            NSLog("Unable to prepare DukeX run log: %@", error.localizedDescription)
            return nil
        }
    }

    private static func prepareCameraDiagnosticLog(
        for plan: XemuLaunchPlan,
        arguments: [String],
        runLogURL: URL?
    ) -> URL? {
        guard plan.xboxCameraEnabled else {
            return nil
        }

        do {
            let documentsURL = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let logDirectoryURL = documentsURL.appendingPathComponent(
                "DukeXLogs",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: logDirectoryURL,
                withIntermediateDirectories: true
            )

            let logURL = logDirectoryURL.appendingPathComponent("camera-latest.log")
            let header = """

            === DukeX Xbox Camera Diagnostic ===
            Date: \(ISO8601DateFormatter().string(from: Date()))
            Target: \(plan.gameName)
            Run Log: \(runLogURL?.path ?? "unavailable")
            Camera Peripheral: enabled
            Headset Mic Peripheral: \(plan.xboxHeadsetMicEnabled ? "enabled" : "disabled")
            Arguments: \(arguments.joined(separator: " "))

            Milestones:
            - permission primer
            - AV capture start/stop
            - frame provider registration
            - USB camera realize/reset
            - descriptor/config/interface requests
            - OV519 bridge/I2C register traffic
            - isochronous frame delivery

            """

            try header.write(to: logURL, atomically: true, encoding: .utf8)
            return logURL
        } catch {
            NSLog("Unable to prepare Xbox camera diagnostic log: %@", error.localizedDescription)
            return nil
        }
    }

    private static func setEnvironment(_ values: [(String, String)]) {
        for (name, value) in values {
            setenv(name, value, 1)
        }
    }

    private static func unsetEnvironment(_ names: [String]) {
        for name in names {
            unsetenv(name)
        }
    }

    private static func configureCameraDiagnosticEnvironment(
        cameraEnabled: Bool,
        cameraLogURL: URL?
    ) {
        if cameraEnabled {
            setEnvironment([
                ("XEMU_IOS_CAMERA_DEBUG", "1"),
                ("XEMU_IOS_CAMERA_TRACE", "1")
            ])

            if let cameraLogURL {
                let pvideoDumpURL = cameraLogURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("pvideo-frame-latest.bmp")
                setEnvironment([
                    ("XEMU_IOS_CAMERA_LOG_PATH", cameraLogURL.path),
                    ("XEMU_IOS_PVIDEO_DUMP_PATH", pvideoDumpURL.path)
                ])
            } else {
                unsetEnvironment([
                    "XEMU_IOS_CAMERA_LOG_PATH",
                    "XEMU_IOS_PVIDEO_DUMP_PATH"
                ])
            }
        } else {
            setEnvironment([
                ("XEMU_IOS_CAMERA_DEBUG", "0")
            ])
            unsetEnvironment([
                "XEMU_IOS_CAMERA_TRACE",
                "XEMU_IOS_CAMERA_LOG_PATH",
                "XEMU_IOS_PVIDEO_DUMP_PATH"
            ])
        }
    }

    private static func invoke(
        _ entryPoint: XemuMain,
        arguments: [String],
        coreSlotIndex: Int,
        coreSlotURL: URL,
        coreHandle: UnsafeMutableRawPointer?,
        jitMode: RuntimeJITMode,
        universalJITEnabled: Bool,
        xboxCameraEnabled: Bool,
        xboxHeadsetMicEnabled: Bool,
        cameraLogURL: URL?,
        setExternalMetalLayer: XemuSetExternalMetalLayer?,
        setXboxCameraFrameProvider: XemuSetXboxCameraFrameProvider?,
        setGameplayTouchCallback: XemuSetGameplayTouchCallback?,
        setInputDiagnosticCallback: XemuSetInputDiagnosticCallback?,
        requestShutdown: XemuRequestShutdown?,
        requestSystemReset: QemuSystemResetRequest?,
        session: NativeMetalPresenterSession
    ) -> Int32 {
        MetalDiagnostics.configurePerformanceHUD()
        let presentPacingMode = PresentPacingMode.current
        let forceThirtyFPSLock =
            UserDefaults.standard.object(forKey: EmulatorFileStore.forceThirtyFPSLockEnabledKey) as? Bool ?? false
        let depthClampEnabled =
            UserDefaults.standard.object(forKey: EmulatorFileStore.depthClampEnabledKey) as? Bool ?? true
        let effectivePresentFPS = forceThirtyFPSLock ? "30" : presentPacingMode.presentFPS
        let effectivePresentMode = forceThirtyFPSLock ? "fifo" : presentPacingMode.vulkanPresentMode
        let effectiveDisplaySync = forceThirtyFPSLock ? true : presentPacingMode.displaySyncEnabled
        let effectiveNominalFPS = forceThirtyFPSLock ? "30" : presentPacingMode.nominalFramesPerSecond

        setEnvironment([
            ("XEMU_IOS_JIT_MODE", jitMode.environmentValue),
            ("XEMU_IOS_UNIVERSAL_JIT", universalJITEnabled ? "1" : "0"),
            ("XEMU_IOS_XBOX_CAMERA", xboxCameraEnabled ? "1" : "0"),
            ("XEMU_IOS_XBOX_HEADSET_MIC", xboxHeadsetMicEnabled ? "1" : "0"),
            ("XEMU_IOS_CAMERA_DEBUG", xboxCameraEnabled ? "1" : "0"),
            ("XEMU_IOS_VK_SWAPCHAIN", "1"),
            ("XEMU_IOS_NATIVE_METAL_PRESENTER", "1"),
            ("XEMU_IOS_PRESENTER_PORTRAIT_SCALE", "1.0"),
            ("XEMU_IOS_PRESENTER_PORTRAIT_ALIGN_X", "0.5"),
            ("XEMU_IOS_PRESENTER_PORTRAIT_ALIGN_Y", "0.5"),
            ("XEMU_IOS_PRESENTER_LANDSCAPE_SCALE", "1.0"),
            ("XEMU_IOS_PRESENTER_LANDSCAPE_ALIGN_X", "0.5"),
            ("XEMU_IOS_PRESENTER_LANDSCAPE_ALIGN_Y", "0.5"),
            ("XEMU_IOS_PRESENTER_ASPECT", "auto"),
            ("XEMU_IOS_PRESENTER_LINEAR_FILTER", "1"),
            ("XEMU_IOS_PRESENTER_FLIP_X", "0"),
            ("XEMU_IOS_PRESENTER_FLIP_Y", "1"),
            ("XEMU_IOS_VK_PRESENT_FPS", effectivePresentFPS),
            ("XEMU_IOS_VK_PRESENT_MODE", effectivePresentMode),
            ("XEMU_IOS_DISPLAY_SYNC", effectiveDisplaySync ? "1" : "0"),
            ("XEMU_IOS_NOMINAL_FPS", effectiveNominalFPS),
            ("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "0"),
            ("XEMU_IOS_HOST_DEPTH_INTERPOLATION", "0"),
            ("XEMU_IOS_HOST_DEPTH_INTERPOLATION_MODE", "perspective"),
            ("XEMU_IOS_DEPTH_CLAMP", depthClampEnabled ? "1" : "0"),
            ("XEMU_IOS_DISABLE_SHADER_DEPTH", "1"),
            ("XEMU_IOS_STRICT_SURFACE_TEXTURE_FORMATS", "0"),
            ("XEMU_IOS_FALLBACK_GENERATION_FILTER", "1"),
            ("XEMU_IOS_SKIP_GL_FINISH", "1"),
            ("XEMU_IOS_TCG_WATCHDOG", "off"),
            ("XEMU_IOS_COROUTINE_PRIME_COUNT", "640")
        ])

        configureCameraDiagnosticEnvironment(
            cameraEnabled: xboxCameraEnabled,
            cameraLogURL: cameraLogURL
        )

        setEnvironment([
            ("XEMU_IOS_VK_SWAPCHAIN_TRACE", "0"),
            ("XEMU_IOS_DISPLAY_PERF_STATS", "0"),
            ("XEMU_IOS_SURFACE_STATS", "0"),
            ("XEMU_IOS_SURFACE_TEXTURE_TRACE", "0"),
            ("XEMU_IOS_TCG_TRACE", "0"),
            ("XEMU_IOS_IRQ_TRACE", "0"),
            ("XEMU_IOS_SYNC_DMA", "0"),
            ("XEMU_IOS_NV2A_READ_TRACE", "0"),
            ("XEMU_IOS_PCI_TRACE", "0"),
            ("XEMU_IOS_NV2A_WRITE_TRACE", "0"),
            ("XEMU_IOS_SYNC_RAW", "0"),
            ("XEMU_IOS_QCOW2_TRACE", "0"),
            ("XEMU_IOS_BLK_TRACE", "0"),
            ("XEMU_IOS_DMA_TRACE", "0"),
            ("XEMU_IOS_COROUTINE_TRACE", "0"),
            ("XEMU_IOS_VK_SUBMIT_TRACE", "0"),
            ("XEMU_IOS_RR_RETURN_TRACE", "0"),
            ("XEMU_IOS_IDE_TRACE", "0"),
            ("XEMU_IOS_PVIDEO_TRACE", xboxCameraEnabled ? "1" : "0"),
            ("XEMU_IOS_VK_RENDERER_TRACE", "0"),
            ("XEMU_IOS_VK_MEMORY_TRACE", "0"),
            ("XEMU_IOS_FRAMEBUFFER_TRACE", "0"),
            ("XEMU_IOS_VK_TEXTURE_TRACE", "0"),
            ("XEMU_IOS_RENDER_TRACE", "0"),
            ("XEMU_IOS_IO_TRACE", "0"),
            ("XEMU_IOS_TCG_EXIT_TRACE", "0"),
            ("XEMU_IOS_NET_TRACE", "0")
        ])

        unsetEnvironment([
            "XEMU_IOS_TCG_MAX_INSNS",
            "XEMU_IOS_TCG_IRQ_INSNS",
            "XEMU_IOS_TCG_NOCHAIN",
            "XEMU_IOS_DIRECT_RWX_COPY"
        ])
        NSLog("XEMU_IOS_JIT_MODE=%@", jitMode.environmentValue)
        NSLog("XEMU_IOS_UNIVERSAL_JIT=%@", universalJITEnabled ? "1" : "0")
        NSLog("XEMU_IOS_XBOX_CAMERA=%@", xboxCameraEnabled ? "1" : "0")
        NSLog("XEMU_IOS_XBOX_HEADSET_MIC=%@", xboxHeadsetMicEnabled ? "1" : "0")
        NSLog("XEMU_IOS_CAMERA_LOG_PATH=%@", cameraLogURL?.path ?? "unset")
        NSLog(
            "XEMU_IOS_PVIDEO_DUMP_PATH=%@",
            cameraLogURL?
                .deletingLastPathComponent()
                .appendingPathComponent("pvideo-frame-latest.bmp")
                .path ?? "unset"
        )
        NSLog("XEMU_IOS_VK_SWAPCHAIN=1")
        NSLog(
            "XEMU_IOS_PRESENT_PACING=%@ force30=%@ mode=%@ displaySync=%@ nominalFPS=%@ presentFPS=%@",
            presentPacingMode.rawValue,
            forceThirtyFPSLock ? "1" : "0",
            effectivePresentMode,
            effectiveDisplaySync ? "1" : "0",
            effectiveNominalFPS,
            effectivePresentFPS
        )
        NSLog("XEMU_IOS_DEPTH_CLAMP=%@", depthClampEnabled ? "1" : "0")
        NSLog("Xemu core argv: %@", arguments.joined(separator: " "))

        let presenterHost = NativeMetalPresenterHost()
        var gameplayTouchCallbackRegistered = false
        var inputDiagnosticCallbackRegistered = false

        XemuCoreRuntimeSymbolResolver.shared.activate(
            handle: coreHandle,
            slotIndex: coreSlotIndex,
            coreURL: coreSlotURL
        )
        defer {
            XemuCoreRuntimeSymbolResolver.shared.deactivate(handle: coreHandle)
        }

        if let layerPointer = presenterHost.start(
            session: session,
            onExitRequested: {
                XboxCameraDiagnosticLog.write("exit requested from native presenter")
                setXboxCameraFrameProvider?(nil)
                if xboxCameraEnabled {
                    XboxCameraFrameSource.shared.stop()
                }
                NotificationCenter.default.post(name: .dukeXReturnToGamesRequested, object: nil)
                requestShutdown?()
            },
            onRestartRequested: {
                guard let requestSystemReset else {
                    NSLog("qemu_system_reset_request unavailable; in-place restart request ignored")
                    return false
                }

                NSLog("Requesting in-place Xemu system reset for %@", session.displayTitle)
                requestSystemReset(Self.qemuShutdownCauseGuestReset)
                return true
            }
        ) {
            setExternalMetalLayer?(layerPointer)
            setInputDiagnosticCallback?(dukexInputDiagnosticCallback)
            inputDiagnosticCallbackRegistered = setInputDiagnosticCallback != nil
            setGameplayTouchCallback?(dukexGameplayTouchCallback)
            gameplayTouchCallbackRegistered = setGameplayTouchCallback != nil
            NativeMetalDiagnostics.log(
                "CORE_BRIDGE",
                "externalLayer=\(String(format: "0x%llx", UInt64(UInt(bitPattern: layerPointer)))) gameplayCallbackRegistered=\(gameplayTouchCallbackRegistered ? 1 : 0) inputDiagnosticsRegistered=\(inputDiagnosticCallbackRegistered ? 1 : 0) setExternalAvailable=\(setExternalMetalLayer == nil ? 0 : 1)"
            )
            NSLog(
                "Native CAMetalLayer presenter active: 0x%llx",
                UInt64(UInt(bitPattern: layerPointer))
            )
        } else {
            setExternalMetalLayer?(nil)
            NSLog("Native CAMetalLayer presenter unavailable; xemu will create an SDL Metal layer")
        }
        defer {
            if gameplayTouchCallbackRegistered {
                setGameplayTouchCallback?(nil)
            }
            if inputDiagnosticCallbackRegistered {
                setInputDiagnosticCallback?(nil)
            }
            setExternalMetalLayer?(nil)
            presenterHost.stop()
        }

        let argv = arguments.map { strdup($0) } + [nil]
        defer {
            for arg in argv {
                free(arg)
            }
        }

        var mutableArgv = argv
        NativeMetalDiagnostics.log("CORE_ENTRY", "calling xemu_ios_main argc=\(arguments.count) mainThread=\(Thread.isMainThread ? 1 : 0)")
        XboxCameraDiagnosticLog.write("calling xemu_ios_main argc=\(arguments.count)")
        return mutableArgv.withUnsafeMutableBufferPointer { buffer in
            let status = entryPoint(Int32(arguments.count), buffer.baseAddress)
            NativeMetalDiagnostics.log("CORE_ENTRY", "xemu_ios_main returned status=\(status)")
            XboxCameraDiagnosticLog.write("xemu_ios_main returned status=\(status)")
            return status
        }
    }

    private static func resolveCoreSlotURLs(in bundle: Bundle) -> [URL] {
        let frameworksURL = bundle.privateFrameworksURL
        guard let frameworksURL else {
            return []
        }

        let slotURLs = (0..<coreSlotCount).map {
            frameworksURL.appendingPathComponent("libxemu-ios-core-slot\($0).dylib")
        }
        if slotURLs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            return slotURLs
        }

        let coreURL = frameworksURL.appendingPathComponent("libxemu-ios-core.dylib")
        guard FileManager.default.fileExists(atPath: coreURL.path) else {
            return []
        }
        return [coreURL]
    }

    private static func dynamicLoaderError() -> String {
        guard let error = dlerror() else {
            return "Unknown dynamic loader error."
        }
        return String(cString: error)
    }
}

private enum RuntimeError: LocalizedError {
    case missingCore
    case dynamicLoader(String)
    case coreSlotsExhausted(limit: Int)

    var errorDescription: String? {
        switch self {
        case .missingCore:
            return "libxemu-ios-core.dylib is not embedded."
        case .dynamicLoader(let message):
            return message
        case .coreSlotsExhausted(let limit):
            return "DukeX has used all \(limit) disposable core slots for this session. Restart DukeX to clear the core slots before launching another game."
        }
    }
}

private enum XboxCameraDiagnosticLog {
    private static let lock = NSLock()
    private static var url: URL?

    static func configure(_ newURL: URL?) {
        lock.lock()
        url = newURL
        lock.unlock()

        if let newURL {
            write("diagnostic log configured path=\(newURL.path)")
        }
    }

    static func write(_ message: String) {
        lock.lock()
        let currentURL = url
        lock.unlock()

        guard let currentURL else {
            return
        }

        let timestamp = String(format: "%.6f", Date().timeIntervalSince1970)
        guard let data = "\(timestamp) [AppCamera] \(message)\n".data(using: .utf8) else {
            return
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        if !FileManager.default.fileExists(atPath: currentURL.path) {
            FileManager.default.createFile(atPath: currentURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: currentURL) else {
            return
        }
        handle.seekToEndOfFile()
        handle.write(data)
        handle.closeFile()
    }
}

@MainActor
private final class XboxPeripheralPermissionPrimer {
    static let shared = XboxPeripheralPermissionPrimer()

    private var cameraPrepared = false
    private var microphonePrepared = false

    func prepareIfNeeded(cameraEnabled: Bool, headsetMicEnabled: Bool) async {
        XboxCameraDiagnosticLog.write(
            "permission primer requested camera=\(cameraEnabled ? 1 : 0) mic=\(headsetMicEnabled ? 1 : 0) cameraPrepared=\(cameraPrepared ? 1 : 0) micPrepared=\(microphonePrepared ? 1 : 0)"
        )
        guard cameraEnabled || headsetMicEnabled else {
            return
        }

        var cameraGranted = !cameraEnabled || cameraPrepared
        var microphoneGranted = !headsetMicEnabled || microphonePrepared

        if cameraEnabled && !cameraPrepared {
            XboxCameraDiagnosticLog.write("requesting camera permission")
            cameraGranted = await AVCaptureDevice.requestAccess(for: .video)
            cameraPrepared = cameraGranted
        }

        if headsetMicEnabled && !microphonePrepared {
            XboxCameraDiagnosticLog.write("requesting microphone permission")
            microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
            microphonePrepared = microphoneGranted
        }

        NSLog(
            "Xbox peripheral permissions camera=%@ microphone=%@",
            cameraGranted ? "granted" : "denied",
            microphoneGranted ? "granted" : "denied"
        )
        XboxCameraDiagnosticLog.write(
            "permission result camera=\(cameraGranted ? "granted" : "denied") mic=\(microphoneGranted ? "granted" : "denied")"
        )

        guard cameraGranted else {
            XboxCameraDiagnosticLog.write("camera permission denied; capture source will not be prepared")
            return
        }

        if let frontCamera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .front
        ) {
            NSLog("Xbox camera host source prepared: %@", frontCamera.localizedName)
            XboxCameraDiagnosticLog.write("front camera available name=\(frontCamera.localizedName)")
        } else {
            NSLog("Xbox camera host source unavailable: no front camera")
            XboxCameraDiagnosticLog.write("front camera unavailable")
        }
    }
}

private final class XboxCameraFrameSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let shared = XboxCameraFrameSource()

    private let sessionQueue = DispatchQueue(label: "DukeX.XboxCamera.Session")
    private let sampleQueue = DispatchQueue(label: "DukeX.XboxCamera.Sample")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let videoToolboxJPEGEncoder = XboxCameraVideoToolboxJPEGEncoder()
    private let jpegEncoder = XboxCameraJPEGEncoder()
    private let lock = NSLock()

    private var session: AVCaptureSession?
    private var isRunning = false
    private var latestJPEG = Data()
    private var latestWidth: UInt32 = 320
    private var latestHeight: UInt32 = 240
    private var latestSequence: UInt64 = 0
    private var lastFrameTime = 0.0
    private var providerCopyCount: UInt64 = 0
    private var diagnosticJPEGDumped = false

    private override init() {
        latestJPEG = Self.makePlaceholderJPEG()
        super.init()
    }

    func start() {
        XboxCameraDiagnosticLog.write("capture source start requested")
        lock.lock()
        diagnosticJPEGDumped = false
        lock.unlock()
        sessionQueue.async { [weak self] in
            guard let self, !self.isRunning else {
                XboxCameraDiagnosticLog.write("capture source start skipped; already running")
                return
            }

            let session = AVCaptureSession()
            session.beginConfiguration()
            if session.canSetSessionPreset(.low) {
                session.sessionPreset = .low
                XboxCameraDiagnosticLog.write("capture session preset=low")
            } else {
                XboxCameraDiagnosticLog.write("capture session preset=default")
            }

            guard let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .front
            ) else {
                NSLog("Xbox camera host source unavailable: no front camera")
                XboxCameraDiagnosticLog.write("capture source failed: no front camera")
                session.commitConfiguration()
                return
            }
            XboxCameraDiagnosticLog.write("capture source selected camera=\(camera.localizedName)")

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if session.canAddInput(input) {
                    session.addInput(input)
                    XboxCameraDiagnosticLog.write("capture input added")
                } else {
                    NSLog("Xbox camera host source unavailable: cannot add input")
                    XboxCameraDiagnosticLog.write("capture source failed: cannot add input")
                    session.commitConfiguration()
                    return
                }
            } catch {
                NSLog("Xbox camera host source failed: %@", error.localizedDescription)
                XboxCameraDiagnosticLog.write("capture input creation failed: \(error.localizedDescription)")
                session.commitConfiguration()
                return
            }

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: self.sampleQueue)

            if session.canAddOutput(output) {
                session.addOutput(output)
                XboxCameraDiagnosticLog.write("capture output added")
            } else {
                NSLog("Xbox camera host source unavailable: cannot add output")
                XboxCameraDiagnosticLog.write("capture source failed: cannot add output")
                session.commitConfiguration()
                return
            }

            if let connection = output.connection(with: .video) {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                    XboxCameraDiagnosticLog.write("capture connection orientation=portrait")
                }
                if connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = true
                    XboxCameraDiagnosticLog.write("capture connection mirrored=1")
                }
            }

            session.commitConfiguration()
            self.session = session
            self.isRunning = true
            XboxCameraDiagnosticLog.write("capture session committed; startRunning begin")
            session.startRunning()
            NSLog("Xbox camera host source streaming: %@", camera.localizedName)
            XboxCameraDiagnosticLog.write("capture source streaming isRunning=\(session.isRunning ? 1 : 0)")
        }
    }

    func stop() {
        XboxCameraDiagnosticLog.write("capture source stop requested")
        sessionQueue.async { [weak self] in
            guard let self else {
                return
            }

            let session = self.session
            self.session = nil
            self.isRunning = false

            if let session {
                XboxCameraDiagnosticLog.write("capture session stopRunning begin")
                session.stopRunning()
            }

            self.lock.lock()
            self.latestJPEG = Self.makePlaceholderJPEG()
            self.latestSequence &+= 1
            self.lastFrameTime = 0
            self.providerCopyCount = 0
            self.diagnosticJPEGDumped = false
            self.lock.unlock()

            if session != nil {
                NSLog("Xbox camera host source stopped")
                XboxCameraDiagnosticLog.write("capture source stopped")
            } else {
                XboxCameraDiagnosticLog.write("capture source stop completed; no active session")
            }
        }
    }

    func copyJPEGFrame(
        to destination: UnsafeMutablePointer<UInt8>?,
        capacity: Int,
        width: UnsafeMutablePointer<UInt32>?,
        height: UnsafeMutablePointer<UInt32>?,
        sequence: UnsafeMutablePointer<UInt64>?
    ) -> Int {
        lock.lock()
        providerCopyCount &+= 1
        let copyCount = providerCopyCount
        let jpeg = latestJPEG
        let frameWidth = latestWidth
        let frameHeight = latestHeight
        let frameSequence = latestSequence
        lock.unlock()

        guard let destination, capacity > 0 else {
            if Self.shouldLog(count: copyCount, every: 120) {
                XboxCameraDiagnosticLog.write(
                    "provider copy #\(copyCount) rejected: destination unavailable capacity=\(capacity)"
                )
            }
            return 0
        }

        guard !jpeg.isEmpty, jpeg.count <= capacity else {
            if Self.shouldLog(count: copyCount, every: 120) {
                XboxCameraDiagnosticLog.write(
                    "provider copy #\(copyCount) rejected: jpegBytes=\(jpeg.count) capacity=\(capacity)"
                )
            }
            return 0
        }

        jpeg.withUnsafeBytes { buffer in
            if let baseAddress = buffer.baseAddress {
                memcpy(destination, baseAddress, jpeg.count)
            }
        }
        width?.pointee = frameWidth
        height?.pointee = frameHeight
        sequence?.pointee = frameSequence
        if Self.shouldLog(count: copyCount, every: 120) {
            XboxCameraDiagnosticLog.write(
                "provider copy #\(copyCount) bytes=\(jpeg.count) size=\(frameWidth)x\(frameHeight) seq=\(frameSequence)"
            )
        }
        return jpeg.count
    }

    private static func shouldLog(count: UInt64, every: UInt64) -> Bool {
        count <= 8 || (every > 0 && count % every == 0)
    }

    private static func makePlaceholderJPEG() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240))
        let image = renderer.image { context in
            UIColor(white: 0.02, alpha: 1.0).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 240))

            UIColor(white: 0.18, alpha: 1.0).setFill()
            context.fill(CGRect(x: 0, y: 108, width: 320, height: 24))
        }

        return image.jpegData(compressionQuality: 0.55) ?? Data()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard now - lastFrameTime >= 1.0 / 15.0 else {
            return
        }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let jpeg = makeJPEG(from: pixelBuffer) else {
            return
        }

        lock.lock()
        latestJPEG = jpeg
        latestWidth = 320
        latestHeight = 240
        latestSequence &+= 1
        let frameSequence = latestSequence
        let shouldDumpDiagnosticJPEG = !diagnosticJPEGDumped
        if shouldDumpDiagnosticJPEG {
            diagnosticJPEGDumped = true
        }
        lock.unlock()
        if shouldDumpDiagnosticJPEG {
            Self.dumpDiagnosticJPEG(jpeg, sequence: frameSequence)
        }
        if Self.shouldLog(count: frameSequence, every: 60) {
            XboxCameraDiagnosticLog.write(
                "captured frame seq=\(frameSequence) jpegBytes=\(jpeg.count) \(Self.describeJPEG(jpeg))"
            )
        }
    }

    private func makeJPEG(from pixelBuffer: CVPixelBuffer) -> Data? {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceExtent = sourceImage.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0 else {
            return nil
        }

        let targetSize = CGSize(width: 320, height: 240)
        let targetAspect = targetSize.width / targetSize.height
        var crop = sourceExtent
        let sourceAspect = sourceExtent.width / sourceExtent.height

        if sourceAspect > targetAspect {
            let croppedWidth = sourceExtent.height * targetAspect
            crop.origin.x += (sourceExtent.width - croppedWidth) * 0.5
            crop.size.width = croppedWidth
        } else if sourceAspect < targetAspect {
            let croppedHeight = sourceExtent.width / targetAspect
            crop.origin.y += (sourceExtent.height - croppedHeight) * 0.5
            crop.size.height = croppedHeight
        }

        let normalized = sourceImage
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let scaled = normalized.transformed(
            by: CGAffineTransform(
                scaleX: targetSize.width / crop.width,
                y: targetSize.height / crop.height
            )
        )
        let outputRect = CGRect(origin: .zero, size: targetSize)

        guard let bgraPixelBuffer = makeBGRAPixelBuffer(
            from: scaled,
            bounds: outputRect
        ) else {
            return nil
        }

        if let jpeg = jpegEncoder.encode(bgraPixelBuffer: bgraPixelBuffer) {
            return jpeg
        }

        if jpegEncoder.shouldLogFallback() {
            XboxCameraDiagnosticLog.write("Custom MJPEG unavailable; falling back to VideoToolbox JPEG")
        }

        if let jpeg = videoToolboxJPEGEncoder.encode(bgraPixelBuffer: bgraPixelBuffer) {
            return jpeg
        }

        if videoToolboxJPEGEncoder.shouldLogFallback() {
            XboxCameraDiagnosticLog.write("VideoToolbox JPEG unavailable; falling back to ImageIO JPEG")
        }

        guard let cgImage = ciContext.createCGImage(scaled, from: outputRect) else {
            return nil
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality: 0.55
        ] as CFDictionary
        CGImageDestinationAddImage(destination, cgImage, options)

        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return data as Data
    }

    private func makeBGRAPixelBuffer(from image: CIImage, bounds: CGRect) -> CVPixelBuffer? {
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            320,
            240,
            kCVPixelFormatType_32BGRA,
            attributes,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            XboxCameraDiagnosticLog.write("camera BGRA pixel buffer creation failed status=\(status)")
            return nil
        }

        ciContext.render(
            image,
            to: pixelBuffer,
            bounds: bounds,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        return pixelBuffer
    }

    private static func describeJPEG(_ data: Data) -> String {
        data.withUnsafeBytes { buffer in
            guard let bytes = buffer.bindMemory(to: UInt8.self).baseAddress,
                  data.count >= 4,
                  bytes[0] == 0xff,
                  bytes[1] == 0xd8 else {
                return "jpeg=invalid"
            }

            var offset = 2
            var hasJFIFApplicationSegment = false
            while offset + 4 <= data.count {
                while offset < data.count, bytes[offset] != 0xff {
                    offset += 1
                }
                while offset < data.count, bytes[offset] == 0xff {
                    offset += 1
                }
                guard offset < data.count else {
                    break
                }

                let marker = bytes[offset]
                offset += 1
                if marker == 0xd9 || marker == 0xda {
                    break
                }
                guard offset + 2 <= data.count else {
                    break
                }

                let length = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
                guard length >= 2, offset + length <= data.count else {
                    break
                }

                if marker == 0xe0,
                   offset + 7 <= data.count,
                   bytes[offset + 2] == 0x4a,
                   bytes[offset + 3] == 0x46,
                   bytes[offset + 4] == 0x49,
                   bytes[offset + 5] == 0x46,
                   bytes[offset + 6] == 0x00 {
                    hasJFIFApplicationSegment = true
                }

                if marker >= 0xc0, marker <= 0xc3, offset + 8 <= data.count {
                    let precision = bytes[offset + 2]
                    let height = (Int(bytes[offset + 3]) << 8) | Int(bytes[offset + 4])
                    let width = (Int(bytes[offset + 5]) << 8) | Int(bytes[offset + 6])
                    let components = Int(bytes[offset + 7])
                    var sampling: [String] = []
                    var componentOffset = offset + 8
                    for _ in 0..<components where componentOffset + 2 < offset + length {
                        let factor = bytes[componentOffset + 1]
                        sampling.append("\((factor >> 4) & 0x0f)\(factor & 0x0f)")
                        componentOffset += 3
                    }
                    let frameDescription = String(
                        format: "jpeg=sof%02x %dx%d p=%u comps=%d samp=%@",
                        marker,
                        width,
                        height,
                        precision,
                        components,
                        sampling.joined(separator: "/")
                    )
                    return hasJFIFApplicationSegment
                        ? "\(frameDescription) app0=jfif"
                        : "\(frameDescription) app0=none"
                }

                offset += length
            }

            return "jpeg=sof-missing"
        }
    }

    private static func dumpDiagnosticJPEG(_ jpeg: Data, sequence: UInt64) {
        do {
            let documentsURL = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            )[0]
            let logDirectoryURL = documentsURL.appendingPathComponent(
                "DukeXLogs",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: logDirectoryURL,
                withIntermediateDirectories: true
            )

            let frameURL = logDirectoryURL.appendingPathComponent("camera-frame-latest.jpg")
            try jpeg.write(to: frameURL, options: [.atomic])
            XboxCameraDiagnosticLog.write(
                "diagnostic jpeg dumped seq=\(sequence) path=\(frameURL.path) bytes=\(jpeg.count) \(Self.describeJPEG(jpeg)) \(Self.describeAppleDecode(jpeg))"
            )
        } catch {
            XboxCameraDiagnosticLog.write(
                "diagnostic jpeg dump failed seq=\(sequence) error=\(error.localizedDescription)"
            )
        }
    }

    private static func describeAppleDecode(_ jpeg: Data) -> String {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return "iosDecode=failed"
        }

        return "iosDecode=ok \(image.width)x\(image.height)"
    }
}

private final class XboxCameraJPEGEncoder {
    private enum Constants {
        static let width = 320
        static let height = 240
        static let quality = 50
        static let restartIntervalMCUs = 20
    }

    private struct HuffmanCode {
        let code: Int
        let length: Int
    }

    private struct HuffmanTables {
        let luminanceDC: [Int: HuffmanCode]
        let luminanceAC: [Int: HuffmanCode]
        let chrominanceDC: [Int: HuffmanCode]
        let chrominanceAC: [Int: HuffmanCode]
    }

    private struct JPEGWriter {
        var data = Data()
        private var bitBuffer = 0
        private var bitCount = 0

        init(capacity: Int) {
            data.reserveCapacity(capacity)
        }

        mutating func appendByte(_ value: Int) {
            data.append(UInt8(value & 0xff))
        }

        mutating func appendMarker(_ marker: Int) {
            appendByte(0xff)
            appendByte(marker)
        }

        mutating func appendUInt16(_ value: Int) {
            appendByte((value >> 8) & 0xff)
            appendByte(value & 0xff)
        }

        mutating func appendBytes(_ values: [UInt8]) {
            data.append(contentsOf: values)
        }

        mutating func writeBits(code: Int, length: Int) {
            guard length > 0 else {
                return
            }

            for shift in stride(from: length - 1, through: 0, by: -1) {
                bitBuffer = (bitBuffer << 1) | ((code >> shift) & 1)
                bitCount += 1
                if bitCount == 8 {
                    appendEntropyByte(bitBuffer)
                    bitBuffer = 0
                    bitCount = 0
                }
            }
        }

        mutating func flushEntropy() {
            guard bitCount > 0 else {
                return
            }

            let padding = 8 - bitCount
            let byte = (bitBuffer << padding) | ((1 << padding) - 1)
            appendEntropyByte(byte)
            bitBuffer = 0
            bitCount = 0
        }

        private mutating func appendEntropyByte(_ value: Int) {
            let byte = value & 0xff
            appendByte(byte)
            if byte == 0xff {
                appendByte(0x00)
            }
        }
    }

    private var fallbackLogCount = 0
    private var encodeCount = 0
    private var loggedFailure = false
    private var yTopLeft = [Double](repeating: 0, count: 64)
    private var yTopRight = [Double](repeating: 0, count: 64)
    private var yBottomLeft = [Double](repeating: 0, count: 64)
    private var yBottomRight = [Double](repeating: 0, count: 64)
    private var cbBlock = [Double](repeating: 0, count: 64)
    private var crBlock = [Double](repeating: 0, count: 64)
    private var temp = [Double](repeating: 0, count: 64)
    private var quantized = [Int](repeating: 0, count: 64)
    private let luminanceQuant: [Int]
    private let chrominanceQuant: [Int]
    private let huffmanTables: HuffmanTables

    init() {
        luminanceQuant = Self.scaledQuantTable(Self.baseLuminanceQuant, quality: Constants.quality)
        chrominanceQuant = Self.scaledQuantTable(Self.baseChrominanceQuant, quality: Constants.quality)
        huffmanTables = HuffmanTables(
            luminanceDC: Self.buildHuffmanCodes(
                counts: Self.standardDCLuminanceCounts,
                values: Self.standardDCValues
            ),
            luminanceAC: Self.buildHuffmanCodes(
                counts: Self.standardACLuminanceCounts,
                values: Self.standardACLuminanceValues
            ),
            chrominanceDC: Self.buildHuffmanCodes(
                counts: Self.standardDCChrominanceCounts,
                values: Self.standardDCValues
            ),
            chrominanceAC: Self.buildHuffmanCodes(
                counts: Self.standardACChrominanceCounts,
                values: Self.standardACChrominanceValues
            )
        )
    }

    func shouldLogFallback() -> Bool {
        fallbackLogCount += 1
        return fallbackLogCount <= 4 || fallbackLogCount % 120 == 0
    }

    func encode(bgraPixelBuffer: CVPixelBuffer) -> Data? {
        let lockStatus = CVPixelBufferLockBaseAddress(bgraPixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            logFailure("source lock failed status=\(lockStatus)")
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(bgraPixelBuffer, .readOnly)
        }

        guard CVPixelBufferGetPixelFormatType(bgraPixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(bgraPixelBuffer) == Constants.width,
              CVPixelBufferGetHeight(bgraPixelBuffer) == Constants.height,
              let sourceBase = CVPixelBufferGetBaseAddress(bgraPixelBuffer)?.assumingMemoryBound(to: UInt8.self) else {
            logFailure("unexpected BGRA source layout")
            return nil
        }

        var writer = JPEGWriter(capacity: 18 * 1024)
        writeHeaders(to: &writer)

        var previousYDC = 0
        var previousCbDC = 0
        var previousCrDC = 0
        var restartMarkerIndex = 0
        let sourceStride = CVPixelBufferGetBytesPerRow(bgraPixelBuffer)
        var minY = 255
        var maxY = 0
        var yTotal = 0
        var cbTotal = 0
        var crTotal = 0
        let chromaSampleCount = (Constants.width / 2) * (Constants.height / 2)

        for mcuY in stride(from: 0, to: Constants.height, by: 16) {
            for mcuX in stride(from: 0, to: Constants.width, by: 16) {
                for chromaRow in 0..<8 {
                    let topSourceRow = sourceBase.advanced(by: (mcuY + chromaRow * 2) * sourceStride)
                    let bottomSourceRow = sourceBase.advanced(by: (mcuY + chromaRow * 2 + 1) * sourceStride)

                    for chromaColumn in 0..<8 {
                        let sourceX = mcuX + chromaColumn * 2
                        let topLeftPixel = topSourceRow.advanced(by: sourceX * 4)
                        let topRightPixel = topSourceRow.advanced(by: (sourceX + 1) * 4)
                        let bottomLeftPixel = bottomSourceRow.advanced(by: sourceX * 4)
                        let bottomRightPixel = bottomSourceRow.advanced(by: (sourceX + 1) * 4)
                        let topLeftComponents = Self.ycbcrFromBGRA(topLeftPixel)
                        let topRightComponents = Self.ycbcrFromBGRA(topRightPixel)
                        let bottomLeftComponents = Self.ycbcrFromBGRA(bottomLeftPixel)
                        let bottomRightComponents = Self.ycbcrFromBGRA(bottomRightPixel)
                        let yIndex = (chromaRow % 4) * 16 + (chromaColumn % 4) * 2
                        let chromaIndex = chromaRow * 8 + chromaColumn
                        let cbAverageSample = (
                            topLeftComponents.cb + topRightComponents.cb
                            + bottomLeftComponents.cb + bottomRightComponents.cb + 2
                        ) / 4
                        let crAverageSample = (
                            topLeftComponents.cr + topRightComponents.cr
                            + bottomLeftComponents.cr + bottomRightComponents.cr + 2
                        ) / 4

                        switch (chromaRow < 4, chromaColumn < 4) {
                        case (true, true):
                            yTopLeft[yIndex] = Double(topLeftComponents.y - 128)
                            yTopLeft[yIndex + 1] = Double(topRightComponents.y - 128)
                            yTopLeft[yIndex + 8] = Double(bottomLeftComponents.y - 128)
                            yTopLeft[yIndex + 9] = Double(bottomRightComponents.y - 128)
                        case (true, false):
                            yTopRight[yIndex] = Double(topLeftComponents.y - 128)
                            yTopRight[yIndex + 1] = Double(topRightComponents.y - 128)
                            yTopRight[yIndex + 8] = Double(bottomLeftComponents.y - 128)
                            yTopRight[yIndex + 9] = Double(bottomRightComponents.y - 128)
                        case (false, true):
                            yBottomLeft[yIndex] = Double(topLeftComponents.y - 128)
                            yBottomLeft[yIndex + 1] = Double(topRightComponents.y - 128)
                            yBottomLeft[yIndex + 8] = Double(bottomLeftComponents.y - 128)
                            yBottomLeft[yIndex + 9] = Double(bottomRightComponents.y - 128)
                        case (false, false):
                            yBottomRight[yIndex] = Double(topLeftComponents.y - 128)
                            yBottomRight[yIndex + 1] = Double(topRightComponents.y - 128)
                            yBottomRight[yIndex + 8] = Double(bottomLeftComponents.y - 128)
                            yBottomRight[yIndex + 9] = Double(bottomRightComponents.y - 128)
                        }

                        cbBlock[chromaIndex] = Double(cbAverageSample - 128)
                        crBlock[chromaIndex] = Double(crAverageSample - 128)

                        minY = min(
                            minY,
                            topLeftComponents.y,
                            topRightComponents.y,
                            bottomLeftComponents.y,
                            bottomRightComponents.y
                        )
                        maxY = max(
                            maxY,
                            topLeftComponents.y,
                            topRightComponents.y,
                            bottomLeftComponents.y,
                            bottomRightComponents.y
                        )
                        yTotal += topLeftComponents.y + topRightComponents.y
                            + bottomLeftComponents.y + bottomRightComponents.y
                        cbTotal += cbAverageSample
                        crTotal += crAverageSample
                    }
                }

                guard encodeBlock(
                    yTopLeft,
                    quantTable: luminanceQuant,
                    dcTable: huffmanTables.luminanceDC,
                    acTable: huffmanTables.luminanceAC,
                    previousDC: &previousYDC,
                    writer: &writer
                ), encodeBlock(
                    yTopRight,
                    quantTable: luminanceQuant,
                    dcTable: huffmanTables.luminanceDC,
                    acTable: huffmanTables.luminanceAC,
                    previousDC: &previousYDC,
                    writer: &writer
                ), encodeBlock(
                    yBottomLeft,
                    quantTable: luminanceQuant,
                    dcTable: huffmanTables.luminanceDC,
                    acTable: huffmanTables.luminanceAC,
                    previousDC: &previousYDC,
                    writer: &writer
                ), encodeBlock(
                    yBottomRight,
                    quantTable: luminanceQuant,
                    dcTable: huffmanTables.luminanceDC,
                    acTable: huffmanTables.luminanceAC,
                    previousDC: &previousYDC,
                    writer: &writer
                ), encodeBlock(
                    cbBlock,
                    quantTable: chrominanceQuant,
                    dcTable: huffmanTables.chrominanceDC,
                    acTable: huffmanTables.chrominanceAC,
                    previousDC: &previousCbDC,
                    writer: &writer
                ), encodeBlock(
                    crBlock,
                    quantTable: chrominanceQuant,
                    dcTable: huffmanTables.chrominanceDC,
                    acTable: huffmanTables.chrominanceAC,
                    previousDC: &previousCrDC,
                    writer: &writer
                ) else {
                    logFailure("Huffman encode failed")
                    return nil
                }
            }

            if mcuY + 16 < Constants.height {
                writer.flushEntropy()
                writer.appendMarker(0xd0 + restartMarkerIndex)
                restartMarkerIndex = (restartMarkerIndex + 1) & 0x07
                previousYDC = 0
                previousCbDC = 0
                previousCrDC = 0
            }
        }

        writer.flushEntropy()
        writer.appendMarker(0xd9)

        encodeCount += 1
        if encodeCount <= 4 || encodeCount % 60 == 0 {
            let yAverage = yTotal / max(Constants.width * Constants.height, 1)
            let cbAverage = cbTotal / max(chromaSampleCount, 1)
            let crAverage = crTotal / max(chromaSampleCount, 1)
            XboxCameraDiagnosticLog.write(
                "Custom MJPEG encoded frame=\(encodeCount) bytes=\(writer.data.count) sampling=22/11/11 markers=jfif-gspca-420-dri\(Constants.restartIntervalMCUs) y=\(minY)-\(maxY)/\(yAverage) cbAvg=\(cbAverage) crAvg=\(crAverage)"
            )
        }

        return writer.data
    }

    private func writeHeaders(to writer: inout JPEGWriter) {
        writer.appendMarker(0xd8)
        writeJFIFApplicationSegment(to: &writer)
        writeQuantTables(to: &writer)
        writeHuffmanTables(to: &writer)
        writeStartOfFrame(to: &writer)
        writeDefineRestartInterval(to: &writer)
        writeStartOfScan(to: &writer)
    }

    private func writeJFIFApplicationSegment(to writer: inout JPEGWriter) {
        writer.appendMarker(0xe0)
        writer.appendUInt16(16)
        writer.appendBytes([
            0x4a, 0x46, 0x49, 0x46, 0x00,
            0x01, 0x01,
            0x00,
            0x00, 0x01,
            0x00, 0x01,
            0x00, 0x00
        ])
    }

    private func writeQuantTables(to writer: inout JPEGWriter) {
        writer.appendMarker(0xdb)
        writer.appendUInt16(132)
        writeQuantTablePayload(luminanceQuant, identifier: 0, to: &writer)
        writeQuantTablePayload(chrominanceQuant, identifier: 1, to: &writer)
    }

    private func writeQuantTablePayload(_ table: [Int], identifier: Int, to writer: inout JPEGWriter) {
        writer.appendByte(identifier)
        for index in Self.zigzag {
            writer.appendByte(table[index])
        }
    }

    private func writeHuffmanTables(to writer: inout JPEGWriter) {
        writer.appendMarker(0xc4)
        writer.appendUInt16(
            2
            + Self.huffmanPayloadLength(values: Self.standardDCValues)
            + Self.huffmanPayloadLength(values: Self.standardDCValues)
            + Self.huffmanPayloadLength(values: Self.standardACLuminanceValues)
            + Self.huffmanPayloadLength(values: Self.standardACChrominanceValues)
        )
        writeHuffmanTablePayload(
            counts: Self.standardDCLuminanceCounts,
            values: Self.standardDCValues,
            tableClass: 0,
            identifier: 0,
            to: &writer
        )
        writeHuffmanTablePayload(
            counts: Self.standardDCChrominanceCounts,
            values: Self.standardDCValues,
            tableClass: 0,
            identifier: 1,
            to: &writer
        )
        writeHuffmanTablePayload(
            counts: Self.standardACLuminanceCounts,
            values: Self.standardACLuminanceValues,
            tableClass: 1,
            identifier: 0,
            to: &writer
        )
        writeHuffmanTablePayload(
            counts: Self.standardACChrominanceCounts,
            values: Self.standardACChrominanceValues,
            tableClass: 1,
            identifier: 1,
            to: &writer
        )
    }

    private func writeQuantTable(_ table: [Int], identifier: Int, to writer: inout JPEGWriter) {
        writer.appendMarker(0xdb)
        writer.appendUInt16(67)
        writeQuantTablePayload(table, identifier: identifier, to: &writer)
    }

    private func writeStartOfFrame(to writer: inout JPEGWriter) {
        writer.appendMarker(0xc0)
        writer.appendUInt16(17)
        writer.appendByte(8)
        writer.appendUInt16(Constants.height)
        writer.appendUInt16(Constants.width)
        writer.appendByte(3)
        writer.appendByte(1)
        writer.appendByte(0x22)
        writer.appendByte(0)
        writer.appendByte(2)
        writer.appendByte(0x11)
        writer.appendByte(1)
        writer.appendByte(3)
        writer.appendByte(0x11)
        writer.appendByte(1)
    }

    private func writeDefineRestartInterval(to writer: inout JPEGWriter) {
        writer.appendMarker(0xdd)
        writer.appendUInt16(4)
        writer.appendUInt16(Constants.restartIntervalMCUs)
    }

    private func writeHuffmanTable(
        counts: [UInt8],
        values: [UInt8],
        tableClass: Int,
        identifier: Int,
        to writer: inout JPEGWriter
    ) {
        writer.appendMarker(0xc4)
        writer.appendUInt16(2 + Self.huffmanPayloadLength(values: values))
        writeHuffmanTablePayload(
            counts: counts,
            values: values,
            tableClass: tableClass,
            identifier: identifier,
            to: &writer
        )
    }

    private func writeHuffmanTablePayload(
        counts: [UInt8],
        values: [UInt8],
        tableClass: Int,
        identifier: Int,
        to writer: inout JPEGWriter
    ) {
        writer.appendByte((tableClass << 4) | identifier)
        writer.appendBytes(counts)
        writer.appendBytes(values)
    }

    private static func huffmanPayloadLength(values: [UInt8]) -> Int {
        1 + 16 + values.count
    }

    private func writeStartOfScan(to writer: inout JPEGWriter) {
        writer.appendMarker(0xda)
        writer.appendUInt16(12)
        writer.appendByte(3)
        writer.appendByte(1)
        writer.appendByte(0x00)
        writer.appendByte(2)
        writer.appendByte(0x11)
        writer.appendByte(3)
        writer.appendByte(0x11)
        writer.appendByte(0)
        writer.appendByte(63)
        writer.appendByte(0)
    }

    private func encodeBlock(
        _ block: [Double],
        quantTable: [Int],
        dcTable: [Int: HuffmanCode],
        acTable: [Int: HuffmanCode],
        previousDC: inout Int,
        writer: inout JPEGWriter
    ) -> Bool {
        quantize(block, quantTable: quantTable, output: &quantized)

        let dcDiff = quantized[0] - previousDC
        previousDC = quantized[0]
        let dcCategory = Self.magnitudeCategory(dcDiff)
        guard let dcCode = dcTable[dcCategory] else {
            return false
        }
        writer.writeBits(code: dcCode.code, length: dcCode.length)
        writer.writeBits(
            code: Self.magnitudeBits(dcDiff, category: dcCategory),
            length: dcCategory
        )

        var zeroRun = 0
        for zigzagIndex in 1..<64 {
            let coefficient = quantized[Self.zigzag[zigzagIndex]]
            if coefficient == 0 {
                zeroRun += 1
                continue
            }

            while zeroRun > 15 {
                guard let zrl = acTable[0xf0] else {
                    return false
                }
                writer.writeBits(code: zrl.code, length: zrl.length)
                zeroRun -= 16
            }

            let category = Self.magnitudeCategory(coefficient)
            let symbol = zeroRun * 16 + category
            guard let acCode = acTable[symbol] else {
                return false
            }
            writer.writeBits(code: acCode.code, length: acCode.length)
            writer.writeBits(
                code: Self.magnitudeBits(coefficient, category: category),
                length: category
            )
            zeroRun = 0
        }

        if zeroRun > 0 {
            guard let eob = acTable[0x00] else {
                return false
            }
            writer.writeBits(code: eob.code, length: eob.length)
        }
        return true
    }

    private func quantize(_ block: [Double], quantTable: [Int], output: inout [Int]) {
        for row in 0..<8 {
            for u in 0..<8 {
                var sum = 0.0
                for x in 0..<8 {
                    sum += block[row * 8 + x] * Self.cosine[u * 8 + x]
                }
                temp[row * 8 + u] = sum
            }
        }

        for v in 0..<8 {
            for u in 0..<8 {
                var sum = 0.0
                for row in 0..<8 {
                    sum += temp[row * 8 + u] * Self.cosine[v * 8 + row]
                }
                let dct = 0.25 * Self.normalization[u] * Self.normalization[v] * sum
                output[v * 8 + u] = Int((dct / Double(quantTable[v * 8 + u])).rounded())
            }
        }
    }

    private static func ycbcrFromBGRA(_ pixel: UnsafePointer<UInt8>) -> (y: Int, cb: Int, cr: Int) {
        let blue = Int(pixel[0])
        let green = Int(pixel[1])
        let red = Int(pixel[2])

        let y = (77 * red + 150 * green + 29 * blue + 128) >> 8
        let cb = ((-43 * red - 85 * green + 128 * blue + 128) >> 8) + 128
        let cr = ((128 * red - 107 * green - 21 * blue + 128) >> 8) + 128

        return (
            y: clamp(y, minValue: 0, maxValue: 255),
            cb: clamp(cb, minValue: 1, maxValue: 255),
            cr: clamp(cr, minValue: 1, maxValue: 255)
        )
    }

    private static func scaledQuantTable(_ table: [Int], quality: Int) -> [Int] {
        let clampedQuality = clamp(quality, minValue: 1, maxValue: 100)
        let scale = clampedQuality < 50 ? 5000 / clampedQuality : 200 - clampedQuality * 2
        return table.map { value in
            clamp((value * scale + 50) / 100, minValue: 1, maxValue: 255)
        }
    }

    private static func buildHuffmanCodes(counts: [UInt8], values: [UInt8]) -> [Int: HuffmanCode] {
        var table: [Int: HuffmanCode] = [:]
        var code = 0
        var valueIndex = 0

        for length in 1...16 {
            let count = Int(counts[length - 1])
            for _ in 0..<count {
                guard valueIndex < values.count else {
                    break
                }
                table[Int(values[valueIndex])] = HuffmanCode(code: code, length: length)
                code += 1
                valueIndex += 1
            }
            code <<= 1
        }

        return table
    }

    private static func magnitudeCategory(_ value: Int) -> Int {
        var magnitude = abs(value)
        var category = 0
        while magnitude > 0 {
            category += 1
            magnitude >>= 1
        }
        return category
    }

    private static func magnitudeBits(_ value: Int, category: Int) -> Int {
        guard category > 0 else {
            return 0
        }
        if value >= 0 {
            return value
        }
        return ((1 << category) - 1) + value
    }

    private static func clamp(_ value: Int, minValue: Int, maxValue: Int) -> Int {
        min(max(value, minValue), maxValue)
    }

    private func logFailure(_ message: String) {
        guard !loggedFailure else {
            return
        }
        loggedFailure = true
        XboxCameraDiagnosticLog.write("Custom MJPEG \(message)")
    }

    private static let normalization: [Double] = [
        0.7071067811865476, 1, 1, 1, 1, 1, 1, 1
    ]

    private static let cosine: [Double] = {
        var values: [Double] = []
        values.reserveCapacity(64)
        for u in 0..<8 {
            for x in 0..<8 {
                let numerator = Double(2 * x + 1) * Double(u) * Double.pi
                values.append(cos(numerator / 16.0))
            }
        }
        return values
    }()

    private static let zigzag: [Int] = [
        0, 1, 8, 16, 9, 2, 3, 10,
        17, 24, 32, 25, 18, 11, 4, 5,
        12, 19, 26, 33, 40, 48, 41, 34,
        27, 20, 13, 6, 7, 14, 21, 28,
        35, 42, 49, 56, 57, 50, 43, 36,
        29, 22, 15, 23, 30, 37, 44, 51,
        58, 59, 52, 45, 38, 31, 39, 46,
        53, 60, 61, 54, 47, 55, 62, 63
    ]

    private static let baseLuminanceQuant: [Int] = [
        16, 11, 10, 16, 24, 40, 51, 61,
        12, 12, 14, 19, 26, 58, 60, 55,
        14, 13, 16, 24, 40, 57, 69, 56,
        14, 17, 22, 29, 51, 87, 80, 62,
        18, 22, 37, 56, 68, 109, 103, 77,
        24, 35, 55, 64, 81, 104, 113, 92,
        49, 64, 78, 87, 103, 121, 120, 101,
        72, 92, 95, 98, 112, 100, 103, 99
    ]

    private static let baseChrominanceQuant: [Int] = [
        17, 18, 24, 47, 99, 99, 99, 99,
        18, 21, 26, 66, 99, 99, 99, 99,
        24, 26, 56, 99, 99, 99, 99, 99,
        47, 66, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99,
        99, 99, 99, 99, 99, 99, 99, 99
    ]

    private static let standardDCValues: [UInt8] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
    ]

    private static let standardDCLuminanceCounts: [UInt8] = [
        0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0
    ]

    private static let standardDCChrominanceCounts: [UInt8] = [
        0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0
    ]

    private static let standardACLuminanceCounts: [UInt8] = [
        0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d
    ]

    private static let standardACChrominanceCounts: [UInt8] = [
        0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77
    ]

    private static let standardACLuminanceValues: [UInt8] = [
        0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12,
        0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
        0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08,
        0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
        0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16,
        0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
        0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
        0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
        0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
        0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
        0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79,
        0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
        0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98,
        0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6,
        0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
        0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4,
        0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
        0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea,
        0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa
    ]

    private static let standardACChrominanceValues: [UInt8] = [
        0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21,
        0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
        0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91,
        0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
        0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34,
        0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
        0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38,
        0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
        0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
        0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
        0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78,
        0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
        0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96,
        0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
        0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4,
        0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
        0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2,
        0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
        0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9,
        0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
        0xf9, 0xfa
    ]
}

private final class XboxCameraVideoToolboxJPEGEncoder {
    private enum Constants {
        static let width: Int32 = 320
        static let height: Int32 = 240
        static let frameRate: Int32 = 15
    }

    private var session: VTCompressionSession?
    private var frameIndex: Int64 = 0
    private var fallbackLogCount = 0
    private var conversionLogCount = 0
    private var sessionFailureLogged = false

    func shouldLogFallback() -> Bool {
        fallbackLogCount += 1
        return fallbackLogCount <= 4 || fallbackLogCount % 120 == 0
    }

    func encode(bgraPixelBuffer: CVPixelBuffer) -> Data? {
        guard let pixelBuffer = makeYUV422PixelBuffer(from: bgraPixelBuffer) else {
            logSessionFailure("pixel buffer creation failed")
            return nil
        }

        guard let session = makeSession() else {
            return nil
        }

        frameIndex += 1
        let presentationTime = CMTime(value: frameIndex, timescale: Constants.frameRate)
        let frameDuration = CMTime(value: 1, timescale: Constants.frameRate)
        let semaphore = DispatchSemaphore(value: 0)
        var encodedJPEG: Data?
        var callbackStatus: OSStatus = noErr

        let encodeStatus = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: frameDuration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            callbackStatus = status
            if status == noErr,
               let sampleBuffer,
               CMSampleBufferDataIsReady(sampleBuffer),
               let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                let length = CMBlockBufferGetDataLength(blockBuffer)
                if length > 0 {
                    var data = Data(count: length)
                    let copyStatus = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
                        guard let destination = rawBuffer.baseAddress else {
                            return -1
                        }
                        return CMBlockBufferCopyDataBytes(
                            blockBuffer,
                            atOffset: 0,
                            dataLength: length,
                            destination: destination
                        )
                    }
                    if copyStatus == noErr {
                        encodedJPEG = data
                    } else {
                        callbackStatus = copyStatus
                    }
                }
            }
            semaphore.signal()
        }

        guard encodeStatus == noErr else {
            logSessionFailure("encode failed status=\(encodeStatus)")
            return nil
        }

        VTCompressionSessionCompleteFrames(
            session,
            untilPresentationTimeStamp: presentationTime
        )

        guard semaphore.wait(timeout: .now() + .milliseconds(80)) == .success else {
            logSessionFailure("encode timed out")
            return nil
        }

        guard callbackStatus == noErr else {
            logSessionFailure("encode callback failed status=\(callbackStatus)")
            return nil
        }

        return encodedJPEG
    }

    private func makeYUV422PixelBuffer(from source: CVPixelBuffer) -> CVPixelBuffer? {
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_422YpCbCr8BiPlanarFullRange),
            kCVPixelBufferWidthKey as String: Int(Constants.width),
            kCVPixelBufferHeightKey as String: Int(Constants.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ] as CFDictionary
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(Constants.width),
            Int(Constants.height),
            kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
            attributes,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            logSessionFailure("CVPixelBufferCreate failed status=\(status)")
            return nil
        }

        let lockStatus = CVPixelBufferLockBaseAddress(source, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            logSessionFailure("source lock failed status=\(lockStatus)")
            return nil
        }
        let destinationLockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, [])
        guard destinationLockStatus == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            logSessionFailure("destination lock failed status=\(destinationLockStatus)")
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(source) == Int(Constants.width),
              CVPixelBufferGetHeight(source) == Int(Constants.height),
              CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              let sourceBase = CVPixelBufferGetBaseAddress(source)?.assumingMemoryBound(to: UInt8.self),
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
            logSessionFailure("unexpected pixel buffer layout")
            return nil
        }

        let width = Int(Constants.width)
        let height = Int(Constants.height)
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)

        var minY = 255
        var maxY = 0
        var yTotal = 0
        var cbTotal = 0
        var crTotal = 0
        let pairCount = (width / 2) * height

        for row in 0..<height {
            let sourceRow = sourceBase.advanced(by: row * sourceStride)
            let lumaRow = lumaBase.advanced(by: row * lumaStride)
            let chromaRow = chromaBase.advanced(by: row * chromaStride)

            var column = 0
            while column < width {
                let left = sourceRow.advanced(by: column * 4)
                let right = sourceRow.advanced(by: min(column + 1, width - 1) * 4)

                let leftComponents = Self.ycbcrFromBGRA(left)
                let rightComponents = Self.ycbcrFromBGRA(right)
                let y0 = leftComponents.y
                let y1 = rightComponents.y
                let cb = (leftComponents.cb + rightComponents.cb + 1) / 2
                let cr = (leftComponents.cr + rightComponents.cr + 1) / 2

                lumaRow[column] = UInt8(y0)
                if column + 1 < width {
                    lumaRow[column + 1] = UInt8(y1)
                }
                let chromaOffset = (column / 2) * 2
                chromaRow[chromaOffset] = UInt8(cb)
                chromaRow[chromaOffset + 1] = UInt8(cr)

                minY = min(minY, y0, y1)
                maxY = max(maxY, y0, y1)
                yTotal += y0 + y1
                cbTotal += cb
                crTotal += cr
                column += 2
            }
        }

        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferChromaSubsamplingKey,
            kCVImageBufferChromaSubsampling_422,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationTopFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationBottomFieldKey,
            kCVImageBufferChromaLocation_Left,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4,
            .shouldPropagate
        )

        conversionLogCount += 1
        if conversionLogCount <= 4 || conversionLogCount % 120 == 0 {
            let yAverage = yTotal / max(width * height, 1)
            let cbAverage = cbTotal / max(pairCount, 1)
            let crAverage = crTotal / max(pairCount, 1)
            XboxCameraDiagnosticLog.write(
                "YUV422 conversion frame=\(conversionLogCount) y=\(minY)-\(maxY)/\(yAverage) cbAvg=\(cbAverage) crAvg=\(crAverage)"
            )
        }

        return pixelBuffer
    }

    private static func ycbcrFromBGRA(_ pixel: UnsafePointer<UInt8>) -> (y: Int, cb: Int, cr: Int) {
        let blue = Int(pixel[0])
        let green = Int(pixel[1])
        let red = Int(pixel[2])

        let y = (77 * red + 150 * green + 29 * blue + 128) >> 8
        let cb = ((-43 * red - 85 * green + 128 * blue + 128) >> 8) + 128
        let cr = ((128 * red - 107 * green - 21 * blue + 128) >> 8) + 128

        return (
            y: Self.clamp(y, minValue: 0, maxValue: 255),
            cb: Self.clamp(cb, minValue: 1, maxValue: 255),
            cr: Self.clamp(cr, minValue: 1, maxValue: 255)
        )
    }

    private static func clamp(_ value: Int, minValue: Int, maxValue: Int) -> Int {
        min(max(value, minValue), maxValue)
    }

    private func makeSession() -> VTCompressionSession? {
        if let session {
            return session
        }

        let imageBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_422YpCbCr8BiPlanarFullRange),
            kCVPixelBufferWidthKey as String: Int(Constants.width),
            kCVPixelBufferHeightKey as String: Int(Constants.height)
        ] as CFDictionary
        var createdSession: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Constants.width,
            height: Constants.height,
            codecType: kCMVideoCodecType_JPEG,
            encoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &createdSession
        )

        guard status == noErr, let createdSession else {
            logSessionFailure("VTCompressionSessionCreate failed status=\(status)")
            return nil
        }

        VTSessionSetProperty(
            createdSession,
            key: kVTCompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )

        var quality: Float = 0.55
        if let qualityNumber = CFNumberCreate(
            kCFAllocatorDefault,
            .floatType,
            &quality
        ) {
            VTSessionSetProperty(
                createdSession,
                key: kVTCompressionPropertyKey_Quality,
                value: qualityNumber
            )
        }

        VTCompressionSessionPrepareToEncodeFrames(createdSession)
        XboxCameraDiagnosticLog.write("VideoToolbox JPEG session ready pixelFormat=422f codec=jpeg")
        session = createdSession
        return createdSession
    }

    private func logSessionFailure(_ message: String) {
        guard !sessionFailureLogged else {
            return
        }
        sessionFailureLogged = true
        XboxCameraDiagnosticLog.write("VideoToolbox JPEG \(message)")
    }
}
