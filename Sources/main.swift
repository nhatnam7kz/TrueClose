import Cocoa
import SwiftUI
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers
import CoreGraphics
import ScreenCaptureKit

extension Notification.Name {
    static let autoQuitMenuBarVisibilityChanged = Notification.Name("autoQuitMenuBarVisibilityChanged")
}

// Undocumented but long-stable private API (used by many menu-bar utilities — Rectangle,
// AltTab, Contexts, etc. — for over a decade, still present on current macOS) that maps an
// AXUIElement window to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Typed filter mode, backed by a plain String in storage
enum FilterMode: String {
    case blacklist
    case whitelist
}

/// Reads app metadata (like the version shown in Settings)
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

// MARK: - State & Settings management
class AppState: ObservableObject {
    @AppStorage("isPaused") var isPaused: Bool = false
    @AppStorage("delaySeconds") var delaySeconds: Double = 1.5

    @AppStorage("filterMode") private var filterModeRaw: String = FilterMode.blacklist.rawValue {
        didSet { NotificationCenter.default.post(name: .autoQuitFilterChanged, object: nil) }
    }

    var filterMode: FilterMode {
        get { FilterMode(rawValue: filterModeRaw) ?? .blacklist }
        set { filterModeRaw = newValue.rawValue }
    }

