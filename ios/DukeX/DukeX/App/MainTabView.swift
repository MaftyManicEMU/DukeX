import SwiftUI
import UniformTypeIdentifiers
import UIKit
import PhotosUI

private enum MainTab: Hashable {
    case games
    case profile
    case settings
}

struct MainTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: EmulatorFileStore
    @ObservedObject var runtime: EmulatorCoreRuntime
    @StateObject private var autoJIT = StikDebugAutoJITCoordinator()
    @StateObject private var profileStore = InsigniaProfileStore()
    @StateObject private var liveStatusStore = InsigniaLiveStatusStore()
    @State private var importTarget: ImportTarget?
    @State private var autoLaunchAttempted = false
    @State private var coverSelectionTarget: LibraryFile?
    @State private var selectedCoverItem: PhotosPickerItem?
    @State private var isCoverPickerPresented = false
    @State private var selectedProfileImageItem: PhotosPickerItem?
    @State private var isProfileImagePickerPresented = false
    @State private var configImportTarget: LibraryFile?
    @State private var removalConfirmationTarget: LibraryFile?
    @State private var isProfileLoginPresented = false
    @State private var isInsigniaDashboardPresented = false
    @State private var selectedTab: MainTab = .games

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                GamesLibraryView(
                    runtimeState: runtime.state,
                    liveStatusStore: liveStatusStore,
                    launchDashboard: launchDashboard,
                    launchGame: launchGame,
                    importGames: { importTarget = .games },
                    addCover: beginCoverSelection,
                    importConfig: beginConfigImport,
                    clearShaderCache: clearShaderCache,
                    requestRemoveGame: { removalConfirmationTarget = $0 }
                )
                .navigationTitle("DukeX")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    appToolbar(showsRefreshButton: true)
                }
            }
            .tabItem {
                Label("Games", systemImage: "gamecontroller")
            }
            .tag(MainTab.games)

            NavigationStack {
                ProfileView(
                    profileStore: profileStore,
                    signIn: { isProfileLoginPresented = true },
                    openDashboard: { isInsigniaDashboardPresented = true },
                    changeProfileImage: beginProfileImageSelection
                )
                .navigationTitle("DukeX")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    profileToolbar
                }
            }
            .tabItem {
                Label("Profile", systemImage: "person.crop.circle")
            }
            .tag(MainTab.profile)

            NavigationStack {
                SettingsView(
                    store: store,
                    runtimeState: runtime.state,
                    autoJITStatus: autoJIT.status,
                    importSystemFiles: { importTarget = .systemFiles }
                )
                    .navigationTitle("DukeX")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        appToolbar(showsRefreshButton: false)
                    }
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(MainTab.settings)
        }
        .sheet(isPresented: $isProfileLoginPresented) {
            ProfileLoginView(
                profileStore: profileStore,
                openDashboard: { isInsigniaDashboardPresented = true }
            )
        }
        .sheet(isPresented: $isInsigniaDashboardPresented) {
            InsigniaDashboardView(url: InsigniaPublicService.dashboardURL)
                .ignoresSafeArea()
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
        .onChange(of: selectedCoverItem) { _, item in
            handleSelectedCover(item)
        }
        .photosPicker(
            isPresented: $isProfileImagePickerPresented,
            selection: $selectedProfileImageItem,
            matching: .images
        )
        .onChange(of: selectedProfileImageItem) { _, item in
            handleSelectedProfileImage(item)
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
            isPresented: Binding(
                get: { removalConfirmationTarget != nil },
                set: { if !$0 { removalConfirmationTarget = nil } }
            ),
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
            runtime.refresh()
            liveStatusStore.refresh()
            if !environmentRequestsAutoLaunch {
                resumePendingAutoJITLaunchIfNeeded()
            }
        }
        .task {
            await store.prepareAndRefresh()
            runtime.refresh()
            if environmentRequestsAutoLaunch && !autoLaunchAttempted {
                autoJIT.clearPendingForFreshAutomaticLaunch()
            }
            if resumePendingAutoJITLaunchIfNeeded() {
                return
            }
            autoLaunchIfRequested()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                autoJIT.markAppReturnedFromStikDebugIfPending()
                resumePendingAutoJITLaunchIfNeeded()
            case .inactive, .background:
                autoJIT.markAppLeftForStikDebugIfPending()
            @unknown default:
                break
            }
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .games {
                liveStatusStore.refresh()
            } else if newTab == .profile {
                profileStore.refresh()
            } else if newTab == .settings {
                refreshLibraryForSettings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dukeXReturnToGamesRequested)) { _ in
            selectedTab = .games
        }
    }

    private var environmentRequestsAutoLaunch: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XEMU_IOS_AUTO_LAUNCH_GAME"] == "1" ||
            environment["XEMU_IOS_AUTO_LAUNCH_DASHBOARD"] == "1"
    }

    private func refreshLibraryForSettings() {
        do {
            try store.refresh()
        } catch {
            store.message = UserMessage(title: "Library Not Refreshed", detail: error.localizedDescription)
        }
    }

    @ToolbarContentBuilder
    private var profileToolbar: some ToolbarContent {
        appToolbar(showsRefreshButton: false)

        ToolbarItem(placement: .topBarLeading) {
            Button {
                if profileStore.isSignedIn {
                    profileStore.signOut()
                } else {
                    isProfileLoginPresented = true
                }
            } label: {
                Image(systemName: profileStore.isSignedIn ? "rectangle.portrait.and.arrow.right" : "person.crop.circle.badge.plus")
            }
            .accessibilityLabel(profileStore.isSignedIn ? "Sign Out" : "Sign In")
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                profileStore.refresh()
            } label: {
                if profileStore.isRefreshing {
                    ProgressView()
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .disabled(!profileStore.isSignedIn || profileStore.isRefreshing)
            .accessibilityLabel("Refresh Profile")
        }
    }

    @ToolbarContentBuilder
    private func appToolbar(showsRefreshButton: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Image("DukeXLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 118, height: 25)
                .accessibilityLabel("DukeX")
        }

        if showsRefreshButton {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        await store.prepareAndRefresh()
                        runtime.refresh()
                        liveStatusStore.refresh()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh")
            }
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
        guard plan.requiresJITHandoff && store.autoJITBeforeLaunchEnabled else {
            store.playingState = .running(plan: plan)
            return
        }

        try runtime.prepareBeforeAutoJIT()
        autoJIT.requestJIT(for: target, scriptName: plan.jitMode.stikDebugScriptName) { message in
            store.message = message
        }
        scheduleAutoJITFallbackIfNeeded()
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

    private func beginConfigImport(for game: LibraryFile) {
        configImportTarget = game
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

    private func launchWithoutAutoJIT(_ target: AutoJITLaunchTarget) {
        do {
            store.playingState = .running(plan: try makePlan(for: target))
        } catch {
            store.message = UserMessage(title: "Launch Blocked", detail: error.localizedDescription)
        }
    }

    private func makePlan(for target: AutoJITLaunchTarget) throws -> XemuLaunchPlan {
        switch target {
        case .dashboard:
            return try store.makeDashboardLaunchPlan()
        case .game:
            return try store.makeLaunchPlan()
        }
    }

    @discardableResult
    private func resumePendingAutoJITLaunchIfNeeded() -> Bool {
        guard autoJIT.hasPendingLaunch else {
            return false
        }
        guard let target = autoJIT.consumePendingLaunchIfReady() else {
            if autoJIT.hasObservedStikDebugTrip {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if UIApplication.shared.applicationState == .active {
                        resumePendingAutoJITLaunchIfNeeded()
                    }
                }
            }
            scheduleAutoJITFallbackIfNeeded()
            return true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            launchWithoutAutoJIT(target)
        }
        return true
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

    private func scheduleAutoJITFallbackIfNeeded() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 14_000_000_000)
            guard autoJIT.hasPendingLaunch,
                  UIApplication.shared.applicationState == .active,
                  runtime.state.canLaunch else {
                return
            }
            autoJIT.forcePendingLaunchReady()
            resumePendingAutoJITLaunchIfNeeded()
        }
    }
}
