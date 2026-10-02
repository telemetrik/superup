import Foundation

public struct AppConfig: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var directory: String
    public var command: String
    public var url: String
    public var healthURL: String?
    public var expectedText: String?

    public init(id: String, name: String, directory: String, command: String, url: String, healthURL: String? = nil, expectedText: String? = nil) {
        self.id = id
        self.name = name
        self.directory = directory
        self.command = command
        self.url = url
        self.healthURL = healthURL
        self.expectedText = expectedText
    }

    private enum CodingKeys: String, CodingKey {
        case name, directory, command, url, healthURL, expectedText
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = ""
        name = try values.decode(String.self, forKey: .name)
        directory = try values.decode(String.self, forKey: .directory)
        command = try values.decode(String.self, forKey: .command)
        url = try values.decode(String.self, forKey: .url)
        healthURL = try values.decodeIfPresent(String.self, forKey: .healthURL)
        expectedText = try values.decodeIfPresent(String.self, forKey: .expectedText)
    }

    public var expandedDirectory: String { (directory as NSString).expandingTildeInPath }
    public var browserURL: URL { URL(string: url)! }
    public var probeURL: URL { URL(string: healthURL ?? url)! }
}

public struct ConfigIssue: Equatable {
    public var filename: String
    public var message: String

    public init(filename: String, message: String) {
        self.filename = filename
        self.message = message
    }
}

public struct ConfigLoadResult {
    public var apps: [AppConfig]
    public var issues: [ConfigIssue]
}

public enum ConfigLoader {
    public static func userDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/SuperUp/apps", isDirectory: true)
    }

    public static func prepareDirectory(at directory: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static func load(from directory: URL, fileManager: FileManager = .default) -> ConfigLoadResult {
        var result = ConfigLoadResult(apps: [], issues: [])
        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            result.issues.append(ConfigIssue(filename: directory.path, message: error.localizedDescription))
            return result
        }
        var ports = Set<Int>()
        for file in files {
            do {
                var app = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: file))
                app.id = file.deletingPathExtension().lastPathComponent
                try validate(app, fileManager: fileManager)
                let port = app.browserURL.port ?? 80
                guard ports.insert(port).inserted else { throw ConfigError("another app already uses local port \(port)") }
                result.apps.append(app)
            } catch {
                result.issues.append(ConfigIssue(filename: file.lastPathComponent, message: error.localizedDescription))
            }
        }
        return result
    }

    public static func validate(_ app: AppConfig, fileManager: FileManager = .default) throws {
        guard !app.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigError("name is empty") }
        guard !app.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigError("command is empty") }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: app.expandedDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigError("directory does not exist: \(app.directory)")
        }
        guard let browser = URL(string: app.url), isLoopbackHTTP(browser) else { throw ConfigError("url must be an http loopback URL") }
        guard let health = URL(string: app.healthURL ?? app.url), isLoopbackHTTP(health), originKey(health) == originKey(browser) else {
            throw ConfigError("healthURL must use the same local origin as url")
        }
    }

    private static func isLoopbackHTTP(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "") && url.user == nil && url.password == nil
    }

    private static func originKey(_ url: URL) -> String {
        "\(url.host?.lowercased() ?? ""):\(url.port ?? 80)"
    }
}

public struct ConfigError: LocalizedError {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
