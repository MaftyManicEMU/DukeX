import SwiftUI
import UIKit
import GameController

struct GamesLibraryView: View {
    @Environment(\.dukeXTheme) private var theme
    @EnvironmentObject private var store: EmulatorFileStore
    @AppStorage(GameLibrarySortMode.defaultsKey) private var sortModeRawValue = GameLibrarySortMode.title.rawValue
    @State private var favoriteGameKeys = GameLibraryFavorites.load()
    @State private var recentlyPlayedGameTimes = GameLibraryRecents.load()
    @State private var isLandscapeLayout = false
    @State private var statusDate = Date()
    @State private var deviceBatteryPercent: Int?
    @State private var isDeviceBatteryCharging = false
    @State private var controllerLandscapePageIndex = 0
    @State private var controllerLandscapeSelectedGameID: String?
    @State private var controllerLandscapeSelectionInitialized = false
    @State private var controllerInputController: GCController?
    @State private var controllerPolledInputs: Set<ControllerLandscapePolledInput> = []

    private let statusRefreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    private let controllerInputPollTimer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()
    private let libraryHorizontalPadding: CGFloat = 20
    private let controllerLandscapePageSize = 5
    private let controllerLandscapeTileSpacing: CGFloat = 18
    private let controllerLandscapeTileScale: CGFloat = 1.06

    let runtimeState: EmulatorCoreRuntime.RunState
    let liveStatusStore: InsigniaLiveStatusStore
    let metadataStore: GameMetadataStore
    let launchDashboard: () -> Void
    let launchGame: (LibraryFile) -> Void
    let importGames: () -> Void
    let addCover: (LibraryFile) -> Void
    let copyLaunchLink: (LibraryFile) -> Void
    let importConfig: (LibraryFile) -> Void
    let clearShaderCache: (LibraryFile) -> Void
    let editGameData: (LibraryFile) -> Void
    let requestRemoveGame: (LibraryFile) -> Void
    let launchManicEmu: (() -> Void)?
    let openXBLive: (() -> Void)?
    let hasPhysicalControllerConnected: Bool
    let controllerBatteryPercent: Int?
    let isActiveTab: Bool

