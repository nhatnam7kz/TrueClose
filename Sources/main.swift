import Cocoa
import SwiftUI
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

extension Notification.Name {
    static let autoQuitMenuBarVisibilityChanged = Notification.Name("autoQuitMenuBarVisibilityChanged")
}

/// Typed filter mode, backed by a plain String in storage (see `AppState.filterModeRaw`) so
/// existing installs' UserDefaults data keeps working unchanged.
enum FilterMode: String {
    case blacklist
    case whitelist
}

/// Reads app metadata (like the version shown in Settings) straight from the bundled
/// Info.plist, so there is only ONE place to bump the version number — no separate
/// hardcoded constant to keep in sync.
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

// MARK: - State & Settings management
class AppState: ObservableObject {
    @AppStorage("isPaused") var isPaused: Bool = false
    @AppStorage("delaySeconds") var delaySeconds: Double = 1.5

    /// Raw on-disk storage for filter mode. Kept private — everything else in the app should
    /// go through the typed `filterMode` accessor below instead of comparing string literals.
    @AppStorage("filterMode") private var filterModeRaw: String = FilterMode.blacklist.rawValue {
        didSet { NotificationCenter.default.post(name: .autoQuitFilterChanged, object: nil) }
    }

    /// Typed accessor over `filterModeRaw`. Falls back to `.blacklist` if the stored value is
    /// ever somehow invalid (e.g. corrupted defaults), which matches the app's original default.
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
        didSet {
            UserDefaults.standard.set(blacklistApps, forKey: "blacklistAppList")
            NotificationCenter.default.post(name: .autoQuitFilterChanged, object: nil)
        }
    }

    /// List used in Whitelist mode (inclusion — ONLY these apps get auto-quit).
    @Published private var whitelistApps: [String] {
        didSet {
            UserDefaults.standard.set(whitelistApps, forKey: "whitelistAppList")
            NotificationCenter.default.post(name: .autoQuitFilterChanged, object: nil)
        }
    }

    /// The list currently displayed/applied, depending on the active filter mode.
    /// Key point: Blacklist and Whitelist are two COMPLETELY INDEPENDENT lists,
    /// they don't share data — switching between the two modes will not show "the same list".
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

    /// Reads the current Accessibility trust state synchronously. This is always called from
    /// the main thread in this app (init, notifications, timers, and menu actions all run on
    /// main), so there is no need to hop queues here — doing so previously (via
    /// DispatchQueue.main.async) meant callers that read `isAccessibilityGranted` right after
    /// calling this could still see the OLD value for one run-loop turn, which was a source of
    /// a race against `updateStatusItemVisibility()` on the didBecomeActive path.
    func checkAccessibility() {
        isAccessibilityGranted = AXIsProcessTrusted()
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

    /// Removes an app from the currently active list. If the app is one of the protected
    /// system apps and we're in Blacklist mode, removing it means it loses its protection and
    /// WILL be auto-quit — so ask for confirmation first instead of silently allowing it.
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

extension Notification.Name {
    /// Fired whenever filterMode or either app list changes, so the monitor can drop any
    /// stale "window has been zero since <time>" bookkeeping tied to the old configuration.
    /// BUG FIX: without this, an app that briefly left the monitored set (e.g. because you
    /// switched Blacklist/Whitelist, or added/removed it from a list) while its zero-window
    /// timer was already running could get auto-quit INSTANTLY the moment it re-entered the
    /// monitored set, completely skipping "delaySeconds" — because the old timestamp was
    /// still sitting there and may already have "expired".
    static let autoQuitFilterChanged = Notification.Name("autoQuitFilterChanged")
}

// MARK: - Window-tracking logic
class AutoQuitMonitor {
    private weak var appState: AppState?
    private var timer: Timer?
    private var everHadWindow: Set<pid_t> = []
    private var zeroWindowSince: [pid_t: Date] = [:]
    private var wasMonitored: Set<pid_t> = []

    /// Tracks whether we've already logged the "tick blocked" reason for the CURRENT blocked
    /// stretch, so pausing (or missing Accessibility permission) doesn't spam the Console with
    /// the same line every 0.8s — it now logs once on entry and stays quiet until unblocked.
    private var hasLoggedBlockedState = false

    /// True from the moment macOS announces it's about to sleep until it's confirmed awake
    /// again. See handleWillSleep()/handleDidWake() for why this exists.
    private var isSystemSleeping = false

    init(appState: AppState) {
        self.appState = appState
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleFilterChanged),
            name: .autoQuitFilterChanged,
            object: nil
        )

        // BUG FIX: apps that were genuinely still open were getting auto-quit right after the
        // Mac woke from sleep. Root cause: some apps briefly report 0 windows via Accessibility
        // while the system is preparing to sleep (display/window-server winding down), which
        // starts a "zero window since <time>" debounce timer. The Timer driving tick() is then
        // suspended for the whole duration of sleep — but Date() keeps advancing in real time —
        // so the very first tick after waking sees an elapsed time far past delaySeconds and
        // terminates the app instantly, even though its window was never actually closed.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(handleDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleFilterChanged() {
        // BUG FIX: the monitored set may have just changed (filterMode flip, or an app
        // added/removed from a list). Clear all "zero window since" bookkeeping so nothing
        // gets quit based on a stale timestamp accumulated under the OLD configuration.
        // everHadWindow is left alone — it's just "have we ever observed a window", which
        // stays meaningful across a config change.
        zeroWindowSince.removeAll()
    }

    @objc private func handleWillSleep() {
        // Stop evaluating quit decisions immediately, even before the system has actually
        // finished suspending — a tick firing during the brief sleep-prep window shouldn't be
        // allowed to start (or act on) a debounce timer that's about to become meaningless.
        isSystemSleeping = true
    }

    @objc private func handleDidWake() {
        isSystemSleeping = false
        // Discard every "zero window since <time>" timestamp accumulated before/around sleep.
        // Wall-clock time advanced normally while asleep, so any such timestamp would already
        // look "expired" the instant we resume ticking — treat waking up as a fresh start
        // instead of instantly quitting apps based on a stale pre-sleep timestamp.
        zeroWindowSince.removeAll()
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // When any regular app has a fullscreen-like window, enumerating OTHER apps'
    // windows via AX can be unreliable (heavy GPU/CPU load, Space transitions,
    // Chromium AX-tree quirks under load, etc). We detect "fullscreen-like" two
    // ways, both using only the Accessibility permission we already have — no
    // Screen Recording permission needed:
    //   1. The official AXFullScreen attribute (true macOS fullscreen / its own Space)
    //   2. The frontmost window's bounds exactly matching a screen's size (covers
    //      borderless/"fake fullscreen" games like Roblox, which often don't use
    //      real AppKit fullscreen at all)
    private func isSystemInFullscreenTransition() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let axApp = AXUIElementCreateApplication(front.processIdentifier)
        // BUG FIX: bound how long any single AX call can block. Without an explicit timeout,
        // AXUIElementCopyAttributeValue can hang for seconds against an app that is itself
        // frozen or under heavy GPU/CPU load — freezing this monitor's main-thread timer right
        // along with it, in exactly the "system under heavy load" scenario this fullscreen
        // check exists to detect. 0.3s keeps a stuck call from blocking the whole tick.
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return false
        }

        let screenSizes = NSScreen.screens.map { $0.frame.size }

        for win in windows {
            // Check 1: official fullscreen flag.
            var fsValue: AnyObject?
            if AXUIElementCopyAttributeValue(win, "AXFullScreen" as CFString, &fsValue) == .success,
               let isFullscreen = fsValue as? Bool, isFullscreen {
                return true
            }

            // Check 2: window bounds cover an entire screen (borderless fullscreen).
            var sizeValue: AnyObject?
            guard AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeValue) == .success else {
                continue
            }
            guard let sizeAXValue = sizeValue, CFGetTypeID(sizeAXValue) == AXValueGetTypeID() else {
                continue
            }
            // NOTE: this looks like it wants `as?` for safety, but Swift treats a conditional
            // downcast to a CoreFoundation type as always succeeding at compile time (it can't
            // check the specific CF type here) and makes `as?` a hard build error instead of a
            // warning. The CFGetTypeID check right above is what actually guards this — by the
            // time we get here we already know sizeAXValue really is an AXValue, so the force
            // cast is safe.
            let axValue = sizeAXValue as! AXValue
            var windowSize = CGSize.zero
            if AXValueGetType(axValue) == .cgSize {
                AXValueGetValue(axValue, .cgSize, &windowSize)
            } else {
                continue
            }
            let tolerance: CGFloat = 2.0
            if screenSizes.contains(where: {
                abs($0.width - windowSize.width) < tolerance && abs($0.height - windowSize.height) < tolerance
            }) {
                return true
            }
        }
        return false
    }

    private func tick() {
        guard let state = appState, !state.isPaused, state.isAccessibilityGranted, !isSystemSleeping else {
            // BUG FIX: log the blocked reason only once per blocked stretch, not on every
            // 0.8s tick — previously this printed continuously for as long as the app was
            // paused (or missing permission), flooding the Console with an identical line.
            if !hasLoggedBlockedState {
                hasLoggedBlockedState = true
                print("[DEBUG] tick() bị chặn — isPaused=\(appState?.isPaused ?? true), isAccessibilityGranted=\(appState?.isAccessibilityGranted ?? false), isSystemSleeping=\(isSystemSleeping)")
            }
            return
        }
        hasLoggedBlockedState = false

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular &&
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier &&
            !$0.isTerminated
        }

        let currentPIDs = Set(runningApps.map { $0.processIdentifier })
        everHadWindow = everHadWindow.filter { currentPIDs.contains($0) }
        zeroWindowSince = zeroWindowSince.filter { currentPIDs.contains($0.key) }
        wasMonitored = wasMonitored.filter { currentPIDs.contains($0) }

        let systemInFullscreen = isSystemInFullscreenTransition()
        if systemInFullscreen {
            print("[DEBUG] systemInFullscreen = true — đang tạm dừng auto-quit toàn bộ")
        }

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }

            let isListed = state.appList.contains(bundleID)
            let shouldMonitor = (state.filterMode == .blacklist) ? !isListed : isListed
            let pid = app.processIdentifier

            // BUG FIX: if this app just newly became monitored (it wasn't being watched on
            // the previous tick — e.g. it was on the Blacklist and just got removed from it),
            // drop any leftover zero-window timestamp for it. Otherwise an old timestamp from
            // a much earlier, unrelated stretch of "no windows" could already be older than
            // delaySeconds, causing an INSTANT quit the moment monitoring starts, with no
            // delay actually observed.
            if shouldMonitor && !wasMonitored.contains(pid) {
                zeroWindowSince.removeValue(forKey: pid)
            }

            if shouldMonitor {
                wasMonitored.insert(pid)
            } else {
                wasMonitored.remove(pid)
                continue
            }

            // If we couldn't reliably read the window count this tick (AX call failed
            // or timed out — common when the system is under heavy load, e.g. a
            // fullscreen game), skip this app entirely rather than guessing it has 0
            // windows. Guessing wrong here is what caused unrelated apps to be
            // auto-quit while Roblox was running fullscreen.
            guard let count = countWindows(for: pid) else {
                print("[DEBUG] \(app.localizedName ?? bundleID): countWindows trả về nil (AX call thất bại)")
                continue
            }

            if count > 0 {
                everHadWindow.insert(pid)
                zeroWindowSince.removeValue(forKey: pid)
            } else if count == 0 && everHadWindow.contains(pid) {
                if systemInFullscreen {
                    // Freeze the countdown entirely while any app looks fullscreen
                    // (real or borderless) — this is what caused Brave (and could
                    // cause other apps) to be wrongly auto-quit while Roblox was
                    // fullscreen. No Screen Recording permission needed for this
                    // check, unlike the CGWindowList approach we tried before.
                    continue
                }
                if let firstZeroTime = zeroWindowSince[pid] {
                    if Date().timeIntervalSince(firstZeroTime) >= state.delaySeconds {
                        print("[DEBUG] \(app.localizedName ?? bundleID): đủ delay, gọi terminate()")
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
                    zeroWindowSince[pid] = Date()
                }
            }
        }
    }

    // Returns nil when the AX call itself failed/timed out (system busy, e.g. a
    // fullscreen game hogging the GPU) — this is NOT the same as "0 windows" and
    // must never be treated as the app having closed its last window. Callers
    // should skip the app entirely for this tick when this returns nil.
    private func countWindows(for pid: pid_t) -> Int? {
        let axApp = AXUIElementCreateApplication(pid)
        // Same reasoning as isSystemInFullscreenTransition(): bound the call so a hung/busy
        // target app can't stall this monitor's tick indefinitely.
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue)

        guard result == .success, let windows = windowsValue as? [AXUIElement] else {
            return nil
        }

        var visibleCount = 0
        for win in windows {
            var role: AnyObject?
            guard AXUIElementCopyAttributeValue(win, kAXRoleAttribute as CFString, &role) == .success,
                  let roleStr = role as? String, roleStr == (kAXWindowRole as String) else {
                continue
            }

            // Minimizing is NOT closing — the user explicitly chose to keep the window
            // around, just tucked into the Dock. TrueClose should only act on windows that
            // are actually closed (the red button), so minimized windows still count as
            // "open" here and do not push the app toward auto-quit.
            visibleCount += 1
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
            // The version label lives here too, so it's visible no matter which tab is active.
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

            // BUG FIX: SMAppService (used by configureLaunchAtLogin) is only available on
            // macOS 13+. Previously this toggle was always shown and always looked "on" once
            // tapped, but silently did nothing on older macOS — the user had no way to know
            // launch-at-login wasn't actually being configured. Now it's visibly disabled on
            // unsupported systems instead of lying about its effect.
            if #available(macOS 13.0, *) {
                Toggle("Launch at login", isOn: $appState.launchAtLogin)
            } else {
                Toggle("Launch at login (requires macOS 13 or later)", isOn: .constant(false))
                    .disabled(true)
            }

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

        // BUG FIX: previously this event had TWO separate observers registered against it
        // (one calling checkAccessibility(), another calling updateStatusItemVisibility()),
        // which could fire in either order — and checkAccessibility() used to update its
        // state asynchronously, so updateStatusItemVisibility() could run against a STALE
        // isAccessibilityGranted value on the very notification meant to refresh it. A single
        // handler with a guaranteed order removes that race entirely.
        NotificationCenter.default.addObserver(self, selector: #selector(handleAppDidBecomeActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuBarVisibilityChanged), name: .autoQuitMenuBarVisibilityChanged, object: nil)

        // Poll periodically, in case the user grants permission in System Settings without
        // switching back to TrueClose first (didBecomeActiveNotification would not fire then).
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.appState.checkAccessibility()
            self?.updateStatusItemVisibility()
        }

        // Fallback shortcut: even when the menu bar icon is hidden, the user still has a way
        // to reopen Settings.
        registerGlobalSettingsShortcut()
    }

    @objc func handleAppDidBecomeActive() {
        appState.checkAccessibility()
        updateStatusItemVisibility()
    }

    @objc func menuBarVisibilityChanged() {
        updateStatusItemVisibility()
    }

    /// ⌥⇧A opens Settings at any time, even when the menu bar icon is hidden.
    /// NOTE: this global monitor itself requires Accessibility/Input Monitoring permission to
    /// fire. That means if permission is missing, this shortcut silently does nothing — which
    /// is exactly the "dead end" updateStatusItemVisibility() below is designed to prevent by
    /// always keeping the menu bar icon visible until permission is confirmed granted.
    func registerGlobalSettingsShortcut() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.option, .shift]) && event.charactersIgnoringModifiers?.lowercased() == "a" {
                DispatchQueue.main.async { self?.openSettings() }
            }
        }
    }

    func updateStatusItemVisibility() {
        // BUG FIX ("dead end" bug): hideMenuBarIcon is a persisted preference the user may
        // have turned on in a PREVIOUS session, while Accessibility permission was working.
        // If permission is later lost (e.g. after re-signing the app with a new cert, or a
        // macOS update resets TCC grants), the global ⌥⇧A shortcut stops firing (it also
        // needs Accessibility), there is no Dock icon (activationPolicy = .accessory), and
        // with the menu bar icon hidden too there is now NO WAY AT ALL to reach Settings and
        // re-grant permission — the app is running but completely unreachable.
        // Fix: always force the icon to show while permission isn't granted, regardless of
        // the hideMenuBarIcon preference. Only honor the "hide" preference once permission is
        // confirmed, since at that point ⌥⇧A is guaranteed to work as a fallback.
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
            // Icon already showing — make sure the menu reflects current state.
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
        // Read AXIsProcessTrusted() directly here (rather than via appState.isAccessibilityGranted)
        // to sidestep ordering entirely: checkAccessibility() below updates the published state
        // for the rest of the UI, but this local `trusted` value is what decides the tab jump.
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