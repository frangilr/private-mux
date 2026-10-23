import SwiftUI

@main
struct PrivateTermApp: App {
    @StateObject private var sshSettings = SSHSettings()

    var body: some Scene {
        Window("PrivateMux", id: "main") {
            MainWindow(settings: sshSettings)
                .frame(minWidth: 740, minHeight: 420)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Terminal") {
                    NotificationCenter.default.post(name: .createTerminal, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Previous Terminal") { navigate(.move(-1, acrossHosts: false)) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Next Terminal") { navigate(.move(1, acrossHosts: false)) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Terminal or Host") { navigate(.move(-1, acrossHosts: true)) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
                Button("Next Terminal or Host") { navigate(.move(1, acrossHosts: true)) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
                Divider()
                Button("First Local Terminal") { navigate(.local) }
                    .keyboardShortcut("0", modifiers: .command)
                ForEach(1...9, id: \.self) { number in
                    Button("SSH Host \(number)") { navigate(.host(number)) }
                        .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
                }
            }
        }
        Settings {
            SSHSettingsView(settings: sshSettings)
                .preferredColorScheme(.dark)
        }
    }

    private func navigate(_ request: TerminalNavigation) {
        NotificationCenter.default.post(name: .navigateTerminal, object: nil, userInfo: ["request": request])
    }
}

enum TerminalNavigation {
    case move(Int, acrossHosts: Bool)
    case local
    case host(Int)
}

extension Notification.Name {
    static let createTerminal = Notification.Name("PrivateTerm.CreateTerminal")
    static let navigateTerminal = Notification.Name("PrivateTerm.NavigateTerminal")
}
