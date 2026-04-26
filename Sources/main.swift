import Cocoa
import MetalKit
import Carbon.HIToolbox
import SwiftUI

private enum DefaultsKey {
    static let boostLevel = "boostLevel"
}

private func formattedBoost(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    return rounded.truncatingRemainder(dividingBy: 1) == 0
        ? "\(Int(rounded))x"
        : String(format: "%.1fx", rounded)
}

private func versionComponents(_ version: String) -> [Int] {
    version
        .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        .split(separator: ".")
        .map { Int($0) ?? 0 }
}

private func isVersion(_ candidate: String, newerThan current: String) -> Bool {
    let lhs = versionComponents(candidate)
    let rhs = versionComponents(current)
    let count = max(lhs.count, rhs.count)

    for index in 0..<count {
        let left = index < lhs.count ? lhs[index] : 0
        let right = index < rhs.count ? rhs[index] : 0
        if left != right {
            return left > right
        }
    }

    return false
}

private var sunStatusImageCache: [String: NSImage] = [:]

private func sunStatusImage(boostLevel: Double, isActive: Bool) -> NSImage {
    let clampedLevel = min(max(boostLevel, 1.0), 3.0)
    let boostBucket = Int(round(((clampedLevel - 1.0) / 2.0) * 16.0))
    let cacheKey = "\(isActive)-\(boostBucket)"
    if let cachedImage = sunStatusImageCache[cacheKey] {
        return cachedImage
    }

    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    let normalized = CGFloat(boostBucket) / 16.0
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let coreRadius: CGFloat = isActive ? 2.8 + normalized * 0.5 : 2.5
    let rayInner: CGFloat = 5.0
    let rayOuter: CGFloat = 5.9 + normalized * 2.9
    let alpha: CGFloat = isActive ? 1.0 : 0.62

    image.lockFocus()
    defer {
        image.unlockFocus()
        image.isTemplate = true
    }

    NSColor.black.withAlphaComponent(alpha).setStroke()
    let rays = NSBezierPath()
    rays.lineWidth = isActive ? 1.8 : 1.5
    rays.lineCapStyle = .round

    for index in 0..<8 {
        let angle = CGFloat(index) * .pi / 4
        let inner = CGPoint(
            x: center.x + cos(angle) * rayInner,
            y: center.y + sin(angle) * rayInner
        )
        let outer = CGPoint(
            x: center.x + cos(angle) * rayOuter,
            y: center.y + sin(angle) * rayOuter
        )
        rays.move(to: inner)
        rays.line(to: outer)
    }
    rays.stroke()

    let coreRect = NSRect(
        x: center.x - coreRadius,
        y: center.y - coreRadius,
        width: coreRadius * 2,
        height: coreRadius * 2
    )
    let core = NSBezierPath(ovalIn: coreRect)
    if isActive {
        NSColor.black.withAlphaComponent(alpha).setFill()
        core.fill()
    } else {
        core.lineWidth = 1.5
        core.stroke()
    }

    sunStatusImageCache[cacheKey] = image
    return image
}

private func runProcess(_ executable: String, _ arguments: [String]) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: executable)
    proc.arguments = arguments
    try? proc.run()
    proc.waitUntilExit()
}

private func matchingProcessIDs(named processName: String) -> [pid_t] {
    let pipe = Pipe()
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    proc.arguments = ["-x", processName]
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    try? proc.run()
    proc.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }
    return output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
}

// MARK: - Kill switch

if CommandLine.arguments.contains("--kill") || CommandLine.arguments.contains("-k") {
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let targets = Set(
        matchingProcessIDs(named: "sunray-xdr")
        + matchingProcessIDs(named: "SunrayXDR")
        + matchingProcessIDs(named: "xdr-boost")
        + matchingProcessIDs(named: "XDRBoost")
    )
    for pid in targets where pid != currentPID {
        kill(pid, SIGTERM)
    }
    fputs("All Sunray XDR instances killed\n", stderr)
    exit(0)
}