    @AppStorage("hideMenuBarIcon") var hideMenuBarIcon: Bool = false {
        didSet { NotificationCenter.default.post(name: .autoQuitMenuBarVisibilityChanged, object: nil) }
    }
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet { configureLaunchAtLogin(launchAtLogin) }
    }

    static let protectedBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.systempreferences",
        "com.apple.ActivityMonitor",
        "com.apple.AppStore",
        "com.apple.DiskUtility"
    ]

    @Published private var blacklistApps: [String] {
        didSet {
            UserDefaults.standard.set(blacklistApps, forKey: "blacklistAppList")
            NotificationCenter.default.post(name: .autoQuitFilterChanged, object: nil)
        }
    }

    @Published private var whitelistApps: [String] {
        didSet {
            UserDefaults.standard.set(whitelistApps, forKey: "whitelistAppList")
            NotificationCenter.default.post(name: .autoQuitFilterChanged, object: nil)
        }
    }

    var appList: [String] {
        get { filterMode == .blacklist ? blacklistApps : whitelistApps }
        set {
            if filterMode == .blacklist {
                blacklistApps = newValue
            } else {
                whitelistApps = newValue
            }
        }
    }

    @Published var isAccessibilityGranted: Bool = false
    @Published var isScreenRecordingGranted: Bool = false
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
            self.blacklistApps = legacy
        } else {
            self.blacklistApps = defaultBlacklist
        }

        self.whitelistApps = UserDefaults.standard.stringArray(forKey: "whitelistAppList") ?? []

        checkAccessibility()
        checkScreenRecording()
    }

    func checkAccessibility() {
        isAccessibilityGranted = AXIsProcessTrusted()
    }

    func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func checkScreenRecording() {
        if #available(macOS 11.0, *) {
            isScreenRecordingGranted = CGPreflightScreenCaptureAccess()
        } else {
            isScreenRecordingGranted = true
        }
    }

    func promptScreenRecording() {
        if #available(macOS 11.0, *) {
            if CGPreflightScreenCaptureAccess() { return }
            let requested = CGRequestScreenCaptureAccess()
            if !requested {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
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
                if filterMode == .whitelist && Self.protectedBundleIDs.contains(id) {
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

    func removeFromAppList(_ bundleId: String) {
        let isProtectedInBlacklist = Self.protectedBundleIDs.contains(bundleId) && filterMode == .blacklist

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

extension Notification.Name {
    static let autoQuitFilterChanged = Notification.Name("autoQuitFilterChanged")
}

// MARK: - Window-tracking logic
class AutoQuitMonitor {
    private weak var appState: AppState?
    private var timer: Timer?
    private var everHadWindow: Set<pid_t> = []
    private var zeroWindowSince: [pid_t: Date] = [:]
    private var wasMonitored: Set<pid_t> = []

    private var hasLoggedBlockedState = false
    private var isSystemSleeping = false
    private var isSpaceTransitioning = false
    private var spaceSettleTimer: Timer?
    private var knownFullscreenPids: Set<pid_t> = []
    private var knownWindowIDs: [pid_t: Set<CGWindowID>] = [:]

    private var pidsWithRealWindowAnywhere: Set<pid_t> = []
    private var isRefreshingShareableContent = false

    init(appState: AppState) {
        self.appState = appState
        NotificationCenter.default.addObserver(self, selector: #selector(handleFilterChanged), name: .autoQuitFilterChanged, object: nil)
        
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(handleWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(handleDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(handleActiveSpaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
    }

    @objc private func handleFilterChanged() {
        zeroWindowSince.removeAll()
    }

    @objc private func handleWillSleep() {
        isSystemSleeping = true
    }

    @objc private func handleDidWake() {
        isSystemSleeping = false
        zeroWindowSince.removeAll()
    }

    @objc private func handleActiveSpaceChanged() {
        isSpaceTransitioning = true
        zeroWindowSince.removeAll()
        spaceSettleTimer?.invalidate()
        spaceSettleTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.isSpaceTransitioning = false
            self?.zeroWindowSince.removeAll()
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    @available(macOS 12.3, *)
    private func refreshShareableContentCache() {
        guard !isRefreshingShareableContent else { return }
        isRefreshingShareableContent = true
        Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.isRefreshingShareableContent = false
                }
            }
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                let pids: Set<pid_t> = Set(content.windows.compactMap { window in
                    guard window.windowLayer == 0 else { return nil }
                    guard window.frame.width > 1, window.frame.height > 1 else { return nil }
                    return window.owningApplication?.processID
                })
                await MainActor.run {
                    self.pidsWithRealWindowAnywhere = pids
                }
            } catch {
                print("[DEBUG] ScreenCaptureKit refresh failed: \(error)")
            }
        }
    }

    private func isSystemInFullscreenTransition() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return false
        }

        let screenSizes = NSScreen.screens.map { $0.frame.size }
        for win in windows {
            var fsValue: AnyObject?
            if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsValue) == .success,
               let isFullscreen = fsValue as? Bool, isFullscreen {
                return true
            }

            var sizeValue: AnyObject?
            guard AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeValue) == .success else { continue }
            guard let sizeAXValue = sizeValue, CFGetTypeID(sizeAXValue) == AXValueGetTypeID() else { continue }
            
            let axValue = sizeAXValue as! AXValue
            var windowSize = CGSize.zero
            if AXValueGetType(axValue) == .cgSize {
                AXValueGetValue(axValue, .cgSize, &windowSize)
            } else { continue }
            
            let tolerance: CGFloat = 2.0
            if screenSizes.contains(where: {
                abs($0.width - windowSize.width) < tolerance && abs($0.height - windowSize.height) < tolerance
            }) { return true }
        }
        return false
    }

    private func tick() {
        guard let state = appState, !state.isPaused, state.isAccessibilityGranted,
              !isSystemSleeping, !isSpaceTransitioning else {
            if !hasLoggedBlockedState {
                hasLoggedBlockedState = true
            }
            return
        }
        hasLoggedBlockedState = false

        if #available(macOS 12.3, *), state.isScreenRecordingGranted {
            refreshShareableContentCache()
        }

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular &&
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            !$0.isTerminated
        }

        let currentPIDs = Set(runningApps.map { $0.processIdentifier })
        everHadWindow = everHadWindow.filter { currentPIDs.contains($0) }
        zeroWindowSince = zeroWindowSince.filter { currentPIDs.contains($0.key) }
        wasMonitored = wasMonitored.filter { currentPIDs.contains($0) }
        knownFullscreenPids = knownFullscreenPids.filter { currentPIDs.contains($0) }
        knownWindowIDs = knownWindowIDs.filter { currentPIDs.contains($0.key) }

        let systemInFullscreen = isSystemInFullscreenTransition()

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }

            let isListed = state.appList.contains(bundleID)
            let shouldMonitor = (state.filterMode == .blacklist) ? !isListed : isListed
            let pid = app.processIdentifier

            if shouldMonitor && !wasMonitored.contains(pid) {
                zeroWindowSince.removeValue(forKey: pid)
            }

            if shouldMonitor {
                wasMonitored.insert(pid)
            } else {
                wasMonitored.remove(pid)
                continue
            }

            guard let info = countWindows(for: pid) else { continue }
            let count = info.visibleCount
            
            if count > 0 {
                if info.isFullscreen {
                    knownFullscreenPids.insert(pid)
                } else {
                    knownFullscreenPids.remove(pid)
                }
                if !info.windowIDs.isEmpty {
                    knownWindowIDs[pid, default: []].formUnion(info.windowIDs)
                }
            }

            if count > 0 {
                everHadWindow.insert(pid)
                zeroWindowSince.removeValue(forKey: pid)
            } else if count == 0 && everHadWindow.contains(pid) {
                if systemInFullscreen { continue }
                if knownFullscreenPids.contains(pid) { continue }

                // BỘ LỌC ĐA MÀN HÌNH VÀ CHỐNG ZOMBIE
                if state.isScreenRecordingGranted {
                    var savedByCrossSpace = false
                    
                    if #available(macOS 12.3, *) {
                        if pidsWithRealWindowAnywhere.contains(pid) {
                            savedByCrossSpace = true
                        }
                    } else if hasAnyWindowCrossSpace(for: pid, knownIDs: knownWindowIDs[pid] ?? []) {
                        savedByCrossSpace = true
                    }
                    
                    if savedByCrossSpace {
                        // CHỐT CHẶN CUỐI CÙNG BẰNG AXMainWindow
                        // Bất kỳ app nào (Electron/Native) khi đóng cửa sổ sẽ bị hệ thống tước quyền Main Window
                        // Cửa sổ sống ở Space khác vẫn giữ nguyên Main Window.
                        let axApp = AXUIElementCreateApplication(pid)
                        var mainWindow: CFTypeRef?
                        let result = AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainWindow)
                        
                        if result == .success && mainWindow != nil {
                            continue // Thực sự là cửa sổ sống ở Space khác -> Không tắt
                        }
                        // Nếu không có mainWindow -> 100% là cửa sổ Zombie -> Kệ cho nó đếm ngược để tắt
                    }
                }
                
                // Đếm ngược thời gian tắt app
                if let firstZeroTime = zeroWindowSince[pid] {
                    if Date().timeIntervalSince(firstZeroTime) >= state.delaySeconds {
                        app.terminate()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            guard let self else { return }
                            if app.isTerminated {
                                self.everHadWindow.remove(pid)
                                self.zeroWindowSince.removeValue(forKey: pid)
                                self.knownWindowIDs.removeValue(forKey: pid)
                            } else {
                                self.zeroWindowSince[pid] = Date()
                            }
                        }
                    }
                } else {
                    zeroWindowSince[pid] = Date()
                }
            }
        }
    }

    private func hasAnyWindowCrossSpace(for pid: pid_t, knownIDs: Set<CGWindowID>) -> Bool {
        guard !knownIDs.isEmpty else { return false }
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid else { continue }
            guard let windowNumberRaw = info[kCGWindowNumber as String] as? Int else { continue }
            let windowNumber = CGWindowID(windowNumberRaw)
            if knownIDs.contains(windowNumber) {
                return true
            }
        }
        return false
    }

    private func countWindows(for pid: pid_t) -> (visibleCount: Int, isFullscreen: Bool, windowIDs: Set<CGWindowID>)? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)

        guard result == .success, let windows = windowsValue as? [AXUIElement] else { return nil }

        var visibleCount = 0
        var isFullscreen = false
        var windowIDs: Set<CGWindowID> = []
        for win in windows {
            var fsValue: AnyObject?
            if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsValue) == .success,
               let fs = fsValue as? Bool, fs {
                isFullscreen = true
            }

            var role: AnyObject?
            guard AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &role) == .success,
                  let roleStr = role as? String, roleStr == (kAXWindowRole as String) else { continue }

            visibleCount += 1

            var winID: CGWindowID = 0
            if _AXUIElementGetWindow(win, &winID) == .success {
                windowIDs.insert(winID)
            }
        }
        return (visibleCount, isFullscreen, windowIDs)
    }
}

