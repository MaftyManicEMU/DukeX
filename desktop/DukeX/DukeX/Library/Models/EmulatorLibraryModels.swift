import Foundation
import ImageIO
import UniformTypeIdentifiers

struct LibraryFile: Identifiable, Equatable {
    enum Kind {
        case bios
        case mcpx
        case eeprom
        case hdd
        case game
        case unknown
    }

    let url: URL
    let size: Int64
    let kind: Kind
    let titleName: String?
    let titleID: String?
    let coverURL: URL?
    let customConfigURL: URL?

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
    var fallbackDisplayName: String {
        kind == .game ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }
    var displayName: String {
        if kind == .game, let titleName, !titleName.isEmpty {
            return titleName
        }
        return fallbackDisplayName
    }
    var libraryIdentityKey: String {
        if let titleID = titleID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !titleID.isEmpty {
            return "title:\(titleID.uppercased())"
        }

        return "file:\(url.path)"
    }
    var byteCount: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

enum GameLaunchLink {
    static let scheme = "dukex"

    static func url(for game: LibraryFile) -> URL? {
        guard let titleID = normalizedTitleID(game.titleID) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "launch"
        components.queryItems = [
            URLQueryItem(name: "titleid", value: titleID),
            URLQueryItem(name: "title", value: game.displayName)
        ]
        return components.url
    }

    static func externalGameURL(for game: LibraryFile) -> URL? {
        guard let titleID = normalizedTitleID(game.titleID) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = "game"
        components.queryItems = [
            URLQueryItem(name: "id", value: titleID)
        ]
        return components.url
    }

    static func titleID(from url: URL) -> String? {
        guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame else {
            return nil
        }

        let route = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let titleID: String?

        switch route.lowercased() {
        case "launch":
            titleID = queryItems
                .first { $0.name.caseInsensitiveCompare("titleid") == .orderedSame }?
                .value
        case "game":
            titleID = queryItems
                .first {
                    $0.name.caseInsensitiveCompare("id") == .orderedSame ||
                        $0.name.caseInsensitiveCompare("titleid") == .orderedSame
                }?
                .value
        default:
            titleID = nil
        }

        return normalizedTitleID(titleID)
    }

    static func titleName(from url: URL) -> String? {
        guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame else {
            return nil
        }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let title = queryItems
            .first {
                $0.name.caseInsensitiveCompare("title") == .orderedSame ||
                    $0.name.caseInsensitiveCompare("name") == .orderedSame
            }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title?.isEmpty == false ? title : nil
    }

    static func normalizedTitleID(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let titleID = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !titleID.isEmpty else {
            return nil
        }
        return titleID
    }
}

enum XboxTitleIconCatalog {
    static func iconURL(for titleID: String?) -> URL? {
        xdbIconURL(for: titleID)
    }

    static func xdbIconURL(for titleID: String?) -> URL? {
        guard let normalizedTitleID = GameLaunchLink.normalizedTitleID(titleID),
              normalizedTitleID.count == 8,
              normalizedTitleID.allSatisfy(\.isHexDigit),
              let publisherCode = publisherCode(from: String(normalizedTitleID.prefix(4))),
              let titleNumber = Int(normalizedTitleID.suffix(4), radix: 16) else {
            return nil
        }

        let serialNumber = String(format: "%03d", titleNumber)
        return URL(string: "https://raw.githubusercontent.com/xemu-project/xdb/main/titles/\(publisherCode)/\(serialNumber)/xtimage.png")
    }

    private static func publisherCode(from hexPrefix: String) -> String? {
        guard hexPrefix.count == 4,
              let firstByte = UInt8(hexPrefix.prefix(2), radix: 16),
              let secondByte = UInt8(hexPrefix.suffix(2), radix: 16),
              let firstScalar = UnicodeScalar(UInt32(firstByte)),
              let secondScalar = UnicodeScalar(UInt32(secondByte)) else {
            return nil
        }

        guard (firstByte >= 48 && firstByte <= 57) || (firstByte >= 65 && firstByte <= 90),
              (secondByte >= 48 && secondByte <= 57) || (secondByte >= 65 && secondByte <= 90) else {
            return nil
        }
        return String(Character(firstScalar)) + String(Character(secondScalar))
    }
}

enum GameLibraryExportLink {
    struct Response {
        let callbackURL: URL
        let gameCount: Int
    }