// MARK: - Metal overlay renderer

final class Renderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    var onFirstFrame: (() -> Void)?

    init(device: MTLDevice) {
        self.commandQueue = device.makeCommandQueue()!
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let desc = view.currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: desc) else { return }

        encoder.endEncoding()
        if let drawable = view.currentDrawable {
            buffer.present(drawable)
        }
        if let callback = onFirstFrame {
            onFirstFrame = nil
            buffer.addCompletedHandler { _ in
                DispatchQueue.main.async {
                    callback()
                }
            }
        }
        buffer.commit()
    }
}

// MARK: - App controller

final class XDRApp: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem!
    var overlayWindow: NSWindow?
    var boostView: MTKView?
    var boostRenderer: Renderer?
    var device: MTLDevice!
    var hotkeyRef: EventHotKeyRef?
    var watchdogTimer: Timer?
    var pendingReassert: DispatchWorkItem?

    @Published var isActive = false
    var shouldBeActive = false
    @Published var boostLevel: Double = 2.0
    @Published var maxEDR: CGFloat = 1.0
    @Published var activationPulse = 0
    @Published var splitPreviewEnabled = false
    @Published private(set) var isPanelVisible = false

    private let panelSize = NSSize(width: 330, height: 344)
    private var panelWindow: NSPanel?
    private var popoverController: ControlPanelViewController!
    private var eventMonitor: Any?

    var isSupported: Bool {
        maxEDR > 1.0
    }

    var maxBoostLevel: Double {
        min(3.0, max(1.0, Double(maxEDR)))
    }

    var displayEDRHeadroom: Double {
        max(1.0, Double(maxEDR))
    }

    var effectiveBoostLevel: Double {
        min(boostLevel, maxBoostLevel)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            fputs("No Metal device\n", stderr)
            exit(1)
        }

        device = metalDevice
        refreshDisplayCapabilities()
        loadInitialBoostLevel()
        setupStatusBar()
        setupPopover()
        registerGlobalHotkey()
        observeSystemEvents()

        fputs("Sunray XDR ready — click the menu bar icon or press Ctrl+Option+Cmd+V\n", stderr)
        fputs("Emergency kill: run `sunray-xdr --kill`\n", stderr)
        fputs("Boost range: 1x-\(formattedBoost(maxBoostLevel)) (display EDR headroom: \(formattedBoost(displayEDRHeadroom)))\n", stderr)
    }

    func applicationWillTerminate(_ notification: Notification) {
        deactivate()
    }

    private func loadInitialBoostLevel() {
        let saved = UserDefaults.standard.double(forKey: DefaultsKey.boostLevel)
        let requested = saved > 0 ? saved : 2.0
        if CommandLine.arguments.count > 1, let argumentValue = Double(CommandLine.arguments[1]) {
            boostLevel = clampedBoost(argumentValue)
        } else {
            boostLevel = clampedBoost(requested)
        }
    }

    private func refreshDisplayCapabilities() {
        maxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
    }

    private func clampedBoost(_ value: Double) -> Double {
        min(max(value, 1.0), 3.0)
    }

    private func persistBoostLevel() {
        UserDefaults.standard.set(boostLevel, forKey: DefaultsKey.boostLevel)
    }

    // MARK: - Status bar and popover

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(togglePopover(_:))
        updateStatusItem()
    }

    private func setupPopover() {
        popoverController = ControlPanelViewController(app: self)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        if panelWindow?.isVisible == true {
            closePopover()
        } else {
            popoverController.syncFromApp()
            showPanel(relativeTo: button)
        }
    }

    func closePopover() {
        panelWindow?.orderOut(nil)
        isPanelVisible = false
    }

    private func showPanel(relativeTo button: NSStatusBarButton) {
        let panel = panelWindow ?? makePanelWindow()
        panelWindow = panel

        if let buttonWindow = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = buttonWindow.convertToScreen(buttonRect)
            let screen = buttonWindow.screen ?? NSScreen.main
            let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

            var origin = NSPoint(
                x: screenRect.midX - panelSize.width / 2,
                y: screenRect.minY - panelSize.height - 8
            )
            origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - panelSize.width - 8)
            origin.y = max(origin.y, visibleFrame.minY + 8)

            panel.setFrame(NSRect(origin: origin, size: panelSize), display: true)
        }

        panel.invalidateShadow()
        panel.orderFrontRegardless()
        panel.makeKey()
        isPanelVisible = true
    }

    private func makePanelWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]

        let content = popoverController.view
        content.frame = NSRect(origin: .zero, size: panelSize)
        content.autoresizingMask = [.width, .height]

        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView(frame: NSRect(origin: .zero, size: panelSize))
            glassView.autoresizingMask = [.width, .height]
            glassView.style = .regular
            glassView.cornerRadius = 28
            glassView.contentView = content
            panel.contentView = glassView
        } else {
            panel.contentView = content
        }

        return panel
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        button.image = sunStatusImage(boostLevel: effectiveBoostLevel, isActive: isActive)
        button.title = ""
        button.toolTip = isSupported
            ? "Sunray XDR: \(isActive ? "On" : "Off")"
            : "Sunray XDR: unsupported display"
    }

    private func syncUI() {
        updateStatusItem()
        popoverController?.syncFromApp()
    }

    // MARK: - Global hotkey

    private func registerGlobalHotkey() {
        let hotkeyID = EventHotKeyID(signature: OSType(0x58445242), id: 1) // XDRB
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(controlKey | optionKey | cmdKey),
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr {
            hotkeyRef = ref
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                let app = Unmanaged<XDRApp>.fromOpaque(userData!).takeUnretainedValue()
                DispatchQueue.main.async { app.toggleXDR() }
                return noErr
            }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        } else {
            fputs("Could not register global hotkey Ctrl+Option+Cmd+V\n", stderr)
        }
    }

    // MARK: - System event handling

    private func observeSystemEvents() {
        let notificationCenter = NotificationCenter.default
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        notificationCenter.addObserver(
            self,
            selector: #selector(handleDisplayChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        workspaceCenter.addObserver(
            self,
            selector: #selector(handleSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )

        workspaceCenter.addObserver(
            self,
            selector: #selector(handleScreenWake),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )

        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.watchdogCheck()
        }
    }

    private func watchdogCheck() {
        updateEDRHeadroom()

        guard shouldBeActive else { return }

        if !isSupported {
            if isActive {
                deactivate()
                fputs("Watchdog — EDR unavailable, deactivated\n", stderr)
            }
            return
        }

        if !isActive {
            activate()
            fputs("Watchdog — EDR restored, reactivated\n", stderr)
            return
        }

        if let window = overlayWindow, !window.isVisible {
            window.orderFrontRegardless()
            fputs("Watchdog — window restored\n", stderr)
        } else if overlayWindow == nil {
            isActive = false
            activate()
            fputs("Watchdog — XDR recreated\n", stderr)
        }
    }

    private func updateEDRHeadroom() {
        let previousEffectiveBoost = effectiveBoostLevel
        let currentMaxEDR = NSScreen.main?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0
        guard abs(currentMaxEDR - maxEDR) > 0.05 else { return }

        let oldMaxEDR = maxEDR
        maxEDR = currentMaxEDR

        if isActive, abs(effectiveBoostLevel - previousEffectiveBoost) > 0.05 {
            boostView?.clearColor = clearColorForCurrentBoost()
            fputs("Effective boost — \(formattedBoost(effectiveBoostLevel))\n", stderr)
        }

        fputs("EDR headroom — \(formattedBoost(Double(oldMaxEDR))) to \(formattedBoost(Double(maxEDR)))\n", stderr)
        syncUI()
    }

    @objc private func handleSpaceChange() {
        guard shouldBeActive, isActive else { return }
        scheduleReassert(delay: 0.5)
    }

    @objc private func handleScreenWake() {
        guard shouldBeActive else { return }
        scheduleReassert(delay: 1.5)
    }

    @objc private func handleDisplayChange() {
        let previousEffectiveBoost = effectiveBoostLevel
        refreshDisplayCapabilities()

        guard isActive, shouldBeActive else {
            syncUI()
            return
        }

        guard isSupported else {
            deactivate()
            fputs("Display changed — EDR lost\n", stderr)
            syncUI()
            return
        }

        if let window = overlayWindow, let screen = NSScreen.main {
            let targetFrame = overlayFrame(for: screen)
            if window.frame != targetFrame {
                applyOverlayFrame(targetFrame)
                fputs("Display changed — overlay resized\n", stderr)
            }

            if abs(effectiveBoostLevel - previousEffectiveBoost) > 0.05 {
                boostView?.clearColor = clearColorForCurrentBoost()
                fputs("Display changed — effective boost \(formattedBoost(effectiveBoostLevel))\n", stderr)
            }
        } else {
            isActive = false
            activate()
            fputs("Display changed — XDR recreated\n", stderr)
        }

        syncUI()
    }

    private func scheduleReassert(delay: Double) {
        pendingReassert?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldBeActive else { return }
            self.updateEDRHeadroom()

            if let window = self.overlayWindow {
                if let screen = NSScreen.main {
                    let targetFrame = self.overlayFrame(for: screen)
                    if window.frame != targetFrame {
                        self.applyOverlayFrame(targetFrame)
                    }
                }
                window.orderFrontRegardless()
            } else if self.isSupported {
                self.isActive = false
                self.activate()
                fputs("Reasserted overlay\n", stderr)
            }
        }

        pendingReassert = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - User actions

    @objc func toggleXDR() {
        if isActive {
            shouldBeActive = false
            deactivate()
        } else {
            shouldBeActive = true
            activate()
        }
    }

    func setBoostLevel(_ value: Double) {
        boostLevel = clampedBoost(value)
        persistBoostLevel()

        if isActive, let view = boostView {
            view.clearColor = clearColorForCurrentBoost()
        }

        fputs("XDR level — \(formattedBoost(boostLevel))\n", stderr)
        syncUI()
    }

    func setMaxBoost() {
        setBoostLevel(maxBoostLevel)
    }

    func toggleSplitPreview() {
        splitPreviewEnabled.toggle()

        if splitPreviewEnabled, !isActive {
            shouldBeActive = true
            activate()
        } else if isActive, let screen = NSScreen.main {
            applyOverlayFrame(overlayFrame(for: screen))
        }

        fputs("Split preview — \(splitPreviewEnabled ? "on" : "off")\n", stderr)
        syncUI()
    }

    func checkForUpdates() {
        guard let url = URL(string: "https://api.github.com/repos/SimonMaj/sunray-xdr/releases/latest") else { return }

        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.2"
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let releaseURLString = json["html_url"] as? String,
                  let releaseURL = URL(string: releaseURLString) else {
                DispatchQueue.main.async {
                    self.showUpdateAlert(
                        title: "Could not check for updates",
                        message: "Open GitHub Releases instead?",
                        releaseURL: URL(string: "https://github.com/SimonMaj/sunray-xdr/releases")
                    )
                }
                return
            }

            DispatchQueue.main.async {
                if isVersion(tagName, newerThan: currentVersion) {
                    self.showUpdateAlert(
                        title: "Update available",
                        message: "Sunray XDR \(tagName) is available. You have \(currentVersion).",
                        releaseURL: releaseURL
                    )
                } else {
                    self.showUpdateAlert(
                        title: "You're up to date",
                        message: "Sunray XDR \(currentVersion) is the latest version.",
                        releaseURL: nil
                    )
                }
            }
        }.resume()
    }

    private func showUpdateAlert(title: String, message: String, releaseURL: URL?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational

        if releaseURL != nil {
            alert.addButton(withTitle: "Open Releases")
            alert.addButton(withTitle: "OK")
        } else {
            alert.addButton(withTitle: "OK")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let releaseURL {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    // MARK: - Start at login

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.sunray-xdr.agent.plist")
    }

    private var legacyLaunchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.xdr-boost.agent.plist")
    }

    var startsAtLogin: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
            || FileManager.default.fileExists(atPath: legacyLaunchAgentURL.path)
    }

    func setStartsAtLogin(_ enabled: Bool) {
        if enabled {
            installLaunchAgent()
        } else {
            removeLaunchAgent()
        }
        syncUI()
    }

    private func installLaunchAgent() {
        guard let executablePath = Bundle.main.executableURL?.path else { return }
        removeLegacyLaunchAgent()

        let plist: [String: Any] = [
            "Label": "com.sunray-xdr",
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive"
        ]

        do {
            let directory = launchAgentURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL, options: .atomic)
            runProcess("/bin/launchctl", ["unload", launchAgentURL.path])
            runProcess("/bin/launchctl", ["load", launchAgentURL.path])
            fputs("Start at login enabled\n", stderr)
        } catch {
            fputs("Could not enable start at login: \(error.localizedDescription)\n", stderr)
        }
    }

    private func removeLaunchAgent() {
        runProcess("/bin/launchctl", ["unload", launchAgentURL.path])
        do {
            if FileManager.default.fileExists(atPath: launchAgentURL.path) {
                try FileManager.default.removeItem(at: launchAgentURL)
            }
            removeLegacyLaunchAgent()
            fputs("Start at login disabled\n", stderr)
        } catch {
            fputs("Could not disable start at login: \(error.localizedDescription)\n", stderr)
        }
    }

    private func removeLegacyLaunchAgent() {
        runProcess("/bin/launchctl", ["unload", legacyLaunchAgentURL.path])
        try? FileManager.default.removeItem(at: legacyLaunchAgentURL)
    }

    @objc func quit() {
        deactivate()
        NSApp.terminate(nil)
    }

    // MARK: - XDR overlay

    func activate() {
        refreshDisplayCapabilities()
        guard isSupported else {
            shouldBeActive = false
            NSSound.beep()
            syncUI()
            fputs("Display doesn't support XDR\n", stderr)
            return
        }

        guard let screen = NSScreen.main else { return }
        boostLevel = clampedBoost(boostLevel)
        persistBoostLevel()

        let frame = overlayFrame(for: screen)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.canHide = false
        window.sharingType = .none
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 10
        view.clearColor = clearColorForCurrentBoost()
        view.wantsLayer = true

        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
        }

        boostRenderer = Renderer(device: device)
        view.delegate = boostRenderer
        window.contentView = view
        window.contentView?.layer?.compositingFilter = "multiply"

        window.alphaValue = 0
        window.orderFrontRegardless()

        overlayWindow = window
        boostView = view
        boostRenderer?.onFirstFrame = { [weak window] in
            window?.alphaValue = 1
        }
        isActive = true
        activationPulse += 1

        fputs("XDR ON — \(formattedBoost(effectiveBoostLevel))\n", stderr)
        syncUI()
    }

    func deactivate() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        boostView = nil
        boostRenderer = nil
        isActive = false
        splitPreviewEnabled = false

        fputs("XDR OFF\n", stderr)
        syncUI()
    }

    private func overlayFrame(for screen: NSScreen) -> NSRect {
        guard splitPreviewEnabled else { return screen.frame }
        var frame = screen.frame
        frame.size.width = max(1, floor(frame.width / 2))
        return frame
    }

    private func applyOverlayFrame(_ frame: NSRect) {
        overlayWindow?.setFrame(frame, display: false)
        boostView?.frame = NSRect(origin: .zero, size: frame.size)
    }

    private func clearColorForCurrentBoost() -> MTLClearColor {
        let level = effectiveBoostLevel
        return MTLClearColor(red: level, green: level, blue: level, alpha: 1.0)
    }
}