    var body: some View {
        GeometryReader { geometry in
            let displayedGames = sortedGames
            let controllerLandscapeActive = hasPhysicalControllerConnected &&
                isActiveTab &&
                geometry.size.width > geometry.size.height

            Group {
                if controllerLandscapeActive {
                    controllerLandscapeContent(displayedGames: displayedGames, size: geometry.size)
                } else {
                    standardLibraryContent(displayedGames: displayedGames, size: geometry.size)
                }
            }
            .background(Color.clear)
            .onAppear {
                updateLandscapeLayout(for: geometry.size)
                updateControllerLandscapeMode(active: controllerLandscapeActive, displayedGames: displayedGames)
            }
            .onChange(of: geometry.size) { size in
                updateLandscapeLayout(for: size)
                let active = hasPhysicalControllerConnected && isActiveTab && size.width > size.height
                updateControllerLandscapeMode(active: active, displayedGames: displayedGames)
            }
            .onChange(of: displayedGames.map(\.id)) { _ in
                updateControllerLandscapeMode(active: controllerLandscapeActive, displayedGames: displayedGames)
            }
            .onChange(of: hasPhysicalControllerConnected) { _ in
                updateControllerLandscapeMode(active: controllerLandscapeActive, displayedGames: displayedGames)
            }
            .onChange(of: isActiveTab) { _ in
                updateControllerLandscapeMode(active: controllerLandscapeActive, displayedGames: displayedGames)
            }
            .onChange(of: runtimeState.canLaunch) { _ in
                updateControllerInputHandlers(active: controllerLandscapeActive)
            }
            .onReceive(statusRefreshTimer) { date in
                statusDate = date
                updateDeviceBatteryStatus()
            }
            .onReceive(controllerInputPollTimer) { _ in
                pollControllerLandscapeInput(active: controllerLandscapeActive)
            }
        }
        .background {
            DukeXThemedBackgroundView()
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            updateDeviceBatteryStatus()
        }
        .onDisappear {
            clearControllerInputHandlers()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if showsControllerLandscapeIndicator {
                    ControllerStatusPill(batteryPercent: controllerBatteryPercent)
                } else {
                    Button(action: importGames) {
                        Image(systemName: "plus.circle")
                    }
                    .accessibilityLabel("Import Game")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                if showsControllerLandscapeIndicator {
                    DeviceStatusPill(
                        date: statusDate,
                        batteryPercent: deviceBatteryPercent,
                        isCharging: isDeviceBatteryCharging
                    )
                } else if let launchManicEmu {
                    Button(action: launchManicEmu) {
                        Image("ManicFeelingsThemeIcon")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityLabel("Open Manic EMU")
                } else if let openXBLive {
                    Button(action: openXBLive) {
                        Image("XBLCommunityIcon")
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                    }
                    .accessibilityLabel("Open xb.live")
                }
            }
        }
    }

    @ViewBuilder
    private func standardLibraryContent(displayedGames: [LibraryFile], size: CGSize) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                GameSortPicker(selection: sortModeBinding)

                Button(action: launchDashboard) {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.grid.1x2")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("Launch Dashboard")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: GameLibraryGridMetrics.compactControlHeight)
                    .padding(.horizontal, 12)
                    .background(theme.surfaceColor,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(theme.borderColor, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!store.systemFilesReady || !runtimeState.canLaunch)
                .opacity((store.systemFilesReady && runtimeState.canLaunch) ? 1 : 0.45)

                if store.games.isEmpty {
                    GamesEmptyState(importGames: importGames)
                } else if displayedGames.isEmpty {
                    GameLibraryFilterEmptyState(title: emptyFilterTitle, systemImage: emptyFilterSystemImage)
                } else if store.gameLibraryListViewEnabled {
                    LazyVStack(spacing: 12) {
                        ForEach(displayedGames) { game in
                            GameListRow(
                                game: game,
                                metadata: metadataStore.metadata(for: game),
                                recentlyPlayedTime: recentlyPlayedTime(for: game),
                                isLandscape: size.width > size.height,
                                canLaunch: store.systemFilesReady && runtimeState.canLaunch,
                                liveStatus: liveStatusStore.status(for: game),
                                isFavorite: isFavorite(game),
                                launch: {
                                    markRecentlyPlayed(game)
                                    launchGame(game)
                                },
                                addCover: { addCover(game) },
                                copyLaunchLink: { copyLaunchLink(game) },
                                importConfig: { importConfig(game) },
                                clearShaderCache: { clearShaderCache(game) },
                                editGameData: { editGameData(game) },
                                toggleFavorite: { toggleFavorite(game) },
                                requestRemoveGame: { requestRemoveGame(game) }
                            )
                        }
                    }
                } else {
                    let activeColumnCount = gameLibraryColumnCount(for: size)
                    let availableGridWidth = size.width - (libraryHorizontalPadding * 2)
                    let tileWidth = GameLibraryGridMetrics.tileWidth(for: activeColumnCount,
                                                                     availableWidth: availableGridWidth)
                    LazyVGrid(columns: GameLibraryGridMetrics.columns(for: activeColumnCount,
                                                                      availableWidth: availableGridWidth),
                              alignment: .center,
                              spacing: GameLibraryGridMetrics.spacing(for: activeColumnCount) + 6) {
                        ForEach(displayedGames) { game in
                            GameCoverTile(
                                game: game,
                                canLaunch: store.systemFilesReady && runtimeState.canLaunch,
                                liveStatus: liveStatusStore.status(for: game),
                                isFavorite: isFavorite(game),
                                launch: {
                                    markRecentlyPlayed(game)
                                    launchGame(game)
                                },
                                addCover: { addCover(game) },
                                copyLaunchLink: { copyLaunchLink(game) },
                                importConfig: { importConfig(game) },
                                clearShaderCache: { clearShaderCache(game) },
                                toggleFavorite: { toggleFavorite(game) },
                                requestRemoveGame: { requestRemoveGame(game) }
                            )
                            .frame(width: tileWidth)
                        }
                    }
                }
            }
            .padding(.horizontal, libraryHorizontalPadding)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
    }

    @ViewBuilder
    private func controllerLandscapeContent(displayedGames: [LibraryFile], size: CGSize) -> some View {
        VStack(spacing: 0) {
            if store.games.isEmpty {
                GamesEmptyState(importGames: importGames)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedGames.isEmpty {
                GameLibraryFilterEmptyState(title: emptyFilterTitle, systemImage: emptyFilterSystemImage)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let pages = controllerLandscapePages(from: displayedGames)
                let tileWidth = controllerLandscapeTileWidth(for: size)

                TabView(selection: $controllerLandscapePageIndex) {
                    ForEach(pages.indices, id: \.self) { pageIndex in
                        HStack(spacing: controllerLandscapeTileSpacing) {
                            ForEach(pages[pageIndex]) { game in
                                GameCoverTile(
                                    game: game,
                                    canLaunch: store.systemFilesReady && runtimeState.canLaunch,
                                    liveStatus: liveStatusStore.status(for: game),
                                    isFavorite: isFavorite(game),
                                    isHighlighted: game.id == controllerLandscapeSelectedGameID,
                                    presentation: .controllerLandscapePage,
                                    launch: {
                                        controllerLandscapeSelectedGameID = game.id
                                        markRecentlyPlayed(game)
                                        launchGame(game)
                                    },
                                    addCover: { addCover(game) },
                                    copyLaunchLink: { copyLaunchLink(game) },
                                    importConfig: { importConfig(game) },
                                    clearShaderCache: { clearShaderCache(game) },
                                    toggleFavorite: { toggleFavorite(game) },
                                    requestRemoveGame: { requestRemoveGame(game) }
                                )
                                .frame(width: tileWidth)
                                .scaleEffect(controllerLandscapeTileScale)
                                .zIndex(game.id == controllerLandscapeSelectedGameID ? 1 : 0)
                            }

                            ForEach(0..<max(0, controllerLandscapePageSize - pages[pageIndex].count), id: \.self) { _ in
                                Color.clear
                                    .frame(width: tileWidth)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .tag(pageIndex)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onChange(of: controllerLandscapePageIndex) { _ in
                    syncControllerLandscapeSelectionToVisiblePage(displayedGames: displayedGames)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var showsControllerLandscapeIndicator: Bool {
        hasPhysicalControllerConnected && isActiveTab && isLandscapeLayout
    }

    private func updateLandscapeLayout(for size: CGSize) {
        let newValue = size.width > size.height
        if isLandscapeLayout != newValue {
            isLandscapeLayout = newValue
        }
    }

    private func updateDeviceBatteryStatus() {
        let batteryLevel = UIDevice.current.batteryLevel
        guard batteryLevel >= 0 else {
            deviceBatteryPercent = nil
            isDeviceBatteryCharging = false
            return
        }

        deviceBatteryPercent = Int((batteryLevel * 100).rounded())
        isDeviceBatteryCharging = UIDevice.current.batteryState == .charging ||
            UIDevice.current.batteryState == .full
    }

    private func updateControllerLandscapeMode(active: Bool, displayedGames: [LibraryFile]) {
        guard active else {
            controllerLandscapeSelectionInitialized = false
            controllerLandscapeSelectedGameID = nil
            controllerLandscapePageIndex = 0
            clearControllerInputHandlers()
            return
        }

        normalizeControllerLandscapeSelection(displayedGames: displayedGames)
        updateControllerInputHandlers(active: true)
    }

    private func normalizeControllerLandscapeSelection(displayedGames: [LibraryFile]) {
        guard !displayedGames.isEmpty else {
            controllerLandscapeSelectionInitialized = false
            controllerLandscapeSelectedGameID = nil
            controllerLandscapePageIndex = 0
            return
        }

        let pageCount = controllerLandscapePageCount(for: displayedGames)
        if !controllerLandscapeSelectionInitialized {
            controllerLandscapeSelectedGameID = displayedGames[0].id
            controllerLandscapePageIndex = 0
            controllerLandscapeSelectionInitialized = true
            return
        }

        if let selectedIndex = controllerLandscapeSelectedIndex(in: displayedGames) {
            let selectedPage = selectedIndex / controllerLandscapePageSize
            if controllerLandscapePageIndex < 0 || controllerLandscapePageIndex >= pageCount {
                controllerLandscapePageIndex = selectedPage
            }
        } else {
            controllerLandscapeSelectedGameID = displayedGames[0].id
            controllerLandscapePageIndex = 0
        }
    }

    private func syncControllerLandscapeSelectionToVisiblePage(displayedGames: [LibraryFile]) {
        guard !displayedGames.isEmpty else {
            return
        }

        let clampedPageIndex = min(max(controllerLandscapePageIndex, 0),
                                   controllerLandscapePageCount(for: displayedGames) - 1)
        if controllerLandscapePageIndex != clampedPageIndex {
            controllerLandscapePageIndex = clampedPageIndex
        }

        let range = controllerLandscapeRange(for: clampedPageIndex, totalCount: displayedGames.count)
        if let selectedIndex = controllerLandscapeSelectedIndex(in: displayedGames),
           range.contains(selectedIndex) {
            return
        }

        controllerLandscapeSelectedGameID = displayedGames[range.lowerBound].id
    }

    private func controllerLandscapePages(from games: [LibraryFile]) -> [[LibraryFile]] {
        stride(from: 0, to: games.count, by: controllerLandscapePageSize).map { startIndex in
            let endIndex = min(startIndex + controllerLandscapePageSize, games.count)
            return Array(games[startIndex..<endIndex])
        }
    }

    private func controllerLandscapePageCount(for games: [LibraryFile]) -> Int {
        max(1, Int(ceil(Double(games.count) / Double(controllerLandscapePageSize))))
    }

    private func controllerLandscapeRange(for pageIndex: Int, totalCount: Int) -> Range<Int> {
        let startIndex = min(max(pageIndex, 0) * controllerLandscapePageSize, max(totalCount - 1, 0))
        let endIndex = min(startIndex + controllerLandscapePageSize, totalCount)
        return startIndex..<endIndex
    }

    private func controllerLandscapeSelectedIndex(in games: [LibraryFile]) -> Int? {
        guard let controllerLandscapeSelectedGameID else {
            return nil
        }
        return games.firstIndex { $0.id == controllerLandscapeSelectedGameID }
    }

    private func controllerLandscapeTileWidth(for size: CGSize) -> CGFloat {
        let horizontalInset: CGFloat = 20
        let widthLimited = (size.width - horizontalInset * 2 - controllerLandscapeTileSpacing * CGFloat(controllerLandscapePageSize - 1)) / CGFloat(controllerLandscapePageSize)
        let heightLimited = (max(size.height - 42, 160) - 24 - 5 - 16) * 0.70
        return min(196, min(widthLimited, max(124, heightLimited)))
    }

    private func handleControllerLandscapeAction(_ action: ControllerLandscapeAction) {
        let games = sortedGames
        if case .cycleSort = action {
            cycleControllerLandscapeSortMode()
            return
        }

        if case .launchDashboard = action {
            launchControllerLandscapeDashboard()
            return
        }

        guard !games.isEmpty else {
            logControllerLandscapeInput("ignored \(action.logName): no games")
            return
        }

        logControllerLandscapeInput("action \(action.logName)")
        switch action {
        case .moveLeft:
            moveControllerLandscapeSelection(delta: -1, displayedGames: games)
        case .moveRight:
            moveControllerLandscapeSelection(delta: 1, displayedGames: games)
        case .previousPage:
            moveControllerLandscapePage(delta: -1, displayedGames: games)
        case .nextPage:
            moveControllerLandscapePage(delta: 1, displayedGames: games)
        case .launchSelected:
            launchControllerLandscapeSelection(displayedGames: games)
        case .cycleSort, .launchDashboard:
            break
        }
    }

    private func moveControllerLandscapeSelection(delta: Int, displayedGames: [LibraryFile]) {
        let currentIndex = controllerLandscapeSelectedIndex(in: displayedGames) ?? 0
        let nextIndex = (currentIndex + delta + displayedGames.count) % displayedGames.count

        withAnimation(.easeInOut(duration: 0.18)) {
            controllerLandscapeSelectedGameID = displayedGames[nextIndex].id
            controllerLandscapePageIndex = nextIndex / controllerLandscapePageSize
            controllerLandscapeSelectionInitialized = true
        }
    }

    private func moveControllerLandscapePage(delta: Int, displayedGames: [LibraryFile]) {
        let pageCount = controllerLandscapePageCount(for: displayedGames)
        let currentPage = min(max(controllerLandscapePageIndex, 0), pageCount - 1)
        let selectedIndex = controllerLandscapeSelectedIndex(in: displayedGames) ?? currentPage * controllerLandscapePageSize
        let selectedColumn = selectedIndex % controllerLandscapePageSize
        let nextPage = (currentPage + delta + pageCount) % pageCount
        let nextPageStartIndex = nextPage * controllerLandscapePageSize
        let nextIndex = min(nextPageStartIndex + selectedColumn, displayedGames.count - 1)

        withAnimation(.easeInOut(duration: 0.22)) {
            controllerLandscapePageIndex = nextPage
            controllerLandscapeSelectedGameID = displayedGames[nextIndex].id
            controllerLandscapeSelectionInitialized = true
        }
    }

    private func launchControllerLandscapeSelection(displayedGames: [LibraryFile]) {
        guard store.systemFilesReady, runtimeState.canLaunch else {
            return
        }

        let selectedIndex = controllerLandscapeSelectedIndex(in: displayedGames) ?? 0
        let selectedGame = displayedGames[selectedIndex]
        clearControllerInputHandlers()
        markRecentlyPlayed(selectedGame)
        launchGame(selectedGame)
    }

    private func launchControllerLandscapeDashboard() {
        guard store.systemFilesReady, runtimeState.canLaunch else {
            logControllerLandscapeInput("ignored launchDashboard: blocked")
            return
        }

        logControllerLandscapeInput("action launchDashboard")
        clearControllerInputHandlers()
        launchDashboard()
    }

    private func cycleControllerLandscapeSortMode() {
        let modes = GameLibrarySortMode.allCases
        guard let currentIndex = modes.firstIndex(of: sortMode) else {
            sortModeRawValue = GameLibrarySortMode.title.rawValue
            return
        }

        let nextMode = modes[(currentIndex + 1) % modes.count]
        withAnimation(.easeInOut(duration: 0.18)) {
            sortModeRawValue = nextMode.rawValue
            controllerLandscapeSelectionInitialized = false
            controllerLandscapeSelectedGameID = nil
            controllerLandscapePageIndex = 0
        }
        logControllerLandscapeInput("sort \(nextMode.title)")
    }

    private func updateControllerInputHandlers(active: Bool) {
        guard active else {
            clearControllerInputHandlers()
            return
        }

        guard let controller = Self.connectedPhysicalControllerForLibraryNavigation() else {
            clearControllerInputHandlers()
            return
        }

        if let currentController = controllerInputController,
           currentController === controller {
            return
        }

        controllerInputController = controller
        controllerPolledInputs = controllerLandscapeInputsPressed(on: controller)
        logControllerLandscapeInput("attach controller vendor=\(controller.vendorName ?? "unknown") category=\(controller.productCategory) extended=\(controller.extendedGamepad != nil ? 1 : 0) micro=\(controller.microGamepad != nil ? 1 : 0)")
    }

    private func clearControllerInputHandlers() {
        guard controllerInputController != nil else {
            controllerPolledInputs.removeAll()
            return
        }

        logControllerLandscapeInput("clear controller handlers")
        controllerInputController = nil
        controllerPolledInputs.removeAll()
    }

    private func pollControllerLandscapeInput(active: Bool) {
        guard active else {
            controllerPolledInputs.removeAll()
            return
        }

        if controllerInputController == nil {
            updateControllerInputHandlers(active: true)
        }

        guard let controller = controllerInputController ?? Self.connectedPhysicalControllerForLibraryNavigation() else {
            controllerPolledInputs.removeAll()
            return
        }

        let currentInputs = controllerLandscapeInputsPressed(on: controller)
        let newlyPressedInputs = currentInputs.subtracting(controllerPolledInputs)
        guard !newlyPressedInputs.isEmpty else {
            controllerPolledInputs = currentInputs
            return
        }

        for input in ControllerLandscapePolledInput.actionOrder where newlyPressedInputs.contains(input) {
            logControllerLandscapeInput("poll \(input.logName)")
            handleControllerLandscapeAction(input.action)
        }

        controllerPolledInputs = currentInputs
    }

    private func controllerLandscapeInputsPressed(on controller: GCController) -> Set<ControllerLandscapePolledInput> {
        var inputs: Set<ControllerLandscapePolledInput> = []

        if let gamepad = controller.extendedGamepad {
            if gamepad.dpad.left.isPressed {
                inputs.insert(.dpadLeft)
            }
            if gamepad.dpad.right.isPressed {
                inputs.insert(.dpadRight)
            }
            if gamepad.leftThumbstick.xAxis.value <= -0.65 {
                inputs.insert(.thumbstickLeft)
            }
            if gamepad.leftThumbstick.xAxis.value >= 0.65 {
                inputs.insert(.thumbstickRight)
            }
            if gamepad.leftTrigger.isPressed || gamepad.leftTrigger.value >= 0.5 {
                inputs.insert(.leftTrigger)
            }
            if gamepad.rightTrigger.isPressed || gamepad.rightTrigger.value >= 0.5 {
                inputs.insert(.rightTrigger)
            }
            if gamepad.buttonA.isPressed || gamepad.buttonA.value >= 0.5 {
                inputs.insert(.buttonA)
            }
            if gamepad.buttonX.isPressed || gamepad.buttonX.value >= 0.5 {
                inputs.insert(.buttonX)
            }
            if gamepad.buttonY.isPressed || gamepad.buttonY.value >= 0.5 {
                inputs.insert(.buttonY)
            }
        }

        if let microGamepad = controller.microGamepad {
            if microGamepad.dpad.left.isPressed {
                inputs.insert(.dpadLeft)
            }
            if microGamepad.dpad.right.isPressed {
                inputs.insert(.dpadRight)
            }
            if microGamepad.buttonA.isPressed || microGamepad.buttonA.value >= 0.5 {
                inputs.insert(.buttonA)
            }
        }

        return inputs
    }

    private static func connectedPhysicalControllerForLibraryNavigation() -> GCController? {
        let controllers = GCController.controllers().filter(isPhysicalGameControllerForLibraryNavigation)
        return controllers.first { !$0.isAttachedToDevice } ??
            controllers.first
    }

    private static func isPhysicalGameControllerForLibraryNavigation(_ controller: GCController) -> Bool {
        guard !isVirtualControllerForLibraryNavigation(controller) else {
            return false
        }
        return controller.extendedGamepad != nil || controller.microGamepad != nil
    }

    private static func isVirtualControllerForLibraryNavigation(_ controller: GCController) -> Bool {
        let vendorName = controller.vendorName ?? ""
        return vendorName.localizedCaseInsensitiveContains("virtual") ||
            controller.productCategory.localizedCaseInsensitiveContains("virtual")
    }

    private func logControllerLandscapeInput(_ message: String) {
        NSLog("xemu_ios: controller_landscape_library: %@", message)
    }

    private var sortMode: GameLibrarySortMode {
        GameLibrarySortMode(rawValue: sortModeRawValue) ?? .title
    }

    private var sortModeBinding: Binding<GameLibrarySortMode> {
        Binding(
            get: { sortMode },
            set: { sortModeRawValue = $0.rawValue }
        )
    }

    private var sortedGames: [LibraryFile] {
        let games = store.games

        switch sortMode {
        case .favorites:
            return games
                .filter(isFavorite)
                .sorted(by: titleSort)
        case .title:
            return games.sorted(by: titleSort)
        case .live:
            return games.filter { game in
                liveStatusStore.status(for: game)?.isSupported == true
            }
            .sorted { lhs, rhs in
                let lhsScore = liveSortScore(for: lhs)
                let rhsScore = liveSortScore(for: rhs)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                return titleSort(lhs, rhs)
            }
        case .recent:
            return games.filter { game in
                recentlyPlayedTime(for: game) > 0
            }
            .sorted { lhs, rhs in
                let lhsTime = recentlyPlayedTime(for: lhs)
                let rhsTime = recentlyPlayedTime(for: rhs)
                if lhsTime != rhsTime {
                    return lhsTime > rhsTime
                }
                return titleSort(lhs, rhs)
            }
        }
    }

    private var emptyFilterTitle: String {
        switch sortMode {
        case .favorites:
            return "No Favorite Games"
        case .live:
            return "No Live Games"
        case .recent:
            return "No Recent Games"
        case .title:
            return "No Games"
        }
    }

    private var emptyFilterSystemImage: String {
        switch sortMode {
        case .favorites:
            return "star"
        case .live:
            return "antenna.radiowaves.left.and.right"
        case .recent:
            return "clock"
        case .title:
            return "opticaldisc"
        }
    }

    private func isFavorite(_ game: LibraryFile) -> Bool {
        favoriteGameKeys.contains(GameLibraryFavorites.key(for: game))
    }

    private func toggleFavorite(_ game: LibraryFile) {
        let key = GameLibraryFavorites.key(for: game)
        if favoriteGameKeys.contains(key) {
            favoriteGameKeys.remove(key)
        } else {
            favoriteGameKeys.insert(key)
        }
        GameLibraryFavorites.save(favoriteGameKeys)
    }

    private func markRecentlyPlayed(_ game: LibraryFile) {
        recentlyPlayedGameTimes[game.libraryIdentityKey] = Date().timeIntervalSince1970
        GameLibraryRecents.save(recentlyPlayedGameTimes)
    }

    private func titleSort(_ lhs: LibraryFile, _ rhs: LibraryFile) -> Bool {
        lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }

    private func liveSortScore(for game: LibraryFile) -> Int {
        guard let status = liveStatusStore.status(for: game), status.isSupported else {
            return 0
        }
        return status.hasPlayersOnline ? 2 : 1
    }

    private func recentlyPlayedTime(for game: LibraryFile) -> TimeInterval {
        recentlyPlayedGameTimes[game.libraryIdentityKey] ?? 0
    }

    private func gameLibraryColumnCount(for size: CGSize) -> Int {
        let isLandscape = size.width > size.height
        return isLandscape
            ? store.landscapeGameLibraryColumnCount.columnCount
            : store.portraitGameLibraryColumnCount.columnCount
    }
}

private enum ControllerLandscapeAction {
    case moveLeft
    case moveRight
    case previousPage
    case nextPage
    case launchSelected
    case cycleSort
    case launchDashboard

    var logName: String {
        switch self {
        case .moveLeft:
            return "moveLeft"
        case .moveRight:
            return "moveRight"
        case .previousPage:
            return "previousPage"
        case .nextPage:
            return "nextPage"
        case .launchSelected:
            return "launchSelected"
        case .cycleSort:
            return "cycleSort"
        case .launchDashboard:
            return "launchDashboard"
        }
    }
}

private enum ControllerLandscapePolledInput: Hashable {
    case dpadLeft
    case dpadRight
    case thumbstickLeft
    case thumbstickRight
    case leftTrigger
    case rightTrigger
    case buttonA
    case buttonX
    case buttonY

    static let actionOrder: [ControllerLandscapePolledInput] = [
        .buttonX,
        .buttonY,
        .leftTrigger,
        .rightTrigger,
        .dpadLeft,
        .dpadRight,
        .thumbstickLeft,
        .thumbstickRight,
        .buttonA
    ]

    var action: ControllerLandscapeAction {
        switch self {
        case .dpadLeft, .thumbstickLeft:
            return .moveLeft
        case .dpadRight, .thumbstickRight:
            return .moveRight
        case .leftTrigger:
            return .previousPage
        case .rightTrigger:
            return .nextPage
        case .buttonA:
            return .launchSelected
        case .buttonX:
            return .cycleSort
        case .buttonY:
            return .launchDashboard
        }
    }

    var logName: String {
        switch self {
        case .dpadLeft:
            return "dpadLeft"
        case .dpadRight:
            return "dpadRight"
        case .thumbstickLeft:
            return "thumbstickLeft"
        case .thumbstickRight:
            return "thumbstickRight"
        case .leftTrigger:
            return "leftTrigger"
        case .rightTrigger:
            return "rightTrigger"
        case .buttonA:
            return "buttonA"
        case .buttonX:
            return "buttonX"
        case .buttonY:
            return "buttonY"
        }
    }
}

struct ControllerStatusPill: View {
    let batteryPercent: Int?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text("Controller")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .layoutPriority(2)

            Text(percentText)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .layoutPriority(1)

            Image(systemName: batterySymbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.9)
        .frame(width: 178, height: 24, alignment: .center)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Controller battery \(percentText)")
    }

    private var percentText: String {
        guard let batteryPercent else {
            return "--%"
        }
        return "\(batteryPercent)%"
    }

    private var batterySymbolName: String {
        guard let batteryPercent else {
            return "battery.0"
        }

        switch batteryPercent {
        case 76...100:
            return "battery.100"
        case 51...75:
            return "battery.75"
        case 26...50:
            return "battery.50"
        case 1...25:
            return "battery.25"
        default:
            return "battery.0"
        }
    }
}

struct DeviceStatusPill: View {
    let date: Date
    let batteryPercent: Int?
    let isCharging: Bool

    var body: some View {
        HStack(spacing: 7) {
            Text(Self.timeFormatter.string(from: date))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .monospacedDigit()

            Rectangle()
                .fill(.secondary.opacity(0.55))
                .frame(width: 1, height: 14)

            Text(Self.dateFormatter.string(from: date))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Image(systemName: "wifi")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            Image(systemName: batterySymbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            Text(percentText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .layoutPriority(1)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.9)
        .frame(width: 216, height: 24, alignment: .center)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Device status \(Self.timeFormatter.string(from: date)), \(Self.dateFormatter.string(from: date)), battery \(percentText)")
    }

    private var percentText: String {
        guard let batteryPercent else {
            return "--%"
        }
        return "\(batteryPercent)%"
    }

    private var batterySymbolName: String {
        guard let batteryPercent else {
            return "battery.0"
        }

        if isCharging {
            return "battery.100.bolt"
        }

        switch batteryPercent {
        case 76...100:
            return "battery.100"
        case 51...75:
            return "battery.75"
        case 26...50:
            return "battery.50"
        case 1...25:
            return "battery.25"
        default:
            return "battery.0"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

private struct GameLibraryFilterEmptyState: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }
}
