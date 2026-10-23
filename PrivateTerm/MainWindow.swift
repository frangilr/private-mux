import AppKit
import SwiftUI

private enum AppPalette {
    static let terminal = Color(white: 30.0 / 255.0) // #1E1E1E
    static let sidebar = Color(white: 25.0 / 255.0) // #191919
    static let divider = Color(white: 49.0 / 255.0)
    static let text = Color(red: 225.0 / 255.0, green: 220.0 / 255.0, blue: 220.0 / 255.0) // #E1DCDC
    static let heading = Color(red: 236.0 / 255.0, green: 232.0 / 255.0, blue: 232.0 / 255.0)
    static let tab = Color(red: 198.0 / 255.0, green: 194.0 / 255.0, blue: 194.0 / 255.0)
    static let muted = Color(white: 153.0 / 255.0)
    static let selection = Color(white: 42.0 / 255.0)
    #if PRIVATE_TERM_ACTIVITY_DOTS
    static let activity = Color(red: 109.0 / 255.0, green: 169.0 / 255.0, blue: 245.0 / 255.0)
    #endif
}

@MainActor
final class Workspace: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: UUID?

    init() { addSession() }

    func addSession() {
        let session = TerminalSession(title: "Terminal \(sessions.count + 1)")
        sessions.append(session)
        selectedID = session.id
    }

    func select(_ session: TerminalSession) {
        selectedID = session.id
        session.fitAndFocus()
    }

    func close(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        session.stop()
        sessions.remove(at: index)
        if selectedID == session.id {
            selectedID = sessions.isEmpty ? nil : sessions[min(index, sessions.count - 1)].id
            if let selected = sessions.first(where: { $0.id == selectedID }) {
                selected.fitAndFocus()
            }
        }
    }

    func rename(_ session: TerminalSession, to newName: String) {
        objectWillChange.send()
        session.title = newName
    }

    func stopAll() {
        for session in sessions { session.stop() }
        sessions.removeAll()
        selectedID = nil
    }
}

struct MainWindow: View {
    private enum NavigationTarget {
        case local(TerminalSession)
        case remote(RemoteWindow)
    }

