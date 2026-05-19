import Foundation
import Darwin

struct XemuLaunchPlan: Identifiable, Equatable {
    let id = UUID()
    let configURL: URL
    let arguments: [String]
    let jitMode: RuntimeJITMode
    let requiresJITHandoff: Bool
    let universalJITEnabled: Bool
    let gameName: String
    let isDashboard: Bool

    var commandLine: String {
        arguments.map(Self.shellQuoted).joined(separator: " ")
    }

    static func make(
        documentsURL: URL,
        bios: LibraryFile,
        mcpx: LibraryFile,
        eeprom: LibraryFile?,
        hdd: LibraryFile,
        game: LibraryFile?,
        gamesDirectoryURL: URL,
        universalJITEnabled: Bool,
        networkSettings: NetworkSettings,
        tbCacheSize: TBCacheSize,
        shaderCacheURL: URL
    ) throws -> XemuLaunchPlan {
        let configURL = documentsURL.appendingPathComponent("xemu-ios.toml")
        let gamesPath = game?.url.deletingLastPathComponent().path ?? gamesDirectoryURL.path
        let dvdPath = game?.url.path ?? ""
        let launchName = game?.displayName ?? "Xbox Dashboard"
        let customConfigURL = game?.customConfigURL
        let jitMode = UniversalJITSupport.currentMode
        let requiresJITHandoff = UniversalJITSupport.requiresJITHandoff(for: universalJITEnabled)
        let effectiveUniversalJITEnabled = UniversalJITSupport.effectiveEnabled(for: universalJITEnabled)
        let eepromPathLine = eeprom.map {
            "eeprom_path = \(tomlQuoted($0.url.path))\n"
        } ?? ""
        if customConfigURL == nil {
            let toml = """
            [general]
            show_welcome = false
            skip_boot_anim = false
            games_dir = \(tomlQuoted(gamesPath))

            [display]
            renderer = "VULKAN"

            [display.ui]
            show_menubar = false
            show_notifications = true
            hide_cursor = true

            [perf]
            cache_shaders = true

            [input]
            auto_bind = true
            background_input_capture = true

            [net]
            enable = true
            backend = "nat"

            [[net.nat.forward_ports]]
            host = \(networkSettings.effectiveHostPort)
            guest = \(networkSettings.effectiveGuestPort)
            protocol = \(tomlQuoted(networkSettings.effectivePortProtocol))

            [sys]
            mem_limit = "64"
            avpack = "hdtv"

            [sys.files]
            bootrom_path = \(tomlQuoted(mcpx.url.path))
            flashrom_path = \(tomlQuoted(bios.url.path))
            hdd_path = \(tomlQuoted(hdd.url.path))
            \(eepromPathLine)dvd_path = \(tomlQuoted(dvdPath))
            """

            try toml.write(to: configURL, atomically: true, encoding: .utf8)
        }
        setenv("XEMU_IOS_UNIVERSAL_JIT", effectiveUniversalJITEnabled ? "1" : "0", 1)
        setenv("XEMU_IOS_JIT_MODE", jitMode.environmentValue, 1)
        setenv("XEMU_IOS_VK_PIPELINE_CACHE_PATH", shaderCacheURL.path, 1)
        setenv("XEMU_IOS_FORCE_INSIGNIA_NAT", networkSettings.forceInsigniaNAT ? "1" : "0", 1)
        if let dnsServer = networkSettings.effectiveDNSServer {
            setenv("XEMU_IOS_NAT_DIRECT_DNS", dnsServer, 1)
        } else {
            unsetenv("XEMU_IOS_NAT_DIRECT_DNS")
        }

        let accelOptions: [String] = ([
            "thread=single",
            "tb-size=\(tbCacheSize.launchArgumentValue)",
            jitMode == .wxReprotection ? "split-wx=on" : nil
        ] as [String?]).compactMap { $0 }

        return XemuLaunchPlan(
            configURL: customConfigURL ?? configURL,
            arguments: [
                "xemu-ios",
                "-accel", "tcg,\(accelOptions.joined(separator: ","))",
                "-config_path", (customConfigURL ?? configURL).path
            ],
            jitMode: jitMode,
            requiresJITHandoff: requiresJITHandoff,
            universalJITEnabled: effectiveUniversalJITEnabled,
            gameName: launchName,
            isDashboard: game == nil
        )
    }

    private static func tomlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func shellQuoted(_ value: String) -> String {
        if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines) == nil {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
