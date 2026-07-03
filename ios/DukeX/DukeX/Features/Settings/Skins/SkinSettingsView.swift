import SwiftUI
import UIKit

struct SkinAssignmentView: View {
    @ObservedObject var store: EmulatorFileStore
    let importSkins: () -> Void
    @Environment(\.dukeXTheme) private var theme
    @State private var selectedOrientation: ManicSkinPreviewOrientation = .portrait
    @State private var previewRequest: SkinPreviewRequest?
    @State private var removalConfirmationTarget: ManicSkinLibraryItem?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    SkinOrientationPicker(selection: $selectedOrientation)

                    let activeColumnCount = skinColumnCount(for: geometry.size)
                    let activeGridWidth = max(1, geometry.size.width - 40)
                    let activeTileWidth = GameLibraryGridMetrics.tileWidth(
                        for: activeColumnCount,
                        availableWidth: activeGridWidth
                    )
                    let thumbnailWidth = max(1, activeTileWidth - 20)
                    LazyVGrid(
                        columns: GameLibraryGridMetrics.columns(
                            for: activeColumnCount,
                            availableWidth: activeGridWidth
                        ),
                        alignment: .center,
                        spacing: GameLibraryGridMetrics.spacing(for: activeColumnCount) + 6
                    ) {
                        ForEach(store.skins) { skin in
                            SkinPreviewTile(
                                item: skin,
                                orientation: selectedOrientation,
                                isSelected: skin.id == store.selectedSkin(for: selectedOrientation)?.id,
                                assign: {
                                    store.setSelectedSkin(skin, for: selectedOrientation)
                                },
                                preview: {
                                    previewRequest = SkinPreviewRequest(
                                        item: skin,
                                        orientation: selectedOrientation
                                    )
                                },
                                requestRemoveSkin: {
                                    removalConfirmationTarget = skin
                                }
                            )
                        }

                        ImportSkinTile(
                            orientation: selectedOrientation,
                            referenceItem: store.skins.first,
                            thumbnailWidth: thumbnailWidth,
                            importSkins: importSkins
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            .background(Color.clear)
        }
        .navigationTitle("Assign Skin")
        .navigationBarTitleDisplayMode(.inline)
        .background {
            DukeXThemedBackgroundView()
        }
        .fullScreenCover(item: $previewRequest) { request in
            SkinFullScreenPreview(request: request)
                .environment(\.dukeXTheme, theme)
        }
        .confirmationDialog(
            "Remove Skin",
            isPresented: Binding(
                get: { removalConfirmationTarget != nil },
                set: { if !$0 { removalConfirmationTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let skin = removalConfirmationTarget {
                Button("Remove \(skin.displayName)", role: .destructive) {
                    removeSkin(skin)
                }
            }
            Button("Cancel", role: .cancel) {
                removalConfirmationTarget = nil
            }
        } message: {
            if let skin = removalConfirmationTarget {
                Text("Are you sure you would like to remove \(skin.displayName) and clear any assignments using it?")
            }
        }
    }

    private func skinColumnCount(for size: CGSize) -> Int {
        let isLandscape = size.width > size.height
        return isLandscape
            ? store.landscapeGameLibraryColumnCount.columnCount
            : store.portraitGameLibraryColumnCount.columnCount
    }

    private func removeSkin(_ skin: ManicSkinLibraryItem) {
        defer {
            removalConfirmationTarget = nil
        }

        do {
            try store.removeSkin(skin)
        } catch {
            store.message = UserMessage(title: "Skin Not Removed", detail: error.localizedDescription)
        }
    }
}

struct SkinAssignmentSummaryRow: View {
    let selectedSkinName: String?
    let skinCount: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Assign Skin")
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: 44)
    }

    private var detail: String {
        if let selectedSkinName {
            return selectedSkinName
        }
        return skinCount == 0 ? "No skins installed" : "\(skinCount) skins available"
    }
}

private struct SkinOrientationPicker: View {
    @Binding var selection: ManicSkinPreviewOrientation

    var body: some View {
        Picker("Skin Orientation", selection: $selection) {
            ForEach(ManicSkinPreviewOrientation.allCases) { orientation in
                Text(orientation.title).tag(orientation)
            }
        }
        .frame(height: GameLibraryGridMetrics.compactControlHeight)
        .pickerStyle(.segmented)
        .accessibilityLabel("Skin Orientation")
    }
}

private struct ImportSkinTile: View {
    @Environment(\.dukeXTheme) private var theme

    let orientation: ManicSkinPreviewOrientation
    let referenceItem: ManicSkinLibraryItem?
    let thumbnailWidth: CGFloat
    let importSkins: () -> Void

    var body: some View {
        Button(action: importSkins) {
            VStack(spacing: 6) {
                thumbnail

                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(theme.surfaceColor,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.borderColor, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Import Skin")
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.92))

            VStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 36, weight: .regular))
                Text("Import Skin")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 10)
        }
        .frame(width: thumbnailWidth, height: thumbnailHeight)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var thumbnailHeight: CGFloat {
        thumbnailWidth / thumbnailAspectRatio
    }

    private var thumbnailAspectRatio: CGFloat {
        let nativeAspectRatio = referenceItem?.makeSkin()?.previewAspectRatio(for: orientation)
            ?? orientation.fallbackAspectRatio
        guard nativeAspectRatio > 0 else {
            return 0.70
        }

        let displayedAspectRatio = orientation == .landscape ? 1 / nativeAspectRatio : nativeAspectRatio
        return min(0.70, displayedAspectRatio)
    }
}

