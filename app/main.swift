import AppKit
import UserNotifications

// Menu bar companion for the no-sleep CLI. It polls `no-sleep status` and
// mirrors the result as a status bar icon. Commands run the CLI directly;
// when a transition needs administrator authorization there is no TTY for
// sudo to prompt on, so SUDO_ASKPASS points at the bundled dialog helper.

private let pollInterval: TimeInterval = 5
private let cliCandidates = [
    NSHomeDirectory() + "/.local/bin/no-sleep",
    "/usr/local/bin/no-sleep",
    "/opt/homebrew/bin/no-sleep",
]

enum SleepState {
    case on
    case off
    case degraded
    case cliMissing
}

struct StatusSnapshot {
    let state: SleepState
    let summary: String
}

func findCLI() -> String? {
    if let override = ProcessInfo.processInfo.environment["NOSLEEP_CLI"],
       FileManager.default.isExecutableFile(atPath: override) {
        return override
    }
    for candidate in cliCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
    }
    return nil
}

func queryStatus(cliPath: String?) -> StatusSnapshot {
    guard let cliPath else {
        return StatusSnapshot(state: .cliMissing, summary: "no-sleep CLI not found")
    }

    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: cliPath)
    process.arguments = ["status"]
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return StatusSnapshot(state: .degraded, summary: "no-sleep: failed to run status")
    }
    process.waitUntilExit()

    let data = output.fileHandleForReading.readDataToEndOfFile()
    let firstLine = String(data: data, encoding: .utf8)?
        .split(separator: "\n").first.map(String.init) ?? ""
    let fallback: String
    let state: SleepState
    switch process.terminationStatus {
    case 0:
        state = .on
        fallback = "no-sleep: on"
    case 1:
        state = .off
        fallback = "no-sleep: off"
    default:
        state = .degraded
        fallback = "no-sleep: degraded"
    }
    return StatusSnapshot(state: state, summary: firstLine.isEmpty ? fallback : firstLine)
}

final class StatusBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cliPath = findCLI()
    private var snapshot = StatusSnapshot(state: .degraded, summary: "no-sleep: checking…")
    private var refreshing = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        applyIcon()
        refresh()
        Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func applyIcon() {
        let symbolName: String
        switch snapshot.state {
        case .on: symbolName = "cup.and.saucer.fill"
        case .off: symbolName = "cup.and.saucer"
        case .degraded: symbolName = "exclamationmark.triangle"
        case .cliMissing: symbolName = "questionmark.circle"
        }
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "no-sleep")
        button.image?.isTemplate = true
        button.toolTip = snapshot.summary
    }

    private func addItem(to menu: NSMenu, title: String, action: Selector?, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        // Re-resolve on every poll: the CLI may have been installed (or
        // removed) after the app launched.
        cliPath = findCLI()
        let path = cliPath
        DispatchQueue.global(qos: .utility).async {
            let result = queryStatus(cliPath: path)
            DispatchQueue.main.async {
                self.snapshot = result
                self.refreshing = false
                self.applyIcon()
            }
        }
    }

    @objc private func turnOn() { runCLI("on") }
    @objc private func turnOff() { runCLI("off") }
    @objc private func quit() { NSApp.terminate(nil) }

    // Runs the CLI directly. Power transitions may need administrator
    // authorization: with no TTY, sudo falls back to SUDO_ASKPASS, the
    // bundled helper that shows a GUI password dialog. Failures surface in
    // an alert with the CLI's own output; success is reflected by the icon.
    private func runCLI(_ argument: String) {
        guard let cliPath,
              let askpass = Bundle.main.path(forResource: "no-sleep-askpass", ofType: nil) else {
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = [argument]
            var environment = ProcessInfo.processInfo.environment
            environment["SUDO_ASKPASS"] = askpass
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
            } catch {
                DispatchQueue.main.async {
                    self.showFailure("failed to launch \(cliPath): \(error.localizedDescription)")
                }
                return
            }
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = process.terminationStatus
            DispatchQueue.main.async {
                self.refresh()
                if status == 0 {
                    let firstLine = text.split(separator: "\n").first.map(String.init)
                    self.notify(firstLine ?? "no-sleep \(argument) succeeded")
                } else {
                    self.showFailure(text.isEmpty ? "no-sleep \(argument) exited with status \(status)" : text)
                }
            }
        }
    }

    // Transient success confirmation; failures use the modal alert instead.
    private func notify(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "no-sleep"
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func showFailure(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "no-sleep command failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

extension StatusBarController: UNUserNotificationCenterDelegate {
    // Show banners even when the app is frontmost; it usually is not, but the
    // menu click can make it the active app.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

extension StatusBarController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addItem(to: menu, title: snapshot.summary, action: nil, enabled: false)
        if snapshot.state == .cliMissing {
            addItem(to: menu, title: "install the CLI with: make install", action: nil, enabled: false)
        }
        menu.addItem(.separator())
        addItem(to: menu, title: "Turn Sleep Prevention On", action: #selector(turnOn), enabled: cliPath != nil)
        addItem(to: menu, title: "Turn Sleep Prevention Off", action: #selector(turnOff), enabled: cliPath != nil)
        menu.addItem(.separator())
        addItem(to: menu, title: "Refresh Now", action: #selector(refresh))
        addItem(to: menu, title: "Quit NoSleep", action: #selector(quit), enabled: true)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = StatusBarController()
withExtendedLifetime(controller) {
    application.run()
}