// MARK: - Settings UI (SwiftUI)
struct SettingsView: View {
    @ObservedObject var appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    private var isLocked: Bool {
        !appState.isAccessibilityGranted
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $appState.selectedSettingsTab) {
                generalTab.tabItem { Label("General", systemImage: "gearshape") }.tag(0)
                rulesTab.tabItem { Label("Rules", systemImage: "list.bullet.rectangle") }.tag(1)
                permissionsTab.tabItem { Label("Accessibility", systemImage: "hand.raised") }.tag(2)
            }
            .padding(20)
            .onChange(of: appState.selectedSettingsTab) { newValue in
                if isLocked && newValue != 2 {
                    appState.selectedSettingsTab = 2
                }
            }

            Divider()

            HStack {
                Text("v\(AppInfo.version)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
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

            if #available(macOS 13.0, *) {
                Toggle("Launch at login", isOn: $appState.launchAtLogin)
            } else {
                Toggle("Launch at login (requires macOS 13 or later)", isOn: .constant(false)).disabled(true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Delay before quitting:")
                    Spacer()
                    Text(String(format: "%.1f sec", appState.delaySeconds)).foregroundColor(.secondary)
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
                Text("Exclude (Blacklist)").tag(FilterMode.blacklist)
                Text("Include (Whitelist)").tag(FilterMode.whitelist)
            }
            .pickerStyle(.segmented)

            Text(appState.filterMode == .blacklist
                 ? "Apps on this list will NEVER be auto-quit. This is the Blacklist mode's own list."
                 : "ONLY apps on this list get auto-quit. This is the Whitelist mode's own list, separate from the Blacklist list.")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                ForEach(appState.appList, id: \.self) { bundleId in
                    let isProtected = AppState.protectedBundleIDs.contains(bundleId) && appState.filterMode == .blacklist
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
                Button("Add app (+)") { appState.addAppFromDisk() }
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

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: appState.isScreenRecordingGranted ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundColor(appState.isScreenRecordingGranted ? .green : .secondary)
                    Text("Screen Recording (optional)")
                        .font(.subheadline)
                        .bold()
                }

                Text("Not required, but improves reliability when you use multiple Desktops/Spaces — without it, an app sitting on a Desktop you're not currently viewing can occasionally be quit by mistake.")
                    .multilineTextAlignment(.center)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !appState.isScreenRecordingGranted {
                    Button("Grant Screen Recording permission") {
                        appState.promptScreenRecording()
                    }
                    .buttonStyle(.bordered)
                }
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

        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBarVisibilityChanged), name: .autoQuitMenuBarVisibilityChanged, object: nil)

        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.appState.checkAccessibility()
            self?.appState.checkScreenRecording()
            self?.updateStatusItemVisibility()
        }

        registerGlobalSettingsShortcut()
    }

    @objc func handleAppDidBecomeActive() {
        appState.checkAccessibility()
        appState.checkScreenRecording()
        updateStatusItemVisibility()
    }

    @objc func menuBarVisibilityChanged() {
        updateStatusItemVisibility()
    }

    func registerGlobalSettingsShortcut() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.option, .shift]) && event.charactersIgnoringModifiers?.lowercased() == "a" {
                DispatchQueue.main.async { self?.openSettings() }
            }
        }
    }

    func updateStatusItemVisibility() {
        let shouldHide = appState.hideMenuBarIcon && appState.isAccessibilityGranted

        if shouldHide {
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
        } else {
            rebuildMenu()
        }
    }

    func rebuildMenu() {
        let menu = NSMenu()

        let statusTitle = appState.isPaused ? "Status: Paused" : "Status: Monitoring"
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem(title: appState.isPaused ? "Resume" : "Pause", action: #selector(togglePause), keyEquivalent: "p"))
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