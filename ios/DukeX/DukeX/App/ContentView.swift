import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit
import PhotosUI
import GameController

private enum MainTab: Hashable {
    case games
    case profile
    case settings
}

private struct FriendProfileImageSelectionTarget {
    let key: String
    let title: String
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: EmulatorFileStore
    @StateObject private var runtime = EmulatorCoreRuntime()
    @StateObject private var autoJIT = StikJITAutoJITCoordinator()
    @StateObject private var profileStore = InsigniaProfileStore()
    @StateObject private var socialStore = XBLiveSocialStore()
    @StateObject private var emulatorPresence = XBLiveEmulatorPresenceCoordinator()
    @StateObject private var liveStatusStore = InsigniaLiveStatusStore()
    @StateObject private var gameMetadataStore = GameMetadataStore()
    @StateObject private var controllerBatteryMonitor = ControllerBatteryMonitor()
    @State private var importTarget: ImportTarget?
    @State private var autoLaunchAttempted = false
    @State private var coverSelectionTarget: LibraryFile?
    @State private var selectedCoverItem: PhotosPickerItem?
    @State private var isCoverPickerPresented = false
    @State private var selectedProfileImageItem: PhotosPickerItem?
    @State private var isProfileImagePickerPresented = false
    @State private var friendProfileImageTarget: FriendProfileImageSelectionTarget?
    @State private var selectedFriendProfileImageItem: PhotosPickerItem?
    @State private var isFriendProfileImagePickerPresented = false
    @State private var configImportTarget: LibraryFile?
    @State private var gameMetadataTarget: LibraryFile?
    @State private var removalConfirmationTarget: LibraryFile?
    @State private var isProfileLoginPresented = false
    @State private var selectedTab: MainTab = .games
    @State private var isGamesAutoRefreshRunning = false
    @State private var isAutomaticCloudSaveSyncRunning = false
    @State private var activeRuntimeWasGame = false
    @State private var lastObservedRuntimeState: EmulatorCoreRuntime.RunState?
    @State private var hasPhysicalControllerConnected = false
    @State private var xbliveRealtimeStatusTask: Task<Void, Never>?
    @State private var lastXBLiveRealtimeSocialRefreshAt: Date?
    @State private var lastXBLiveRealtimeProfileDataRefreshAt: Date?
    @AppStorage(GameLibrarySortMode.defaultsKey) private var sortModeRawValue = GameLibrarySortMode.title.rawValue

    private let tabRefreshTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private let controllerBatteryRefreshTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    private let xbliveRealtimeStatusRefreshInterval: UInt64 = 10_000_000_000
    private let xbliveRealtimeSocialRefreshInterval: TimeInterval = 30
    private let xbliveRealtimeProfileDataRefreshInterval: TimeInterval = 60

