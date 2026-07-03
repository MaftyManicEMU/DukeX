import Combine
import Darwin
import Foundation

enum CoverSelectionError: LocalizedError {
    case emptySelection

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "The selected image could not be loaded."
        }
    }
}

enum AutoJITLaunchTarget: String {
    case dashboard
    case game

    var displayName: String {
        switch self {
        case .dashboard:
            return "Dashboard"
        case .game:
            return "Game"
        }
    }
}

@MainActor
final class StikJITAutoJITCoordinator: ObservableObject {
    @Published private(set) var status: String?
    @Published private(set) var isEnabling = false

    private static let suppressAutomaticDashboardLaunchUntilKey = "AutoJITSuppressAutomaticDashboardLaunchUntil"

    private static let automaticDashboardLaunchCooldown: TimeInterval = 45
    private static let activeEnableTimeoutNanoseconds: UInt64 = 120_000_000_000
    private static let attachReadyTimeoutNanoseconds: UInt64 = 30_000_000_000

    // Retained for the duration of an enable so the XPC connection and the
    // launched runner process stay alive until JIT finishes.
    private var activeLauncher: StikJITExtensionLauncher?
    private var activeHost: StikJITHostBridge?
    private var activeTimeoutTask: Task<Void, Never>?
    private var activeAttachReadyTimeoutTask: Task<Void, Never>?
    private var activeReadyToLaunch: (() -> Void)?
    private var didSignalReadyToLaunch = false

    var hasPendingLaunch: Bool {
        isEnabling
    }

    var shouldSuppressAutomaticDashboardLaunch: Bool {
        Date().timeIntervalSince1970 <
            UserDefaults.standard.double(forKey: Self.suppressAutomaticDashboardLaunchUntilKey)
    }

