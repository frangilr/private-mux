import Foundation
import Combine

enum SSHConnectionStatus: String {
    case connected, connecting, disconnected, failed, disabled
}

struct RemoteWindow: Identifiable, Equatable {
    let hostID: String
    let sessionID: String
    let sessionName: String
    let windowID: String
    let name: String
    let paneID: String

    var id: String { "\(hostID):\(sessionID):\(windowID)" }
}

struct RemotePane: Identifiable {
    let sessionID: String
    let windowID: String
    let paneID: String
    let isActive: Bool
    var id: String { paneID }
}

struct RemoteHostSnapshot {
    var status: SSHConnectionStatus = .disconnected
    var windows: [RemoteWindow] = []
    var panes: [RemotePane] = []
    var message: String? = nil
}

/// Owns app-managed SSH clients and tmux state. The SwiftUI layer receives only snapshots.
@MainActor
final class RemoteTmuxManager: ObservableObject {
    @Published private(set) var hosts: [String: RemoteHostSnapshot] = [:]
    // Define PRIVATE_TERM_ACTIVITY_DOTS to restore experimental output indicators.
    #if PRIVATE_TERM_ACTIVITY_DOTS
    @Published private(set) var unreadWindowIDs = Set<String>()
    #endif

    private var connections: [String: TmuxControlConnection] = [:]
    private var allowed: [String: Bool] = [:]
    private var configured: [String: SSHHost] = [:]
    private var attempted = Set<String>()
    #if PRIVATE_TERM_ACTIVITY_DOTS
    private var selectedWindowID: String?
    #endif
    var onPaneOutput: ((String, String, Data) -> Void)?
    var onPaneSnapshot: ((String, String, Data) -> Void)?

    func apply(_ settings: SSHSettings) {
        let currentIDs = Set(settings.hosts.map(\.id))
        for id in Set(configured.keys).subtracting(currentIDs) {
            connections.removeValue(forKey: id)?.disconnect()
            configured.removeValue(forKey: id)
            allowed.removeValue(forKey: id)
            attempted.remove(id)
            hosts.removeValue(forKey: id)
        }
        for host in settings.hosts {
            let destinationChanged = configured[host.id].map { $0.destination != host.destination } ?? false
            configured[host.id] = host
            if destinationChanged {
                connections.removeValue(forKey: host.id)?.disconnect()
                attempted.remove(host.id)
                allowed[host.id] = false
            }
            let shouldConnect = settings.sshEnabled && settings.isEnabled(host)
            let wasAllowed = allowed[host.id] ?? false
            allowed[host.id] = shouldConnect
            if !shouldConnect {
                connections.removeValue(forKey: host.id)?.disconnect()
                attempted.remove(host.id)
                #if PRIVATE_TERM_ACTIVITY_DOTS
                clearUnread(for: host.id)
                #endif
                hosts[host.id] = RemoteHostSnapshot(status: .disabled)
            } else if !wasAllowed {
                attempted.remove(host.id)
                connect(host)
            }
        }
    }

    func reconnect(_ host: SSHHost) {
        guard allowed[host.id] == true else { return }
        connections.removeValue(forKey: host.id)?.disconnect()
        attempted.remove(host.id)
        #if PRIVATE_TERM_ACTIVITY_DOTS
        clearUnread(for: host.id)
        #endif
        connect(host)
    }

    #if PRIVATE_TERM_ACTIVITY_DOTS
    func showWindow(_ id: String?) {
        selectedWindowID = id
        guard let id,
              let window = hosts.values.flatMap(\.windows).first(where: { $0.id == id }),
              let snapshot = hosts[window.hostID] else { return }
        // A tmux window can be linked into multiple sessions; visiting it
        // clears all sidebar copies of the same underlying window.
        let readIDs = Set(snapshot.windows.filter { $0.windowID == window.windowID }.map(\.id))
        let unreadIDs = unreadWindowIDs.intersection(readIDs)
        if !unreadIDs.isEmpty { unreadWindowIDs.subtract(unreadIDs) }
    }