    var body: some View {
        let theme = DukeXTheme(mode: store.themeMode)
        let tabBarBackgroundVisibility: Visibility = theme.usesAnimatedBackground ? .hidden : .automatic

        ZStack {
            if theme.usesAnimatedBackground {
                NostalgicDotBackgroundView()
            } else {
                theme.screenBackground
                    .ignoresSafeArea()
            }

            TabView(selection: $selectedTab) {
                NavigationStack {
                    GamesLibraryView(
                        runtimeState: runtime.state,
                        liveStatusStore: liveStatusStore,
                        metadataStore: gameMetadataStore,
                        launchDashboard: launchDashboard,
                        launchGame: launchGame,
                        importGames: { importTarget = .games },
                        addCover: beginCoverSelection,
                        copyLaunchLink: copyLaunchLink,
                        importConfig: beginConfigImport,
                        clearShaderCache: clearShaderCache,
                        editGameData: { gameMetadataTarget = $0 },
                        requestRemoveGame: { removalConfirmationTarget = $0 },
                        launchManicEmu: store.themeMode == .manicFeelings ? openManicEmu : nil,
                        openXBLive: store.themeMode == .livingOriginal ? openXBLive : nil,
                        hasPhysicalControllerConnected: hasPhysicalControllerConnected,
                        controllerBatteryPercent: controllerBatteryMonitor.batteryPercent,
                        isActiveTab: selectedTab == .games
                    )
                    .navigationTitle("DukeX")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        appToolbar
                    }
                }
                .tabItem {
                    Label("Games", systemImage: "gamecontroller")
                }
                .tag(MainTab.games)

                NavigationStack {
                    ProfileView(
                        profileStore: profileStore,
                        socialStore: socialStore,
                        signIn: { isProfileLoginPresented = true },
                        signOut: {
                            socialStore.clear()
                            emulatorPresence.stop(reason: "sign out")
                            profileStore.signOut()
                        },
                        changeProfileImage: beginProfileImageSelection,
                        changeFriendProfileImage: beginFriendProfileImageSelection,
                        changeSocialFriendProfileImage: beginSocialFriendProfileImageSelection,
                        installedGames: store.games,
                        inviteEligibleGames: gameInviteEligibleGames,
                        launchGameFromInvite: launchGame
                    )
                    .navigationTitle("DukeX")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        appToolbar
                    }
                }
                .onAppear {
                    refreshProfileTab()
                }
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(MainTab.profile)

                NavigationStack {
                    SettingsView(
                        store: store,
                        profileStore: profileStore,
                        runtimeState: runtime.state,
                        autoJITStatus: autoJIT.status,
                        importSystemFiles: { importTarget = .systemFiles },
                        importPairingFile: { importTarget = .pairingFile },
                        importSkins: { importTarget = .skins }
                    )
                        .navigationTitle("DukeX")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            appToolbar
                        }
                }
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(MainTab.settings)
            }
            .background(Color.clear)
            .toolbarBackground(tabBarBackgroundVisibility, for: .tabBar)
            .sheet(isPresented: $isProfileLoginPresented) {
                ProfileLoginView(profileStore: profileStore)
            }
            .sheet(item: $gameMetadataTarget) { game in
                GameMetadataEditorView(
                    game: game,
                    metadata: gameMetadataStore.metadata(for: game),
                    save: { metadata in
                        gameMetadataStore.setMetadata(metadata, for: game)
                    }
                )
            }
            .sheet(item: $importTarget) { target in
                DocumentImportPicker(
                    target: target,
                    onPick: { urls in
                        importTarget = nil
                        store.importFiles(urls, to: target)
                    },
                    onCancel: {
                        importTarget = nil
                    }
                )
            }
            .fileImporter(
                isPresented: Binding(
                    get: { configImportTarget != nil },
                    set: { if !$0 { configImportTarget = nil } }
                ),
                allowedContentTypes: [.item],
                allowsMultipleSelection: false
            ) { result in
                let target = configImportTarget
                configImportTarget = nil

                guard let target else {
                    return
                }

                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        return
                    }
                    do {
                        try store.importCustomConfig(url, for: target)
                    } catch {
                        store.message = UserMessage(title: "Config Not Imported", detail: error.localizedDescription)
                    }
                case .failure(let error):
                    store.message = UserMessage(title: "Config Not Imported", detail: error.localizedDescription)
                }
            }
            .photosPicker(
                isPresented: $isCoverPickerPresented,
                selection: $selectedCoverItem,
                matching: .images
            )
            .onChange(of: selectedCoverItem) { item in
                handleSelectedCover(item)
            }
            .photosPicker(
                isPresented: $isProfileImagePickerPresented,
                selection: $selectedProfileImageItem,
                matching: .images
            )
            .onChange(of: selectedProfileImageItem) { item in
                handleSelectedProfileImage(item)
            }
            .photosPicker(
                isPresented: $isFriendProfileImagePickerPresented,
                selection: $selectedFriendProfileImageItem,
                matching: .images
            )
            .onChange(of: selectedFriendProfileImageItem) { item in
                handleSelectedFriendProfileImage(item)
            }
            .alert(item: $store.message) { message in
                Alert(
                    title: Text(message.title),
                    message: Text(message.detail),
                    dismissButton: .default(Text("OK"))
                )
            }
            .confirmationDialog(
                "Remove Game",
                isPresented: removalConfirmationPresented,
                titleVisibility: .visible
            ) {
                if let game = removalConfirmationTarget {
                    Button("Remove \(game.displayName)", role: .destructive) {
                        removeGame(game)
                    }
                }
                Button("Cancel", role: .cancel) {
                    removalConfirmationTarget = nil
                }
            } message: {
                if let game = removalConfirmationTarget {
                    Text("Are you sure you would like to remove \(game.displayName) and all of its data?")
                }
            }
            .sheet(item: $store.launchPlan) { plan in
                LaunchPlanView(plan: plan)
            }
            .onAppear {
                lastObservedRuntimeState = runtime.state
                refreshControllerStatus()
            }
            .task {
                profileStore.refresh()
                await refreshProfileSocialNowIfAuthenticated()
                startXBLiveRealtimeStatusRefreshIfNeeded()
                await refreshGamesNow()
                await pullCloudSavesAutomaticallyIfNeeded(reason: "launch")
                if environmentRequestsAutoLaunch && !autoLaunchAttempted {
                    autoJIT.clearPendingForFreshAutomaticLaunch()
                }
                autoLaunchIfRequested()
            }
            .onChange(of: scenePhase) { newPhase in
                switch newPhase {
                case .active:
                    startXBLiveRealtimeStatusRefreshIfNeeded()
                case .inactive, .background:
                    stopXBLiveRealtimeStatusRefresh()
                @unknown default:
                    break
                }
            }
            .onChange(of: selectedTab) { newTab in
                if newTab == .profile {
                    refreshProfileTab()
                } else {
                    refreshGamesAndProfile()
                }
                if newTab == .settings {
                    refreshLibraryForSettings()
                }
            }
            .onChange(of: runtime.state) { newState in
                let oldState = lastObservedRuntimeState ?? newState
                handleRuntimeStateChange(from: oldState, to: newState)
                lastObservedRuntimeState = newState
            }
            .onReceive(tabRefreshTimer) { _ in
                guard scenePhase == .active else {
                    return
                }
                refreshOpenTab()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dukeXReturnToGamesRequested)) { _ in
                selectedTab = .games
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in
                refreshControllerStatus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in
                refreshControllerStatus()
            }
            .onReceive(controllerBatteryRefreshTimer) { _ in
                refreshControllerStatus()
            }
            .onOpenURL { url in
                handleIncomingURL(url)
            }

            controllerLandscapeFooterOverlay
        }
        .environment(\.dukeXTheme, theme)
        .tint(theme.accentColor)
        .accentColor(theme.accentColor)
        .onAppear {
            DukeXTheme.applyUIKitAppearance(themeMode: store.themeMode)
        }
        .onChange(of: store.themeMode) { themeMode in
            DukeXTheme.applyUIKitAppearance(themeMode: themeMode)
        }
    }

    private var currentGameSortMode: GameLibrarySortMode {
        GameLibrarySortMode(rawValue: sortModeRawValue) ?? .title
    }

    private var gameInviteEligibleGames: [LibraryFile] {
        store.games
            .filter { game in
                GameLaunchLink.url(for: game) != nil &&
                    liveStatusStore.status(for: game)?.isSupported == true
            }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }

    @ViewBuilder
    private var controllerLandscapeFooterOverlay: some View {
        GeometryReader { geometry in
            if shouldShowControllerLandscapeFooter(in: geometry.size) {
                ControllerLandscapeFooterHelpers(sortTitle: currentGameSortMode.title)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func shouldShowControllerLandscapeFooter(in size: CGSize) -> Bool {
        selectedTab == .games &&
            hasPhysicalControllerConnected &&
            size.width > size.height
    }

    private var environmentRequestsAutoLaunch: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XEMU_IOS_AUTO_LAUNCH_GAME"] == "1" ||
            environment["XEMU_IOS_AUTO_LAUNCH_DASHBOARD"] == "1"
    }

    private func refreshControllerStatus() {
        guard let controller = Self.connectedPhysicalController() else {
            hasPhysicalControllerConnected = false
            controllerBatteryMonitor.clear()
            logControllerIndicatorStatus(selectedController: nil, batteryPercent: nil)
            return
        }

        hasPhysicalControllerConnected = true
        controllerBatteryMonitor.refresh(controllerNameHints: Self.controllerNameHints())
        logControllerIndicatorStatus(selectedController: controller, batteryPercent: controllerBatteryMonitor.batteryPercent)
    }

    private static func connectedPhysicalController() -> GCController? {
        let controllers = GCController.controllers().filter(isPhysicalGameController)
        return controllers.first { !$0.isAttachedToDevice } ??
            controllers.first
    }

    private static func controllerNameHints() -> [String] {
        GCController.controllers()
            .filter(isPhysicalGameController)
            .flatMap { controller in
                [controller.vendorName, controller.productCategory].compactMap { value in
                    let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
            }
    }

    private static func gameControllerBatteryPercent(for controller: GCController) -> Int? {
        guard let battery = controller.battery,
              battery.batteryState != .unknown else {
            return nil
        }

        let batteryLevel = min(max(battery.batteryLevel, 0), 1)
        return Int((batteryLevel * 100).rounded())
    }

    private static func isPhysicalGameController(_ controller: GCController) -> Bool {
        guard !isVirtualController(controller) else {
            return false
        }
        return controller.extendedGamepad != nil || controller.microGamepad != nil
    }

    private static func isVirtualController(_ controller: GCController) -> Bool {
        let vendorName = controller.vendorName ?? ""
        return vendorName.localizedCaseInsensitiveContains("virtual") ||
            controller.productCategory.localizedCaseInsensitiveContains("virtual")
    }

    private func logControllerIndicatorStatus(selectedController: GCController?, batteryPercent: Int?) {
        let selectedText: String
        if let selectedController {
            let vendorName = selectedController.vendorName ?? "unknown"
            let attached = selectedController.isAttachedToDevice ? "attached" : "external"
            let gameControllerPercent = Self.gameControllerBatteryPercent(for: selectedController)
                .map { "\($0)%" } ?? "unavailable"
            selectedText = "\(vendorName) category=\(selectedController.productCategory) \(attached) gameControllerBattery=\(gameControllerPercent)"
        } else {
            selectedText = "none"
        }

        let percentText = batteryPercent.map { "\($0)%" } ?? "unavailable"
        NSLog("xemu_ios: controller_indicator: selected=%@ bluetoothBattery=%@", selectedText, percentText)
    }

    private var removalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { removalConfirmationTarget != nil },
            set: { isPresented in
                if !isPresented {
                    removalConfirmationTarget = nil
                }
            }
        )
    }

    private func refreshLibraryForSettings() {
        do {
            try store.refresh()
        } catch {
            store.message = UserMessage(title: "Library Not Refreshed", detail: error.localizedDescription)
        }
    }

    @ToolbarContentBuilder
    private var appToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Image("DukeXLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 118, height: 25)
                .accessibilityLabel("DukeX")
        }
    }

    private func refreshGamesAndProfile() {
        refreshGamesTab()
        profileStore.refresh()
        refreshProfileSocialIfAuthenticated()
    }

    private func refreshProfileTab() {
        profileStore.refresh()
        refreshProfileSocialIfAuthenticated()
    }

    private func refreshOpenTab() {
        switch selectedTab {
        case .games:
            refreshGamesTab()
        case .profile:
            profileStore.refresh()
        case .settings:
            break
        }
        refreshProfileSocialIfAuthenticated()
    }

    private func refreshProfileSocialIfAuthenticated() {
        Task { @MainActor in
            await refreshProfileSocialNowIfAuthenticated()
        }
    }

    @MainActor
    private func refreshProfileSocialNowIfAuthenticated() async {
        guard profileStore.session?.isAuthenticated == true else {
            socialStore.clear()
            return
        }

        configureSocialNotifications()
        configureEmulatorPresenceNotifications()
        await socialStore.refreshAll()
        lastXBLiveRealtimeSocialRefreshAt = Date()
        await refreshXBLiveRealtimeStatusNow()
    }

    @MainActor
    private func startXBLiveRealtimeStatusRefreshIfNeeded() {
        guard scenePhase == .active,
              xbliveRealtimeStatusTask == nil else {
            return
        }

        xbliveRealtimeStatusTask = Task { @MainActor in
            while !Task.isCancelled {
                await refreshXBLiveRealtimeStatusNow()

                do {
                    try await Task.sleep(nanoseconds: xbliveRealtimeStatusRefreshInterval)
                } catch {
                    break
                }
            }
        }
    }

    @MainActor
    private func stopXBLiveRealtimeStatusRefresh() {
        xbliveRealtimeStatusTask?.cancel()
        xbliveRealtimeStatusTask = nil
    }

    @MainActor
    private func refreshXBLiveRealtimeStatusNow() async {
        await profileStore.refreshXBLiveLiveStatus()

        guard profileStore.session?.isAuthenticated == true else {
            socialStore.clear()
            lastXBLiveRealtimeSocialRefreshAt = nil
            lastXBLiveRealtimeProfileDataRefreshAt = nil
            return
        }

        let now = Date()
        let shouldRefreshSocial = shouldRunXBLiveRealtimeRefresh(
            lastRun: lastXBLiveRealtimeSocialRefreshAt,
            interval: xbliveRealtimeSocialRefreshInterval,
            now: now
        )
        let shouldRefreshProfileData = shouldRunXBLiveRealtimeRefresh(
            lastRun: lastXBLiveRealtimeProfileDataRefreshAt,
            interval: xbliveRealtimeProfileDataRefreshInterval,
            now: now
        )

        configureSocialNotifications()
        configureEmulatorPresenceNotifications()
        await profileStore.refreshLivePresence()
        await socialStore.refreshLivePresence()

        if shouldRefreshProfileData {
            await profileStore.refreshLiveProfileData()
            lastXBLiveRealtimeProfileDataRefreshAt = now
        }

        if shouldRefreshSocial {
            await socialStore.refreshLiveSocialItems()
            lastXBLiveRealtimeSocialRefreshAt = now
        }
    }

    private func shouldRunXBLiveRealtimeRefresh(
        lastRun: Date?,
        interval: TimeInterval,
        now: Date
    ) -> Bool {
        guard let lastRun else {
            return true
        }

        return now.timeIntervalSince(lastRun) >= interval
    }

    @MainActor
    private func configureSocialNotifications() {
        socialStore.configureLocalNotifications(
            customAvatarImage: { username in
                let key = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let image = profileStore.friendProfileImages[key] {
                    return image
                }

                if let friend = socialStore.messageableFriends.first(where: {
                    $0.key == key || $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key
                }) {
                    return profileStore.friendProfileImages[friend.key]
                }

                return nil
            },
            gameTitle: { titleID, embeddedTitle in
                if let normalizedTitleID = GameLaunchLink.normalizedTitleID(titleID),
                   let game = store.game(matchingTitleID: normalizedTitleID) {
                    return game.displayName
                }

                let title = embeddedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                return title?.isEmpty == false ? title! : "Title \(titleID)"
            },
            gameLocalCoverURL: { titleID in
                guard let normalizedTitleID = GameLaunchLink.normalizedTitleID(titleID) else {
                    return nil
                }

                return store.game(matchingTitleID: normalizedTitleID)?.coverURL
            }
        )
    }

    @MainActor
    private func configureEmulatorPresenceNotifications() {
        emulatorPresence.onAuthenticationFailure = { message in
            store.message = UserMessage(
                title: "XB.Live Presence Not Synced",
                detail: message
            )
        }
    }

    private func refreshGamesTab() {
        Task { @MainActor in
            await refreshGamesNow()
        }
    }

    @MainActor
    private func refreshGamesNow() async {
        guard !isGamesAutoRefreshRunning else {
            return
        }

        isGamesAutoRefreshRunning = true
        defer { isGamesAutoRefreshRunning = false }

        await store.prepareAndRefresh()
        runtime.refresh()
        liveStatusStore.refresh()
    }

    @MainActor
    private func pullCloudSavesAutomaticallyIfNeeded(reason: String) async {
        await runAutomaticCloudSaveSync(reason: reason) { sessionKey, hdd, eeprom, directoryURL in
            let result = try await XBLCloudSaveService().pullRemoteSaves(
                sessionKey: sessionKey,
                hdd: hdd,
                eeprom: eeprom,
                cloudSavesDirectoryURL: directoryURL
            )
            NSLog("DukeX automatic cloud save pull completed: %@", result.pullDetail)
        }
    }

    @MainActor
    private func pushCloudSavesAutomaticallyIfNeeded(reason: String) async {
        await runAutomaticCloudSaveSync(reason: reason) { sessionKey, hdd, eeprom, directoryURL in
            let result = try await XBLCloudSaveService().pushLocalSaves(
                sessionKey: sessionKey,
                hdd: hdd,
                eeprom: eeprom,
                cloudSavesDirectoryURL: directoryURL,
                games: store.games
            )
            NSLog("DukeX automatic cloud save push completed: %@", result.pushDetail)
        }
    }

    @MainActor
    private func runAutomaticCloudSaveSync(
        reason: String,
        operation: @escaping (
            _ sessionKey: String,
            _ hdd: LibraryFile,
            _ eeprom: LibraryFile,
            _ cloudSavesDirectoryURL: URL
        ) async throws -> Void
    ) async {
        guard store.cloudSaveSyncEnabled else {
            return
        }
        guard !runtime.state.isRunning,
              !isAutomaticCloudSaveSyncRunning else {
            return
        }
        guard let sessionKey = try? InsigniaProfileStore.storedSessionKey(),
              !sessionKey.isEmpty else {
            NSLog("DukeX automatic cloud save sync skipped (%@): missing xb.live session", reason)
            return
        }
        guard let hdd = store.hdd else {
            NSLog("DukeX automatic cloud save sync skipped (%@): missing HDD", reason)
            return
        }
        guard let eeprom = store.eeprom else {
            NSLog("DukeX automatic cloud save sync skipped (%@): missing EEPROM", reason)
            return
        }

        isAutomaticCloudSaveSyncRunning = true
        defer {
            isAutomaticCloudSaveSyncRunning = false
        }

        do {
            try store.prepareCloudSaveDirectory()
            try await operation(sessionKey, hdd, eeprom, store.cloudSavesDirectoryURL)
        } catch {
            NSLog(
                "DukeX automatic cloud save sync failed (%@): %@",
                reason,
                error.localizedDescription
            )
        }
    }

    private func launchGame() {
        do {
            try launch(.game)
        } catch {
            store.message = UserMessage(title: "Launch Blocked", detail: error.localizedDescription)
        }
    }

    private func launchGame(_ game: LibraryFile) {
        store.selectedGameID = game.id
        launchGame()
    }

    private func launchDashboard() {
        do {
            try launch(.dashboard)
        } catch {
            store.message = UserMessage(title: "Launch Blocked", detail: error.localizedDescription)
        }
    }

    private func launch(_ target: AutoJITLaunchTarget) throws {
        let plan = try makePlan(for: target)
        activeRuntimeWasGame = target == .game
        guard plan.requiresJITHandoff && store.autoJITBeforeLaunchEnabled else {
            launchRuntime(plan, target: target)
            return
        }

        guard let pairingFile = store.jitPairingFileURL else {
            throw LaunchPlanError.missing("StikJIT pairing file")
        }

        do {
            try autoJIT.requestJIT(
                for: target,
                pairingFile: pairingFile,
                jitMode: plan.jitMode
            ) {
                launchRuntimeAfterAutoJITAttach(plan, target: target)
            }
        } catch {
            if target == .game {
                emulatorPresence.stop(reason: "StikJIT failed")
            }
            activeRuntimeWasGame = false
            store.message = UserMessage(
                title: "Auto JIT Failed",
                detail: error.localizedDescription
            )
        }
    }

    private func launchRuntimeAfterAutoJITAttach(_ plan: XemuLaunchPlan, target: AutoJITLaunchTarget) {
        do {
            try runtime.prepareBeforeAutoJIT()
            launchRuntime(plan, target: target)
        } catch {
            autoJIT.cancelActiveJIT(message: error.localizedDescription)
            if target == .game {
                emulatorPresence.stop(reason: "StikJIT failed")
            }
            activeRuntimeWasGame = false
            store.message = UserMessage(
                title: "Auto JIT Failed",
                detail: error.localizedDescription
            )
        }
    }

    private func handleRuntimeStateChange(
        from oldState: EmulatorCoreRuntime.RunState,
        to newState: EmulatorCoreRuntime.RunState
    ) {
        guard activeRuntimeWasGame,
              oldState.isRunning else {
            if activeRuntimeWasGame,
               case .failed = newState {
                emulatorPresence.stop(reason: "launch failed")
            }
            if !newState.isRunning {
                activeRuntimeWasGame = false
            }
            return
        }

        switch newState {
        case .exited:
            activeRuntimeWasGame = false
            emulatorPresence.stop(reason: "game exit")
            Task { @MainActor in
                await pushCloudSavesAutomaticallyIfNeeded(reason: "game exit")
            }
        case .failed:
            activeRuntimeWasGame = false
            emulatorPresence.stop(reason: "runtime failed")
        default:
            break
        }
    }

    private func beginCoverSelection(for game: LibraryFile) {
        coverSelectionTarget = game
        selectedCoverItem = nil
        isCoverPickerPresented = true
    }

    private func beginProfileImageSelection() {
        selectedProfileImageItem = nil
        isProfileImagePickerPresented = true
    }

    private func beginFriendProfileImageSelection(for friend: InsigniaFriend) {
        friendProfileImageTarget = FriendProfileImageSelectionTarget(key: friend.key, title: friend.gamertag)
        selectedFriendProfileImageItem = nil
        isFriendProfileImagePickerPresented = true
    }

    private func beginSocialFriendProfileImageSelection(for friend: XBLiveSocialFriend) {
        friendProfileImageTarget = FriendProfileImageSelectionTarget(key: friend.key, title: friend.title)
        selectedFriendProfileImageItem = nil
        isFriendProfileImagePickerPresented = true
    }

    private func beginConfigImport(for game: LibraryFile) {
        configImportTarget = game
    }

    private func copyLaunchLink(for game: LibraryFile) {
        guard let url = GameLaunchLink.url(for: game) else {
            store.message = UserMessage(
                title: "Launch Link Unavailable",
                detail: "\(game.displayName) does not have a readable TitleID."
            )
            return
        }

        UIPasteboard.general.string = url.absoluteString
        store.message = UserMessage(
            title: "Launch Link Copied",
            detail: url.absoluteString
        )
    }

    private func openManicEmu() {
        guard let launchURL = URL(string: "manicemu://launch"),
              let fallbackURL = URL(string: "https://github.com/Manic-EMU/ManicEMU/releases") else {
            return
        }

        let application = UIApplication.shared
        if application.canOpenURL(launchURL) {
            application.open(launchURL)
        } else {
            application.open(fallbackURL)
        }
    }

    private func openXBLive() {
        guard let url = URL(string: "https://xb.live/") else {
            return
        }

        UIApplication.shared.open(url)
    }

    private func handleIncomingURL(_ url: URL) {
        if let callbackScheme = GameLibraryExportLink.callbackScheme(from: url) {
            handleGameLibraryExportRequest(callbackScheme: callbackScheme)
            return
        }

        handleLaunchLink(url)
    }

    private func handleGameLibraryExportRequest(callbackScheme: String) {
        Task { @MainActor in
            await store.prepareAndRefresh()

            guard let response = GameLibraryExportLink.response(
                for: store.games,
                metadata: { gameMetadataStore.metadata(for: $0) },
                callbackScheme: callbackScheme
            ) else {
                store.message = UserMessage(
                    title: "Library Export Failed",
                    detail: "DukeX could not prepare a game library response for \(callbackScheme)."
                )
                return
            }

            UIApplication.shared.open(response.callbackURL) { success in
                if !success {
                    Task { @MainActor in
                        store.message = UserMessage(
                            title: "Library Export Failed",
                            detail: "DukeX prepared \(response.gameCount) game\(response.gameCount == 1 ? "" : "s"), but could not open \(callbackScheme)."
                        )
                    }
                }
            }
        }
    }

    private func handleLaunchLink(_ url: URL) {
        guard let titleID = GameLaunchLink.titleID(from: url) else {
            return
        }

        selectedTab = .games
        Task { @MainActor in
            await store.prepareAndRefresh()
            guard let game = store.game(matchingTitleID: titleID) else {
                store.message = UserMessage(
                    title: "Game Not Found",
                    detail: "No installed game matched TitleID \(titleID)."
                )
                return
            }

            launchGame(game)
        }
    }

    private func clearShaderCache(for game: LibraryFile) {
        do {
            try store.clearShaderCache(for: game)
        } catch {
            store.message = UserMessage(title: "Shader Cache Not Cleared", detail: error.localizedDescription)
        }
    }

    private func removeGame(_ game: LibraryFile) {
        defer {
            removalConfirmationTarget = nil
        }

        do {
            try store.removeGame(game)
        } catch {
            store.message = UserMessage(title: "Game Not Removed", detail: error.localizedDescription)
        }
    }

    private func handleSelectedCover(_ item: PhotosPickerItem?) {
        guard let item, let game = coverSelectionTarget else {
            return
        }

        Task { @MainActor in
            defer {
                selectedCoverItem = nil
                coverSelectionTarget = nil
            }

            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CoverSelectionError.emptySelection
                }
                try store.assignCover(data, to: game)
            } catch {
                store.message = UserMessage(title: "Cover Not Added", detail: error.localizedDescription)
            }
        }
    }

    private func handleSelectedProfileImage(_ item: PhotosPickerItem?) {
        guard let item else {
            return
        }

        Task { @MainActor in
            defer {
                selectedProfileImageItem = nil
            }

            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CoverSelectionError.emptySelection
                }
                try profileStore.assignProfileImage(data)
            } catch {
                store.message = UserMessage(title: "Profile Picture Not Added", detail: error.localizedDescription)
            }
        }
    }

    private func handleSelectedFriendProfileImage(_ item: PhotosPickerItem?) {
        guard let item, let target = friendProfileImageTarget else {
            return
        }

        Task { @MainActor in
            defer {
                selectedFriendProfileImageItem = nil
                friendProfileImageTarget = nil
            }

            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CoverSelectionError.emptySelection
                }
                try profileStore.assignFriendProfileImage(data, key: target.key)
            } catch {
                store.message = UserMessage(title: "\(target.title) Picture Not Added", detail: error.localizedDescription)
            }
        }
    }

    private func launchWithoutAutoJIT(_ target: AutoJITLaunchTarget) {
        do {
            let plan = try makePlan(for: target)
            activeRuntimeWasGame = target == .game
            launchRuntime(plan, target: target)
        } catch {
            store.message = UserMessage(title: "Launch Blocked", detail: error.localizedDescription)
        }
    }

    private func launchRuntime(_ plan: XemuLaunchPlan, target: AutoJITLaunchTarget) {
        if target == .game {
            emulatorPresence.start(titleID: plan.titleID, gameName: plan.gameName)
        } else {
            emulatorPresence.stop(reason: "dashboard launch")
        }
        runtime.launch(plan: plan)
    }

    private func makePlan(for target: AutoJITLaunchTarget) throws -> XemuLaunchPlan {
        switch target {
        case .dashboard:
            return try store.makeDashboardLaunchPlan()
        case .game:
            return try store.makeLaunchPlan()
        }
    }

    private func autoLaunchIfRequested() {
        guard !autoLaunchAttempted else {
            return
        }
        guard !autoJIT.hasPendingLaunch else {
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let shouldAutoLaunchGame = environment["XEMU_IOS_AUTO_LAUNCH_GAME"] == "1"
        let shouldAutoLaunchDashboard =
            store.autoLaunchDashboardOnOpenEnabled ||
            environment["XEMU_IOS_AUTO_LAUNCH_DASHBOARD"] == "1"
        guard shouldAutoLaunchGame || shouldAutoLaunchDashboard else {
            return
        }
        guard shouldAutoLaunchGame || !autoJIT.shouldSuppressAutomaticDashboardLaunch else {
            return
        }

        autoLaunchAttempted = true
        if shouldAutoLaunchGame {
            launchGame()
        } else if shouldAutoLaunchDashboard {
            autoJIT.noteAutomaticDashboardLaunchAttempt()
            launchDashboard()
        }
    }
}

