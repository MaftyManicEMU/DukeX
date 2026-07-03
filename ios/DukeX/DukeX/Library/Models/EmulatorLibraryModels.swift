import Foundation
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
        guard let titleID = GameLaunchLink.normalizedTitleID(game.titleID),
              let launchURL = GameLaunchLink.externalGameURL(for: game) else {
            return nil
        }

        let metadataTitle = metadata?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleName = metadataTitle?.isEmpty == false ? metadataTitle! : game.displayName

        return ExportedGame(
            titleName: titleName,
            version: "1.0",
            iconData: iconData(for: game),
            titleId: titleID,
            titleID: titleID,
            id: titleID,
            developer: metadata?.studio.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            launchURL: launchURL.absoluteString,
            launchUrl: launchURL.absoluteString,
            url: launchURL.absoluteString,
            fileName: game.fileName,
            platform: "Xbox"
        )
    }

    private static func encodedPayload(for games: [ExportedGame]) -> String? {
        guard let data = try? JSONEncoder().encode(games) else {
            return nil
        }

        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingTrailingBase64Padding()
    }

    private static func iconData(for game: LibraryFile) -> String {
        guard let coverURL = game.coverURL,
              let data = try? Data(contentsOf: coverURL) else {
            return ""
        }

        return data.base64EncodedString()
    }

    private static func isValidCallbackScheme(_ scheme: String) -> Bool {
        guard let first = scheme.unicodeScalars.first,
              CharacterSet.letters.contains(first) else {
            return false
        }

        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-.")
        return scheme.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private struct ExportedGame: Encodable {
        let titleName: String
        let version: String
        let iconData: String
        let titleId: String
        let titleID: String
        let id: String
        let developer: String
        let launchURL: String
        let launchUrl: String
        let url: String
        let fileName: String
        let platform: String
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
    case pairingFile

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
        case .pairingFile:
            return [
                UTType(filenameExtension: "plist"),
                .propertyList,
                .data,
                .item
            ].compactMap { $0 }
        }
    }
}

enum GameLibraryColumnCount: Int, CaseIterable, Identifiable {
    case two = 2
    case three = 3
    case four = 4

    static let portraitDefaultsKey = "DukeXPortraitGameLibraryColumnCount"
    static let landscapeDefaultsKey = "DukeXLandscapeGameLibraryColumnCount"
    private static let legacyDefaultsKey = "DukeXGameLibraryColumnCount"

    static let portraitOptions: [GameLibraryColumnCount] = [.two, .three]
    static let landscapeOptions: [GameLibraryColumnCount] = [.three, .four]

    var id: Int { rawValue }
    var columnCount: Int { rawValue }

    static var currentPortrait: GameLibraryColumnCount {
        if let value = storedValue(forKey: portraitDefaultsKey, allowedValues: portraitOptions) {
            return value
        }

        return storedValue(forKey: legacyDefaultsKey, allowedValues: portraitOptions) ?? .two
    }

    static var currentLandscape: GameLibraryColumnCount {
        storedValue(forKey: landscapeDefaultsKey, allowedValues: landscapeOptions) ?? .three
    }

    var title: String {
        switch self {
        case .two:
            return "2 Columns"
        case .three:
            return "3 Columns"
        case .four:
            return "4 Columns"
        }
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

enum LaunchPlanError: LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "\(name) is missing."
        }
    }
}