    private static let callbackHost = "dukex"
    private static let coverJPEGQuality = 0.7

    static func callbackScheme(from url: URL) -> String? {
        guard url.scheme?.caseInsensitiveCompare(GameLaunchLink.scheme) == .orderedSame else {
            return nil
        }

        let route = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard route.caseInsensitiveCompare("gameInfo") == .orderedSame else {
            return nil
        }

        let scheme = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name.caseInsensitiveCompare("scheme") == .orderedSame }?
            .value?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let scheme, isValidCallbackScheme(scheme) else {
            return nil
        }

        return scheme
    }

    static func response(
        for games: [LibraryFile],
        metadata: (LibraryFile) -> GameListMetadata?,
        callbackScheme: String
    ) -> Response? {
        guard isValidCallbackScheme(callbackScheme) else {
            return nil
        }

        let exportedGames = games.compactMap { exportedGame(from: $0, metadata: metadata($0)) }
        guard let payload = encodedPayload(for: exportedGames) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = callbackScheme
        components.host = callbackHost
        components.queryItems = [
            URLQueryItem(name: "games", value: payload)
        ]

        guard let callbackURL = components.url else {
            return nil
        }

        return Response(callbackURL: callbackURL, gameCount: exportedGames.count)
    }

    private static func exportedGame(from game: LibraryFile, metadata: GameListMetadata?) -> ExportedGame? {
        guard let titleID = GameLaunchLink.normalizedTitleID(game.titleID) else {
            return nil
        }

        let metadataTitle = metadata?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleName = metadataTitle?.isEmpty == false ? metadataTitle! : game.displayName

        return ExportedGame(
            id: titleID,
            titleName: titleName,
            titleId: titleID,
            developer: metadata?.studio.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            version: "1.0",
            iconData: iconData(for: game)
        )
    }

    private static func encodedPayload(for games: [ExportedGame]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(games) else {
            return nil
        }

        return base64URLEncode(data)
    }

    /// Inverse of ManicEMU `GameScheme.base64URLDecode`. Query strings treat `+` as space and `/` is not URL-safe.
    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingTrailingBase64Padding()
    }

    private static func iconData(for game: LibraryFile) -> Data? {
        guard let coverURL = game.coverURL,
              let source = CGImageSourceCreateWithURL(coverURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let jpeg = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            jpeg,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }

        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: coverJPEGQuality
        ]
        CGImageDestinationAddImage(destination, image, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }

        return jpeg as Data
    }

    private static func isValidCallbackScheme(_ scheme: String) -> Bool {
        guard let first = scheme.unicodeScalars.first,
              CharacterSet.letters.contains(first) else {
            return false
        }

        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.")
        return scheme.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    /// Matches ManicEMU `GameScheme`; `id` must equal `titleId`.
    private struct ExportedGame: Encodable {
        let id: String
        let titleName: String
        let titleId: String
        let developer: String
        let version: String
        let iconData: Data?
    }
}

private extension String {
    func trimmingTrailingBase64Padding() -> String {
        var value = self
        while value.hasSuffix("=") {
            value.removeLast()
        }
        return value
    }
}

enum SkinPackageFormat {
    static let fileExtensions = ["manicskin", "deltaskin", "gammaskin"]
    static let readableFileExtensions = ".manicskin, .deltaskin, or .gammaskin"

    static var allowedContentTypes: [UTType] {
        fileExtensions.map { UTType(filenameExtension: $0) }.compactMap { $0 }
    }

    static func isSupportedPackage(_ url: URL) -> Bool {
        isSupportedExtension(url.pathExtension)
    }

    static func isSupportedExtension(_ pathExtension: String) -> Bool {
        fileExtensions.contains {
            pathExtension.caseInsensitiveCompare($0) == .orderedSame
        }
    }

