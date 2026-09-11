import Cocoa
import SwiftUI
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

extension Notification.Name {
    static let autoQuitMenuBarVisibilityChanged = Notification.Name("autoQuitMenuBarVisibilityChanged")
}

// MARK: - State & Settings management
class AppState: ObservableObject {
    @AppStorage("isPaused") var isPaused: Bool = false
    @AppStorage("delaySeconds") var delaySeconds: Double = 1.5
    @AppStorage("filterMode") var filterMode: String = "blacklist"
    @AppStorage("hideMenuBarIcon") var hideMenuBarIcon: Bool = false {
        didSet { NotificationCenter.default.post(name: .autoQuitMenuBarVisibilityChanged, object: nil) }
    }
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet { configureLaunchAtLogin(launchAtLogin) }
    }

    /// Important system apps — cannot be removed from the Blacklist,
    /// because excluding them would allow them to be auto-quit and could harm the system.
    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.ActivityMonitor",
        "com.apple.AppStore",
        "com.apple.DiskUtility"
    ]

    /// List used in Blacklist mode (exclusion — these apps are NEVER auto-quit).
    @Published private var blacklistApps: [String] {
        didSet { UserDefaults.standard.set(blacklistApps, forKey: "blacklistAppList") }
    }

    /// List used in Whitelist mode (inclusion — ONLY these apps get auto-quit).
    @Published private var whitelistApps: [String] {
        didSet { UserDefaults.standard.set(whitelistApps, forKey: "whitelistAppList") }
    }

    /// The list currently displayed/applied, depending on the active filter mode.
    /// Key point: Blacklist and Whitelist are two COMPLETELY INDEPENDENT lists,
    /// they don't share data — switching between the two modes will not show "the same list".
    var appList: [String] {
        get { filterMode == "blacklist" ? blacklistApps : whitelistApps }
        set {
            if filterMode == "blacklist" {
                blacklistApps = newValue
            } else {
                whitelistApps = newValue
            }
        }
    }

    @Published var isAccessibilityGranted: Bool = false

    /// Which tab is currently selected in the Settings window. Kept here (instead of a local
    /// @State in the View) so AppDelegate can force a tab switch every time the window is
    /// opened, even if the window already existed before.
    @Published var selectedSettingsTab: Int = 0

    init() {
        let defaultBlacklist = [
            "com.apple.finder",
            "com.apple.systempreferences",
            "com.apple.ActivityMonitor",
            "com.apple.AppStore",
            "com.apple.DiskUtility"
        ]

        if let saved = UserDefaults.standard.stringArray(forKey: "blacklistAppList") {
            self.blacklistApps = saved
        } else if let legacy = UserDefaults.standard.stringArray(forKey: "savedAppList") {
            // Migrate data from an older version (when both modes still shared a single list).
            self.blacklistApps = legacy
        } else {
            self.blacklistApps = defaultBlacklist
        }

        self.whitelistApps = UserDefaults.standard.stringArray(forKey: "whitelistAppList") ?? []

        checkAccessibility()
    }

    func checkAccessibility() {
        let trusted = AXIsProcessTrusted()
        DispatchQueue.main.async {
            self.isAccessibilityGranted = trusted
        }
    }

    func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func configureLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Launch at login error: \(error)")
            }
        }
    }

    func addAppFromDisk() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                // Adding an important system app to the Whitelist means it WILL be auto-quit —
                // warn and ask for confirmation instead of blocking outright, since it's the
                // user's call to make.
                if filterMode == "whitelist" && Self.protectedBundleIDs.contains(id) {
                    let proceed = confirmProtectedAction(
                        bundleId: id,
                        informativeText: "\(id) is an important system app. Adding it to the Whitelist means it WILL be auto-quit whenever it has no open windows, which could affect your system.",
                        confirmButtonTitle: "Add Anyway"
                    )
                    if !proceed { return }
                }

                if !appList.contains(id) {
                    appList.append(id)
                }
            }
        }
    }

    /// Removes an app from the currently active list. If the app is one of the protected
    /// system apps and we're in Blacklist mode, removing it means it loses its protection and
    /// WILL be auto-quit — so ask for confirmation first instead of silently allowing it.
    func removeFromAppList(_ bundleId: String) {
        let isProtectedInBlacklist = Self.protectedBundleIDs.contains(bundleId) && filterMode == "blacklist"

        if isProtectedInBlacklist {
            let proceed = confirmProtectedAction(
                bundleId: bundleId,
                informativeText: "\(bundleId) is an important system app. Removing it from the Blacklist means it loses its protection — it WILL be auto-quit whenever it has no open windows, which could affect your system.",
                confirmButtonTitle: "Remove Anyway"
            )
            if !proceed { return }
        }

        appList.removeAll { $0 == bundleId }
    }

    /// Shared confirmation dialog for actions that would let a protected system app be
    /// auto-quit. Returns true if the user chose to proceed anyway.
    private func confirmProtectedAction(bundleId: String, informativeText: String, confirmButtonTitle: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "This affects an important system app"
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

}

