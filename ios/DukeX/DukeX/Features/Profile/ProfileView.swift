import SwiftUI
import UIKit

enum DukeXDownloadCountState: Equatable {
    case hidden
    case loading
    case loaded(Int)
    case failed
}

private enum ProfileHeaderDestination: Hashable {
    case activityFeed
    case achievements
    case friends
    case messages
    case playtime
}

struct ProfileView: View {
    @ObservedObject var profileStore: InsigniaProfileStore
    @ObservedObject var socialStore: XBLiveSocialStore
    @AppStorage(ProfileFriendSortMode.defaultsKey) private var friendSortModeRawValue = ProfileFriendSortMode.favorites.rawValue
    @AppStorage(ProfileEventMode.defaultsKey) private var eventModeRawValue = ProfileEventMode.today.rawValue
    @AppStorage(ProfileActivityMode.defaultsKey) private var activityModeRawValue = ProfileActivityMode.activeGames.rawValue
    @State private var favoriteFriendKeys = ProfileFriendFavorites.load()
    @State private var maftyAvatarTapCount = 0
    @State private var maftyDownloadCountUnlocked = false
    @State private var maftyDownloadCountState = DukeXDownloadCountState.hidden
    @State private var maftyDownloadCountTask: Task<Void, Never>?
    @State private var profileHeaderDestination: ProfileHeaderDestination?
    @StateObject private var activityFeedStore = XBLiveActivityFeedStore()

    let signIn: () -> Void
    let signOut: () -> Void
    let changeProfileImage: () -> Void
    let changeFriendProfileImage: (InsigniaFriend) -> Void
    let changeSocialFriendProfileImage: (XBLiveSocialFriend) -> Void
    let installedGames: [LibraryFile]
    let inviteEligibleGames: [LibraryFile]
    let launchGameFromInvite: (LibraryFile) -> Void

    var body: some View {
        List {
            if let session = profileStore.session {
                signedInContent(session)
            } else {
                signedOutContent
            }

            poweredBySection
        }
        .listStyle(.insetGrouped)
        .dukeXThemedListBackground()
        .navigationDestination(isPresented: profileHeaderDestinationBinding) {
            if let destination = profileHeaderDestination {
                profileHeaderDestinationView(destination, snapshot: profileStore.authenticatedSnapshot)
            }
        }
        .task(id: profileStore.session?.gamertag) {
            guard profileStore.session?.isAuthenticated == true else {
                await MainActor.run {
                    socialStore.clear()
                }
                return
            }

            await socialStore.refreshAll()
            await activityFeedStore.refreshNewsIfNeeded(maxAge: 60)
        }
    }

