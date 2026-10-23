import Foundation
import Combine

struct SSHHost: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var username: String
    var hostname: String
    var enabled: Bool = true
    var collapsed: Bool = false

    var destination: String { "\(username)@\(hostname)" }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.isEmpty && !hostname.isEmpty &&
        !username.contains(where: { $0.isWhitespace || $0 == "@" }) &&
        !username.hasPrefix("-") &&
        !hostname.contains(where: { $0.isWhitespace || $0 == "@" || $0 == "/" }) &&
        !hostname.hasPrefix("-")
    }
}

@MainActor
final class SSHSettings: ObservableObject {
    private let defaults: UserDefaults
    private static let hostsKey = "sshHostsV2"

    @Published var sshEnabled: Bool {
        didSet { defaults.set(sshEnabled, forKey: "sshEnabled") }
    }
    @Published private(set) var hosts: [SSHHost] {
        didSet {
            if let data = try? JSONEncoder().encode(hosts) {
                defaults.set(data, forKey: Self.hostsKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["sshEnabled": true])
        sshEnabled = defaults.bool(forKey: "sshEnabled")
        if let data = defaults.data(forKey: Self.hostsKey),
           let saved = try? JSONDecoder().decode([SSHHost].self, from: data) {
            hosts = saved.filter(\.isValid)
        } else {
            hosts = []
        }
    }

    func save(_ host: SSHHost) {
        var host = host
        host.name = host.name.trimmingCharacters(in: .whitespacesAndNewlines)
        host.username = host.username.trimmingCharacters(in: .whitespacesAndNewlines)
        host.hostname = host.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.isValid else { return }
        if let index = hosts.firstIndex(where: { $0.id == host.id }) {
            hosts[index] = host
        } else {
            hosts.append(host)
        }
    }

    func remove(_ host: SSHHost) { hosts.removeAll { $0.id == host.id } }
    func isEnabled(_ host: SSHHost) -> Bool { hosts.first(where: { $0.id == host.id })?.enabled ?? false }
    func setEnabled(_ enabled: Bool, for host: SSHHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index].enabled = enabled
    }
    func isCollapsed(_ host: SSHHost) -> Bool { hosts.first(where: { $0.id == host.id })?.collapsed ?? false }
    func toggleCollapsed(_ host: SSHHost) {
        guard let index = hosts.firstIndex(where: { $0.id == host.id }) else { return }
        hosts[index].collapsed.toggle()
    }
}