private struct ControllerLandscapeFooterHelpers: View {
    let sortTitle: String

    var body: some View {
        HStack(alignment: .center) {
            sortHelper

            Spacer(minLength: 16)

            actionHelpers
        }
        .padding(.horizontal, 52)
        .padding(.bottom, 33)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .foregroundStyle(.primary)
        .accessibilityHidden(true)
    }

    private var sortHelper: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ControllerLandscapeButtonGlyph("X")
                Text("Sort")
                    .font(.system(size: 12, weight: .semibold))
                Text("|")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                Text(sortTitle)
                    .font(.system(size: 12, weight: .regular))
            }

            HStack(spacing: 6) {
                ControllerLandscapeButtonGlyph("Y")
                Text("Dashboard")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    private var actionHelpers: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                ControllerLandscapeButtonGlyph("A")
                Text("Select")
                    .font(.system(size: 12, weight: .semibold))
            }

            HStack(spacing: 5) {
                ControllerLandscapeButtonGlyph("LT", style: .wide)
                Text("/")
                    .font(.system(size: 12, weight: .semibold))
                ControllerLandscapeButtonGlyph("RT", style: .wide)
                Text("Page")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private struct ControllerLandscapeButtonGlyph: View {
    enum Style {
        case round
        case wide
    }

    let label: String
    var style: Style

    init(_ label: String, style: Style = .round) {
        self.label = label
        self.style = style
    }

    var body: some View {
        Text(label)
            .font(.system(size: style == .round ? 10 : 9, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.88))
            .frame(width: style == .round ? 18 : 27,
                   height: 18,
                   alignment: .center)
            .background(.white.opacity(0.92),
                        in: Capsule(style: .continuous))
    }
}
