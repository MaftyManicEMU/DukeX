import Darwin
import Foundation
import Metal
import QuartzCore
import UIKit

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

    @Published private(set) var state: RunState

    private var handle: UnsafeMutableRawPointer?
    private var entryPoint: XemuMain?
    private var primeCoroutines: XemuPrimeCoroutines?
    private var setExternalMetalLayer: XemuSetExternalMetalLayer?
    private var requestShutdown: XemuRequestShutdown?

    init(bundle: Bundle = .main) {
        state = Self.resolveCoreURL(in: bundle).map(RunState.ready) ??
            .unavailable("libxemu-ios-core.dylib is not embedded.")
        NSLog("Xemu core runtime initialized: %@", String(describing: state))
    }

    func refresh(bundle: Bundle = .main) {
        guard !state.isRunning else {
            return
        }
        state = Self.resolveCoreURL(in: bundle).map(RunState.ready) ??
            .unavailable("libxemu-ios-core.dylib is not embedded.")
        NSLog("Xemu core runtime refreshed: %@", String(describing: state))
    }

    func launch(plan: XemuLaunchPlan, layer: UnsafeMutableRawPointer) {
        guard !state.isRunning else {
            return
        }

        do {
            let entryPoint = try loadEntryPoint()
            let arguments = plan.arguments
            let jitMode = plan.jitMode
            let universalJITEnabled = plan.universalJITEnabled
            let setExternalMetalLayer = loadSetExternalMetalLayer()
            let requestShutdown = loadRequestShutdown()
            
            let logURL = Self.prepareRunLog(for: plan, arguments: arguments)
            state = .running(plan.gameName)
            NSLog("Launching Xemu core for %@", plan.gameName)
            if let logURL {
                NSLog("Xemu run log: %@", logURL.path)
            }
            GameControllerBootstrap.shared.logSnapshot(reason: "before core launch")
            
            RunLoop.main.perform {
                let status = Self.invoke(
                    entryPoint,
                    arguments: arguments,
                    jitMode: jitMode,
                    layer: layer,
                    universalJITEnabled: universalJITEnabled,
                    setExternalMetalLayer: setExternalMetalLayer,
                    requestShutdown: requestShutdown
                )
                
                
                NSLog("Xemu core exited with status %d", status)
                self.state = .exited(status)
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
            NSLog("Skipping pre-StikDebug coroutine prime")
            return
        }

        _ = try loadEntryPoint()
        let primeCoroutines = try loadPrimeCoroutines()
        NSLog("Pre-priming Xemu coroutine pool before StikDebug: %u", coroutineReserve)
        primeCoroutines(coroutineReserve)
    }

    private func loadEntryPoint() throws -> XemuMain {
        if let entryPoint {
            return entryPoint
        }

        guard let coreURL = Self.resolveCoreURL(in: .main) else {
            throw RuntimeError.missingCore
        }

        NSLog("Loading Xemu core dylib from %@", coreURL.path)
        let openFlags = RTLD_NOW | RTLD_LOCAL
        guard let handle = dlopen(coreURL.path, openFlags) else {
            throw RuntimeError.dynamicLoader(Self.dynamicLoaderError())
        }

        guard let symbol = dlsym(handle, "xemu_ios_main") else {
            throw RuntimeError.dynamicLoader(Self.dynamicLoaderError())
        }

        NSLog("Resolved xemu_ios_main")
        self.handle = handle
        let entryPoint = unsafeBitCast(symbol, to: XemuMain.self)
        self.entryPoint = entryPoint
        return entryPoint
    }

    private func loadPrimeCoroutines() throws -> XemuPrimeCoroutines {
        if let primeCoroutines {
            return primeCoroutines
        }

        _ = try loadEntryPoint()
        guard let handle else {
            throw RuntimeError.missingCore
        }

        guard let symbol = dlsym(handle, "xemu_ios_coroutine_prime_global_pool") else {
            throw RuntimeError.dynamicLoader(Self.dynamicLoaderError())
        }

        NSLog("Resolved xemu_ios_coroutine_prime_global_pool")
        let primeCoroutines = unsafeBitCast(symbol, to: XemuPrimeCoroutines.self)
        self.primeCoroutines = primeCoroutines
        return primeCoroutines
    }

    private func loadSetExternalMetalLayer() -> XemuSetExternalMetalLayer? {
        if let setExternalMetalLayer {
            return setExternalMetalLayer
        }

        guard let handle else {
            return nil
        }

        guard let symbol = dlsym(handle, "xemu_ios_set_external_metal_layer") else {
            NSLog("xemu_ios_set_external_metal_layer is not available; falling back to SDL Metal layer")
            return nil
        }

        NSLog("Resolved xemu_ios_set_external_metal_layer")
        let setter = unsafeBitCast(symbol, to: XemuSetExternalMetalLayer.self)
        setExternalMetalLayer = setter
        return setter
    }

    private func loadRequestShutdown() -> XemuRequestShutdown? {
        if let requestShutdown {
            return requestShutdown
        }

        guard let handle else {
            return nil
        }

        guard let symbol = dlsym(handle, "xemu_ios_request_shutdown") else {
            NSLog("xemu_ios_request_shutdown is not available")
            return nil
        }

        NSLog("Resolved xemu_ios_request_shutdown")
        let requestShutdown = unsafeBitCast(symbol, to: XemuRequestShutdown.self)
        self.requestShutdown = requestShutdown
        return requestShutdown
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

    private static func invoke(
        _ entryPoint: XemuMain,
        arguments: [String],
        jitMode: RuntimeJITMode,
        layer: UnsafeMutableRawPointer,
        universalJITEnabled: Bool,
        setExternalMetalLayer: XemuSetExternalMetalLayer?,
        requestShutdown: XemuRequestShutdown?
    ) -> Int32 {
        MetalDiagnostics.configurePerformanceHUD()
        let bundleIdentifier = Bundle.main.bundleIdentifier?.lowercased() ?? ""
        
        let presentPacingMode = PresentPacingMode.current
        let forceThirtyFPSLock =
        UserDefaults.standard.object(forKey: EmulatorFileStore.forceThirtyFPSLockEnabledKey) as? Bool ?? false
        let effectivePresentFPS = forceThirtyFPSLock ? "30" : presentPacingMode.presentFPS
        let effectivePresentMode = forceThirtyFPSLock ? "fifo" : presentPacingMode.vulkanPresentMode
        let effectiveDisplaySync = forceThirtyFPSLock ? true : presentPacingMode.displaySyncEnabled
        let effectiveNominalFPS = forceThirtyFPSLock ? "30" : presentPacingMode.nominalFramesPerSecond
        
        setEnvironment([
            ("XEMU_IOS_JIT_MODE", jitMode.environmentValue),
            ("XEMU_IOS_UNIVERSAL_JIT", universalJITEnabled ? "1" : "0"),
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
            ("XEMU_IOS_STRICT_SURFACE_TEXTURE_FORMATS", "0"),
            ("XEMU_IOS_FALLBACK_GENERATION_FILTER", "1"),
            ("XEMU_IOS_SKIP_GL_FINISH", "1"),
            ("XEMU_IOS_TCG_WATCHDOG", "off"),
            ("XEMU_IOS_COROUTINE_PRIME_COUNT", "640")
        ])
        
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
            ("XEMU_IOS_PVIDEO_TRACE", "0"),
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
        NSLog("XEMU_IOS_VK_SWAPCHAIN=%@", "1")
        NSLog(
            "XEMU_IOS_PRESENT_PACING=%@ force30=%@ mode=%@ displaySync=%@ nominalFPS=%@ presentFPS=%@",
            presentPacingMode.rawValue,
            forceThirtyFPSLock ? "1" : "0",
            effectivePresentMode,
            effectiveDisplaySync ? "1" : "0",
            effectiveNominalFPS,
            effectivePresentFPS
        )
        NSLog("Xemu core argv: %@", arguments.joined(separator: " "))
        
        
        setExternalMetalLayer?(layer)
        NSLog(
            "Native CAMetalLayer presenter active: 0x%llx",
            UInt64(UInt(bitPattern: layer))
        )
        defer {
            setExternalMetalLayer?(nil)
        }

        let argv = arguments.map { strdup($0) } + [nil]
        defer {
            for arg in argv {
                free(arg)
            }
        }

        var mutableArgv = argv
        return mutableArgv.withUnsafeMutableBufferPointer { buffer in
            entryPoint(Int32(arguments.count), buffer.baseAddress)
        }
    }

    private static func resolveCoreURL(in bundle: Bundle) -> URL? {
        let frameworksURL = bundle.privateFrameworksURL
        let coreURL = frameworksURL?.appendingPathComponent("libxemu-ios-core.dylib")

        guard let coreURL, FileManager.default.fileExists(atPath: coreURL.path) else {
            return nil
        }
        return coreURL
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

    var errorDescription: String? {
        switch self {
        case .missingCore:
            return "libxemu-ios-core.dylib is not embedded."
        case .dynamicLoader(let message):
            return message
        }
    }
}
