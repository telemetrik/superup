import Darwin
import Foundation
import SuperUpCore

@main
struct Checks {
    static func main() async throws {
        try checkConfigLoading()
        try checkConfigPreparation()
        try checkLogRotation()
        try await checkManagedLogRotation()
        await checkHealthProbe()
        try await checkManagedServerLifecycle()
        print("SuperUp checks passed")
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func checkConfigLoading() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let working = directory.appendingPathComponent("working")
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        let first = AppConfig(id: "ignored", name: "First", directory: working.path, command: "true", url: "http://localhost:51001")
        let duplicate = AppConfig(id: "ignored", name: "Duplicate", directory: working.path, command: "true", url: "http://localhost:51001/other")
        let remote = AppConfig(id: "ignored", name: "Remote", directory: working.path, command: "true", url: "https://example.com")
        try encoder.encode(first).write(to: directory.appendingPathComponent("a.json"))
        try encoder.encode(duplicate).write(to: directory.appendingPathComponent("b.json"))
        try encoder.encode(remote).write(to: directory.appendingPathComponent("c.json"))
        try Data("{".utf8).write(to: directory.appendingPathComponent("broken.json"))

        let result = ConfigLoader.load(from: directory)
        precondition(result.apps.map(\.id) == ["a"])
        precondition(result.issues.count == 3)
    }