    func hasUnread(in host: SSHHost) -> Bool {
        hosts[host.id]?.windows.contains(where: { unreadWindowIDs.contains($0.id) }) ?? false
    }
    #endif

    func select(_ window: RemoteWindow, columns: Int, rows: Int) {
        connections[window.hostID]?.select(window, columns: columns, rows: rows)
    }

    func send(_ data: Data, to window: RemoteWindow) {
        connections[window.hostID]?.send(data, to: window.paneID)
    }

    func resize(columns: Int, rows: Int, window: RemoteWindow) {
        connections[window.hostID]?.resize(columns: columns, rows: rows, windowID: window.windowID)
    }

    func stopAll() {
        for connection in connections.values { connection.disconnect() }
        connections.removeAll()
    }

    private func connect(_ host: SSHHost) {
        guard !attempted.contains(host.id) else { return }
        attempted.insert(host.id)
        #if PRIVATE_TERM_ACTIVITY_DOTS
        clearUnread(for: host.id)
        #endif
        hosts[host.id] = RemoteHostSnapshot(status: .connecting)
        let connection = TmuxControlConnection(host: host)
        connections[host.id] = connection
        connection.onStatus = { [weak self, weak connection] status, message in
            guard let self, self.connections[host.id] === connection else { return }
            var snapshot = self.hosts[host.id] ?? RemoteHostSnapshot()
            snapshot.status = status
            snapshot.message = message
            if status != .connected {
                snapshot.windows = []
                snapshot.panes = []
                #if PRIVATE_TERM_ACTIVITY_DOTS
                self.clearUnread(for: host.id)
                #endif
            }
            self.hosts[host.id] = snapshot
        }
        connection.onWindows = { [weak self, weak connection] windows in
            guard let self, self.connections[host.id] === connection else { return }
            var snapshot = self.hosts[host.id] ?? RemoteHostSnapshot()
            snapshot.windows = windows
            self.hosts[host.id] = snapshot
            #if PRIVATE_TERM_ACTIVITY_DOTS
            let validIDs = Set(windows.map(\.id))
            let staleIDs = self.unreadWindowIDs.filter {
                $0.hasPrefix("\(host.id):") && !validIDs.contains($0)
            }
            if !staleIDs.isEmpty { self.unreadWindowIDs.subtract(staleIDs) }
            #endif
        }
        connection.onPanes = { [weak self, weak connection] panes in
            guard let self, self.connections[host.id] === connection else { return }
            var snapshot = self.hosts[host.id] ?? RemoteHostSnapshot()
            snapshot.panes = panes
            self.hosts[host.id] = snapshot
        }
        connection.onOutput = { [weak self, weak connection] pane, bytes in
            guard let self, self.connections[host.id] === connection else { return }
            #if PRIVATE_TERM_ACTIVITY_DOTS
            self.handleOutput(hostID: host.id, paneID: pane, bytes: bytes)
            #else
            self.onPaneOutput?(host.id, pane, bytes)
            #endif
        }
        connection.onCapture = { [weak self] pane, bytes in self?.onPaneSnapshot?(host.id, pane, bytes) }
        connection.start()
    }

    #if PRIVATE_TERM_ACTIVITY_DOTS
    private func handleOutput(hostID: String, paneID: String, bytes: Data) {
        guard !bytes.isEmpty else { return }
        guard let snapshot = hosts[hostID] else { return }
        let visibleWindow = snapshot.windows.first(where: { $0.id == selectedWindowID })
        let displayingPane = visibleWindow?.paneID == paneID
        if let pane = snapshot.panes.first(where: { $0.paneID == paneID }),
           visibleWindow?.windowID != pane.windowID {
            let matchingWindows = snapshot.windows.filter { $0.windowID == pane.windowID }
            let newIDs = Set(matchingWindows.map(\.id)).subtracting(unreadWindowIDs)
            if !newIDs.isEmpty { unreadWindowIDs.formUnion(newIDs) }
        }
        // The next selection captures the pane from tmux, so inactive output
        // does not need to wake or render the shared hidden WebView.
        if displayingPane { onPaneOutput?(hostID, paneID, bytes) }
    }