    func requestJIT(
        for target: AutoJITLaunchTarget,
        pairingFile: URL,
        jitMode: RuntimeJITMode,
        onReadyToLaunch: @escaping () -> Void
    ) throws {
        guard !isEnabling else {
            throw StikJITAutoJITError.alreadyRunning
        }
        guard FileManager.default.fileExists(atPath: pairingFile.path) else {
            throw StikJITAutoJITError.missingPairingFile
        }

        isEnabling = true
        activeReadyToLaunch = onReadyToLaunch
        didSignalReadyToLaunch = false

        let targetPID = getpid()
        status = "Starting JIT helper for \(target.displayName)"

        #if !targetEnvironment(simulator)
        if #available(iOS 26.0, *) {
            do {
                try startStikJITExtension(
                    target: target,
                    targetPID: targetPID,
                    pairingFile: pairingFile,
                    scriptIdentifier: Self.scriptIdentifier(for: jitMode)
                )
            } catch {
                resetActiveJIT()
                throw error
            }
        } else {
            resetActiveJIT()
            throw StikJITAutoJITError.unavailableOnCurrentPlatform
        }
        #else
        resetActiveJIT()
        throw StikJITAutoJITError.unavailableOnCurrentPlatform
        #endif
    }

    func cancelActiveJIT(message: String) {
        guard isEnabling else {
            return
        }
        resetActiveJIT()
        status = "StikJIT failed: \(message)"
    }

    func noteAutomaticDashboardLaunchAttempt() {
        UserDefaults.standard.set(Date().timeIntervalSince1970 + Self.automaticDashboardLaunchCooldown,
                                  forKey: Self.suppressAutomaticDashboardLaunchUntilKey)
    }

    func clearPendingForFreshAutomaticLaunch() {
        if !isEnabling {
            status = nil
        }
    }

    private static func scriptIdentifier(for jitMode: RuntimeJITMode) -> String {
        switch jitMode {
        case .wxReprotection:
            return "legacy"
        case .universalJS:
            return "universal"
        }
    }

    // Launches the embedded StikJIT runner .appex (classic NSExtension, its own
    // process) and asks it to bless this process's JIT pages. The pairing file is
    // shipped as data over XPC because the runner runs in a separate sandbox and
    // cannot read the app's Documents container.
    @available(iOS 26.0, *)
    private func startStikJITExtension(
        target: AutoJITLaunchTarget,
        targetPID: Int32,
        pairingFile: URL,
        scriptIdentifier: String
    ) throws {
        let pairingData = try Data(contentsOf: pairingFile)
        NSLog("[DukeX] pairing file %@ -> %lu bytes", pairingFile.path, pairingData.count)

        let host = StikJITHostBridge()
        let launcher = StikJITExtensionLauncher(host: host)
        activeHost = host
        activeLauncher = launcher

        host.onFinished = { [weak self] ok, message in
            Task { @MainActor in
                self?.completeActiveJIT(
                    target: target,
                    ok: ok,
                    message: message
                )
            }
        }
        host.onLog = { [weak self] line in
            NSLog("StikJIT runner: %@", line)
            Task { @MainActor in
                self?.handleRunnerLog(line, target: target)
            }
        }

        scheduleActiveTimeout(for: target)

        launcher.launch { [weak self] _, runner, error in
            if let error {
                Task { @MainActor in
                    self?.completeActiveJIT(
                        target: target,
                        ok: false,
                        message: error.localizedDescription
                    )
                }
                return
            }
            guard let runner else {
                Task { @MainActor in
                    self?.completeActiveJIT(
                        target: target,
                        ok: false,
                        message: "Could not create the StikJIT runner proxy."
                    )
                }
                return
            }

            NSLog("[DukeX] StikJIT runner connected; attaching to pid %d", targetPID)
            runner.enableJIT(
                forParentPID: targetPID,
                pairingData: pairingData,
                scriptIdentifier: scriptIdentifier
            )
            Task { @MainActor in
                self?.status = "Waiting for StikJIT attach for \(target.displayName)"
                self?.scheduleAttachReadyTimeout(for: target)
            }
        }
    }

    private func handleRunnerLog(_ line: String, target: AutoJITLaunchTarget) {
        guard let attachResponse = Self.attachResponse(in: line) else {
            return
        }

        guard Self.isSuccessfulAttachResponse(attachResponse) else {
            completeActiveJIT(
                target: target,
                ok: false,
                message: "StikJIT attach failed: \(attachResponse.isEmpty ? "empty attach response" : attachResponse)"
            )
            return
        }

        signalReadyToLaunch(target: target)
    }

    private static func attachResponse(in line: String) -> String? {
        guard line.contains("attach_response") else {
            return nil
        }
        guard let separator = line.firstIndex(of: "=") else {
            return ""
        }
        return line[line.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSuccessfulAttachResponse(_ response: String) -> Bool {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.hasPrefix("E")
    }

    private func scheduleAttachReadyTimeout(for target: AutoJITLaunchTarget) {
        guard isEnabling, !didSignalReadyToLaunch else {
            return
        }
        activeAttachReadyTimeoutTask?.cancel()
        activeAttachReadyTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.attachReadyTimeoutNanoseconds)
            } catch {
                return
            }
            await MainActor.run {
                self?.completeActiveJIT(
                    target: target,
                    ok: false,
                    message: "Timed out waiting for StikJIT attach."
                )
            }
        }
    }

    private func signalReadyToLaunch(target: AutoJITLaunchTarget) {
        guard isEnabling, !didSignalReadyToLaunch else {
            return
        }
        didSignalReadyToLaunch = true
        activeAttachReadyTimeoutTask?.cancel()
        activeAttachReadyTimeoutTask = nil
        status = "StikJIT attached for \(target.displayName)"

        let readyToLaunch = activeReadyToLaunch
        activeReadyToLaunch = nil
        readyToLaunch?()
    }

    private func scheduleActiveTimeout(for target: AutoJITLaunchTarget) {
        activeTimeoutTask?.cancel()
        activeTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.activeEnableTimeoutNanoseconds)
            } catch {
                return
            }
            await MainActor.run {
                self?.completeActiveJIT(
                    target: target,
                    ok: false,
                    message: "Timed out waiting for StikJIT to finish."
                )
            }
        }
    }

    private func completeActiveJIT(
        target: AutoJITLaunchTarget,
        ok: Bool,
        message: String?
    ) {
        activeTimeoutTask?.cancel()
        activeTimeoutTask = nil
        activeAttachReadyTimeoutTask?.cancel()
        activeAttachReadyTimeoutTask = nil
        activeLauncher?.invalidate()
        activeLauncher = nil
        activeHost = nil
        activeReadyToLaunch = nil
        didSignalReadyToLaunch = false
        isEnabling = false
        if ok {
            status = "JIT enabled for \(target.displayName)"
        } else {
            status = message.map { "StikJIT failed: \($0)" } ?? "StikJIT failed."
        }
    }

    private func resetActiveJIT() {
        activeTimeoutTask?.cancel()
        activeTimeoutTask = nil
        activeAttachReadyTimeoutTask?.cancel()
        activeAttachReadyTimeoutTask = nil
        activeLauncher?.invalidate()
        activeLauncher = nil
        activeHost = nil
        activeReadyToLaunch = nil
        didSignalReadyToLaunch = false
        isEnabling = false
        status = nil
    }
}

enum StikJITAutoJITError: LocalizedError {
    case alreadyRunning
    case missingPairingFile
    case unavailableOnCurrentPlatform
    case extensionNotFound
    case extensionConnectionFailed(String)
    case extensionEnableFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "StikJIT is already enabling JIT."
        case .missingPairingFile:
            return "The StikJIT pairing file is missing."
        case .unavailableOnCurrentPlatform:
            return "StikJIT auto-enable requires a device build with the StikJIT runner extension."
        case .extensionNotFound:
            return "The StikJIT runner extension was not found."
        case .extensionConnectionFailed(let message):
            return message
        case .extensionEnableFailed(let message):
            return message
        }
    }
}

// Host-side XPC object the runner calls back into. Callbacks arrive on arbitrary
// queues, so it only forwards to plain closures (which are thread-safe here) and
// never touches main-actor state directly.
private final class StikJITHostBridge: NSObject, StikJITHostXPCProtocol {
    var onLog: ((String) -> Void)?
    var onFinished: ((Bool, String?) -> Void)?

    func jitLog(_ line: String) {
        onLog?(line)
    }

    func jitFinished(_ ok: Bool, error: String?) {
        onFinished?(ok, error)
    }
}
