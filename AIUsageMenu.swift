import AppKit
import Foundation
import UserNotifications

private struct QuotaWindow {
    let remaining: Double
    let durationMinutes: Int
    let resetDate: Date?

    init?(_ value: Any?) {
        guard let data = value as? [String: Any],
              let used = data["usedPercent"] as? Double else { return nil }
        remaining = max(0, min(100, 100 - used))
        durationMinutes = data["windowDurationMins"] as? Int ?? 0
        if let seconds = data["resetsAt"] as? Double {
            resetDate = Date(timeIntervalSince1970: seconds)
        } else {
            resetDate = nil
        }
    }

    var period: String {
        if durationMinutes == 10_080 { return "7-day" }
        if durationMinutes > 0 && durationMinutes % 60 == 0 { return "\(durationMinutes / 60)-hour" }
        return "\(durationMinutes)-minute"
    }

    var remainingText: String { String(format: "%.0f%%", remaining) }

    var compactPeriod: String {
        if durationMinutes == 10_080 { return "7d" }
        if durationMinutes > 0 && durationMinutes % 60 == 0 { return "\(durationMinutes / 60)h" }
        return "\(durationMinutes)m"
    }

    var resetText: String {
        guard let resetDate else { return "Reset time unavailable" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return "Resets \(formatter.string(from: resetDate))"
    }
}

private struct ResetCreditExpiry {
    let id: String
    let date: Date

    init?(_ data: [String: Any]) {
        guard let id = data["id"] as? String,
              let seconds = data["expiresAt"] as? Double else { return nil }
        self.id = id
        date = Date(timeIntervalSince1970: seconds)
    }

    var formattedDate: String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    func expiresSoon(at now: Date) -> Bool {
        let remaining = date.timeIntervalSince(now)
        return remaining > 0 && remaining <= 24 * 60 * 60
    }
}

private struct UsageSnapshot {
    let windows: [QuotaWindow]
    let resetCreditsAvailable: Int?
    let resetCreditExpiries: [ResetCreditExpiry]
}

private struct Provider {
    let id: String
    let name: String
    let labelLetters: [String]
    let script: String
    let hasResetCredits: Bool

    var enabledKey: String { "\(id)Enabled" }