    @ViewBuilder
    private func signedInContent(_ session: InsigniaProfileSession) -> some View {
        let snapshot = profileStore.authenticatedSnapshot

        Section {
            VStack(spacing: 12) {
                ProfileHeaderRow(
                    session: session,
                    snapshot: snapshot,
                    profileImage: profileStore.profileImage,
                    dukeXDownloadCountState: dukeXDownloadCountState(for: session),
                    avatarTapAction: { handleProfileAvatarTap(for: session) },
                    changeProfileImage: changeProfileImage,
                    clearProfileImage: profileStore.clearProfileImage
                )

                if session.isAuthenticated {
                    profileActionPills(snapshot: snapshot)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dukeXThemedListRowBackground()

        if session.isAuthenticated {
            authenticatedSections(snapshot: snapshot)
        } else {
            gamertagOnlySections
        }
    }

    @ViewBuilder
    private func profileActionPills(snapshot: InsigniaAuthenticatedSnapshot?) -> some View {
        let friends = snapshot?.friends ?? []

        VStack(spacing: 4) {
            ProfileHeaderActionPillsRow {
                Button {
                    profileHeaderDestination = .achievements
                } label: {
                    ProfileHeaderActionPill(
                        title: "Achievements",
                        value: snapshot?.achievements?.summaryText ??
                            snapshot?.xbProfile?.achievementCount.map(String.init) ??
                            "Not Synced",
                        systemImage: "medal",
                        tint: .green
                    )
                }
                .buttonStyle(.plain)

                Button {
                    profileHeaderDestination = .friends
                } label: {
                    ProfileHeaderActionPill(
                        title: "Friends",
                        value: countText(mergedFriendsCount(insigniaFriends: friends)),
                        systemImage: "person.2",
                        tint: .mint
                    )
                }
                .buttonStyle(.plain)

                Button {
                    profileHeaderDestination = .messages
                } label: {
                    ProfileHeaderActionPill(
                        title: "Messages",
                        value: unreadMessagesText(legacyMessages: snapshot?.messages ?? []),
                        systemImage: "envelope",
                        tint: .teal
                    )
                }
                .buttonStyle(.plain)

                Button {
                    profileHeaderDestination = .playtime
                } label: {
                    ProfileHeaderActionPill(
                        title: "Playtime",
                        value: playtimeSummaryText(
                            totalMinutes: snapshot?.xbProfile?.totalMinutes,
                            gameCount: snapshot?.playtimeGames.count ?? 0
                        ),
                        systemImage: "timer",
                        tint: .yellow
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                profileHeaderDestination = .activityFeed
            } label: {
                ProfileHeaderActionPill(
                    title: "Activity Feed",
                    value: countText(activityFeedStore.unreadArticleCount),
                    systemImage: "sidebar.leading",
                    tint: .blue
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func profileHeaderDestinationView(
        _ destination: ProfileHeaderDestination,
        snapshot: InsigniaAuthenticatedSnapshot?
    ) -> some View {
        switch destination {
        case .activityFeed:
            ProfileActivityFeedView(
                feedStore: activityFeedStore,
                profileStore: profileStore,
                socialStore: socialStore,
                installedGames: installedGames,
                inviteEligibleGames: inviteEligibleGames,
                launchGameFromInvite: launchGameFromInvite,
                changeFriendProfileImage: changeFriendProfileImage,
                changeSocialFriendProfileImage: changeSocialFriendProfileImage
            )
        case .achievements:
            ProfileAchievementsView(
                snapshot: snapshot?.achievements,
                profileScore: snapshot?.xbProfile?.achievementScore,
                profileCount: snapshot?.xbProfile?.achievementCount,
                supportedGames: snapshot?.supportedGames ?? [],
                gamesPlayed: snapshot?.playtimeGames ?? []
            )
        case .friends:
            ProfileFriendsView(
                profileStore: profileStore,
                socialStore: socialStore,
                sortMode: friendSortModeBinding,
                favoriteFriendKeys: favoriteFriendKeys,
                toggleFavorite: toggleFavorite,
                toggleSocialFavorite: toggleSocialFavorite,
                changeFriendProfileImage: changeFriendProfileImage,
                changeSocialFriendProfileImage: changeSocialFriendProfileImage,
                installedGames: installedGames,
                inviteEligibleGames: inviteEligibleGames,
                currentUserAchievements: snapshot?.achievements,
                currentUserGamesPlayed: snapshot?.playtimeGames ?? [],
                launchGameFromInvite: launchGameFromInvite
            )
        case .messages:
            ProfileSocialMessagesView(
                socialStore: socialStore,
                legacyMessages: snapshot?.messages ?? [],
                legacyUnreadMessages: profileStore.unviewedMessages(from: snapshot?.messages ?? []),
                friendProfileImages: profileStore.friendProfileImages,
                friendProfiles: snapshot?.friendProfiles ?? [:],
                socialFriends: socialStore.messageableFriends,
                markLegacyMessageViewed: profileStore.markMessageViewed,
                installedGames: installedGames,
                inviteEligibleGames: inviteEligibleGames,
                currentUserAchievements: snapshot?.achievements,
                currentUserGamesPlayed: snapshot?.playtimeGames ?? [],
                launchGameFromInvite: launchGameFromInvite
            )
        case .playtime:
            ProfilePlaytimeView(
                totalMinutes: snapshot?.xbProfile?.totalMinutes,
                games: snapshot?.playtimeGames ?? []
            )
        }
    }

    @ViewBuilder
    private func authenticatedSections(snapshot: InsigniaAuthenticatedSnapshot?) -> some View {
        activitySection

        Section("Events") {
            ProfileEventModePickerRow(selection: eventModeBinding)

            let events = events(for: eventMode, snapshot: snapshot)
            if events.isEmpty {
                ProfileEmptyRow(title: eventMode.emptyTitle, systemImage: "calendar")
            } else {
                ForEach(events) { event in
                    NavigationLink {
                        ProfileEventDetailView(event: event)
                    } label: {
                        ProfileEventRow(event: event)
                    }
                }
            }

            if eventMode.requiresPaidEventDisclaimer {
                ProfilePaidEventDisclaimerRow()
            }
        }
        .dukeXThemedListRowBackground()
    }

    private var gamertagOnlySections: some View {
        Group {
            Section("Account") {
                Text("This profile is using local gamertag lookup only. Sign in with an Insignia account to sync friends, messages, active games, events, and xb.live profile details.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .dukeXThemedListRowBackground()

            Section("Insignia Status") {
                ProfileInfoRow(title: "Users Online",
                               value: profileStore.usersOnlineText,
                               systemImage: "person.2.wave.2")
                ProfileInfoRow(title: "Registered Users",
                               value: profileStore.registeredUsersText,
                               systemImage: "person.3")
                ProfileInfoRow(title: "Games Supported",
                               value: profileStore.gamesSupportedText,
                               systemImage: "gamecontroller")
            }
            .dukeXThemedListRowBackground()

            activitySection
        }
    }

    private var signedOutContent: some View {
        Section {
            VStack(spacing: 16) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 50))
                    .foregroundStyle(.secondary)

                VStack(spacing: 4) {
                    Text("Insignia Profile")
                        .font(.headline)
                    Text("Not signed in")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button(action: signIn) {
                    Text("Sign In")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
                        .multilineTextAlignment(.center)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text("Profile sign-in only powers the DukeX profile tab. Online play still requires Force NAT to Insignia in Settings and a dashboard registered with Insignia's Xbox Live services.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
        }
        .dukeXThemedListRowBackground()
    }

    private var activitySection: some View {
        Section("Activity") {
            ProfileActivityModePickerRow(selection: activityModeBinding)

            switch activityMode {
            case .activeGames:
                if profileStore.activeGames.isEmpty {
                    ProfileEmptyRow(title: "No public activity synced",
                                    systemImage: "antenna.radiowaves.left.and.right")
                } else {
                    ForEach(profileStore.activeGames) { game in
                        ProfileActiveGameRow(game: game)
                    }
                }
            case .twentyFourHour:
                if profileStore.activity24h.isEmpty {
                    ProfileEmptyRow(title: "No 24-hour activity data synced",
                                    systemImage: "chart.line.uptrend.xyaxis")
                } else {
                    ProfileActivityChartRow(points: profileStore.activity24h, mode: activityMode)
                }
            case .sevenDay:
                if profileStore.activity7d.isEmpty {
                    ProfileEmptyRow(title: "No 7-day activity data synced",
                                    systemImage: "chart.line.uptrend.xyaxis")
                } else {
                    ProfileActivityChartRow(points: profileStore.activity7d, mode: activityMode)
                }
            }
        }
        .dukeXThemedListRowBackground()
    }

    private var poweredBySection: some View {
        Section {
            VStack(spacing: 8) {
                if profileStore.isSignedIn {
                    Button(role: .destructive, action: signOut) {
                        Text("Sign Out")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(Color.red.opacity(0.88), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityLabel("Sign Out")
                }

                JustifiedProfileFootnote(
                    text: "DukeX’s profile features are powered by xb.live and Insignia services. An Insignia account and xb.live profile setup may be required to access the full functionality of the Profiles section."
                )
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)
        }
        .dukeXThemedListRowBackground()
    }

    private func playTimeText(_ minutes: Double) -> String {
        ProfilePlaytimeFormatter.text(from: minutes)
    }

    private func playtimeSummaryText(totalMinutes: Double?, gameCount: Int) -> String {
        if let totalMinutes {
            return playTimeText(totalMinutes)
        }
        if gameCount > 0 {
            return countText(gameCount)
        }
        return "Not Synced"
    }

    private var friendSortMode: ProfileFriendSortMode {
        ProfileFriendSortMode(rawValue: friendSortModeRawValue) ?? .favorites
    }

    private var eventMode: ProfileEventMode {
        ProfileEventMode(rawValue: eventModeRawValue) ?? .today
    }

    private var activityMode: ProfileActivityMode {
        ProfileActivityMode(rawValue: activityModeRawValue) ?? .activeGames
    }

    private var friendSortModeBinding: Binding<ProfileFriendSortMode> {
        Binding(
            get: { friendSortMode },
            set: { friendSortModeRawValue = $0.rawValue }
        )
    }

    private var eventModeBinding: Binding<ProfileEventMode> {
        Binding(
            get: { eventMode },
            set: { eventModeRawValue = $0.rawValue }
        )
    }

    private var activityModeBinding: Binding<ProfileActivityMode> {
        Binding(
            get: { activityMode },
            set: { activityModeRawValue = $0.rawValue }
        )
    }

    private var profileHeaderDestinationBinding: Binding<Bool> {
        Binding(
            get: { profileHeaderDestination != nil },
            set: { isPresented in
                if !isPresented {
                    profileHeaderDestination = nil
                }
            }
        )
    }

    private func events(for mode: ProfileEventMode, snapshot: InsigniaAuthenticatedSnapshot?) -> [XBLiveEvent] {
        let events = snapshot?.events ?? []
        switch mode {
        case .today:
            return XBLiveEvent.currentEvents(from: events.filter { !$0.isPaid })
        case .paid:
            return XBLiveEvent.paidEvents(from: events)
        case .tournaments:
            return XBLiveEvent.tournaments(from: events)
        }
    }

    private func toggleFavorite(_ friend: InsigniaFriend) {
        let key = ProfileFriendFavorites.key(for: friend)
        if favoriteFriendKeys.contains(key) {
            favoriteFriendKeys.remove(key)
        } else {
            favoriteFriendKeys.insert(key)
        }
        ProfileFriendFavorites.save(favoriteFriendKeys)
    }

    private func toggleSocialFavorite(_ friend: XBLiveSocialFriend) {
        let key = ProfileFriendFavorites.key(for: friend)
        if favoriteFriendKeys.contains(key) {
            favoriteFriendKeys.remove(key)
        } else {
            favoriteFriendKeys.insert(key)
        }
        ProfileFriendFavorites.save(favoriteFriendKeys)
    }

    private func countText(_ count: Int) -> String {
        count == 0 ? "None" : "\(count)"
    }

    private func mergedFriendsCount(insigniaFriends: [InsigniaFriend]) -> Int {
        let insigniaKeys = Set(insigniaFriends.map(\.key))
        let xbLiveOnlyCount = socialStore.messageableFriends.filter { friend in
            let keys = [
                friend.username,
                friend.displayName ?? ""
            ]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }

            return keys.allSatisfy { !insigniaKeys.contains($0) }
        }.count

        return insigniaFriends.count + xbLiveOnlyCount
    }

    private func unreadMessagesText(legacyMessages: [InsigniaMessage]) -> String {
        let count = socialStore.unreadCount + profileStore.unviewedMessages(from: legacyMessages).count
        return "\(count)"
    }

    private func pendingMessagesText(_ count: Int) -> String {
        count == 0 ? "None" : "\(count) Pending"
    }

    private func dukeXDownloadCountState(for session: InsigniaProfileSession) -> DukeXDownloadCountState {
        guard maftyDownloadCountUnlocked,
              session.gamertag.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Mafty") == .orderedSame else {
            return .hidden
        }

        return maftyDownloadCountState
    }

    private func handleProfileAvatarTap(for session: InsigniaProfileSession) {
        guard session.gamertag.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Mafty") == .orderedSame else {
            maftyAvatarTapCount = 0
            return
        }

        maftyAvatarTapCount += 1

        guard maftyAvatarTapCount >= 3 else {
            return
        }

        maftyAvatarTapCount = 0
        maftyDownloadCountUnlocked = true
        refreshMaftyDownloadCount()
    }

    private func refreshMaftyDownloadCount() {
        maftyDownloadCountTask?.cancel()
        maftyDownloadCountState = .loading
        maftyDownloadCountTask = Task {
            do {
                let totalDownloads = try await DukeXReleaseStatsService.fetchTotalDownloads()
                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run {
                    maftyDownloadCountState = .loaded(totalDownloads)
                }
            } catch {
                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run {
                    maftyDownloadCountState = .failed
                }
            }
        }
    }
}

enum DukeXReleaseStatsService {
    private static let releasesURL = URL(string: "https://api.github.com/repos/MaftyManicEMU/DukeX/releases")!

    static func fetchTotalDownloads() async throws -> Int {
        var request = URLRequest(url: releasesURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DukeX", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ServiceError.unavailable
        }

        return try JSONDecoder()
            .decode([GitHubRelease].self, from: data)
            .reduce(0) { releaseTotal, release in
                releaseTotal + release.assets.reduce(0) { assetTotal, asset in
                    assetTotal + asset.downloadCount
                }
            }
    }

    private struct GitHubRelease: Decodable {
        let assets: [GitHubReleaseAsset]
    }

    private struct GitHubReleaseAsset: Decodable {
        let downloadCount: Int

        enum CodingKeys: String, CodingKey {
            case downloadCount = "download_count"
        }
    }

    enum ServiceError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "DukeX release download stats are unavailable."
        }
    }
}

private struct JustifiedProfileFootnote: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 3
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.88
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        applyText(to: label)
        return label
    }

    func updateUIView(_ uiView: UILabel, context: Context) {
        applyText(to: uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        uiView.preferredMaxLayoutWidth = width
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let maxHeight = UIFont.preferredFont(forTextStyle: .footnote).lineHeight * 3.0 + 2.0
        return CGSize(width: width, height: min(size.height, maxHeight))
    }

    private func applyText(to label: UILabel) {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .justified
        paragraphStyle.lineBreakMode = .byTruncatingTail

        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraphStyle
            ]
        )
    }
}