// MARK: - Control panel

private final class ControlPanelViewController: NSHostingController<BoostPanelView> {
    private weak var xdrApp: XDRApp?

    init(app: XDRApp) {
        self.xdrApp = app
        super.init(rootView: BoostPanelView(app: app))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        nil
    }

    func syncFromApp() {
        xdrApp?.objectWillChange.send()
    }
}

private struct RadiantSunIcon: View {
    let boostLevel: Double
    let isActive: Bool

    var body: some View {
        Canvas { context, size in
            let normalized = CGFloat((min(max(boostLevel, 1.0), 3.0) - 1.0) / 2.0)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let coreRadius: CGFloat = isActive ? 3.0 + normalized * 0.8 : 2.8
            let rayInner: CGFloat = 6.1
            let rayOuter: CGFloat = 7.0 + normalized * 3.6
            let color = isActive ? Color.yellow : Color.secondary

            var rays = Path()
            for index in 0..<8 {
                let angle = CGFloat(index) * .pi / 4
                rays.move(to: CGPoint(
                    x: center.x + cos(angle) * rayInner,
                    y: center.y + sin(angle) * rayInner
                ))
                rays.addLine(to: CGPoint(
                    x: center.x + cos(angle) * rayOuter,
                    y: center.y + sin(angle) * rayOuter
                ))
            }
            context.stroke(
                rays,
                with: .color(color.opacity(isActive ? 1 : 0.62)),
                style: StrokeStyle(lineWidth: isActive ? 2.0 : 1.6, lineCap: .round)
            )

            let coreRect = CGRect(
                x: center.x - coreRadius,
                y: center.y - coreRadius,
                width: coreRadius * 2,
                height: coreRadius * 2
            )
            let core = Path(ellipseIn: coreRect)
            if isActive {
                context.fill(core, with: .color(color))
                context.addFilter(.blur(radius: 3.5))
                context.fill(Path(ellipseIn: coreRect.insetBy(dx: -2.5, dy: -2.5)), with: .color(color.opacity(0.26)))
            } else {
                context.stroke(core, with: .color(color.opacity(0.7)), lineWidth: 1.6)
            }
        }
    }
}

