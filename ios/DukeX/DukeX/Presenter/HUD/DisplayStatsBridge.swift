import Darwin
import Foundation

final class XemuDisplayStatsBridge {
    static let shared = XemuDisplayStatsBridge()

    private typealias CopyDisplayStats = @convention(c) (UnsafeMutableRawPointer?) -> CInt
    private var copyDisplayStats: CopyDisplayStats?
    private var copyDisplayStatsGeneration: UInt64?

    func sample() -> DukeXDisplayStats? {
        let currentGeneration = XemuCoreRuntimeSymbolResolver.shared.currentGeneration()
        if copyDisplayStats == nil || copyDisplayStatsGeneration != currentGeneration {
            resolve()
        }

        guard let copyDisplayStats else {
            return nil
        }

        var stats = DukeXDisplayStats()
        let copied = withUnsafeMutablePointer(to: &stats) { pointer in
            copyDisplayStats(UnsafeMutableRawPointer(pointer))
        }
        guard copied != 0 else {
            return nil
        }
        return stats
    }

    private func resolve() {
        copyDisplayStats = nil
        copyDisplayStatsGeneration = nil
        guard let resolved = XemuCoreRuntimeSymbolResolver.shared.resolve("xemu_ios_copy_display_stats") else {
            return
        }

        copyDisplayStats = unsafeBitCast(resolved.symbol, to: CopyDisplayStats.self)
        copyDisplayStatsGeneration = resolved.generation
    }
}