    static func fileExtension(for url: URL) -> String {
        fileExtensions.first {
            url.pathExtension.caseInsensitiveCompare($0) == .orderedSame
        } ?? fileExtensions[0]
    }
}

enum ImportTarget: String, Identifiable {
    case systemFiles
    case games
    case skins

    var id: String { rawValue }

    var allowedTypes: [UTType] {
        switch self {
        case .systemFiles:
            return [
                UTType(filenameExtension: "bin"),
                UTType(filenameExtension: "qcow2"),
                UTType(filenameExtension: "qcow"),
                UTType(filenameExtension: "img"),
                UTType(filenameExtension: "raw"),
                UTType(filenameExtension: "hdd"),
                .data
            ].compactMap { $0 }
        case .games:
            return [
                UTType(filenameExtension: "xiso"),
                UTType(filenameExtension: "iso"),
                .diskImage,
                .data,
                .item
            ].compactMap { $0 }
        case .skins:
            return SkinPackageFormat.allowedContentTypes + [.item]
        }
    }
}

enum GameLibraryColumnCount: Int, CaseIterable, Identifiable {
    case two = 2
    case three = 3
    case four = 4
    case five = 5
    case six = 6
    case seven = 7
    case eight = 8

    static let portraitDefaultsKey = "DukeXPortraitGameLibraryColumnCount"
    static let landscapeDefaultsKey = "DukeXLandscapeGameLibraryColumnCount"
    private static let legacyDefaultsKey = "DukeXGameLibraryColumnCount"

    static let portraitOptions: [GameLibraryColumnCount] = [.two, .three]
    static let landscapeOptions: [GameLibraryColumnCount] = [.four, .five, .six, .seven, .eight]

    var id: Int { rawValue }
    var columnCount: Int { rawValue }

    static var currentPortrait: GameLibraryColumnCount {
        if let value = storedValue(forKey: portraitDefaultsKey, allowedValues: portraitOptions) {
            return value
        }

        return storedValue(forKey: legacyDefaultsKey, allowedValues: portraitOptions) ?? .two
    }

    static var currentLandscape: GameLibraryColumnCount {
        storedValue(forKey: landscapeDefaultsKey, allowedValues: landscapeOptions) ?? .four
    }

    var title: String {
        "\(rawValue) Columns"
    }

    var gamesPerRowTitle: String {
        "\(rawValue)"
    }

    private static func storedValue(forKey key: String,
                                    allowedValues: [GameLibraryColumnCount]) -> GameLibraryColumnCount? {
        guard UserDefaults.standard.object(forKey: key) != nil else {
            return nil
        }

        let value = GameLibraryColumnCount(rawValue: UserDefaults.standard.integer(forKey: key))
        guard let value, allowedValues.contains(value) else {
            return nil
        }
        return value
    }
}

enum TouchHapticFeedbackLevel: String, CaseIterable, Identifiable {
    case off
    case low
    case medium
    case high

    static let defaultsKey = "DukeXTouchHapticFeedbackLevel"

    var id: String { rawValue }

    static var current: TouchHapticFeedbackLevel {
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey) ?? TouchHapticFeedbackLevel.medium.rawValue
        return TouchHapticFeedbackLevel(rawValue: rawValue) ?? .medium
    }

    var title: String {
        switch self {
        case .off:
            return "Off"
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        }
    }
}

struct UserMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

enum RuntimeJITMode: String {
    case wxReprotection
    case universalJS

    static var current: RuntimeJITMode {
        if #available(iOS 26.0, *) {
            return .universalJS
        }
        return .wxReprotection
    }

    var title: String {
        switch self {
        case .wxReprotection:
            return "W^X reprotection"
        case .universalJS:
            return "Universal.js"
        }
    }

    var systemImage: String {
        switch self {
        case .wxReprotection:
            return "lock.rotation"
        case .universalJS:
            return "bolt.horizontal.circle.fill"
        }
    }

    var environmentValue: String {
        switch self {
        case .wxReprotection:
            return "wx-reprotection"
        case .universalJS:
            return "universal-js"
        }
    }

    var usesUniversalJS: Bool {
        self == .universalJS
    }

    var stikDebugScriptName: String? {
        switch self {
        case .wxReprotection:
            return nil
        case .universalJS:
            return "Universal.js"
        }
    }
}

