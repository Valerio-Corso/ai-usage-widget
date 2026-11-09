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

private final class UsageApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private static let resetCreditAlertsKey = "sentResetCreditExpiryAlerts"
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let notifications = UNUserNotificationCenter.current()
    private var sentResetCreditAlerts =
        UserDefaults.standard.dictionary(forKey: resetCreditAlertsKey) as? [String: Date] ?? [:]
    private var pendingResetCreditAlerts: Set<String> = []
    private var refreshing = false
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notifications.delegate = self
        notifications.requestAuthorization(options: [.alert]) { _, error in
            if let error {
                NSLog("Could not request reset credit alert permission: %@", error.localizedDescription)
            }
        }
        setStatusTitle("Codex …")
        showMenu(message: "Checking usage…")
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Self.readUsage()
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                switch result {
                case let .success(usage):
                    self.showUsage(usage)
                    self.checkResetCreditExpiries(usage.resetCreditExpiries)
                case let .failure(error):
                    self.setStatusTitle("Codex ⚠")
                    self.showMenu(message: error.localizedDescription)
                }
            }
        }
    }

    private func checkResetCreditExpiries(_ expiries: [ResetCreditExpiry]) {
        let now = Date()
        let expiring = expiries.filter { $0.expiresSoon(at: now) && sentResetCreditAlerts[$0.id] == nil }
        guard !expiring.isEmpty else { return }

        notifications.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .authorized else { return }
            DispatchQueue.main.async {
                self?.sendResetCreditAlerts(for: expiring)
            }
        }
    }

    private func sendResetCreditAlerts(for expiries: [ResetCreditExpiry]) {
        let now = Date()
        for expiry in expiries {
            guard expiry.expiresSoon(at: now), sentResetCreditAlerts[expiry.id] == nil,
                  pendingResetCreditAlerts.insert(expiry.id).inserted else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Codex reset credit expiring soon"
            content.body = "An available reset credit expires \(expiry.formattedDate)."
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

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    private static func readUsage() -> Result<UsageSnapshot, Error> {
        do {
            guard let script = Bundle.main.path(forResource: "codex_usage", ofType: "py") else {
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
                  let codex = limits["codex"] ?? limits.values.first else {
                throw UsageError("No Codex quota was returned")
            }
            let windows = [QuotaWindow(codex["primary"]), QuotaWindow(codex["secondary"])].compactMap { $0 }
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

    private func statusImage(for windows: [QuotaWindow], nextReset: Date?) -> NSImage {
        let valueFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let labelFont = NSFont.systemFont(ofSize: 6.5, weight: .medium)
        let valueAttributes: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: NSColor.black]
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black]
        let periods = windows.map { NSAttributedString(string: $0.compactPeriod, attributes: valueAttributes) }
        let values = windows.map { NSAttributedString(string: $0.remainingText, attributes: valueAttributes) }
        let letters = ["G", "P", "T"].map { NSAttributedString(string: $0, attributes: labelAttributes) }
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
            for (index, letter) in letters.enumerated() {
                let size = letter.size()
                letter.draw(at: NSPoint(x: (labelWidth - size.width) / 2,
                                        y: 11 - size.height / 2 + CGFloat(1 - index) * 7))
            }
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

    private func showUsage(_ usage: UsageSnapshot) {
        let windows = usage.windows
        let now = Date()
        let nextReset = windows.compactMap { window -> (window: QuotaWindow, date: Date)? in
            guard let date = window.resetDate, date > now else { return nil }
            return (window, date)
        }.min { $0.date < $1.date }
        let image = statusImage(for: windows, nextReset: nextReset?.date)
        item.length = image.size.width + 8
        item.button?.title = ""
        item.button?.attributedTitle = NSAttributedString(string: "")
        item.button?.image = image
        var description = "Codex Usage. "
        if let nextReset {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            description += "Next reset: \(nextReset.window.period), \(formatter.string(from: nextReset.date)). "
        }
        description += windows.map {
            "\($0.period): \($0.remainingText) remaining. \($0.resetText)"
        }.joined(separator: ". ")
        item.button?.toolTip = description
        item.button?.setAccessibilityLabel(description)

        let menu = NSMenu()
        menu.minimumWidth = 270
        addInformation(NSAttributedString(string: "Codex Usage", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]), to: menu)
        menu.addItem(.separator())
        for window in windows {
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
            addInformation(NSAttributedString(string: window.resetText, attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]), to: menu)
        }
        let resetCreditsText: String
        if let count = usage.resetCreditsAvailable {
            let creditLabel = count == 1 ? "reset credit" : "reset credits"
            resetCreditsText = "\(count) \(creditLabel) available"
        } else {
            resetCreditsText = "Reset credit count unavailable"
        }
        menu.addItem(.separator())
        addInformation(NSAttributedString(string: resetCreditsText, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]), to: menu)
        let upcomingExpiries = usage.resetCreditExpiries.filter { $0.date > now }.sorted { $0.date < $1.date }
        for expiry in upcomingExpiries {
            addInformation(NSAttributedString(string: "Expires \(expiry.formattedDate)", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]), to: menu)
        }
        addActions(to: menu)
        item.menu = menu
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

    private func showMenu(message: String) {
        let menu = NSMenu()
        let status = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        addActions(to: menu)
        item.menu = menu
    }

    private func addActions(to menu: NSMenu) {
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "Refresh now", action: #selector(refresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let quitItem = NSMenuItem(title: "Quit Codex Usage", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
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