// MARK: - Window-tracking logic
class AutoQuitMonitor {
    private weak var appState: AppState?
    private var timer: Timer?
    private var everHadWindow: Set<pid_t> = []
    private var zeroWindowSince: [pid_t: Date] = [:]

    init(appState: AppState) {
        self.appState = appState
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func tick() {
        guard let state = appState, !state.isPaused, state.isAccessibilityGranted else { return }

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular &&
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            !$0.isTerminated
        }

        let currentPIDs = Set(runningApps.map { $0.processIdentifier })
        everHadWindow = everHadWindow.filter { currentPIDs.contains($0) }
        zeroWindowSince = zeroWindowSince.filter { currentPIDs.contains($0.key) }

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }

            let isListed = state.appList.contains(bundleID)
            let shouldMonitor = (state.filterMode == "blacklist") ? !isListed : isListed

            if !shouldMonitor { continue }

            let count = countWindows(for: app.processIdentifier)

            if count > 0 {
                everHadWindow.insert(app.processIdentifier)
                zeroWindowSince.removeValue(forKey: app.processIdentifier)
            } else if count == 0 && everHadWindow.contains(app.processIdentifier) {
                if let firstZeroTime = zeroWindowSince[app.processIdentifier] {
                    if Date().timeIntervalSince(firstZeroTime) >= state.delaySeconds {
                        let pid = app.processIdentifier
                        app.terminate()
                        // Don't assume terminate() succeeded (e.g. the app shows a "Save changes?"
                        // dialog and the user clicks Cancel). Wait for isTerminated to confirm before
                        // stopping tracking; if the app didn't actually quit, it will be retried on
                        // the next cycle.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            guard let self else { return }
                            if app.isTerminated {
                                self.everHadWindow.remove(pid)
                                self.zeroWindowSince.removeValue(forKey: pid)
                            } else {
                                // Wait one more cycle before retrying termination, to avoid
                                // spamming terminate() on an app that won't quit.
                                self.zeroWindowSince[pid] = Date()
                            }
                        }
                    }
                } else {
                    zeroWindowSince[app.processIdentifier] = Date()
                }
            }
        }
    }

    private func countWindows(for pid: pid_t) -> Int {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)

        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return 0
        }

        var visibleCount = 0
        for win in windows {
            var role: AnyObject?
            guard AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &role) == .success,
                  let roleStr = role as? String, roleStr == (kAXWindowRole as String) else {
                continue
            }

            // A minimized window does not count as "open" — otherwise, a user who minimizes
            // every window would find the app never gets auto-quit.
            var minimizedValue: AnyObject?
            let isMinimized = AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minimizedValue) == .success
                && (minimizedValue as? Bool == true)

            if !isMinimized {
                visibleCount += 1
            }
        }
        return visibleCount
    }
}

// MARK: - Settings UI (SwiftUI)
struct SettingsView: View {
    @ObservedObject var appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    /// While Accessibility permission hasn't been granted, nothing in the General or Rules
    /// tabs actually works, so both are locked (dimmed + non-interactive) and the user is
    /// kept on the Accessibility tab until permission is granted.
    private var isLocked: Bool {
        !appState.isAccessibilityGranted
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $appState.selectedSettingsTab) {
                generalTab
                    .tabItem { Label("General", systemImage: "gearshape") }
                    .tag(0)

                rulesTab
                    .tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }
                    .tag(1)