enum UniversalJITSupport {
    static var currentMode: RuntimeJITMode {
        RuntimeJITMode.current
    }

    static var requiresUniversalJS: Bool {
        currentMode.usesUniversalJS
    }

    static func effectiveEnabled(for setting: Bool) -> Bool {
        setting && requiresUniversalJS
    }

    static func environmentValue(for setting: Bool) -> String {
        effectiveEnabled(for: setting) ? "1" : "0"
    }

    static func requiresJITHandoff(for setting: Bool) -> Bool {
        switch currentMode {
        case .wxReprotection:
            return true
        case .universalJS:
            return setting
        }
    }
}

struct FolderStorageUsage: Equatable {
    struct Folder: Equatable {
        static let zero = Folder(byteCount: 0)

        let byteCount: Int64

        var displayText: String {
            ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        }
    }

    static let empty = FolderStorageUsage(bios: .zero, roms: .zero, covers: .zero)

    let bios: Folder
    let roms: Folder
    let covers: Folder
}

struct NetworkSettings {
    static let insigniaDNSServer = "46.101.64.175"
    static let defaultHostPort = "3074"
    static let defaultGuestPort = "3074"
    static let defaultProtocol = "udp"

    let forceInsigniaNAT: Bool
    let dnsServer: String
    let hostPort: String
    let guestPort: String
    let portProtocol: String

    var effectiveDNSServer: String? {
        if forceInsigniaNAT {
            return Self.insigniaDNSServer
        }

        let trimmed = dnsServer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var effectiveHostPort: Int {
        Self.portValue(hostPort, fallback: Int(Self.defaultHostPort) ?? 3074)
    }

    var effectiveGuestPort: Int {
        Self.portValue(guestPort, fallback: Int(Self.defaultGuestPort) ?? 3074)
    }

    var effectivePortProtocol: String {
        let normalized = portProtocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "tcp" ? "tcp" : "udp"
    }

    private static func portValue(_ value: String, fallback: Int) -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1...65_535).contains(port) else {
            return fallback
        }
        return port
    }
}

enum PresentPacingMode: String, CaseIterable, Identifiable {
    case speed
    case smooth
    case accurate

    var id: String { rawValue }

    static let defaultsKey = "PresentPacingMode"

    static var current: PresentPacingMode {
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey) ?? PresentPacingMode.accurate.rawValue
        return PresentPacingMode(rawValue: rawValue) ?? .accurate
    }

    var title: String {
        switch self {
        case .speed:
            return "Speed"
        case .smooth:
            return "Smooth"
        case .accurate:
            return "Accurate"
        }
    }

    var detail: String {
        switch self {
        case .speed:
            return "Immediate present, display sync off."
        case .smooth:
            return "Mailbox present, display sync off."
        case .accurate:
            return "FIFO present, display sync on."
        }
    }

    var vulkanPresentMode: String {
        switch self {
        case .speed:
            return "immediate"
        case .smooth:
            return "mailbox"
        case .accurate:
            return "fifo"
        }
    }

    var presentFPS: String {
        switch self {
        case .speed, .smooth:
            return "0"
        case .accurate:
            return "60"
        }
    }

    var displaySyncEnabled: Bool {
        self == .accurate
    }

    var nominalFramesPerSecondValue: Int {
        switch self {
        case .speed, .smooth:
            return 120
        case .accurate:
            return 60
        }
    }

    var nominalFramesPerSecond: String {
        String(nominalFramesPerSecondValue)
    }
}

enum TBCacheSize: Int, CaseIterable, Identifiable {
    case mb64 = 64
    case mb128 = 128
    case mb256 = 256

    var id: Int { rawValue }

    static let defaultsKey = "DukeXTBCacheSizeMB"

    static var current: TBCacheSize {
        let storedValue = UserDefaults.standard.integer(forKey: defaultsKey)
        return TBCacheSize(rawValue: storedValue) ?? .mb64
    }