    private static func checkConfigPreparation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configs = directory.appendingPathComponent("apps")
        try ConfigLoader.prepareDirectory(at: configs)
        let empty = ConfigLoader.load(from: configs)
        precondition(empty.apps.isEmpty && empty.issues.isEmpty, "first launch must start without private examples or errors")
        let existing = configs.appendingPathComponent("custom.json")
        try Data("custom".utf8).write(to: existing)
        try ConfigLoader.prepareDirectory(at: configs)
        let contents = try String(contentsOf: existing)
        let files = try FileManager.default.contentsOfDirectory(atPath: configs.path)
        precondition(contents == "custom")
        precondition(files.count == 1)
    }

    private static func checkLogRotation() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("test.log")
        try LogRotation.rotateIfNeeded(at: log, limit: 8)
        try Data("old-12345678".utf8).write(to: log)
        // Match the persistent descriptor held by a running child.
        let fd = open(log.path, O_WRONLY | O_APPEND)
        precondition(fd >= 0)
        defer { close(fd) }
        try LogRotation.rotateIfNeeded(at: log, limit: 8)
        let archive = log.appendingPathExtension("1")
        let archived = try String(contentsOf: archive)
        precondition(archived == "12345678")
        let appended = "next".withCString { write(fd, $0, 4) }
        precondition(appended == 4)
        let current = try String(contentsOf: log)
        precondition(current == "next", "rotation must preserve the running child's descriptor")
        try LogRotation.rotateIfNeeded(at: log, limit: 8)
        let unchanged = try String(contentsOf: log)
        precondition(unchanged == "next")
        let appendedAgain = "56789012".withCString { write(fd, $0, 8) }
        precondition(appendedAgain == 8)
        try LogRotation.rotateIfNeeded(at: log, limit: 8)
        let replaced = try String(contentsOf: archive)
        precondition(replaced == "56789012")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(files.count == 2, "rotation must retain only one archive")
        let permissions = try FileManager.default.attributesOfItem(atPath: archive.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)
    }

    private static func checkHealthProbe() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let app = AppConfig(id: "test", name: "Test", directory: "/tmp", command: "true", url: "http://localhost:51234", expectedText: "<title>Test</title>")
        StubURLProtocol.status = 200
        StubURLProtocol.body = "<title>Test</title>"
        let good = await HealthProbe.check(app, session: session)
        precondition(good)
        StubURLProtocol.body = "<title>Other</title>"
        let wrongMarker = await HealthProbe.check(app, session: session)
        precondition(!wrongMarker)
        StubURLProtocol.status = 503
        StubURLProtocol.body = "<title>Test</title>"
        let failureStatus = await HealthProbe.check(app, session: session)
        precondition(!failureStatus)
    }

    private static func checkManagedLogRotation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("running.log")
        let process = try ManagedProcess(
            command: "/usr/bin/python3 -c 'import sys,time; sys.stdout.write(\"x\" * \(LogRotation.defaultLimit)); sys.stdout.flush(); time.sleep(30)'",
            directory: directory.path, logURL: log) { _, _ in }
        defer { process.terminateAndWait() }
        let archive = log.appendingPathExtension("1")
        try await waitUntil {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: log.path) else { return false }
            return FileManager.default.fileExists(atPath: archive.path) && (attributes[.size] as? NSNumber)?.uint64Value == 0
        }
        precondition(kill(process.pid, 0) == 0, "rotation must not restart a running process")
        let archiveSize = try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber
        precondition(archiveSize?.uint64Value == LogRotation.defaultLimit)
    }

    @MainActor
    private static func checkManagedServerLifecycle() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configDirectory = directory.appendingPathComponent("configs")
        let working = directory.appendingPathComponent("working")
        let logs = directory.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        let port = try availablePort()
        let app = AppConfig(id: "fixture", name: "Fixture", directory: working.path,
                            command: "/usr/bin/python3 -m http.server \(port) --bind 127.0.0.1",
                            url: "http://127.0.0.1:\(port)")
        try JSONEncoder().encode(app).write(to: configDirectory.appendingPathComponent("fixture.json"))
        var opened: [URL] = []
        let manager = ServerManager(configDirectory: configDirectory, logDirectory: logs) { opened.append($0) }
        manager.start()
        defer { manager.stopAll() }
        manager.select("fixture")
        try await waitUntil { manager.statuses.first?.healthy == true && opened.count == 1 }
        precondition(manager.statuses.first?.owned == true)

        manager.select("fixture")
        try await waitUntil { opened.count == 2 }

        let firstPID = manager.statuses.first!.ownedPID!
        _ = kill(-firstPID, SIGKILL)
        try await waitUntil { manager.statuses.first?.healthy == true && manager.statuses.first?.ownedPID != firstPID }
        precondition(opened.count == 2, "crash recovery must not reopen the browser")

        manager.stop("fixture")
        try await waitUntil { manager.statuses.first?.owned == false && manager.statuses.first?.healthy == false }

        let external = try ManagedProcess(command: app.command, directory: working.path,
                                          logURL: logs.appendingPathComponent("external.log")) { _, _ in }
        defer { external.terminateAndWait() }
        try await waitUntil { await HealthProbe.check(app) }
        let externalManager = ServerManager(configDirectory: configDirectory, logDirectory: logs) { opened.append($0) }
        externalManager.start()
        try await waitUntil { externalManager.statuses.first?.healthy == true }
        precondition(externalManager.statuses.first?.owned == false)
        externalManager.stopAll()
        let externalSurvivedQuit = await HealthProbe.check(app)
        precondition(externalSurvivedQuit, "quit must leave external servers running")

        let wrongApp = AppConfig(id: "fixture", name: "Wrong", directory: working.path,
                                 command: app.command, url: app.url, expectedText: "never-the-right-server")
        try JSONEncoder().encode(wrongApp).write(to: configDirectory.appendingPathComponent("fixture.json"))
        let collisionManager = ServerManager(configDirectory: configDirectory, logDirectory: logs) { opened.append($0) }
        collisionManager.start()
        collisionManager.select("fixture")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        precondition(collisionManager.statuses.first?.healthy == false)
        precondition(opened.count == 2, "wrong service on port must not open browser")
        collisionManager.stopAll()
        let externalSurvivedCollision = await HealthProbe.check(app)
        precondition(externalSurvivedCollision, "port collision must not kill external server")
    }

    private static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConfigError("could not open test socket") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw ConfigError("could not bind test socket") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let obtained = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard obtained == 0 else { throw ConfigError("could not read test port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw ConfigError("timed out waiting for server behavior")
    }
}

private final class StubURLProtocol: URLProtocol {
    static var status = 200
    static var body = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