    private func clearUnread(for hostID: String) {
        let matchingIDs = unreadWindowIDs.filter { $0.hasPrefix("\(hostID):") }
        if !matchingIDs.isEmpty { unreadWindowIDs.subtract(matchingIDs) }
    }
    #endif
}

/// A single SSH process attached to one tmux control-mode client.
/// Command replies and asynchronous notifications are parsed separately.
@MainActor
final class TmuxControlConnection {
    let host: SSHHost
    var onStatus: ((SSHConnectionStatus, String?) -> Void)?
    var onWindows: (([RemoteWindow]) -> Void)?
    var onPanes: (([RemotePane]) -> Void)?
    var onOutput: ((String, Data) -> Void)?
    var onCapture: ((String, Data) -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private let writeQueue = DispatchQueue(label: "PrivateTerm.SSH.Write")
    private var buffer = Data()
    private var errorBuffer = Data()
    private var reply = Data()
    private var inReply = false
    private var replyID: String?
    private var pending: [(Data, Bool) -> Void] = []
    private var connected = false
    private var stopped = false
    private var refreshScheduled = false
    private var timeout: DispatchWorkItem?

    init(host: SSHHost) { self.host = host }

    func start() {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        child.environment = environment
        child.arguments = [
            "-tt", "-o", "BatchMode=yes", "-o", "NumberOfPasswordPrompts=0",
            "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
            "-o", "StrictHostKeyChecking=yes", "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=1", host.destination,
            "tmux -CC new-session -A -s PrivateTerm"
        ]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        errors = stderr.fileHandleForReading
        process = child

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            DispatchQueue.main.async { self?.receiveError(data) }
        }
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async { self?.didExit(code: child.terminationStatus) }
        }
        do {
            try child.run()
        } catch {
            fail("Could not launch /usr/bin/ssh: \(error.localizedDescription)")
            return
        }
        // This also bounds remote tmux startup and SSH configuration that ignores ConnectTimeout.
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, !self.connected, !self.stopped else { return }
            self.fail("Connection timed out.")
        }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: deadline)
    }

    func disconnect() {
        guard !stopped else { return }
        stopped = true
        timeout?.cancel()
        // Detach the control client. tmux sessions and their panes stay alive.
        write("detach-client\n")
        closeInput()
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        let child = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if child?.isRunning == true { child?.terminate() }
        }
        onStatus?(.disconnected, nil)
    }

    func select(_ window: RemoteWindow, columns: Int, rows: Int) {
        guard connected, validID(window.sessionID, prefix: "$"),
              validID(window.windowID, prefix: "@"),
              validID(window.paneID, prefix: "%") else { return }
        // The pane must have its final size before capture-pane reports its screen and cursor.
        command("switch-client -t \(window.sessionID)") { [weak self] _, _ in
            guard let self else { return }
            self.command("select-window -t \(window.windowID)") { [weak self] _, _ in
                guard let self else { return }
                self.resize(columns: columns, rows: rows, windowID: window.windowID) { [weak self] in
                    self?.capture(window.paneID)
                }
            }
        }
    }

    func send(_ bytes: Data, to pane: String) {
        guard connected, validID(pane, prefix: "%") else { return }
        // -H accepts byte values, so no terminal data enters tmux command syntax.
        let codes: [UInt32]
        if let string = String(data: bytes, encoding: .utf8) {
            codes = string.unicodeScalars.map(\.value)
        } else {
            codes = bytes.map(UInt32.init)
        }
        for chunk in stride(from: 0, to: codes.count, by: 128) {
            let end = min(chunk + 128, codes.count)
            let hex = codes[chunk..<end].map { String($0, radix: 16) }.joined(separator: " ")
            command("send-keys -H -t \(pane) \(hex)") { _, _ in }
        }
    }

    func resize(columns: Int, rows: Int, windowID: String) {
        resize(columns: columns, rows: rows, windowID: windowID, completion: nil)
    }

    private func resize(columns: Int, rows: Int, windowID: String, completion: (() -> Void)?) {
        guard connected, validID(windowID, prefix: "@") else { return }
        let cols = min(max(columns, 2), 1000), lines = min(max(rows, 2), 1000)
        command("refresh-client -C \(cols)x\(lines)") { _, _ in completion?() }
    }

    private func capture(_ pane: String) {
        guard validID(pane, prefix: "%") else { return }
        command("display-message -p -t \(pane) '#{cursor_x}|#{cursor_y}'") { [weak self] position, _ in
            guard let self else { return }
            self.command("capture-pane -p -e -t \(pane)") { [weak self] bytes, success in
                guard let self else { return }
                if !success {
                    self.onCapture?(pane, Data("[Could not capture tmux pane.]\r\n".utf8))
                    return
                }
                var screen = Data("\u{1b}[2J\u{1b}[H".utf8)
                screen.reserveCapacity(bytes.count + 64)
                var lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
                if lines.last?.isEmpty == true { lines.removeLast() }
                // A final newline from capture-pane must not scroll the xterm screen.
                // Place each row explicitly so a full-height pane restores without shifting down.
                for (index, line) in lines.enumerated() {
                    screen.append(Data("\u{1b}[\(index + 1);1H".utf8))
                    screen.append(contentsOf: line)
                }
                let coordinates = String(decoding: position, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "|")
                if coordinates.count == 2, let x = Int(coordinates[0]), let y = Int(coordinates[1]),
                   (0...1000).contains(x), (0...1000).contains(y) {
                    screen.append(Data("\u{1b}[\(y + 1);\(x + 1)H".utf8))
                }
                self.onCapture?(pane, screen)
            }
        }
    }

    private func refreshWindows() {
        guard connected, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.connected, !self.stopped else { return }
            self.refreshScheduled = false
            self.command("list-windows -a -F '#{session_id}|#{session_name}|#{window_id}|#{window_name}|#{pane_id}'") { [weak self] data, success in
                guard let self, success else { return }
                let windows = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> RemoteWindow? in
                    let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    guard fields.count >= 5,
                          self.validID(fields[0], prefix: "$"),
                          self.validID(fields[2], prefix: "@"),
                          self.validID(fields.last!, prefix: "%") else { return nil }
                    return RemoteWindow(hostID: self.host.id, sessionID: fields[0], sessionName: fields[1],
                                        windowID: fields[2], name: fields[3..<(fields.count-1)].joined(separator: "|"),
                                        paneID: fields.last!)
                }
                self.onWindows?(windows)
                self.refreshPanes()
            }
        }
    }

    private func refreshPanes() {
        command("list-panes -a -F '#{session_id}|#{window_id}|#{pane_id}|#{pane_active}'") { [weak self] data, success in
            guard let self, success else { return }
            let panes = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> RemotePane? in
                let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard fields.count == 4,
                      self.validID(fields[0], prefix: "$"),
                      self.validID(fields[1], prefix: "@"),
                      self.validID(fields[2], prefix: "%") else { return nil }
                return RemotePane(sessionID: fields[0], windowID: fields[1],
                                  paneID: fields[2], isActive: fields[3] == "1")
            }
            self.onPanes?(panes)
        }
    }

    private func command(_ text: String, completion: @escaping (Data, Bool) -> Void) {
        pending.append(completion)
        write(text + "\n")
    }

    private func write(_ text: String) {
        guard process?.isRunning == true else { return }
        guard let input else { return }
        let data = Data(text.utf8)
        writeQueue.async { input.write(data) }
    }

    private func closeInput() {
        guard let input else { return }
        self.input = nil
        writeQueue.async { input.closeFile() }
    }

    private func receive(_ bytes: Data) {
        guard !stopped, !bytes.isEmpty else { return }
        buffer.append(bytes)
        while let newline = buffer.firstIndex(of: 10) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 13 { line.removeLast() }
            handleLine(line)
        }
        if buffer.count > 4 * 1024 * 1024 { fail("tmux sent an oversized protocol line.") }
    }

    private func handleLine(_ raw: Data) {
        var line = raw
        let prelude = Data("\u{1b}P1000p".utf8)
        if line.starts(with: prelude) { line.removeFirst(prelude.count) }
        if line.isEmpty {
            // Empty lines inside a command reply are data. capture-pane uses them
            // for blank screen rows, which must retain their original positions.
            if inReply { reply.append(10) }
            return
        }
        let text = String(decoding: line, as: UTF8.self)
        if inReply {
            let parts = text.split(separator: " ")
            if parts.count == 4, (parts[0] == "%end" || parts[0] == "%error"),
               "\(parts[1]) \(parts[2]) \(parts[3])" == replyID {
                let success = parts[0] == "%end"
                inReply = false
                replyID = nil
                if !pending.isEmpty { pending.removeFirst()(reply, success) }
            } else {
                reply.append(line)
                reply.append(10)
            }
        } else if line.starts(with: Data("%begin ".utf8)) {
            inReply = true
            reply.removeAll(keepingCapacity: true)
            replyID = text.dropFirst(7).description
        } else if line.starts(with: Data("%output ".utf8)) {
            routeOutput(line, offset: 8)
        } else if line.starts(with: Data("%extended-output ".utf8)) {
            if let colon = line.range(of: Data(" : ".utf8)) {
                let header = String(decoding: line[..<colon.lowerBound], as: UTF8.self)
                let pane = header.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                if validID(pane, prefix: "%") { onOutput?(pane, decodeOctal(Data(line[colon.upperBound...]))) }
            }
        } else {
            if text.hasPrefix("%session-changed ") {
                if !connected {
                    connected = true
                    timeout?.cancel()
                    onStatus?(.connected, nil)
                }
                refreshWindows()
            } else if text.hasPrefix("%window-") || text.hasPrefix("%unlinked-window-") ||
                        text.hasPrefix("%sessions-changed") || text.hasPrefix("%session-renamed") ||
                        text.hasPrefix("%window-pane-changed") || text.hasPrefix("%layout-change") {
                refreshWindows()
            } else if text.hasPrefix("%exit") {
                fail("tmux control client exited.")
            }
        }
    }

    private func routeOutput(_ line: Data, offset: Int) {
        guard let space = line[offset...].firstIndex(of: 32) else { return }
        let pane = String(decoding: line[offset..<space], as: UTF8.self)
        guard validID(pane, prefix: "%") else { return }
        onOutput?(pane, decodeOctal(Data(line[(space + 1)...])))
    }

    private func decodeOctal(_ source: Data) -> Data {
        let bytes = [UInt8](source)
        var output = Data()
        output.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == 92, i + 3 < bytes.count,
               (48...55).contains(bytes[i+1]), (48...55).contains(bytes[i+2]), (48...55).contains(bytes[i+3]) {
                output.append((bytes[i+1]-48)*64 + (bytes[i+2]-48)*8 + (bytes[i+3]-48))
                i += 4
            } else {
                output.append(bytes[i])
                i += 1
            }
        }
        return output
    }

    private func validID(_ value: String, prefix: Character) -> Bool {
        value.first == prefix && value.count > 1 && value.dropFirst().utf8.allSatisfy { (48...57).contains($0) }
    }

    private func receiveError(_ bytes: Data) {
        guard !bytes.isEmpty, errorBuffer.count < 4096 else { return }
        errorBuffer.append(bytes.prefix(4096 - errorBuffer.count))
    }

    private func didExit(code: Int32) {
        guard !stopped else { return }
        let detail = String(decoding: errorBuffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        fail(detail.isEmpty ? "SSH or tmux exited (status \(code))." : detail)
    }

    private func fail(_ message: String) {
        guard !stopped else { return }
        stopped = true
        timeout?.cancel()
        if process?.isRunning == true { process?.terminate() }
        closeInput()
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        onStatus?(.failed, message)
    }
}