    var title: String {
        "\(rawValue) MB"
    }

    var launchArgumentValue: String {
        String(rawValue)
    }
}

enum DesktopAccelerationMode: String, CaseIterable, Identifiable {
    case automatic
    case hvf
    case tcgMultiThread

    var id: String { rawValue }

    static let defaultsKey = "DukeXDesktopAccelerationMode"

    static var current: DesktopAccelerationMode {
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey) ?? DesktopAccelerationMode.automatic.rawValue
        return DesktopAccelerationMode(rawValue: rawValue) ?? .automatic
    }

    var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .hvf:
            return "HVF"
        case .tcgMultiThread:
            return "TCG"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Lets Xemu choose the fastest available desktop accelerator."
        case .hvf:
            return "Uses Apple's Hypervisor.framework on supported Macs."
        case .tcgMultiThread:
            return "Uses QEMU TCG with multi-threading and the selected translated block cache size."
        }
    }

    func launchArguments(tbCacheSize: TBCacheSize) -> [String] {
        switch self {
        case .automatic:
            return []
        case .hvf:
            return ["-accel", "hvf"]
        case .tcgMultiThread:
            return ["-accel", "tcg,thread=multi,tb-size=\(tbCacheSize.launchArgumentValue)"]
        }
    }
}

enum DesktopRendererBackend: String, CaseIterable, Identifiable {
    case opengl
    case vulkan

    var id: String { rawValue }

    static let defaultsKey = "DukeXDesktopRendererBackend"

    static var current: DesktopRendererBackend {
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey) ?? DesktopRendererBackend.opengl.rawValue
        return DesktopRendererBackend(rawValue: rawValue) ?? .opengl
    }

    var title: String {
        switch self {
        case .opengl:
            return "OpenGL"
        case .vulkan:
            return "Vulkan"
        }
    }

    var detail: String {
        switch self {
        case .opengl:
            return "Uses Xemu's OpenGL renderer. This matches the upstream default on macOS."
        case .vulkan:
            return "Uses Xemu's Vulkan renderer on supported macOS builds."
        }
    }

    var tomlValue: String {
        rawValue.uppercased()
    }
}

enum DesktopGameResolutionScale: Int, CaseIterable, Identifiable {
    case x1 = 1
    case x2 = 2
    case x3 = 3
    case x4 = 4
    case x5 = 5
    case x6 = 6
    case x7 = 7
    case x8 = 8
    case x9 = 9
    case x10 = 10

    var id: Int { rawValue }

    static let defaultsKey = "DukeXDesktopGameResolutionScale"

    static var current: DesktopGameResolutionScale {
        let storedValue = UserDefaults.standard.integer(forKey: defaultsKey)
        return DesktopGameResolutionScale(rawValue: storedValue) ?? .x1
    }

    var title: String {
        "\(rawValue)x"
    }

    var detail: String {
        switch self {
        case .x1:
            return "Native Xbox internal resolution."
        default:
            return "\(rawValue)x internal render scale."
        }
    }
}

enum DesktopDisplayAspectRatio: String, CaseIterable, Identifiable {
    case fourByThree = "4x3"
    case sixteenByNine = "16x9"

    var id: String { rawValue }

    static let defaultsKey = "DukeXDesktopDisplayAspectRatio"

    static var current: DesktopDisplayAspectRatio {
        let rawValue = UserDefaults.standard.string(forKey: defaultsKey) ?? DesktopDisplayAspectRatio.sixteenByNine.rawValue
        return DesktopDisplayAspectRatio(rawValue: rawValue) ?? .sixteenByNine
    }

    var title: String {
        switch self {
        case .fourByThree:
            return "4:3"
        case .sixteenByNine:
            return "16:9"
        }
    }

    var detail: String {
        switch self {
        case .fourByThree:
            return "Displays gameplay in the original standard Xbox aspect ratio."
        case .sixteenByNine:
            return "Displays gameplay in widescreen when supported."
        }
    }

    var tomlValue: String {
        rawValue
    }
}

enum LaunchPlanError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "\(name) is missing."
        }
    }
}
