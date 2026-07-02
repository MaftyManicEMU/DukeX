import Foundation
import Darwin
import SwiftUI
import UIKit

@MainActor
final class EmulatorFileStore: ObservableObject {
    @Published private(set) var bios: LibraryFile?
    @Published private(set) var mcpx: LibraryFile?
    @Published private(set) var eeprom: LibraryFile?
    @Published private(set) var hdd: LibraryFile?
    @Published private(set) var jitPairingFile: LibraryFile?
    @Published private(set) var games: [LibraryFile] = []
    @Published private(set) var skins: [ManicSkinLibraryItem] = []
    @Published var selectedGameID = "" {
        didSet {
            UserDefaults.standard.set(selectedGameID, forKey: Self.selectedGameIDKey)
            if let selectedGame {
                UserDefaults.standard.set(selectedGame.fileName, forKey: Self.selectedGameNameKey)
            }
        }
    }
    @Published var selectedSkinID = "" {
        didSet {
            UserDefaults.standard.set(selectedSkinID, forKey: Self.selectedSkinIDKey)
            if let selectedSkin {
                UserDefaults.standard.set(selectedSkin.fileName, forKey: Self.selectedSkinNameKey)
            }
        }
    }
    @Published var selectedPortraitSkinID = "" {
        didSet {
            UserDefaults.standard.set(selectedPortraitSkinID, forKey: Self.selectedPortraitSkinIDKey)
            if let selectedPortraitSkin {
                UserDefaults.standard.set(selectedPortraitSkin.fileName, forKey: Self.selectedPortraitSkinNameKey)
            }
        }
    }
    @Published var selectedLandscapeSkinID = "" {
        didSet {
            UserDefaults.standard.set(selectedLandscapeSkinID, forKey: Self.selectedLandscapeSkinIDKey)
            if let selectedLandscapeSkin {
                UserDefaults.standard.set(selectedLandscapeSkin.fileName, forKey: Self.selectedLandscapeSkinNameKey)
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
    @Published var forceThirtyFPSLockEnabled: Bool {
        didSet {
            UserDefaults.standard.set(forceThirtyFPSLockEnabled, forKey: Self.forceThirtyFPSLockEnabledKey)
        }
    }
    @Published var depthClampEnabled: Bool {
        didSet {
            UserDefaults.standard.set(depthClampEnabled, forKey: Self.depthClampEnabledKey)
        }
    }
    @Published var xboxCameraPeripheralEnabled: Bool {
        didSet {
            let effectiveValue = Self.xboxCameraPeripheralAvailable && xboxCameraPeripheralEnabled
            if xboxCameraPeripheralEnabled != effectiveValue {
                xboxCameraPeripheralEnabled = effectiveValue
            }
            UserDefaults.standard.set(effectiveValue, forKey: Self.xboxCameraPeripheralEnabledKey)
        }
    }
    @Published var xboxHeadsetMicPeripheralEnabled: Bool {
        didSet {
            UserDefaults.standard.set(xboxHeadsetMicPeripheralEnabled,
                                      forKey: Self.xboxHeadsetMicPeripheralEnabledKey)
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
    @Published var gameLibraryListViewEnabled: Bool {
        didSet {
            UserDefaults.standard.set(gameLibraryListViewEnabled, forKey: Self.gameLibraryListViewEnabledKey)
        }
    }
    @Published var touchHapticFeedbackLevel: TouchHapticFeedbackLevel {
        didSet {
            UserDefaults.standard.set(touchHapticFeedbackLevel.rawValue, forKey: TouchHapticFeedbackLevel.defaultsKey)
        }
    }
    @Published private(set) var alwaysRememberedThemeUnlocked: Bool {
        didSet {
            UserDefaults.standard.set(alwaysRememberedThemeUnlocked, forKey: Self.alwaysRememberedThemeUnlockedKey)
        }
    }
    @Published private(set) var livingOriginalThemeUnlocked: Bool {
        didSet {
            UserDefaults.standard.set(livingOriginalThemeUnlocked, forKey: Self.livingOriginalThemeUnlockedKey)
        }
    }
    @Published var themeMode: DukeXThemeMode {
        didSet {
            UserDefaults.standard.set(themeMode.rawValue, forKey: DukeXTheme.selectedThemeDefaultsKey)
            UserDefaults.standard.set(themeMode == .xboxNostalgia, forKey: DukeXTheme.xboxNostalgiaDefaultsKey)
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
    @Published var cloudSaveSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(cloudSaveSyncEnabled, forKey: Self.cloudSaveSyncEnabledKey)
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
    static let selectedSkinIDKey = "DukeXSelectedSkinID"
    static let selectedSkinNameKey = "DukeXSelectedSkinName"
    static let selectedPortraitSkinIDKey = "DukeXSelectedPortraitSkinID"
    static let selectedPortraitSkinNameKey = "DukeXSelectedPortraitSkinName"
    static let selectedLandscapeSkinIDKey = "DukeXSelectedLandscapeSkinID"
    static let selectedLandscapeSkinNameKey = "DukeXSelectedLandscapeSkinName"
    static let removedBundledSkinNamesKey = "DukeXRemovedBundledSkinNames"
    static let metalHUDEnabledKey = "DukeXMetalHUDEnabled"
    static let forceThirtyFPSLockEnabledKey = "DukeXForceThirtyFPSLockEnabled"
    static let depthClampEnabledKey = "DukeXDepthClampEnabled"
    static let xboxCameraPeripheralAvailable = false
    static let xboxCameraPeripheralEnabledKey = "DukeXXboxCameraPeripheralEnabled"
    static let xboxHeadsetMicPeripheralEnabledKey = "DukeXXboxHeadsetMicPeripheralEnabled"
    static let gameLibraryListViewEnabledKey = "DukeXGameLibraryListViewEnabled"
    static let alwaysRememberedThemeUnlockedKey = "DukeXAlwaysRememberedThemeUnlocked"
    static let livingOriginalThemeUnlockedKey = "DukeXLivingOriginalThemeUnlocked"
    static let forceInsigniaNATKey = "ForceInsigniaNATEnabled"
    static let natDNSServerKey = "NATDNSServer"
    static let natHostPortKey = "NATHostPort"
    static let natGuestPortKey = "NATGuestPort"
    static let natPortProtocolKey = "NATPortProtocol"
    static let cloudSaveSyncEnabledKey = "DukeXCloudSaveSyncEnabled"
    private static let bundledSkinFileNames: Set<String> = ["DukeX Default.manicskin"]
    private static let retiredBundledSkinFileNames: Set<String> = ["PS1.manicskin"]

    let documentsURL: URL
    let biosDirectoryURL: URL
    let romsDirectoryURL: URL
    let coversDirectoryURL: URL
    let gameConfigsDirectoryURL: URL
    let shaderCachesDirectoryURL: URL
    let skinsDirectoryURL: URL
    let cloudSavesDirectoryURL: URL
    let pairingDirectoryURL: URL

    var selectedGame: LibraryFile? {
        games.first { $0.id == selectedGameID }
    }

    var selectedSkin: ManicSkinLibraryItem? {
        selectedPortraitSkin ?? selectedLandscapeSkin ?? skins.first { $0.id == selectedSkinID }
    }

    var selectedPortraitSkin: ManicSkinLibraryItem? {
        skins.first { $0.id == selectedPortraitSkinID }
    }

    var selectedLandscapeSkin: ManicSkinLibraryItem? {
        skins.first { $0.id == selectedLandscapeSkinID }
    }

    var selectedSkinSummaryText: String? {
        switch (selectedPortraitSkin, selectedLandscapeSkin) {
        case (.some(let portrait), .some(let landscape)) where portrait.id == landscape.id:
            return portrait.displayName
        case (.some(let portrait), .some(let landscape)):
            return "\(portrait.displayName) / \(landscape.displayName)"
        case (.some(let portrait), .none):
            return portrait.displayName
        case (.none, .some(let landscape)):
            return landscape.displayName
        case (.none, .none):
            return selectedSkin?.displayName
        }
    }

    func game(matchingTitleID titleID: String) -> LibraryFile? {
        guard let titleID = GameLaunchLink.normalizedTitleID(titleID) else {
            return nil
        }

        return games.first {
            GameLaunchLink.normalizedTitleID($0.titleID) == titleID
        }
    }

    var systemFilesReady: Bool {
        bios != nil && mcpx != nil && hdd != nil
    }

    var jitPairingFileURL: URL? {
        jitPairingFile?.url
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

    func setTheme(_ mode: DukeXThemeMode, enabled: Bool) {
        guard mode != .alwaysRemembered || alwaysRememberedThemeUnlocked else {
            return
        }
        guard mode != .livingOriginal || livingOriginalThemeUnlocked else {
            return
        }

        if enabled {
            themeMode = mode
        } else if themeMode == mode {
            themeMode = .standard
        }
    }

    func unlockAlwaysRememberedTheme() {
        guard !alwaysRememberedThemeUnlocked else {
            return
        }

        alwaysRememberedThemeUnlocked = true
    }

    func unlockLivingOriginalTheme() {
        guard !livingOriginalThemeUnlocked else {
            return
        }

        livingOriginalThemeUnlocked = true
    }

    func selectedSkin(for orientation: ManicSkinPreviewOrientation) -> ManicSkinLibraryItem? {
        switch orientation {
        case .portrait:
            return selectedPortraitSkin ?? selectedSkin
        case .landscape:
            return selectedLandscapeSkin ?? selectedSkin
        }
    }

    func setSelectedSkin(_ skin: ManicSkinLibraryItem, for orientation: ManicSkinPreviewOrientation) {
        switch orientation {
        case .portrait:
            selectedPortraitSkinID = skin.id
        case .landscape:
            selectedLandscapeSkinID = skin.id
        }

        if selectedSkinID.isEmpty {
            selectedSkinID = skin.id
        }
    }

    init(fileManager: FileManager = .default) {
        documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        biosDirectoryURL = documentsURL.appendingPathComponent("BIOS", isDirectory: true)
        romsDirectoryURL = documentsURL.appendingPathComponent("ROMs", isDirectory: true)
        coversDirectoryURL = documentsURL.appendingPathComponent("Covers", isDirectory: true)
        gameConfigsDirectoryURL = documentsURL.appendingPathComponent("GameConfigs", isDirectory: true)
        shaderCachesDirectoryURL = documentsURL.appendingPathComponent("ShaderCaches", isDirectory: true)
        skinsDirectoryURL = documentsURL.appendingPathComponent("Skins", isDirectory: true)
        cloudSavesDirectoryURL = documentsURL.appendingPathComponent("CloudSaves", isDirectory: true)
        pairingDirectoryURL = documentsURL.appendingPathComponent("Pairing", isDirectory: true)
        if UserDefaults.standard.object(forKey: Self.libraryTabsMigrationKey) == nil {
            UserDefaults.standard.set(false, forKey: Self.autoLaunchDashboardOnOpenKey)
            UserDefaults.standard.set(true, forKey: Self.libraryTabsMigrationKey)
        }
        universalJITEnabled = UserDefaults.standard.object(forKey: Self.universalJITKey) as? Bool ?? true
        autoJITBeforeLaunchEnabled = UserDefaults.standard.object(forKey: Self.autoJITBeforeLaunchKey) as? Bool ?? true
        autoLaunchDashboardOnOpenEnabled = UserDefaults.standard.object(forKey: Self.autoLaunchDashboardOnOpenKey) as? Bool ?? false
        presentPacingMode = PresentPacingMode.current
        metalHUDEnabled = UserDefaults.standard.object(forKey: Self.metalHUDEnabledKey) as? Bool ?? false
        forceThirtyFPSLockEnabled = UserDefaults.standard.object(forKey: Self.forceThirtyFPSLockEnabledKey) as? Bool ?? false
        depthClampEnabled = UserDefaults.standard.object(forKey: Self.depthClampEnabledKey) as? Bool ?? true
        let effectiveXboxCameraPeripheralEnabled = Self.xboxCameraPeripheralAvailable
            && (UserDefaults.standard.object(forKey: Self.xboxCameraPeripheralEnabledKey) as? Bool ?? false)
        xboxCameraPeripheralEnabled = effectiveXboxCameraPeripheralEnabled
        UserDefaults.standard.set(effectiveXboxCameraPeripheralEnabled, forKey: Self.xboxCameraPeripheralEnabledKey)
        xboxHeadsetMicPeripheralEnabled =
            UserDefaults.standard.object(forKey: Self.xboxHeadsetMicPeripheralEnabledKey) as? Bool ?? false
        portraitGameLibraryColumnCount = GameLibraryColumnCount.currentPortrait
        landscapeGameLibraryColumnCount = GameLibraryColumnCount.currentLandscape
        gameLibraryListViewEnabled = UserDefaults.standard.object(forKey: Self.gameLibraryListViewEnabledKey) as? Bool ?? false
        touchHapticFeedbackLevel = TouchHapticFeedbackLevel.current
        alwaysRememberedThemeUnlocked =
            UserDefaults.standard.object(forKey: Self.alwaysRememberedThemeUnlockedKey) as? Bool ?? false
        livingOriginalThemeUnlocked =
            UserDefaults.standard.object(forKey: Self.livingOriginalThemeUnlockedKey) as? Bool ?? false
        themeMode = Self.currentThemeMode()
        tbCacheSize = TBCacheSize.current
        forceInsigniaNATEnabled = UserDefaults.standard.object(forKey: Self.forceInsigniaNATKey) as? Bool ?? true
        natDNSServer = UserDefaults.standard.string(forKey: Self.natDNSServerKey) ?? NetworkSettings.insigniaDNSServer
        natHostPort = UserDefaults.standard.string(forKey: Self.natHostPortKey) ?? NetworkSettings.defaultHostPort
        natGuestPort = UserDefaults.standard.string(forKey: Self.natGuestPortKey) ?? NetworkSettings.defaultGuestPort
        natPortProtocol = UserDefaults.standard.string(forKey: Self.natPortProtocolKey) ?? NetworkSettings.defaultProtocol
        cloudSaveSyncEnabled = UserDefaults.standard.object(forKey: Self.cloudSaveSyncEnabledKey) as? Bool ?? false
        selectedGameID = UserDefaults.standard.string(forKey: Self.selectedGameIDKey) ?? ""
        selectedSkinID = UserDefaults.standard.string(forKey: Self.selectedSkinIDKey) ?? ""
        selectedPortraitSkinID = UserDefaults.standard.string(forKey: Self.selectedPortraitSkinIDKey) ?? selectedSkinID
        selectedLandscapeSkinID = UserDefaults.standard.string(forKey: Self.selectedLandscapeSkinIDKey) ?? selectedSkinID
        setenv("XEMU_IOS_UNIVERSAL_JIT", UniversalJITSupport.environmentValue(for: universalJITEnabled), 1)
        setenv("XEMU_IOS_JIT_MODE", UniversalJITSupport.currentMode.environmentValue, 1)
    }

    private static func currentThemeMode() -> DukeXThemeMode {
        let alwaysRememberedUnlocked =
            UserDefaults.standard.object(forKey: Self.alwaysRememberedThemeUnlockedKey) as? Bool ?? false
        let livingOriginalUnlocked =
            UserDefaults.standard.object(forKey: Self.livingOriginalThemeUnlockedKey) as? Bool ?? false

        if let rawValue = UserDefaults.standard.string(forKey: DukeXTheme.selectedThemeDefaultsKey),
           let mode = DukeXThemeMode(rawValue: rawValue) {
            if mode == .alwaysRemembered && !alwaysRememberedUnlocked {
                return .standard
            }
            if mode == .livingOriginal && !livingOriginalUnlocked {
                return .standard
            }

            return mode
        }

        if UserDefaults.standard.object(forKey: DukeXTheme.xboxNostalgiaDefaultsKey) as? Bool == true {
            return .xboxNostalgia
        }

        return .standard
    }

    func prepareAndRefresh() async {
        do {
            try prepareDirectories()
            try refresh()
            if await scrapeMissingGameCoversIfNeeded() {
                try refresh()
            }
        } catch {
            message = UserMessage(title: "Library Error", detail: error.localizedDescription)
        }
    }

    func refresh() throws {
        try prepareDirectories()
        try installBundledSkinsIfNeeded()
        let systemFiles = try scanDirectory(biosDirectoryURL)
        let gameFiles = try scanDirectory(romsDirectoryURL)
        let skinFiles = try scanSkinsDirectory()
        let pairingFiles = try scanDirectory(pairingDirectoryURL)
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

        jitPairingFile = pairingFiles
            .filter { $0.url.pathExtension.caseInsensitiveCompare("plist") == .orderedSame }
            .sorted(by: sortByName)
            .first

        games = gameFiles
            .filter { isGame($0) }
            .map { makeGameLibraryFile(from: $0) }
            .sorted(by: sortByName)

        skins = skinFiles

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

        if selectedSkin == nil {
            let selectedName = UserDefaults.standard.string(forKey: Self.selectedSkinNameKey)
            if let selectedName,
               let matchingSkin = skins.first(where: { $0.fileName == selectedName }) {
                selectedSkinID = matchingSkin.id
            } else {
                selectedSkinID = skins.first?.id ?? ""
            }
        }

        repairSelectedSkin(
            current: \.selectedPortraitSkin,
            id: \.selectedPortraitSkinID,
            nameKey: Self.selectedPortraitSkinNameKey
        )
        repairSelectedSkin(
            current: \.selectedLandscapeSkin,
            id: \.selectedLandscapeSkinID,
            nameKey: Self.selectedLandscapeSkinNameKey
        )
    }

    func importFiles(_ urls: [URL], to target: ImportTarget) {
        do {
            try prepareDirectories()
            var importedSkinCount: Int?

            switch target {
            case .skins:
                importedSkinCount = try importSkinFiles(urls)
            case .pairingFile:
                try importPairingFile(urls)
            case .systemFiles, .games:
                let destinationDirectory = target == .systemFiles ? biosDirectoryURL : romsDirectoryURL

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
            }

            try refresh()
            if let importedSkinCount {
                message = UserMessage(
                    title: importedSkinCount == 1 ? "Skin Imported" : "Skins Imported",
                    detail: importedSkinCount == 1 ?
                        "The skin is ready in Assign Skin." :
                        "\(importedSkinCount) skins are ready in Assign Skin."
                )
            } else if target == .pairingFile {
                message = UserMessage(
                    title: "Pairing File Imported",
                    detail: "StikJIT will use pairingFile.plist for in-app JIT enablement."
                )
            }
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

    func prepareCloudSaveDirectory() throws {
        try prepareDirectories()
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
            shaderCacheURL: shaderCacheURL(for: selectedGame),
            xboxCameraEnabled: Self.xboxCameraPeripheralAvailable && xboxCameraPeripheralEnabled,
            xboxHeadsetMicEnabled: xboxHeadsetMicPeripheralEnabled,
            manicSkinPortraitURL: selectedPortraitSkin?.url ?? selectedSkin?.url,
            manicSkinLandscapeURL: selectedLandscapeSkin?.url ?? selectedSkin?.url
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
            shaderCacheURL: dashboardShaderCacheURL,
            xboxCameraEnabled: Self.xboxCameraPeripheralAvailable && xboxCameraPeripheralEnabled,
            xboxHeadsetMicEnabled: xboxHeadsetMicPeripheralEnabled,
            manicSkinPortraitURL: selectedPortraitSkin?.url ?? selectedSkin?.url,
            manicSkinLandscapeURL: selectedLandscapeSkin?.url ?? selectedSkin?.url
        )
    }

    func assignCover(_ data: Data, to game: LibraryFile) throws {
        try prepareDirectories()
        let imageData = UIImage(data: data)?.jpegData(compressionQuality: 0.92) ?? data
        try imageData.write(to: coverURL(for: game), options: .atomic)
        try refresh()
    }

    private func scrapeMissingGameCoversIfNeeded() async -> Bool {
        var addedCover = false
        let gamesNeedingCovers = games.filter { game in
            game.kind == .game &&
            game.coverURL == nil &&
            GameLaunchLink.normalizedTitleID(game.titleID) != nil
        }

        guard !gamesNeedingCovers.isEmpty else {
            return false
        }

        for game in gamesNeedingCovers {
            let destination = coverURL(for: game)
            guard !FileManager.default.fileExists(atPath: destination.path),
                  let titleID = GameLaunchLink.normalizedTitleID(game.titleID) else {
                continue
            }

            do {
                guard let coverData = try await XDBCoverArtScraper.fetchCoverData(for: titleID) else {
                    continue
                }

                let imageData = UIImage(data: coverData)?.jpegData(compressionQuality: 0.92) ?? coverData
                try imageData.write(to: destination, options: .atomic)
                addedCover = true
                NSLog("DukeX xdb cover scrape installed cover for %@ [%@]", game.displayName, titleID)
            } catch {
                NSLog(
                    "DukeX xdb cover scrape failed for %@ [%@]: %@",
                    game.displayName,
                    titleID,
                    error.localizedDescription
                )
            }
        }

        return addedCover
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

    func removeSkin(_ skin: ManicSkinLibraryItem) throws {
        try prepareDirectories()

        if FileManager.default.fileExists(atPath: skin.url.path) {
            try FileManager.default.removeItem(at: skin.url)
        }

        if Self.bundledSkinFileNames.contains(skin.fileName) {
            markBundledSkinRemoved(named: skin.fileName)
        }

        clearSkinSelectionIfNeeded(skin)
        try refresh()
        message = UserMessage(
            title: "Skin Removed",
            detail: "\(skin.displayName) was removed from Assign Skin."
        )
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
        try FileManager.default.createDirectory(at: skinsDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: cloudSavesDirectoryURL, withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: pairingDirectoryURL, withIntermediateDirectories: true, attributes: nil)
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

    private func installBundledSkinsIfNeeded() throws {
        guard let bundledSkinURL = Bundle.main.url(
            forResource: "DukeX Default",
            withExtension: "manicskin",
            subdirectory: "Skins"
        ) else {
            return
        }

        guard !isBundledSkinRemoved(named: bundledSkinURL.lastPathComponent) else {
            return
        }

        let values = try bundledSkinURL.resourceValues(forKeys: [.isDirectoryKey])
        let destination = skinsDirectoryURL.appendingPathComponent(bundledSkinURL.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return
        }

        if values.isDirectory == true {
            try DukeXZipArchive.createArchive(atPath: destination.path, fromDirectory: bundledSkinURL.path)
        } else {
            try FileManager.default.copyItem(at: bundledSkinURL, to: destination)
        }
    }

    private func scanSkinsDirectory() throws -> [ManicSkinLibraryItem] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        return try FileManager.default.contentsOfDirectory(
            at: skinsDirectoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard SkinPackageFormat.isSupportedPackage(url) else {
                return nil
            }
            guard !Self.retiredBundledSkinFileNames.contains(url.lastPathComponent) else {
                return nil
            }

            let values = try url.resourceValues(forKeys: keys)
            guard values.isDirectory == true || values.isRegularFile == true else {
                return nil
            }

            guard let item = ManicSkinLibraryItem(url: url) else {
                NSLog("DukeX skipped invalid Manic skin at %@", url.path)
                return nil
            }

            return item
        }
        .sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func importSkinFiles(_ urls: [URL]) throws -> Int {
        var importedCount = 0
        for url in urls {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            importedCount += try importSkinFileOrFolder(at: url)
        }

        if importedCount == 0 {
            throw SkinImportError.noSkinsFound
        }
        return importedCount
    }

    private func importPairingFile(_ urls: [URL]) throws {
        guard let url = urls.first else {
            throw PairingFileImportError.emptySelection
        }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let destination = pairingDirectoryURL.appendingPathComponent("pairingFile.plist")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
    }

    private func importSkinFileOrFolder(at url: URL) throws -> Int {
        if SkinPackageFormat.isSupportedPackage(url) {
            try installSkinArchive(at: url)
            return 1
        }

        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            return 0
        }

        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let skinPackages = children.filter {
            SkinPackageFormat.isSupportedPackage($0)
        }
        try skinPackages.forEach { child in
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try validateSkinPackage(at: child)
            }
        }
        for child in skinPackages {
            try installSkinArchive(at: child)
        }
        let importedCount = skinPackages.count
        return importedCount
    }

    private func installSkinArchive(at url: URL) throws {
        guard ManicSkin(baseURL: url) != nil else {
            throw SkinImportError.invalidSkin(url.lastPathComponent)
        }
        let destination = uniqueSkinDestinationURL(
            forBaseName: url.deletingPathExtension().lastPathComponent,
            fileExtension: SkinPackageFormat.fileExtension(for: url),
            isDirectory: false
        )
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            try DukeXZipArchive.createArchive(atPath: destination.path, fromDirectory: url.path)
        } else {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        guard ManicSkin(baseURL: destination) != nil else {
            throw SkinImportError.importedSkinUnreadable(url.lastPathComponent)
        }
        unmarkBundledSkinRemoved(named: destination.lastPathComponent)
    }

    private func importSkinPackage(at url: URL) throws {
        try validateSkinPackage(at: url)
        try copyValidatedSkinPackage(at: url)
    }

    private func validateSkinPackage(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw SkinImportError.notSkinPackage(url.lastPathComponent)
        }
        guard ManicSkin(baseURL: url) != nil else {
            throw SkinImportError.invalidSkin(url.lastPathComponent)
        }
    }

    private func copyValidatedSkinPackage(at url: URL) throws {
        let destination = uniqueSkinDestinationURL(
            forBaseName: url.deletingPathExtension().lastPathComponent,
            fileExtension: SkinPackageFormat.fileExtension(for: url),
            isDirectory: false
        )
        try DukeXZipArchive.createArchive(atPath: destination.path, fromDirectory: url.path)
        guard ManicSkin(baseURL: destination) != nil else {
            throw SkinImportError.importedSkinUnreadable(url.lastPathComponent)
        }
        unmarkBundledSkinRemoved(named: destination.lastPathComponent)
    }

    private func extractedSkinPackageURL(from archiveURL: URL) throws -> URL {
        let extractURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DukeXSkinImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractURL, withIntermediateDirectories: true)
        do {
            try DukeXZipArchive.extractArchive(atPath: archiveURL.path, toDirectory: extractURL.path)
        } catch {
            throw SkinImportError.archiveExtractionFailed(archiveURL.lastPathComponent)
        }

        if ManicSkin(baseURL: extractURL) != nil {
            return extractURL
        }

        let candidateURLs = try skinPackageCandidates(in: extractURL)
        if let validCandidate = candidateURLs.first(where: { ManicSkin(baseURL: $0) != nil }) {
            return validCandidate
        }

        throw SkinImportError.invalidSkin(archiveURL.lastPathComponent)
    }

    private func skinPackageCandidates(in directoryURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                continue
            }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("info.json").path) {
                candidates.append(url)
            }
        }

        return candidates.sorted { first, second in
            first.pathComponents.count < second.pathComponents.count
        }
    }

    private func copySkinPackageContents(from sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        let children = try FileManager.default.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for child in children {
            try FileManager.default.copyItem(
                at: child,
                to: destinationURL.appendingPathComponent(child.lastPathComponent)
            )
        }
    }

    private func repairSelectedSkin(
        current: KeyPath<EmulatorFileStore, ManicSkinLibraryItem?>,
        id: ReferenceWritableKeyPath<EmulatorFileStore, String>,
        nameKey: String
    ) {
        guard self[keyPath: current] == nil else {
            return
        }

        let selectedName = UserDefaults.standard.string(forKey: nameKey)
        if let selectedName,
           let matchingSkin = skins.first(where: { $0.fileName == selectedName }) {
            self[keyPath: id] = matchingSkin.id
        } else {
            self[keyPath: id] = selectedSkin?.id ?? skins.first?.id ?? ""
        }
    }

    private func clearSkinSelectionIfNeeded(_ skin: ManicSkinLibraryItem) {
        if selectedPortraitSkinID == skin.id {
            selectedPortraitSkinID = ""
        }
        if selectedLandscapeSkinID == skin.id {
            selectedLandscapeSkinID = ""
        }
        if selectedSkinID == skin.id {
            selectedSkinID = ""
        }

        clearSkinNameDefault(Self.selectedSkinNameKey, matching: skin.fileName)
        clearSkinNameDefault(Self.selectedPortraitSkinNameKey, matching: skin.fileName)
        clearSkinNameDefault(Self.selectedLandscapeSkinNameKey, matching: skin.fileName)
    }

    private func clearSkinNameDefault(_ key: String, matching fileName: String) {
        guard UserDefaults.standard.string(forKey: key) == fileName else {
            return
        }
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func isBundledSkinRemoved(named fileName: String) -> Bool {
        removedBundledSkinNames.contains(fileName)
    }

    private func markBundledSkinRemoved(named fileName: String) {
        var fileNames = removedBundledSkinNames
        fileNames.insert(fileName)
        saveRemovedBundledSkinNames(fileNames)
    }

    private func unmarkBundledSkinRemoved(named fileName: String) {
        var fileNames = removedBundledSkinNames
        guard fileNames.remove(fileName) != nil else {
            return
        }
        saveRemovedBundledSkinNames(fileNames)
    }

    private var removedBundledSkinNames: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.removedBundledSkinNamesKey) ?? [])
    }

    private func saveRemovedBundledSkinNames(_ fileNames: Set<String>) {
        UserDefaults.standard.set(fileNames.sorted(), forKey: Self.removedBundledSkinNamesKey)
    }

    private func uniqueSkinDestinationURL(
        forBaseName baseName: String,
        fileExtension: String,
        isDirectory: Bool
    ) -> URL {
        let fileManager = FileManager.default
        var destination = skinsDirectoryURL.appendingPathComponent(
            "\(baseName).\(fileExtension)",
            isDirectory: isDirectory
        )
        var suffix = 2

        while fileManager.fileExists(atPath: destination.path) {
            destination = skinsDirectoryURL.appendingPathComponent(
                "\(baseName) \(suffix).\(fileExtension)",
                isDirectory: isDirectory
            )
            suffix += 1
        }

        return destination
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

private enum SkinImportError: LocalizedError {
    case noSkinsFound
    case notSkinPackage(String)
    case invalidSkin(String)
    case importedSkinUnreadable(String)
    case archiveExtractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noSkinsFound:
            return "No \(SkinPackageFormat.readableFileExtensions) skin files were found in the selected item."
        case .notSkinPackage(let name):
            return "\(name) is not a valid skin package."
        case .invalidSkin(let name):
            return "\(name) could not be loaded. Make sure it contains a valid info.json and DukeX-compatible skin layout."
        case .importedSkinUnreadable(let name):
            return "\(name) was copied, but the imported copy could not be loaded."
        case .archiveExtractionFailed(let name):
            return "\(name) could not be opened as a skin archive."
        }
    }
}

private enum PairingFileImportError: LocalizedError {
    case emptySelection

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            return "No pairing file was selected."
        }
    }
}

