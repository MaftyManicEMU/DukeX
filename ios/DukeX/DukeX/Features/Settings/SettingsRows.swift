import SwiftUI

struct AssetRow: View {
    let title: String
    let file: LibraryFile?
    let missingSystemImage: String
    let missingText: String
    let showsDisclosureIndicator: Bool

    init(
        title: String,
        file: LibraryFile?,
        missingSystemImage: String,
        missingText: String = "Missing",
        showsDisclosureIndicator: Bool = false
    ) {
        self.title = title
        self.file = file
        self.missingSystemImage = missingSystemImage
        self.missingText = missingText
        self.showsDisclosureIndicator = showsDisclosureIndicator
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: file == nil ? missingSystemImage : "checkmark.circle.fill")
                .foregroundStyle(file == nil ? Color.secondary : Color.green)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(file?.displayName ?? missingText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let file {
                Text(file.byteCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if showsDisclosureIndicator {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 44)
    }
}

struct ImportAssetRow: View {
    let title: String
    let file: LibraryFile?
    let missingSystemImage: String
    let missingText: String
    let action: () -> Void

    init(
        title: String,
        file: LibraryFile?,
        missingSystemImage: String,
        missingText: String = "Missing",
        action: @escaping () -> Void
    ) {
        self.title = title
        self.file = file
        self.missingSystemImage = missingSystemImage
        self.missingText = missingText
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            AssetRow(
                title: title,
                file: file,
                missingSystemImage: missingSystemImage,
                missingText: missingText,
                showsDisclosureIndicator: true
            )
        }
        .buttonStyle(.plain)
    }
}

struct GameRow: View {
    let game: LibraryFile
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(game.displayName)
                    .lineLimit(1)
                Text(game.byteCount)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 44)
    }
}

struct EmptyStateRow: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
    }
}

struct CoreStatusRow: View {
    let state: EmulatorCoreRuntime.RunState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(minHeight: 44)
    }

    private var title: String {
        switch state {
        case .ready:
            return "Core Ready"
        case .running:
            return "Core Running"
        case .exited:
            return "Core Exited"
        case .failed:
            return "Core Failed"
        case .unavailable:
            return "Core Missing"
        }
    }

    private var detail: String {
        switch state {
        case .ready(let url):
            return url.lastPathComponent
        case .running(let game):
            return game
        case .exited(let status):
            return "Exit status \(status)"
        case .failed(let message), .unavailable(let message):
            return message
        }
    }

    private var systemImage: String {
        switch state {
        case .ready:
            return "checkmark.circle.fill"
        case .running:
            return "play.circle.fill"
        case .exited:
            return "stop.circle"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "questionmark.circle"
        }
    }

    private var color: Color {
        switch state {
        case .ready:
            return .green
        case .running:
            return .accentColor
        case .exited:
            return .secondary
        case .failed:
            return .red
        case .unavailable:
            return .orange
        }
    }
}

struct AutoJITStatusRow: View {
    let status: String?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status == nil ? "link.circle" : "link.circle.fill")
                .foregroundStyle(status == nil ? Color.secondary : Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("StikJIT")
                Text(status ?? "Ready for in-app auto-enable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(minHeight: 44)
    }
}

struct CommunityLinkRow: View {
    @Environment(\.openURL) private var openURL

    let title: String
    let detail: String
    let imageName: String
    let glyphSize: CGFloat
    let url: URL
    var beforeOpen: () -> Void = {}

    var body: some View {
        Button {
            beforeOpen()
            openURL(url)
        } label: {
            HStack(spacing: 12) {
                Image(imageName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.accentColor)
                    .frame(width: glyphSize, height: glyphSize)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Image(systemName: "arrow.up.right.square")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 58)
        }
        .buttonStyle(.plain)
    }
}

struct FolderRow: View {
    let title: String
    let url: URL
    let storageUsed: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Label(title, systemImage: "folder")
                Spacer()
                Text(storageUsed)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
    }
}
