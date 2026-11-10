import Foundation
import Observation

/// Every running server's lifecycle. Whether a call may run is the coordinator's decision.
@MainActor
@Observable
final class MCPServerManager {
    private(set) var connections: [UUID: MCPServerConnection] = [:]

    @ObservationIgnored private let oauth: MCPOAuthManager?
    @ObservationIgnored private let secrets: MCPSecretStore
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    /// Owned so a withdrawn server's start, still queued, is cancelled rather than run late.
    @ObservationIgnored private var starts: [UUID: Task<Void, Never>] = [:]

    /// Servers outlive one summon but not an afternoon; a resident helper is the memory budget.
    private static let idleTimeout: Duration = .seconds(600)

    init(secrets: MCPSecretStore = MCPSecretStore(), oauth: MCPOAuthManager? = nil) {
        self.oauth = oauth
        self.secrets = secrets
    }

    func status(of id: UUID) -> MCPServerStatus {
        connections[id]?.status ?? .stopped
    }

    var tools: [MCPTool] {
        connections.values.filter { $0.status.isReady }.flatMap(\.tools)
    }

    /// Brings the running set in line with what Settings holds, starting only what is missing.
    func reconcile(_ servers: [MCPServer]) {
        let wanted = Dictionary(servers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, connection) in connections where wanted[id] != connection.server {
            starts.removeValue(forKey: id)?.cancel()
            connection.stop()
            connections[id] = nil
        }
        for server in servers {
            guard let existing = connections[server.id] else {
                let connection = MCPServerConnection(
                    server: server, secrets: secrets.secrets(for: server.id), oauth: oauth)
                connections[server.id] = connection
                start(connection)
                continue
            }
            // Idle covers failed, so entering chat retries a server that lost its network once.
            if existing.isIdle { start(existing) }
        }
        armIdleTimer()
    }

    func disconnect(_ id: UUID) {
        starts.removeValue(forKey: id)?.cancel()
        connections.removeValue(forKey: id)?.stop()
    }

    func stop() {
        idleTask?.cancel()
        idleTask = nil
        starts.values.forEach { $0.cancel() }
        starts = [:]
        for connection in connections.values { connection.stop() }
        connections = [:]
    }

    private func start(_ connection: MCPServerConnection) {
        let id = connection.server.id
        starts[id]?.cancel()
        starts[id] = Task { await connection.start() }
    }

    /// Restarted on every use, so the countdown measures idleness rather than uptime.
    func markUsed() {
        armIdleTimer()
    }

    private func armIdleTimer() {
        idleTask?.cancel()
        guard !connections.isEmpty else {
            idleTask = nil
            return
        }
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
}
