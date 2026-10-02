import Foundation

public struct AppStatus {
    public let config: AppConfig
    public let healthy: Bool
    public let owned: Bool
    public let ownedPID: pid_t?
    public let message: String
}

@MainActor
public final class ServerManager {
    private final class Entry {
        var config: AppConfig
        var process: ManagedProcess?
        var healthy = false
        var everHealthy = false
        var probeInFlight = false
        var pendingOpen = false
        var shouldMaintain = false
        var stoppedByUser = false
        var startedAt: Date?
        var failedChecks = 0
        var restartFailures = 0
        var nextRestartAt: Date?
        var message = "Checking…"

        init(config: AppConfig) { self.config = config }
    }

    private var entries: [String: Entry] = [:]
    private var timer: Timer?
    private let configDirectory: URL
    private let logDirectory: URL
    private let openBrowser: (URL) -> Void
    public var onUpdate: (() -> Void)?
    public private(set) var issues: [ConfigIssue] = []

    public init(configDirectory: URL, logDirectory: URL, openBrowser: @escaping (URL) -> Void) {
        self.configDirectory = configDirectory
        self.logDirectory = logDirectory
        self.openBrowser = openBrowser
    }

    public var statuses: [AppStatus] {
        entries.values.map { AppStatus(config: $0.config, healthy: $0.healthy, owned: $0.process != nil, ownedPID: $0.process?.pid, message: $0.message) }
            .sorted { $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending }
    }

    public var healthyCount: Int { entries.values.filter(\.healthy).count }

    public func start() {
        reloadConfigs()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    public func reloadConfigs() {
        let loaded = ConfigLoader.load(from: configDirectory)
        issues = loaded.issues
        let next = Dictionary(uniqueKeysWithValues: loaded.apps.map { ($0.id, $0) })
        for (id, entry) in Array(entries) where next[id] == nil || next[id] != entry.config {
            entry.stoppedByUser = true
            entry.process?.terminateAndWait()
            entries.removeValue(forKey: id)
        }
        for config in loaded.apps where entries[config.id] == nil {
            entries[config.id] = Entry(config: config)
        }
        onUpdate?()
        tick()
    }

    public func select(_ id: String) {
        guard let entry = entries[id] else { return }
        entry.pendingOpen = true
        entry.stoppedByUser = false
        if !entry.healthy { entry.message = "Checking…" }
        onUpdate?()
        Task {
            let healthy = await HealthProbe.check(entry.config)
            guard entries[id] === entry else { return }
            if healthy {
                markHealthy(entry)
            } else {
                entry.healthy = false
                startIfNeeded(id, force: true)
            }
        }
    }

    public func stop(_ id: String) {
        guard let entry = entries[id], let process = entry.process else { return }
        entry.stoppedByUser = true
        entry.shouldMaintain = false
        entry.pendingOpen = false
        entry.nextRestartAt = nil
        entry.healthy = false
        entry.message = "Stopping…"
        process.terminate()
        onUpdate?()
    }

    public func stopAll() {
        timer?.invalidate()
        timer = nil
        for entry in entries.values {
            entry.stoppedByUser = true
            entry.shouldMaintain = false
            entry.process?.terminateAndWait()
        }
    }

    public func logURL(for id: String) -> URL? {
        guard entries[id] != nil else { return nil }
        return logDirectory.appendingPathComponent("\(id).log")
    }

    private func tick() {
        for id in entries.keys { probe(id) }
    }

    private func probe(_ id: String) {
        guard let entry = entries[id], !entry.probeInFlight else { return }
        entry.probeInFlight = true
        Task {
            let healthy = await HealthProbe.check(entry.config)
            guard entries[id] === entry else { return }
            entry.probeInFlight = false
            if healthy {
                markHealthy(entry)
            } else {
                markUnhealthy(id, entry: entry)
            }
        }
    }

    private func markHealthy(_ entry: Entry) {
        entry.healthy = true
        entry.everHealthy = true
        entry.failedChecks = 0
        entry.restartFailures = 0
        entry.nextRestartAt = nil
        entry.message = entry.process == nil ? "Running externally" : "Running"
        if entry.pendingOpen {
            entry.pendingOpen = false
            openBrowser(entry.config.browserURL)
        }
        onUpdate?()
    }

    private func markUnhealthy(_ id: String, entry: Entry) {
        entry.healthy = false
        if entry.process != nil {
            entry.failedChecks += 1
            if (entry.everHealthy || entry.startedAt.map { Date().timeIntervalSince($0) > 60 } == true) && entry.failedChecks >= 3 {
                entry.message = "Unresponsive; restarting…"
                entry.process?.terminate()
            } else if entry.message == "Checking…" || entry.message == "Running" {
                entry.message = "Starting…"
            }
        } else if entry.shouldMaintain && !entry.stoppedByUser {
            if entry.nextRestartAt.map({ Date() >= $0 }) ?? true { startIfNeeded(id) }
        } else if !entry.stoppedByUser {
            entry.message = "Stopped"
        }
        onUpdate?()
    }

    private func startIfNeeded(_ id: String, force: Bool = false) {
        guard let entry = entries[id], entry.process == nil, !entry.healthy, !entry.stoppedByUser else { return }
        if !force, let next = entry.nextRestartAt, Date() < next { return }
        entry.shouldMaintain = true
        entry.startedAt = Date()
        entry.failedChecks = 0
        entry.everHealthy = false
        entry.nextRestartAt = nil
        entry.message = "Starting…"
        let logURL = logDirectory.appendingPathComponent("\(id).log")
        do {
            let process = try ManagedProcess(command: entry.config.command, directory: entry.config.expandedDirectory, logURL: logURL) { [weak self] pid, _ in
                Task { @MainActor in self?.processExited(id, pid: pid) }
            }
            entry.process = process
        } catch {
            entry.message = "Start failed: \(error.localizedDescription)"
            scheduleRestart(entry)
        }
        onUpdate?()
    }

    private func processExited(_ id: String, pid: pid_t) {
        guard let entry = entries[id], entry.process?.pid == pid else { return }
        entry.process = nil
        entry.startedAt = nil
        entry.healthy = false
        if entry.stoppedByUser {
            entry.message = "Stopped"
        } else {
            entry.message = "Server exited; restarting…"
            scheduleRestart(entry)
        }
        onUpdate?()
    }

    private func scheduleRestart(_ entry: Entry) {
        guard entry.shouldMaintain, !entry.stoppedByUser else { return }
        let delays: [TimeInterval] = [2, 5, 15, 30, 60]
        let delay = delays[min(entry.restartFailures, delays.count - 1)]
        entry.restartFailures += 1
        entry.nextRestartAt = Date().addingTimeInterval(delay)
    }
}