private struct SolarAtmosphereView: View {
    let boostLevel: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let normalized = CGFloat((min(max(boostLevel, 1.0), 3.0) - 1.0) / 2.0)
                let source = CGPoint(x: 42, y: 48)
                let panelRect = CGRect(origin: .zero, size: size)
                let bloomRadius = max(size.width, size.height) * (0.86 + normalized * 0.16)

                context.fill(
                    Path(panelRect),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: Color.yellow.opacity(0.16 + normalized * 0.06), location: 0.00),
                            .init(color: Color.orange.opacity(0.07 + normalized * 0.03), location: 0.22),
                            .init(color: Color.yellow.opacity(0.025), location: 0.48),
                            .init(color: Color.clear, location: 0.86)
                        ]),
                        center: source,
                        startRadius: 0,
                        endRadius: bloomRadius
                    )
                )

                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 16))

                    for index in 0..<6 {
                        let phase = time * 0.22 + Double(index) * 0.76
                        let angle = CGFloat(0.10 + Double(index) * 0.20 + sin(phase) * 0.028)
                        let spread = CGFloat(0.055 + normalized * 0.014)
                        let length = max(size.width, size.height) * (1.28 + normalized * 0.12)
                        let start = CGFloat(12 + index * 12)

                        var ray = Path()
                        ray.move(to: CGPoint(
                            x: source.x + cos(angle) * start,
                            y: source.y + sin(angle) * start
                        ))
                        ray.addLine(to: CGPoint(
                            x: source.x + cos(angle - spread) * length,
                            y: source.y + sin(angle - spread) * length
                        ))
                        ray.addLine(to: CGPoint(
                            x: source.x + cos(angle + spread) * length,
                            y: source.y + sin(angle + spread) * length
                        ))
                        ray.closeSubpath()

                        let shimmer = CGFloat((sin(phase * 0.8) + 1) / 2)
                        layer.fill(
                            ray,
                            with: .linearGradient(
                                Gradient(stops: [
                                    .init(color: Color.yellow.opacity(0.060 + shimmer * 0.018), location: 0.00),
                                    .init(color: Color.orange.opacity(0.020), location: 0.35),
                                    .init(color: Color.clear, location: 1.00)
                                ]),
                                startPoint: source,
                                endPoint: CGPoint(
                                    x: source.x + cos(angle) * length,
                                    y: source.y + sin(angle) * length
                                )
                            )
                        )
                    }
                }
            }
            .drawingGroup(opaque: false)
        }
        .blendMode(.screen)
        .opacity(0.78)
        .allowsHitTesting(false)
    }
}