                permissionsTab
                    .tabItem { Label("Accessibility", systemImage: "hand.raised") }
                    .tag(2)
            }
            .padding(20)
            .onChange(of: appState.selectedSettingsTab) { newValue in
                // If the user manages to switch away from the Accessibility tab while
                // permission is still missing, snap the selection right back — General/Rules
                // are locked.
                if isLocked && newValue != 2 {
                    appState.selectedSettingsTab = 2
                }
            }

            Divider()

            // Kept outside the TabView on purpose: quitting the app must always work, even
            // while the General/Rules tabs are locked pending Accessibility permission.
            HStack {
                Spacer()
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Text("Quit TrueClose")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 480, height: 400)
    }

    var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Pause TrueClose", isOn: $appState.isPaused)
            Toggle("Launch at login", isOn: $appState.launchAtLogin)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Delay before quitting:")
                    Spacer()
                    Text(String(format: "%.1f sec", appState.delaySeconds))
                        .foregroundColor(.secondary)
                }
                Slider(value: $appState.delaySeconds, in: 0.2...5.0, step: 0.1)
                Text("Prevents an app from being quit by mistake right after you close a window to open a different document.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            Toggle("Hide menu bar icon", isOn: $appState.hideMenuBarIcon)
            Text("If hidden, you can reopen Settings anytime with the ⌥⇧A shortcut.")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .disabled(isLocked)
        .opacity(isLocked ? 0.35 : 1.0)
    }

    var rulesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Filter mode:", selection: $appState.filterMode) {
                Text("Exclude (Blacklist)").tag("blacklist")
                Text("Include (Whitelist)").tag("whitelist")
            }
            .pickerStyle(.segmented)

            Text(appState.filterMode == "blacklist"
                 ? "Apps on this list will NEVER be auto-quit. This is the Blacklist mode's own list."
                 : "ONLY apps on this list get auto-quit. This is the Whitelist mode's own list, separate from the Blacklist list.")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                ForEach(appState.appList, id: \.self) { bundleId in
                    let isProtected = AppState.protectedBundleIDs.contains(bundleId) && appState.filterMode == "blacklist"
                    HStack {
                        Text(bundleId)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.primary)
                        if isProtected {
                            Image(systemName: "shield.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                                .help("Important system app — removing it will ask for confirmation")
                        }
                        Spacer()
                        Button {
                            appState.removeFromAppList(bundleId)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundColor(isProtected ? .orange.opacity(0.7) : .red)
                        }
                        .buttonStyle(.plain)
                        .help(isProtected ? "Important system app — you'll be asked to confirm" : "Remove from list")
                    }
                }
            }
            .frame(height: 140)

            HStack {
                Button("Add app (+)") {
                    appState.addAppFromDisk()
                }
                Spacer()
            }
            Text("Tip: for system apps like Migration Assistant, Installer, etc., use this button to pick them directly from /Applications, avoiding typos in the bundle ID.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .disabled(isLocked)
        .opacity(isLocked ? 0.35 : 1.0)
    }

    var permissionsTab: some View {
        VStack(spacing: 16) {
            Image(systemName: appState.isAccessibilityGranted ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundColor(appState.isAccessibilityGranted ? Color.green : Color.orange)

            Text(appState.isAccessibilityGranted ? "Accessibility permission granted!" : "Accessibility permission required")
                .font(.headline)

            Text("TrueClose needs Accessibility permission to check how many windows an app has open.")
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundColor(.secondary)

            if !appState.isAccessibilityGranted {
                Button("Open System Settings to grant permission") {
                    appState.promptAccessibility()
                }
                .buttonStyle(.borderedProminent)

                Text("The General and Rules tabs are locked until permission is granted.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - App Delegate & Menu Bar
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    var accessibilityPollTimer: Timer?
    let appState = AppState()
    lazy var monitor = AutoQuitMonitor(appState: appState)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        updateStatusItemVisibility()
        monitor.start()

        NotificationCenter.default.addObserver(self, selector: #selector(accessibilityStatusChanged), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBarVisibilityChanged), name: .autoQuitMenuBarVisibilityChanged, object: nil)

        // Poll periodically, in case the user grants permission in System Settings without
        // switching back to TrueClose first (didBecomeActiveNotification would not fire then).
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.appState.checkAccessibility()
        }

        // Fallback shortcut: even when the menu bar icon is hidden, the user still has a way
        // to reopen Settings.
        registerGlobalSettingsShortcut()
    }

    @objc func accessibilityStatusChanged() {
        appState.checkAccessibility()
    }

    @objc func menuBarVisibilityChanged() {
        updateStatusItemVisibility()
    }

    /// ⌥⇧A opens Settings at any time, even when the menu bar icon is hidden.
    func registerGlobalSettingsShortcut() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.option, .shift]) && event.charactersIgnoringModifiers?.lowercased() == "a" {
                DispatchQueue.main.async { self?.openSettings() }
            }
        }
    }

    func updateStatusItemVisibility() {
        if appState.hideMenuBarIcon {
            if let item = statusItem {
                NSStatusBar.system.removeStatusItem(item)
                statusItem = nil
            }
        } else if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = statusItem?.button {
                button.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: "TrueClose")
            }
            rebuildMenu()
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let statusTitle = appState.isPaused ? "Status: Paused" : "Status: Monitoring"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem(title: appState.isPaused ? "Resume" : "Pause",
                                action: #selector(togglePause),
                                keyEquivalent: "p"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc func togglePause() {
        appState.isPaused.toggle()
        rebuildMenu()
    }

    @objc func openSettings() {
        // Always re-check Accessibility permission every time Settings is opened (even if the
        // window already existed before), and jump straight to the Accessibility tab if
        // permission isn't granted, so the user immediately knows what to do.
        // Read AXIsProcessTrusted() directly here because checkAccessibility() updates state
        // asynchronously (DispatchQueue.main.async), so reading appState.isAccessibilityGranted
        // right after would be stale.
        let trusted = AXIsProcessTrusted()
        appState.checkAccessibility()
        appState.selectedSettingsTab = trusted ? 0 : 2

        if settingsWindow == nil {
            let view = SettingsView(appState: appState)
            let hostingController = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "TrueClose - Settings"
            window.styleMask = [NSWindow.StyleMask.titled, NSWindow.StyleMask.closable]
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called when the user reopens the app (via Spotlight, Finder, or double-click) while
    /// the process is still running in the background. Since this is an agent app
    /// (LSUIElement) with no window shown by default, without handling this method,
    /// "reopening via Spotlight" would have no effect.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
