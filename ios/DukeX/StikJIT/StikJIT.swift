import Foundation
import StikJIT

// Classic NSExtension principal class (see also StikJITExtensionLauncher on the
// app side). The host launches this extension via the private NSExtension API and
// hands over an anonymous NSXPCListener endpoint through the extension item. The
// extension connects back, receives the parent PID + pairing data + script, and
// runs StikJIT's debugserver attach in its own process.
//
// These @objc protocols mirror the ObjC declarations in
// DukeX/Runtime/JIT/StikJITExtensionLauncher.h. They live in two separate
// processes, so matching @objc selector names (not a shared type) is what makes
// the XPC interfaces line up.
@objc(StikJITRunnerXPCProtocol)
protocol StikJITRunnerXPCProtocol {
    func enableJIT(forParentPID pid: Int32, pairingData: Data, scriptIdentifier: String)
}

@objc(StikJITHostXPCProtocol)
protocol StikJITHostXPCProtocol {
    func jitLog(_ line: String)
    func jitFinished(_ ok: Bool, error: String?)
}

@objc(StikJITHelper)
final class StikJITHelper: NSObject, NSExtensionRequestHandling, StikJITRunnerXPCProtocol {
    static let endpointKey = "DukeXStikJITListenerEndpoint"

    private var connection: NSXPCConnection?
    private var host: StikJITHostXPCProtocol?

    func beginRequest(with context: NSExtensionContext) {
        NSLog("[DukeX StikJIT] helper beginRequest")
        guard let item = context.inputItems.first as? NSExtensionItem,
              let endpoint = item.userInfo?[Self.endpointKey] as? NSXPCListenerEndpoint
        else {
            NSLog("[DukeX StikJIT] missing listener endpoint")
            context.cancelRequest(withError: NSError(domain: "StikJITHelper", code: 1))
            return
        }

        let c = NSXPCConnection(listenerEndpoint: endpoint)
        c.exportedInterface = NSXPCInterface(with: StikJITRunnerXPCProtocol.self)
        c.exportedObject = self
        c.remoteObjectInterface = NSXPCInterface(with: StikJITHostXPCProtocol.self)
        c.resume()
        connection = c
        host = c.remoteObjectProxyWithErrorHandler { _ in } as? StikJITHostXPCProtocol
        host?.jitLog("StikJIT runner alive, pid \(getpid())")
    }

    func enableJIT(forParentPID pid: Int32, pairingData: Data, scriptIdentifier: String) {
        let host = self.host
        let script = Self.script(for: scriptIdentifier)
        host?.jitLog("enableJIT pid=\(pid) script=\(scriptIdentifier) pairingBytes=\(pairingData.count)")

        Thread.detachNewThread {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("dukex-pairing-\(getpid()).plist")
            do {
                try pairingData.write(to: tmp, options: .atomic)
                host?.jitLog("wrote \(pairingData.count) pairing bytes to \(tmp.path); attaching to pid \(pid)")
                defer { try? FileManager.default.removeItem(at: tmp) }
                try StikJIT.enableJIT(
                    targetPID: pid,
                    pairingFile: tmp,
                    script: script
                ) { line in
                    host?.jitLog(line)
                }
                host?.jitFinished(true, error: nil)
            } catch {
                host?.jitLog("enableJIT failed: \(String(describing: error))")
                host?.jitFinished(false, error: error.localizedDescription)
            }
        }
    }

    private static func script(for identifier: String) -> StikJIT.Script {
        identifier == "legacy" ? .legacy : .universal
    }
}