private struct BoostSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let isActive: Bool
    let isEnabled: Bool

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let progress = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                .clamped(to: 0...1)
            let knobSize: CGFloat = 20
            let knobX = progress * (width - knobSize) + knobSize / 2

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(height: 6)

                Capsule()
                    .fill((isActive ? Color.yellow : Color.secondary).opacity(isActive ? 0.82 : 0.42))
                    .frame(width: max(knobX, 6), height: 6)

                Circle()
                    .fill(Color.white.opacity(isEnabled ? 0.94 : 0.52))
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: Color.black.opacity(0.22), radius: 3, y: 1)
                    .position(x: knobX, y: proxy.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        let clampedX = min(max(gesture.location.x, knobSize / 2), width - knobSize / 2)
                        let nextProgress = Double((clampedX - knobSize / 2) / (width - knobSize))
                        value = range.lowerBound + nextProgress * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: 24)
        .opacity(isEnabled ? 1 : 0.48)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private struct BoostPanelView: View {
    @ObservedObject var app: XDRApp
    @State private var activationGlow = false

    private var boostBinding: Binding<Double> {
        Binding(
            get: { app.effectiveBoostLevel },
            set: { app.setBoostLevel($0) }
        )
    }

    private var activeBinding: Binding<Bool> {
        Binding(
            get: { app.isActive },
            set: { enabled in
                if enabled != app.isActive {
                    app.toggleXDR()
                }
            }
        )
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { app.startsAtLogin },
            set: { app.setStartsAtLogin($0) }
        )
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            ZStack {
                if app.isActive && app.isPanelVisible {
                    SolarAtmosphereView(boostLevel: app.effectiveBoostLevel)
                        .transition(.opacity)
                }

                panelContent
                    .frame(width: 292)
                    .padding(18)
            }
                .frame(width: 330, height: 344)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay { activationGlowOverlay }
                .onChange(of: app.activationPulse) { _, _ in
                    playActivationGlow()
                }
                .animation(.easeOut(duration: 0.28), value: app.isActive)
        } else {
            panelContent
                .frame(width: 292)
                .padding(18)
                .background(
                    Color.primary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                )
                .padding(10)
        }
    }

    private var panelContent: some View {
        VStack(spacing: 13) {
            header
            Divider().opacity(0.38)
            controls
            Divider().opacity(0.26)
            settings
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            RadiantSunIcon(boostLevel: app.effectiveBoostLevel, isActive: app.isActive)
                .frame(width: 24, height: 24)
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: app.effectiveBoostLevel)
                .animation(.spring(response: 0.24, dampingFraction: 0.7), value: app.isActive)

            VStack(alignment: .leading, spacing: 1) {
                Text("Sunray XDR")
                    .font(.system(size: 16, weight: .semibold))
                Text(app.isSupported ? "Liquid Retina XDR" : "XDR unavailable")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var activationGlowOverlay: some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.yellow.opacity(0.85),
                        Color.white.opacity(0.75),
                        Color.yellow.opacity(0.25),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: activationGlow ? 1.6 : 0.4
            )
            .shadow(color: Color.yellow.opacity(activationGlow ? 0.46 : 0), radius: 18)
            .opacity(activationGlow ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func playActivationGlow() {
        guard app.isActive else { return }

        activationGlow = false
        withAnimation(.easeOut(duration: 0.14)) {
            activationGlow = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
            withAnimation(.easeOut(duration: 0.55)) {
                activationGlow = false
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formattedBoost(app.effectiveBoostLevel))
                        .font(.system(size: 29, weight: .semibold, design: .default))
                        .monospacedDigit()
                    Text(app.isActive ? "On" : "Off")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: activeBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(.yellow)
                    .disabled(!app.isSupported)
            }

            BoostSlider(
                value: boostBinding,
                range: 1.0...max(app.maxBoostLevel, 1.1),
                isActive: app.isActive,
                isEnabled: app.isSupported
            )

            HStack {
                Text("1x")
                Spacer()
                Text("3x")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)

            HStack(spacing: 7) {
                presetButton("Soft", value: 1.5)
                presetButton("2x", value: 2.0)
                presetButton("Max", value: app.maxBoostLevel)
            }
        }
    }

    @ViewBuilder
    private func presetButtonBackground(selected: Bool) -> some View {
        if #available(macOS 26.0, *) {
            Capsule()
                .fill(selected ? Color.yellow.opacity(0.20) : Color.clear)
        } else {
            Capsule()
                .fill(selected ? Color.yellow.opacity(0.20) : Color.primary.opacity(0.04))
        }
    }

    private var settings: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    Text("Start with macOS")
                        .font(.system(size: 12, weight: .medium))

                    Toggle("", isOn: loginBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Spacer()

                utilityIconButton(
                    symbol: "rectangle.split.2x1",
                    isActive: app.splitPreviewEnabled,
                    help: "Split preview"
                ) {
                    app.toggleSplitPreview()
                }
                .disabled(!app.isSupported)

                utilityIconButton(
                    symbol: "arrow.clockwise",
                    isActive: false,
                    help: "Check for updates"
                ) {
                    app.checkForUpdates()
                }
            }

            Divider().opacity(0.34)

            compactLabel("keyboard", "Ctrl Option Cmd V")

            HStack(spacing: 7) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                Text("Hidden from screenshots")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    app.quit()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "power")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Exit")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Exit Sunray XDR")
            }

            if !app.isSupported {
                Text("Requires a MacBook Pro Liquid Retina XDR display.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func utilityIconButton(
        symbol: String,
        isActive: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? .yellow : .secondary)
        .background(
            Circle()
                .fill(isActive ? Color.yellow.opacity(0.18) : Color.primary.opacity(0.05))
        )
        .overlay(
            Circle()
                .strokeBorder(Color.primary.opacity(isActive ? 0.16 : 0.08), lineWidth: 1)
        )
        .help(help)
    }

    private func presetButton(_ title: String, value: Double) -> some View {
        let selected = abs(value - app.effectiveBoostLevel) < 0.05
        return Button {
            app.setBoostLevel(value)
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .primary : .secondary)
        .contentShape(Capsule())
        .background { presetButtonBackground(selected: selected) }
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(selected ? 0.16 : 0.08), lineWidth: 1)
        )
        .disabled(!app.isSupported || value > app.maxBoostLevel + 0.01)
    }

    private func compactLabel(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = XDRApp()
app.delegate = delegate

signal(SIGINT) { _ in exit(0) }
signal(SIGTERM) { _ in exit(0) }

app.run()