    @ObservedObject var settings: SSHSettings
    @StateObject private var workspace = Workspace()
    @StateObject private var remote = RemoteTmuxManager()
    @StateObject private var remoteTerminal = RemoteTerminalView()
    @State private var selectedRemoteID: String?
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var arrowShortcutMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 200)
            Rectangle()
                .fill(AppPalette.divider)
                .frame(width: 1)
            ZStack {
                AppPalette.terminal
                ForEach(workspace.sessions) { session in
                    TerminalSurface(session: session)
                        .opacity(selectedRemoteID == nil && workspace.selectedID == session.id ? 1 : 0)
                        .allowsHitTesting(selectedRemoteID == nil && workspace.selectedID == session.id)
                        .accessibilityHidden(selectedRemoteID != nil || workspace.selectedID != session.id)
                }
                RemoteTerminalSurface(terminal: remoteTerminal)
                    .opacity(selectedRemoteID == nil ? 0 : 1)
                    .allowsHitTesting(selectedRemoteID != nil)
                    .accessibilityHidden(selectedRemoteID == nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onReceive(NotificationCenter.default.publisher(for: .createTerminal)) { _ in
            workspace.addSession()
            selectedRemoteID = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateTerminal)) { notification in
            guard let request = notification.userInfo?["request"] as? TerminalNavigation else { return }
            switch request {
            case let .move(direction, acrossHosts): moveSelection(direction, acrossHosts: acrossHosts)
            case .local:
                if let first = workspace.sessions.first { select(.local(first)) }
            case let .host(number):
                selectHost(number)
            }
        }
        .onChange(of: workspace.selectedID) { _, newID in
            if let session = workspace.sessions.first(where: { $0.id == newID }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    session.fitAndFocus()
                }
            }
        }
        .onChange(of: selectedRemoteID) { _, newID in
            #if PRIVATE_TERM_ACTIVITY_DOTS
            remote.showWindow(newID)
            #endif
            if newID != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    remoteTerminal.focus()
                }
            }
        }
        .onReceive(remote.$hosts) { hosts in
            guard let id = selectedRemoteID else { return }
            if let window = hosts.values.flatMap(\.windows).first(where: { $0.id == id }) {
                if remoteTerminal.selected?.paneID != window.paneID { remoteTerminal.select(window) }
            } else if hosts.values.allSatisfy({ $0.status != .connecting }) {
                selectedRemoteID = nil
                workspace.selectedID = workspace.sessions.first?.id
            }
        }
        .onAppear {
            arrowShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                guard event.window?.title == "PrivateMux",
                      modifiers == .command || modifiers == [.command, .shift] else { return event }
                let direction: Int
                switch event.keyCode {
                case 126: direction = -1 // Up arrow
                case 125: direction = 1  // Down arrow
                default: return event
                }
                NotificationCenter.default.post(
                    name: .navigateTerminal, object: nil,
                    userInfo: ["request": TerminalNavigation.move(direction, acrossHosts: modifiers.contains(.shift))]
                )
                return nil
            }
            let terminal = remoteTerminal
            remoteTerminal.onSelect = { window, columns, rows in
                remote.select(window, columns: columns, rows: rows)
            }
            remoteTerminal.onInput = { window, bytes in remote.send(bytes, to: window) }
            remote.onPaneOutput = { [weak terminal] host, pane, bytes in
                terminal?.append(bytes, hostID: host, paneID: pane)
            }
            remote.onPaneSnapshot = { [weak terminal] host, pane, bytes in
                terminal?.snapshot(bytes, hostID: host, paneID: pane)
            }
            remote.apply(settings)
        }
        .onChange(of: settings.sshEnabled) { _, _ in remote.apply(settings) }
        .onChange(of: settings.hosts) { _, _ in remote.apply(settings) }
        .onDisappear {
            if let arrowShortcutMonitor { NSEvent.removeMonitor(arrowShortcutMonitor) }
            arrowShortcutMonitor = nil
            remote.stopAll()
            remoteTerminal.stop()
            workspace.stopAll()
        }
    }

    private var navigationGroups: [[NavigationTarget]] {
        var groups: [[NavigationTarget]] = []
        if !workspace.sessions.isEmpty {
            groups.append(workspace.sessions.map { .local($0) })
        }
        if settings.sshEnabled {
            for host in settings.hosts where settings.isEnabled(host) && !settings.isCollapsed(host) {
                let windows = remote.hosts[host.id]?.windows ?? []
                if !windows.isEmpty {
                    groups.append(orderedRemoteWindows(windows).map { .remote($0) })
                }
            }
        }
        return groups
    }

    private func moveSelection(_ direction: Int, acrossHosts: Bool) {
        let groups = navigationGroups
        guard !groups.isEmpty else { return }
        let currentGroup = groups.firstIndex { group in group.contains(where: isSelected) }
        guard let groupIndex = currentGroup,
              let itemIndex = groups[groupIndex].firstIndex(where: isSelected) else {
            select(direction > 0 ? groups[0][0] : groups[groups.count - 1].last!)
            return
        }
        let nextItem = itemIndex + direction
        if groups[groupIndex].indices.contains(nextItem) {
            select(groups[groupIndex][nextItem])
        } else if acrossHosts {
            let nextGroup = (groupIndex + direction + groups.count) % groups.count
            select(direction > 0 ? groups[nextGroup][0] : groups[nextGroup].last!)
        } else {
            select(direction > 0 ? groups[groupIndex][0] : groups[groupIndex].last!)
        }
    }

    private func isSelected(_ target: NavigationTarget) -> Bool {
        switch target {
        case let .local(session): selectedRemoteID == nil && workspace.selectedID == session.id
        case let .remote(window): selectedRemoteID == window.id
        }
    }

    private func select(_ target: NavigationTarget) {
        switch target {
        case let .local(session):
            selectedRemoteID = nil
            workspace.select(session)
        case let .remote(window):
            #if PRIVATE_TERM_ACTIVITY_DOTS
            remote.showWindow(window.id)
            #endif
            selectedRemoteID = window.id
            workspace.selectedID = nil
            remoteTerminal.select(window)
        }
    }

    private func selectHost(_ number: Int) {
        guard settings.sshEnabled else { return }
        let enabledHosts = settings.hosts.filter { settings.isEnabled($0) }
        guard enabledHosts.indices.contains(number - 1) else { return }
        let host = enabledHosts[number - 1]
        let windows = orderedRemoteWindows(remote.hosts[host.id]?.windows ?? [])
        guard let window = windows.first(where: { $0.sessionName == "PrivateTerm" && $0.name == "bash" })
                ?? windows.first else { return }
        if settings.isCollapsed(host) { settings.toggleCollapsed(host) }
        select(.remote(window))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TERMINALS")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(AppPalette.muted)
                Spacer()
                Button {
                    workspace.addSession()
                    selectedRemoteID = nil
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppPalette.muted)
                .help("New terminal (⌘T)")
                .accessibilityLabel("New terminal")
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)
            .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(workspace.sessions) { session in
                        sessionRow(session)
                    }
                    if settings.sshEnabled {
                        ForEach(settings.hosts.filter { settings.isEnabled($0) }) { host in
                            hostGroup(host)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Settings")
                .accessibilityLabel("Settings")
                Spacer()
                Image(systemName: "lock.shield")
            }
            .font(.caption2)
            .foregroundStyle(AppPalette.muted)
            .padding(13)
        }
        .background(AppPalette.sidebar)
        .alert("Rename Terminal", isPresented: Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Save") {
                if let id = renamingID,
                   let session = workspace.sessions.first(where: { $0.id == id }),
                   !renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    workspace.rename(session, to: renameText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                renamingID = nil
            }
            Button("Cancel", role: .cancel) { renamingID = nil }
        }
    }

    private func sessionRow(_ session: TerminalSession) -> some View {
        let selected = selectedRemoteID == nil && workspace.selectedID == session.id
        return HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(selected ? AppPalette.text : AppPalette.muted)
                .frame(width: 16)
            Text(session.title)
                .font(.system(size: 12.5))
                .foregroundStyle(selected ? AppPalette.text : AppPalette.tab)
                .lineLimit(1)
            Spacer(minLength: 0)
            if selected {
                Button { workspace.close(session) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AppPalette.muted)
                .help("Close terminal")
                .accessibilityLabel("Close \(session.title)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? AppPalette.selection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRemoteID = nil
            workspace.select(session)
        }
        .contextMenu {
            Button("Rename") {
                renameText = session.title
                renamingID = session.id
            }
            Button("Close") { workspace.close(session) }
        }
    }

    private func hostGroup(_ host: SSHHost) -> some View {
        let snapshot = remote.hosts[host.id] ?? RemoteHostSnapshot()
        let collapsed = settings.isCollapsed(host)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Button { settings.toggleCollapsed(host) } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppPalette.muted)
                        .frame(width: 12, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("\(collapsed ? "Expand" : "Collapse") \(host.name) terminals")
                .accessibilityLabel("\(collapsed ? "Expand" : "Collapse") \(host.name) terminals")
                Circle()
                    .fill(statusColor(snapshot.status))
                    .frame(width: 7, height: 7)
                Text(host.name.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(AppPalette.heading)
                Spacer()
                #if PRIVATE_TERM_ACTIVITY_DOTS
                if collapsed && remote.hasUnread(in: host) {
                    activityDot
                        .accessibilityLabel("New output on \(host.name)")
                }
                #endif
                Button { remote.reconnect(host) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(AppPalette.muted)
                }
                .buttonStyle(.borderless)
                .disabled(snapshot.status == .disabled || snapshot.status == .connecting)
                .help("Reconnect \(host.name)")
                .accessibilityLabel("Reconnect \(host.name)")
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            Text(snapshot.status.rawValue.capitalized)
                .font(.caption2)
                .foregroundStyle(AppPalette.muted)
                .padding(.leading, 23)
                .help(snapshot.message ?? snapshot.status.rawValue.capitalized)
            if !collapsed {
                ForEach(orderedRemoteWindows(snapshot.windows)) { window in
                    Button {
                        #if PRIVATE_TERM_ACTIVITY_DOTS
                        remote.showWindow(window.id)
                        #endif
                        selectedRemoteID = window.id
                        workspace.selectedID = nil
                        remoteTerminal.select(window)
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(window.sessionName): \(window.name)")
                                .font(.system(size: 12.5))
                                .foregroundStyle(selectedRemoteID == window.id ? AppPalette.text : AppPalette.tab)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            #if PRIVATE_TERM_ACTIVITY_DOTS
                            if remote.unreadWindowIDs.contains(window.id) { activityDot }
                            #endif
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 23)
                        .padding(.trailing, 10)
                        .frame(height: 32)
                        .background(selectedRemoteID == window.id ? AppPalette.selection : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    #if PRIVATE_TERM_ACTIVITY_DOTS
                    .accessibilityValue(remote.unreadWindowIDs.contains(window.id) ? "New output" : "")
                    #endif
                    .help("\(host.name) / \(window.sessionName) / \(window.name)")
                }
            }
        }
    }

    #if PRIVATE_TERM_ACTIVITY_DOTS
    private var activityDot: some View {
        Circle()
            .fill(AppPalette.activity)
            .frame(width: 6, height: 6)
    }
    #endif

    private func orderedRemoteWindows(_ windows: [RemoteWindow]) -> [RemoteWindow] {
        func priority(_ window: RemoteWindow) -> Int {
            if window.sessionName == "PrivateTerm" && window.name == "bash" { return 0 }
            if window.sessionName == "PrivateTerm" { return 1 }
            return 2
        }
        return windows.enumerated().sorted { left, right in
            let leftPriority = priority(left.element)
            let rightPriority = priority(right.element)
            return leftPriority == rightPriority
                ? left.offset < right.offset
                : leftPriority < rightPriority
        }.map(\.element)
    }

    private func statusColor(_ status: SSHConnectionStatus) -> Color {
        switch status {
        case .connected: .green
        case .connecting: .yellow
        case .disconnected: .gray
        case .failed: .red
        case .disabled: .secondary
        }
    }
}

struct SSHSettingsView: View {
    @ObservedObject var settings: SSHSettings

    var body: some View {
        Form {
            Toggle("Connect to SSH servers automatically", isOn: $settings.sshEnabled)
            ForEach(settings.hosts) { host in
                HStack {
                    Toggle(host.name, isOn: Binding(
                        get: { settings.isEnabled(host) },
                        set: { settings.setEnabled($0, for: host) }
                    ))
                    Spacer()
                    Text(host.destination)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Button("Edit") { draft = host }
                    Button("Remove", role: .destructive) { settings.remove(host) }
                }
            }
            Button("Add Server") {
                draft = SSHHost(name: "", username: NSUserName(), hostname: "")
            }
            if settings.hosts.isEmpty {
                Text("No SSH servers configured. Local terminals are ready to use.")
                    .foregroundStyle(.secondary)
            }
            Text("Automatic connections use your macOS SSH agent and SSH config. PrivateMux does not save keys or passwords.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 650)
        .sheet(item: $draft) { host in
            SSHHostEditor(host: host) { saved in
                settings.save(saved)
                draft = nil
            } onCancel: {
                draft = nil
            }
        }
    }

    @State private var draft: SSHHost?
}

private struct SSHHostEditor: View {
    @State var host: SSHHost
    let onSave: (SSHHost) -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            TextField("Name", text: $host.name)
            TextField("Username", text: $host.username)
            TextField("Host or SSH alias", text: $host.hostname)
            Text("Uses your existing macOS SSH keys, agent, and SSH configuration.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(host) }
                    .disabled(!host.isValid)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