private enum XDBCoverArtScraper {
    private static let rawBaseURL = URL(string: "https://raw.githubusercontent.com/xemu-project/xdb/main/titles")!

    static func fetchCoverData(for titleID: String) async throws -> Data? {
        guard let titlePath = titlePath(for: titleID) else {
            return nil
        }

        for fileName in ["cover_front.jpg", "cover_front_thumbnail.jpg"] {
            let url = rawBaseURL
                .appendingPathComponent(titlePath.publisherCode)
                .appendingPathComponent(titlePath.releaseCode)
                .appendingPathComponent(fileName)

            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            request.timeoutInterval = 20

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                continue
            }

            switch httpResponse.statusCode {
            case 200 where UIImage(data: data) != nil:
                return data
            case 404:
                continue
            default:
                continue
            }
        }

        return nil
    }

    private static func titlePath(for titleID: String) -> (publisherCode: String, releaseCode: String)? {
        let normalized = titleID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count == 8,
              UInt32(normalized, radix: 16) != nil,
              let publisherHigh = UInt8(normalized.prefix(2), radix: 16),
              let publisherLow = UInt8(normalized.dropFirst(2).prefix(2), radix: 16),
              let releaseNumber = UInt16(normalized.suffix(4), radix: 16) else {
            return nil
        }

        let publisherBytes = [publisherHigh, publisherLow]
        guard let publisherCode = String(bytes: publisherBytes, encoding: .ascii),
              publisherCode.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil else {
            return nil
        }

        return (publisherCode, String(format: "%03d", Int(releaseNumber)))
    }
}