    static let codex = Provider(id: "codex", name: "Codex", labelLetters: ["G", "P", "T"],
                                script: "codex_usage", hasResetCredits: true)
    static let claude = Provider(id: "claude", name: "Claude", labelLetters: ["C", "L", "A"],
                                 script: "claude_usage", hasResetCredits: false)
    static let all = [codex, claude]
}

private enum ProviderState {
    case loading
    case loaded(UsageSnapshot)
    case failed(String)
}

private final class UsageApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let resetCreditAlertsKey = "sentResetCreditExpiryAlerts"
    private static let alertsEnabledKey = "resetCreditAlertsEnabled"
    private static let valueAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.black
    ]
    private static let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 6.5, weight: .medium), .foregroundColor: NSColor.black
    ]
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let notifications = UNUserNotificationCenter.current()
    private var sentResetCreditAlerts =
        UserDefaults.standard.dictionary(forKey: resetCreditAlertsKey) as? [String: Date] ?? [:]
    private var pendingResetCreditAlerts: Set<String> = []
    private var states: [String: ProviderState] = [:]
    private var refreshing: Set<String> = []
    private var timer: Timer?

    private var enabledProviders: [Provider] {
        Provider.all.filter { UserDefaults.standard.bool(forKey: $0.enabledKey) }
    }

    private var alertsEnabled: Bool { UserDefaults.standard.bool(forKey: Self.alertsEnabledKey) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var defaults: [String: Any] = [Self.alertsEnabledKey: true]
        for provider in Provider.all { defaults[provider.enabledKey] = true }
        UserDefaults.standard.register(defaults: defaults)
        notifications.delegate = self
        notifications.requestAuthorization(options: [.alert]) { _, error in
            if let error {
                NSLog("Could not request reset credit alert permission: %@", error.localizedDescription)
            }
        }
        refreshNow()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refreshNow()
        }
    }

    @objc private func refreshNow() {
        refresh(enabledProviders)
    }

    private func refresh(_ providers: [Provider]) {
        for provider in providers where refreshing.insert(provider.id).inserted {
            if states[provider.id] == nil { states[provider.id] = .loading }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = Self.readUsage(provider)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshing.remove(provider.id)
                    guard UserDefaults.standard.bool(forKey: provider.enabledKey) else { return }
                    switch result {
                    case let .success(usage):
                        self.states[provider.id] = .loaded(usage)
                        self.checkResetCreditExpiries(usage.resetCreditExpiries, for: provider)
                    case let .failure(error):
                        self.states[provider.id] = .failed(error.localizedDescription)
                    }
                    self.render()
                }
            }
        }
        render()
    }

    @objc private func toggleProvider(_ sender: NSMenuItem) {
        let provider = Provider.all[sender.tag]
        let enabled = !UserDefaults.standard.bool(forKey: provider.enabledKey)
        UserDefaults.standard.set(enabled, forKey: provider.enabledKey)
        if enabled {
            refresh([provider])
        } else {
            states[provider.id] = nil
            render()
        }
    }

    @objc private func toggleAlerts() {
        UserDefaults.standard.set(!alertsEnabled, forKey: Self.alertsEnabledKey)
        if alertsEnabled {
            for provider in enabledProviders {
                if case let .loaded(usage) = states[provider.id] {
                    checkResetCreditExpiries(usage.resetCreditExpiries, for: provider)
                }
            }
        }
        render()
    }

    private func checkResetCreditExpiries(_ expiries: [ResetCreditExpiry], for provider: Provider) {
        guard alertsEnabled else { return }
        let now = Date()
        let expiring = expiries.filter { $0.expiresSoon(at: now) && sentResetCreditAlerts[$0.id] == nil }
        guard !expiring.isEmpty else { return }

        notifications.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized else { return }
            DispatchQueue.main.async {
                self?.sendResetCreditAlerts(for: expiring, provider: provider)
            }
        }
    }

    private func sendResetCreditAlerts(for expiries: [ResetCreditExpiry], provider: Provider) {
        let now = Date()
        for expiry in expiries {
            guard expiry.expiresSoon(at: now), sentResetCreditAlerts[expiry.id] == nil,
                  pendingResetCreditAlerts.insert(expiry.id).inserted else { continue }

            let content = Self.resetCreditAlert(for: provider, expiry: expiry.formattedDate)
            let request = UNNotificationRequest(identifier: expiry.id, content: content, trigger: nil)
            notifications.add(request) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pendingResetCreditAlerts.remove(expiry.id)
                    if let error {
                        NSLog("Could not send reset credit alert: %@", error.localizedDescription)
                        return
                    }
                    let now = Date()
                    self.sentResetCreditAlerts = self.sentResetCreditAlerts.filter { $0.value > now }
                    self.sentResetCreditAlerts[expiry.id] = expiry.date
                    UserDefaults.standard.set(self.sentResetCreditAlerts, forKey: Self.resetCreditAlertsKey)
                }
            }
        }
    }

    private static func resetCreditAlert(for provider: Provider, expiry: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "\(provider.name) reset credit expiring soon"
        content.body = "An available reset credit expires \(expiry)."
        return content
    }

    @objc private func sendTestNotification() {
        notifications.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional:
                    self.postTestNotification()
                case .notDetermined:
                    self.notifications.requestAuthorization(options: [.alert]) { granted, _ in
                        DispatchQueue.main.async {
                            if granted { self.postTestNotification() } else { self.showNotificationsOffAlert() }
                        }
                    }
                default:
                    self.showNotificationsOffAlert()
                }
            }
        }
    }

    private func postTestNotification() {
        let expiry = DateFormatter.localizedString(from: Date().addingTimeInterval(23 * 60 * 60),
                                                   dateStyle: .medium, timeStyle: .short)
        let content = Self.resetCreditAlert(for: .codex, expiry: expiry)
        content.subtitle = "Test notification"
        let request = UNNotificationRequest(identifier: "test-\(UUID().uuidString)", content: content, trigger: nil)
        notifications.add(request) { error in
            if let error {
                NSLog("Could not send test notification: %@", error.localizedDescription)
            }
        }
    }

    private func showNotificationsOffAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Notifications are off for AI Usage"
        alert.informativeText = "Allow notifications in System Settings to get reset credit alerts."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)") {
            NSWorkspace.shared.open(url)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    private static func readUsage(_ provider: Provider) -> Result<UsageSnapshot, Error> {
        do {
            guard let script = Bundle.main.path(forResource: provider.script, ofType: "py") else {
                throw UsageError("Bundled usage script is missing")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script, "--json"]
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw UsageError(message?.isEmpty == false ? message! : "Usage check failed")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let limits = json["limits"] as? [String: [String: Any]],
                  let limit = limits[provider.id] ?? limits.values.first else {
                throw UsageError("No \(provider.name) quota was returned")
            }
            let windows = [QuotaWindow(limit["primary"]), QuotaWindow(limit["secondary"])].compactMap { $0 }
            guard !windows.isEmpty else { throw UsageError("No usage windows were returned") }
            let resetCreditsAvailable = json["resetCreditsAvailable"] as? Int
            let expiryData = json["resetCreditExpiries"] as? [[String: Any]] ?? []
            return .success(UsageSnapshot(
                windows: windows,
                resetCreditsAvailable: resetCreditsAvailable,
                resetCreditExpiries: expiryData.compactMap(ResetCreditExpiry.init)
            ))
        } catch {
            return .failure(error)
        }
    }

    private func setStatusTitle(_ title: String) {
        item.length = NSStatusItem.variableLength
        item.button?.image = nil
        item.button?.attributedTitle = NSAttributedString(string: "")
        item.button?.title = title
        item.button?.toolTip = title
        item.button?.setAccessibilityLabel(title)
    }

    private static func drawLabel(_ letters: [NSAttributedString], width: CGFloat) {
        for (index, letter) in letters.enumerated() {
            let size = letter.size()
            letter.draw(at: NSPoint(x: (width - size.width) / 2,
                                    y: 11 - size.height / 2 + CGFloat(1 - index) * 7))
        }
    }

    private func statusImage(for provider: Provider, windows: [QuotaWindow], nextReset: Date?) -> NSImage {
        let valueAttributes = Self.valueAttributes
        let periods = windows.map { NSAttributedString(string: $0.compactPeriod, attributes: valueAttributes) }
        let values = windows.map { NSAttributedString(string: $0.remainingText, attributes: valueAttributes) }
        let letters = provider.labelLetters.map { NSAttributedString(string: $0, attributes: Self.labelAttributes) }
        let labelWidth = ceil(letters.map { $0.size().width }.max() ?? 0)
        let periodWidth = ceil(periods.map { $0.size().width }.max() ?? 0)
        let valueWidth = ceil(NSAttributedString(string: "100%", attributes: valueAttributes).size().width)
        let resetParts: [NSAttributedString]
        if let nextReset {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            resetParts = formatter.string(from: nextReset).components(separatedBy: ":").map {
                NSAttributedString(string: $0, attributes: valueAttributes)
            }
        } else {
            resetParts = []
        }
        let periodX = labelWidth + 2
        let valueX = periodX + periodWidth + 2
        let resetIcon = resetParts.isEmpty ? nil : NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Next reset")
        let resetIconX = valueX + valueWidth + 4
        let resetX = resetIconX + (resetIcon == nil ? 0 : 11)
        let resetWidth = ceil(resetParts.map { $0.size().width }.max() ?? 0)
        let width = resetParts.isEmpty ? valueX + valueWidth : resetX + resetWidth
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            Self.drawLabel(letters, width: labelWidth)
            for index in windows.indices {
                let centerY: CGFloat = windows.count == 1 ? 11 : (index == 0 ? 16 : 6)
                let periodSize = periods[index].size()
                let valueSize = values[index].size()
                periods[index].draw(at: NSPoint(x: periodX + periodWidth - periodSize.width,
                                               y: centerY - periodSize.height / 2))
                values[index].draw(at: NSPoint(x: valueX + (valueWidth - valueSize.width) / 2,
                                              y: centerY - valueSize.height / 2))
            }
            resetIcon?.draw(in: NSRect(x: resetIconX, y: 6.5, width: 9, height: 9))
            for (index, part) in resetParts.enumerated() {
                let size = part.size()
                let centerY: CGFloat = index == 0 ? 16 : 6
                part.draw(at: NSPoint(x: resetX + (resetWidth - size.width) / 2,
                                     y: centerY - size.height / 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func placeholderImage(for provider: Provider, text: String) -> NSImage {
        let letters = provider.labelLetters.map { NSAttributedString(string: $0, attributes: Self.labelAttributes) }
        let mark = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.black
        ])
        let labelWidth = ceil(letters.map { $0.size().width }.max() ?? 0)
        let markSize = mark.size()
        let image = NSImage(size: NSSize(width: labelWidth + 3 + ceil(markSize.width), height: 22), flipped: false) { _ in
            Self.drawLabel(letters, width: labelWidth)
            mark.draw(at: NSPoint(x: labelWidth + 3, y: 11 - markSize.height / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    private func combinedImage(_ parts: [NSImage]) -> NSImage {
        let gap: CGFloat = 10
        let width = parts.reduce(0) { $0 + $1.size.width } + gap * CGFloat(parts.count - 1)
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                part.draw(at: NSPoint(x: x, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
                x += part.size.width + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func render() {
        let providers = enabledProviders
        let now = Date()
        let menu = NSMenu()
        menu.minimumWidth = 270
        var images: [NSImage] = []
        var descriptions: [String] = []
        for provider in providers {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            addInformation(NSAttributedString(string: "\(provider.name) Usage", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]), to: menu)
            switch states[provider.id] ?? .loading {
            case .loading:
                images.append(placeholderImage(for: provider, text: "…"))
                descriptions.append("\(provider.name): checking usage.")
                addDetail("Checking usage…", to: menu)
            case let .failed(message):
                images.append(placeholderImage(for: provider, text: "⚠︎"))
                descriptions.append("\(provider.name): \(message)")
                addDetail(message, to: menu)
            case let .loaded(usage):
                let nextReset = usage.windows.compactMap { window -> (window: QuotaWindow, date: Date)? in
                    guard let date = window.resetDate, date > now else { return nil }
                    return (window, date)
                }.min { $0.date < $1.date }
                images.append(statusImage(for: provider, windows: usage.windows, nextReset: nextReset?.date))
                var description = "\(provider.name) Usage. "
                if let nextReset {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .short
                    description += "Next reset: \(nextReset.window.period), \(formatter.string(from: nextReset.date)). "
                }
                description += usage.windows.map {
                    "\($0.period): \($0.remainingText) remaining. \($0.resetText)"
                }.joined(separator: ". ")
                descriptions.append(description)
                addUsage(usage, of: provider, to: menu, now: now)
            }
        }
        if providers.isEmpty {
            setStatusTitle("AI Usage")
            addDetail("No services tracked. Turn one on in Settings.", to: menu)
        } else {
            let image = combinedImage(images)
            item.length = image.size.width + 8
            item.button?.title = ""
            item.button?.attributedTitle = NSAttributedString(string: "")
            item.button?.image = image
            let description = descriptions.joined(separator: "\n")
            item.button?.toolTip = description
            item.button?.setAccessibilityLabel(description)
        }
        addActions(to: menu)
        item.menu = menu
    }

    private func addUsage(_ usage: UsageSnapshot, of provider: Provider, to menu: NSMenu, now: Date) {
        for window in usage.windows {
            let rowParagraph = NSMutableParagraphStyle()
            rowParagraph.tabStops = [NSTextTab(textAlignment: .right, location: 230)]
            let row = NSMutableAttributedString(string: "\(window.period)\t\(window.remainingText) left", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: rowParagraph
            ])
            let valueRange = (row.string as NSString).range(of: "\(window.remainingText) left")
            row.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: valueRange)
            addInformation(row, to: menu)
            addDetail(window.resetText, to: menu)
        }
        guard provider.hasResetCredits else { return }
        let resetCreditsText: String
        if let count = usage.resetCreditsAvailable {
            let creditLabel = count == 1 ? "reset credit" : "reset credits"
            resetCreditsText = "\(count) \(creditLabel) available"
        } else {
            resetCreditsText = "Reset credit count unavailable"
        }
        addInformation(NSAttributedString(string: resetCreditsText, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]), to: menu)
        let upcomingExpiries = usage.resetCreditExpiries.filter { $0.date > now }.sorted { $0.date < $1.date }
        for expiry in upcomingExpiries {
            addDetail("Expires \(expiry.formattedDate)", to: menu)
        }
    }

    private func addDetail(_ text: String, to menu: NSMenu) {
        addInformation(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]), to: menu)
    }

    private func addInformation(_ text: NSAttributedString, to menu: NSMenu) {
        // A label view preserves semantic colors instead of disabled-item dimming.
        let label = NSTextField(labelWithAttributedString: text)
        let size = label.fittingSize
        let width = max(270, size.width + 28)
        let height = max(22, size.height + 6)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        label.frame = NSRect(x: 14, y: (height - size.height) / 2, width: width - 28, height: size.height)
        label.autoresizingMask = [.width]
        view.addSubview(label)
        let information = NSMenuItem(title: text.string, action: nil, keyEquivalent: "")
        information.isEnabled = false
        information.view = view
        menu.addItem(information)
    }

    private func addActions(to menu: NSMenu) {
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = settingsMenu()
        menu.addItem(settingsItem)
        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "Quit AI Usage", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func settingsMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, provider) in Provider.all.enumerated() {
            let toggle = NSMenuItem(title: "Track \(provider.name)", action: #selector(toggleProvider), keyEquivalent: "")
            toggle.target = self
            toggle.tag = index
            toggle.state = UserDefaults.standard.bool(forKey: provider.enabledKey) ? .on : .off
            menu.addItem(toggle)
        }
        menu.addItem(.separator())
        let alerts = NSMenuItem(title: "Reset credit expiry alerts", action: #selector(toggleAlerts), keyEquivalent: "")
        alerts.target = self
        alerts.state = alertsEnabled ? .on : .off
        menu.addItem(alerts)
        let test = NSMenuItem(title: "Send test notification", action: #selector(sendTestNotification), keyEquivalent: "")
        test.target = self
        menu.addItem(test)
        return menu
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

private struct UsageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
private let delegate = UsageApp()
app.delegate = delegate
app.run()
