import Foundation
import Darwin
import SwiftUI
import UIKit

enum PlayingState: Equatable {
    case none
    case running(plan: XemuLaunchPlan)
}

@MainActor
final class EmulatorFileStore: ObservableObject {
    @Published private(set) var bios: LibraryFile?
    @Published private(set) var mcpx: LibraryFile?
    @Published private(set) var eeprom: LibraryFile?
    @Published private(set) var hdd: LibraryFile?
    @Published private(set) var games: [LibraryFile] = []
    
    @Published var playingState: PlayingState = .none
    
    @Published var selectedGameID = "" {
        didSet {
            UserDefaults.standard.set(selectedGameID, forKey: Self.selectedGameIDKey)
            if let selectedGame {
                UserDefaults.standard.set(selectedGame.fileName, forKey: Self.selectedGameNameKey)
            }
        }
    }
    @Published var universalJITEnabled: Bool {
        didSet {
            UserDefaults.standard.set(universalJITEnabled, forKey: Self.universalJITKey)
            setenv("XEMU_IOS_UNIVERSAL_JIT", UniversalJITSupport.environmentValue(for: universalJITEnabled), 1)
            setenv("XEMU_IOS_JIT_MODE", UniversalJITSupport.currentMode.environmentValue, 1)
        }
    }
    @Published var autoJITBeforeLaunchEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoJITBeforeLaunchEnabled, forKey: Self.autoJITBeforeLaunchKey)
        }
    }
    @Published var autoLaunchDashboardOnOpenEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoLaunchDashboardOnOpenEnabled, forKey: Self.autoLaunchDashboardOnOpenKey)
        }
    }
    @Published var presentPacingMode: PresentPacingMode {
        didSet {
            UserDefaults.standard.set(presentPacingMode.rawValue, forKey: PresentPacingMode.defaultsKey)
        }
    }
    @Published var metalHUDEnabled: Bool {
        didSet {
            UserDefaults.standard.set(metalHUDEnabled, forKey: Self.metalHUDEnabledKey)
            MetalDiagnostics.configurePerformanceHUD()
        }
    }
    @Published var statsHUDEnabled: Bool {
        didSet {
            UserDefaults.standard.set(statsHUDEnabled, forKey: Self.statsHUDEnabledKey)
        }
    }
    @Published var forceThirtyFPSLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(forceThirtyFPSLockEnabled, forKey: Self.forceThirtyFPSLockEnabledKey)
        }
    }
    @Published var portraitGameLibraryColumnCount: GameLibraryColumnCount {
        didSet {
            UserDefaults.standard.set(portraitGameLibraryColumnCount.rawValue,
                                      forKey: GameLibraryColumnCount.portraitDefaultsKey)
        }
    }
    @Published var landscapeGameLibraryColumnCount: GameLibraryColumnCount {
        didSet {
            UserDefaults.standard.set(landscapeGameLibraryColumnCount.rawValue,
                                      forKey: GameLibraryColumnCount.landscapeDefaultsKey)
        }
    }
    @Published var tbCacheSize: TBCacheSize {
        didSet {
            UserDefaults.standard.set(tbCacheSize.rawValue, forKey: TBCacheSize.defaultsKey)
        }
    }
    @Published var forceInsigniaNATEnabled: Bool {
        didSet {
            UserDefaults.standard.set(forceInsigniaNATEnabled, forKey: Self.forceInsigniaNATKey)
        }
    }
    @Published var natDNSServer: String {
        didSet {
            UserDefaults.standard.set(natDNSServer, forKey: Self.natDNSServerKey)
        }
    }
    @Published var natHostPort: String {
        didSet {
            UserDefaults.standard.set(natHostPort, forKey: Self.natHostPortKey)
        }
    }
    @Published var natGuestPort: String {
        didSet {
            UserDefaults.standard.set(natGuestPort, forKey: Self.natGuestPortKey)
        }
    }
    @Published var natPortProtocol: String {
        didSet {
            UserDefaults.standard.set(natPortProtocol, forKey: Self.natPortProtocolKey)
        }
    }
    @Published var message: UserMessage?
    @Published var launchPlan: XemuLaunchPlan?
    @Published private(set) var folderStorageUsage = FolderStorageUsage.empty

    static let universalJITKey = "UniversalJITEnabled"
    static let autoJITBeforeLaunchKey = "AutoJITBeforeLaunchEnabled"
    static let autoLaunchDashboardOnOpenKey = "AutoLaunchDashboardOnOpenEnabled"
    static let libraryTabsMigrationKey = "LibraryTabsDisabledInitialDashboardAutolaunch"
    static let selectedGameIDKey = "SelectedGameID"
    static let selectedGameNameKey = "SelectedGameName"
    static let metalHUDEnabledKey = "DukeXMetalHUDEnabled"
    static let statsHUDEnabledKey = "DukeXStatsHUDEnabled"
    static let forceThirtyFPSLockEnabledKey = "DukeXForceThirtyFPSLockEnabled"
    static let forceInsigniaNATKey = "ForceInsigniaNATEnabled"
    static let natDNSServerKey = "NATDNSServer"
    static let natHostPortKey = "NATHostPort"
    static let natGuestPortKey = "NATGuestPort"
    static let natPortProtocolKey = "NATPortProtocol"

    let documentsURL: URL
    let biosDirectoryURL: URL
    let romsDirectoryURL: URL
    let coversDirectoryURL: URL
    let gameConfigsDirectoryURL: URL
    let shaderCachesDirectoryURL: URL

    var selectedGame: LibraryFile? {
        games.first { $0.id == selectedGameID }
    }

    var systemFilesReady: Bool {
        bios != nil && mcpx != nil && hdd != nil
    }

    var isReady: Bool {
        systemFilesReady && selectedGame != nil
    }

    var networkSettings: NetworkSettings {
        NetworkSettings(
            forceInsigniaNAT: forceInsigniaNATEnabled,
            dnsServer: natDNSServer,
            hostPort: natHostPort,
            guestPort: natGuestPort,
            portProtocol: natPortProtocol
        )
    }

    init(fileManager: FileManager = .default) {
        documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        biosDirectoryURL = documentsURL.appendingPathComponent("BIOS", isDirectory: true)
        romsDirectoryURL = documentsURL.appendingPathComponent("ROMs", isDirectory: true)
        coversDirectoryURL = documentsURL.appendingPathComponent("Covers", isDirectory: true)
        gameConfigsDirectoryURL = documentsURL.appendingPathComponent("GameConfigs", isDirectory: true)
        shaderCachesDirectoryURL = documentsURL.appendingPathComponent("ShaderCaches", isDirectory: true)
        if UserDefaults.standard.object(forKey: Self.libraryTabsMigrationKey) == nil {
            UserDefaults.standard.set(false, forKey: Self.autoLaunchDashboardOnOpenKey)
            UserDefaults.standard.set(true, forKey: Self.libraryTabsMigrationKey)
        }
        universalJITEnabled = UserDefaults.standard.object(forKey: Self.universalJITKey) as? Bool ?? true
        autoJITBeforeLaunchEnabled = UserDefaults.standard.object(forKey: Self.autoJITBeforeLaunchKey) as? Bool ?? true
        autoLaunchDashboardOnOpenEnabled = UserDefaults.standard.object(forKey: Self.autoLaunchDashboardOnOpenKey) as? Bool ?? false
        presentPacingMode = PresentPacingMode.current
        metalHUDEnabled = UserDefaults.standard.object(forKey: Self.metalHUDEnabledKey) as? Bool ?? false
        statsHUDEnabled = UserDefaults.standard.object(forKey: Self.statsHUDEnabledKey) as? Bool ?? true
        forceThirtyFPSLockEnabled = UserDefaults.standard.object(forKey: Self.forceThirtyFPSLockEnabledKey) as? Bool ?? false
        portraitGameLibraryColumnCount = GameLibraryColumnCount.currentPortrait
        landscapeGameLibraryColumnCount = GameLibraryColumnCount.currentLandscape
        tbCacheSize = TBCacheSize.current
        forceInsigniaNATEnabled = UserDefaults.standard.object(forKey: Self.forceInsigniaNATKey) as? Bool ?? true
        natDNSServer = UserDefaults.standard.string(forKey: Self.natDNSServerKey) ?? NetworkSettings.insigniaDNSServer
        natHostPort = UserDefaults.standard.string(forKey: Self.natHostPortKey) ?? NetworkSettings.defaultHostPort
        natGuestPort = UserDefaults.standard.string(forKey: Self.natGuestPortKey) ?? NetworkSettings.defaultGuestPort
        natPortProtocol = UserDefaults.standard.string(forKey: Self.natPortProtocolKey) ?? NetworkSettings.defaultProtocol
        selectedGameID = UserDefaults.standard.string(forKey: Self.selectedGameIDKey) ?? ""
        setenv("XEMU_IOS_UNIVERSAL_JIT", UniversalJITSupport.environmentValue(for: universalJITEnabled), 1)
        setenv("XEMU_IOS_JIT_MODE", UniversalJITSupport.currentMode.environmentValue, 1)
    }

    func prepareAndRefresh() async {
        do {
            try prepareDirectories()
            try refresh()
        } catch {
            message = UserMessage(title: "Library Error", detail: error.localizedDescription)
        }
    }

    func refresh() throws {
        try prepareDirectories()
        let systemFiles = try scanDirectory(biosDirectoryURL)
        let gameFiles = try scanDirectory(romsDirectoryURL)
        mcpx = systemFiles
            .filter { $0.url.pathExtension.caseInsensitiveCompare("bin") == .orderedSame && $0.size == 512 }
            .sorted(by: sortByName)
            .first

        eeprom = systemFiles
            .filter { $0.url.pathExtension.caseInsensitiveCompare("bin") == .orderedSame && $0.size == 256 }
            .sorted(by: sortByName)
            .first

        bios = systemFiles
            .filter { file in
                file.url.pathExtension.caseInsensitiveCompare("bin") == .orderedSame &&
                file.size > 512 &&
                file.size % 65_536 == 0
            }
            .sorted(by: sortByName)
            .first

        hdd = systemFiles
            .filter { isHDD($0) }
            .sorted(by: sortByName)
            .first

        games = gameFiles
            .filter { isGame($0) }
            .map { makeGameLibraryFile(from: $0) }
            .sorted(by: sortByName)

        try refreshFolderStorageUsage()

        if selectedGame == nil {
            let selectedName = UserDefaults.standard.string(forKey: Self.selectedGameNameKey)
            if let selectedName,
               let matchingGame = games.first(where: { $0.fileName == selectedName }) {
                selectedGameID = matchingGame.id
            } else {
                selectedGameID = games.first?.id ?? ""
            }
        }
    }

    func importFiles(_ urls: [URL], to target: ImportTarget) {
        do {
            let destinationDirectory = target == .systemFiles ? biosDirectoryURL : romsDirectoryURL
            try prepareDirectories()

            for url in urls {
                let didStartAccessing = url.startAccessingSecurityScopedResource()
                defer {
                    if didStartAccessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }

                let destination = destinationDirectory.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
            }

            try refresh()
        } catch {
            message = UserMessage(title: "Import Failed", detail: error.localizedDescription)
        }
    }

    func prepareLaunchPlan() {
        do {
            launchPlan = try makeLaunchPlan()
        } catch {
            message = UserMessage(title: "Launch Blocked", detail: error.localizedDescription)
        }
    }

    func makeLaunchPlan() throws -> XemuLaunchPlan {
        let systemFiles = try makeSystemFileSet()
        guard let selectedGame else {
            throw LaunchPlanError.missing("Game")
        }

        return try XemuLaunchPlan.make(
            documentsURL: documentsURL,
            bios: systemFiles.bios,
            mcpx: systemFiles.mcpx,
            eeprom: systemFiles.eeprom,
            hdd: systemFiles.hdd,
            game: selectedGame,
            gamesDirectoryURL: romsDirectoryURL,
            universalJITEnabled: universalJITEnabled,
            networkSettings: networkSettings,
            tbCacheSize: tbCacheSize,
            shaderCacheURL: shaderCacheURL(for: selectedGame)
        )
    }

    func makeDashboardLaunchPlan() throws -> XemuLaunchPlan {
        let systemFiles = try makeSystemFileSet()

        return try XemuLaunchPlan.make(
            documentsURL: documentsURL,
            bios: systemFiles.bios,
            mcpx: systemFiles.mcpx,
            eeprom: systemFiles.eeprom,
            hdd: systemFiles.hdd,
            game: nil,
            gamesDirectoryURL: romsDirectoryURL,
            universalJITEnabled: universalJITEnabled,
            networkSettings: networkSettings,
            tbCacheSize: tbCacheSize,
            shaderCacheURL: dashboardShaderCacheURL
        )
    }

    func assignCover(_ data: Data, to game: LibraryFile) throws {
        try prepareDirectories()
        let imageData = UIImage(data: data)?.jpegData(compressionQuality: 0.92) ?? data
        try imageData.write(to: coverURL(for: game), options: .atomic)
        try refresh()
    }

    func importCustomConfig(_ url: URL, for game: LibraryFile) throws {
        try prepareDirectories()

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let destination = customConfigURL(for: game)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        try refresh()
    }

    func clearShaderCache(for game: LibraryFile) throws {
        let url = shaderCacheURL(for: game)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        message = UserMessage(
            title: "Shader Cache Cleared",
            detail: "\(game.displayName)'s shader cache will be rebuilt next time it launches."
        )
    }

    func removeGame(_ game: LibraryFile) throws {
        let urls = [
            game.url,
            coverURL(for: game),
            portableCoverURL(for: game),
            legacyCoverURL(forGameURL: game.url),
            customConfigURL(for: game),
            legacyCustomConfigURL(forGameURL: game.url),
            shaderCacheURL(for: game)
        ]

        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        if selectedGameID == game.id {
            selectedGameID = ""
            UserDefaults.standard.removeObject(forKey: Self.selectedGameNameKey)
        }

        try refresh()
    }

    private func makeSystemFileSet() throws -> (bios: LibraryFile, mcpx: LibraryFile, eeprom: LibraryFile?, hdd: LibraryFile) {
        guard let bios else {
            throw LaunchPlanError.missing("Flash BIOS")
        }
        guard let mcpx else {
            throw LaunchPlanError.missing("MCPX")
        }
        guard let hdd else {
            throw LaunchPlanError.missing("HDD")
        }
        return (bios, mcpx, eeprom, hdd)
    }

    private func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: biosDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: romsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: coversDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: gameConfigsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: shaderCachesDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    private func scanDirectory(_ url: URL) throws -> [LibraryFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        return try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { fileURL in
            let values = try fileURL.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else {
                return nil
            }
            let size = Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
            return LibraryFile(
                url: fileURL,
                size: size,
                kind: .unknown,
                titleName: nil,
                titleID: nil,
                coverURL: nil,
                customConfigURL: nil
            )
        }
    }

    private func makeGameLibraryFile(from file: LibraryFile) -> LibraryFile {
        let metadata = XISOGameTitleReader.metadata(in: file.url)
        let title = metadata?.titleName
        let cover = existingCoverURL(for: file.url, titleName: title, size: file.size)
        let customConfig = existingCustomConfigURL(for: file.url, titleName: title, size: file.size)
        return LibraryFile(
            url: file.url,
            size: file.size,
            kind: .game,
            titleName: title,
            titleID: metadata?.titleID,
            coverURL: cover,
            customConfigURL: customConfig
        )
    }

    private func isHDD(_ file: LibraryFile) -> Bool {
        let ext = file.url.pathExtension.lowercased()
        if ["qcow2", "qcow", "img", "raw", "hdd"].contains(ext) {
            return true
        }
        return ext == "bin" && file.size > 512 && file.id != bios?.id
    }

    private func isGame(_ file: LibraryFile) -> Bool {
        ["iso", "xiso"].contains(file.url.pathExtension.lowercased())
    }

    private func sortByName(_ lhs: LibraryFile, _ rhs: LibraryFile) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private func totalSize(of files: [LibraryFile]) -> Int64 {
        files.reduce(Int64(0)) { $0 + $1.size }
    }

    private func refreshFolderStorageUsage() throws {
        folderStorageUsage = FolderStorageUsage(
            bios: FolderStorageUsage.Folder(byteCount: totalSize(of: try scanDirectory(biosDirectoryURL))),
            roms: FolderStorageUsage.Folder(byteCount: totalSize(of: try scanDirectory(romsDirectoryURL))),
            covers: FolderStorageUsage.Folder(byteCount: totalSize(of: try scanDirectory(coversDirectoryURL)))
        )
    }

    private func coverURL(for game: LibraryFile) -> URL {
        coverURL(forGameAssetID: gameAssetID(for: game))
    }

    private func coverURL(forGameAssetID assetID: String) -> URL {
        coversDirectoryURL.appendingPathComponent("cover-\(assetID).jpg")
    }

    private func portableCoverURL(for game: LibraryFile) -> URL {
        portableCoverURL(forGameURL: game.url)
    }

    private func portableCoverURL(forGameURL url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("cover.jpg")
    }

    private func legacyCoverURL(forGameURL url: URL) -> URL {
        coversDirectoryURL.appendingPathComponent("cover-\(Self.stableID(for: url.path)).jpg")
    }

    private func existingCoverURL(for gameURL: URL, titleName: String?, size: Int64) -> URL? {
        let canonicalURL = coverURL(forGameAssetID: gameAssetID(forGameURL: gameURL, titleName: titleName, size: size))
        if FileManager.default.fileExists(atPath: canonicalURL.path) {
            removePortableCoverIfDuplicated(for: gameURL, canonicalURL: canonicalURL)
            return canonicalURL
        }

        let portableURL = portableCoverURL(forGameURL: gameURL)
        if FileManager.default.fileExists(atPath: portableURL.path) {
            try? FileManager.default.copyItemIfNeeded(from: portableURL, to: canonicalURL)
            if FileManager.default.fileExists(atPath: canonicalURL.path) {
                try? FileManager.default.removeItem(at: portableURL)
                return canonicalURL
            }
            return portableURL
        }

        let legacyURL = legacyCoverURL(forGameURL: gameURL)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            return nil
        }

        try? FileManager.default.copyItemIfNeeded(from: legacyURL, to: canonicalURL)
        if FileManager.default.fileExists(atPath: canonicalURL.path) {
            return canonicalURL
        }
        return legacyURL
    }

    private func removePortableCoverIfDuplicated(for gameURL: URL, canonicalURL: URL) {
        let portableURL = portableCoverURL(forGameURL: gameURL)
        guard portableURL.standardizedFileURL.path != canonicalURL.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: portableURL.path) else {
            return
        }
        try? FileManager.default.removeItem(at: portableURL)
    }

    private func customConfigURL(for game: LibraryFile) -> URL {
        customConfigURL(forGameAssetID: gameAssetID(for: game))
    }

    private func customConfigURL(forGameAssetID assetID: String) -> URL {
        gameConfigsDirectoryURL.appendingPathComponent("config-\(assetID).toml")
    }

    private func legacyCustomConfigURL(forGameURL url: URL) -> URL {
        gameConfigsDirectoryURL.appendingPathComponent("config-\(Self.stableID(for: url.path)).toml")
    }

    private func existingCustomConfigURL(for gameURL: URL, titleName: String?, size: Int64) -> URL? {
        let canonicalURL = customConfigURL(forGameAssetID: gameAssetID(forGameURL: gameURL, titleName: titleName, size: size))
        if FileManager.default.fileExists(atPath: canonicalURL.path) {
            return canonicalURL
        }

        let legacyURL = legacyCustomConfigURL(forGameURL: gameURL)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            return nil
        }

        try? FileManager.default.copyItemIfNeeded(from: legacyURL, to: canonicalURL)
        return FileManager.default.fileExists(atPath: canonicalURL.path) ? canonicalURL : legacyURL
    }

    private var dashboardShaderCacheURL: URL {
        shaderCachesDirectoryURL.appendingPathComponent("dashboard-vulkan-pipeline-cache.bin")
    }

    private func shaderCacheURL(for game: LibraryFile) -> URL {
        let url = shaderCachesDirectoryURL.appendingPathComponent("cache-\(gameAssetID(for: game))-vulkan-pipeline.bin")
        let legacyURL = shaderCachesDirectoryURL
            .appendingPathComponent("cache-\(Self.stableID(for: game.url.path))-vulkan-pipeline.bin")
        try? FileManager.default.copyItemIfNeeded(from: legacyURL, to: url)
        return url
    }

    private func gameAssetID(for game: LibraryFile) -> String {
        gameAssetID(forGameURL: game.url, titleName: game.titleName, size: game.size)
    }

    private func gameAssetID(forGameURL url: URL, titleName: String?, size: Int64) -> String {
        let normalizedTitle = Self.normalizedGameIdentityComponent(titleName)
        if !normalizedTitle.isEmpty {
            return Self.stableID(for: "title:\(normalizedTitle)|size:\(size)")
        }

        let relativePath = relativeGamePath(for: url) ?? url.lastPathComponent
        let normalizedPath = Self.normalizedGameIdentityComponent(relativePath)
        return Self.stableID(for: "file:\(normalizedPath)|size:\(size)")
    }

    private func relativeGamePath(for url: URL) -> String? {
        let basePath = romsDirectoryURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = basePath + "/"
        guard path.hasPrefix(prefix) else {
            return nil
        }
        return String(path.dropFirst(prefix.count))
    }

    private static func normalizedGameIdentityComponent(_ value: String?) -> String {
        guard let value else {
            return ""
        }
        return value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func stableID(for string: String) -> String {
        let prime: UInt64 = 1_099_511_628_211
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}