private struct SkinPreviewTile: View {
    @Environment(\.dukeXTheme) private var theme

    let item: ManicSkinLibraryItem
    let orientation: ManicSkinPreviewOrientation
    let isSelected: Bool
    let assign: () -> Void
    let preview: () -> Void
    let requestRemoveSkin: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Button(action: assign) {
                    thumbnail
                }
                .buttonStyle(.plain)

                Button(action: preview) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                        Text("Preview")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: Color.black.opacity(0.32), radius: 7, y: 3)
                }
                .buttonStyle(.plain)

                if isSelected {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(theme.accentColor)
                                .shadow(color: Color.black.opacity(0.35), radius: 5, y: 2)
                        }
                        Spacer()
                    }
                    .padding(7)
                    .allowsHitTesting(false)
                }
            }

            Button(action: assign) {
                VStack(spacing: 2) {
                    Text(item.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .lineSpacing(0)

                    if let creatorName = item.creatorName {
                        Text(creatorName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .top)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(theme.surfaceColor,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(theme.borderColor, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive, action: requestRemoveSkin) {
                Label("Remove Skin", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.92))

            if let skin = item.makeSkin() {
                skinPreview(for: skin)
            } else {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 42, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(thumbnailAspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var thumbnailAspectRatio: CGFloat {
        guard let skin = item.makeSkin() else {
            return 0.70
        }

        let nativeAspectRatio = skin.previewAspectRatio(for: orientation) ?? orientation.fallbackAspectRatio
        guard nativeAspectRatio > 0 else {
            return 0.70
        }

        let displayedAspectRatio = orientation == .landscape ? 1 / nativeAspectRatio : nativeAspectRatio
        return min(0.70, displayedAspectRatio)
    }

    @ViewBuilder
    private func skinPreview(for skin: ManicSkin) -> some View {
        if orientation == .landscape {
            GeometryReader { proxy in
                let landscapeAspectRatio = max(
                    skin.previewAspectRatio(for: orientation) ?? orientation.fallbackAspectRatio,
                    1
                )
                ManicSkinPreviewRepresentable(
                    skin: skin,
                    isInteractive: false,
                    previewOrientation: orientation
                )
                .allowsHitTesting(false)
                .frame(width: proxy.size.width * landscapeAspectRatio,
                       height: proxy.size.width)
                .rotationEffect(.degrees(90))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .padding(2)
        } else {
            ManicSkinPreviewRepresentable(
                skin: skin,
                isInteractive: false,
                previewOrientation: orientation
            )
            .allowsHitTesting(false)
            .padding(2)
        }
    }
}

private struct SkinPreviewRequest: Identifiable {
    let item: ManicSkinLibraryItem
    let orientation: ManicSkinPreviewOrientation

    var id: String {
        "\(item.id)-\(orientation.rawValue)"
    }
}

private struct SkinFullScreenPreview: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dukeXTheme) private var theme

    let request: SkinPreviewRequest

    var body: some View {
        ZStack {
            if theme.usesAnimatedBackground {
                NostalgicDotBackgroundView()
            } else {
                theme.screenBackground
                    .ignoresSafeArea()
            }

            if let skin = request.item.makeSkin() {
                interactivePreview(for: skin)
                    .ignoresSafeArea()
            } else {
                Text(request.item.displayName)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            VStack {
                HStack(spacing: 12) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                        .accessibilityLabel("Close")

                    Text("\(request.item.displayName) \(request.orientation.title)")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)

                Spacer()
            }
        }
        .tint(theme.accentColor)
    }

    @ViewBuilder
    private func interactivePreview(for skin: ManicSkin) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            let isLandscapeContainer = size.width > size.height
            let shouldRotate = request.orientation == .landscape && !isLandscapeContainer
            let renderSize = shouldRotate ?
                CGSize(width: size.height, height: size.width) :
                size

            ManicSkinPreviewRepresentable(
                skin: skin,
                isInteractive: true,
                previewOrientation: request.orientation
            )
            .frame(width: renderSize.width, height: renderSize.height)
            .rotationEffect(.degrees(shouldRotate ? 90 : 0))
            .position(x: size.width / 2, y: size.height / 2)
        }
    }
}

private struct ManicSkinPreviewRepresentable: UIViewRepresentable {
    let skin: ManicSkin
    let isInteractive: Bool
    let previewOrientation: ManicSkinPreviewOrientation?

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        container.clipsToBounds = true

        guard let controlsView = ManicSkinTouchControlsView(
            skin: skin,
            previewMode: true,
            previewOrientation: previewOrientation
        ) else {
            return container
        }

        controlsView.translatesAutoresizingMaskIntoConstraints = false
        controlsView.onMenuRequested = {}
        controlsView.isUserInteractionEnabled = isInteractive
        container.addSubview(controlsView)
        NSLayoutConstraint.activate([
            controlsView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            controlsView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            controlsView.topAnchor.constraint(equalTo: container.topAnchor),
            controlsView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        context.coordinator.controlsView = controlsView
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.controlsView?.isUserInteractionEnabled = isInteractive
        context.coordinator.controlsView?.refreshLayoutForGeometryChange()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var controlsView: ManicSkinTouchControlsView?
    }
}
