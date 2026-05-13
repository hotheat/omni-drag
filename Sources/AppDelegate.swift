import AppKit
import ApplicationServices
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private enum DragMode {
        case disabled
        case move
        case resize
    }

    private var windowRef: AXUIElement?
    private var offset: CGPoint = .zero
    private var mode: DragMode = .disabled
    private var statusItem: NSStatusItem?
    private var eventMonitors: [Any] = []
    private let logger = DragLogger()
    private var lastModeDescription = "disabled"
    private var loggedMissingWindowRef = false
    private var desktopBounds: CGRect = .null
    private var throttledLogs: [String: TimeInterval] = [:]
    private var moveTimer: DispatchSourceTimer?
    private var pendingMovePosition: CGPoint?
    private var lastAppliedMovePosition: CGPoint?
    private var isMoveInFlight = false
    private var resizeAnchorMousePosition: CGPoint?
    private var resizeAnchorWindowSize: CGSize?
    private var lastAppliedResizeSize: CGSize?
    private let axQueue = DispatchQueue(label: "com.omnidrag.ax")
    private let axTimeoutSeconds: Float = 0.02
    private var moveRequestVersion: UInt64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        setup()
        checkAccessibilityPermission()
        logger.log("OmniDrag started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()
        moveTimer?.cancel()
        moveTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc
    private func menuQuit(_ sender: Any?) {
        NSApplication.shared.terminate(sender)
    }

    private func setup() {
        logger.debugMode = Bundle.main.object(forInfoDictionaryKey: "DebugMode") as? Bool ?? false
        updateDesktopBounds()
        setupMoveTimer()
        setupEvents()
        setupStatusBarMenu()
    }

    private func checkAccessibilityPermission() {
        let trusted = AXIsProcessTrusted()
        logger.log("Accessibility trusted: \(trusted)")
        guard !trusted else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "OmniDrag 需要打开辅助操作权限"
        alert.informativeText = "请设置相关权限"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        } else {
            NSApplication.shared.terminate(nil)
        }
    }

    private func setupEvents() {
        UserDefaults.standard.register(defaults: [
            "test": false,
        ])

        let globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.stateChanged(event)
        }
        if let globalFlagsMonitor {
            eventMonitors.append(globalFlagsMonitor)
        }

        let localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.stateChanged(event)
            return event
        }
        if let localFlagsMonitor {
            eventMonitors.append(localFlagsMonitor)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        let globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.mouseMoved(event)
        }
        if let globalMouseMonitor {
            eventMonitors.append(globalMouseMonitor)
        }
    }

    private func setupStatusBarMenu() {
        let menu = NSMenu(title: "OmniDrag")

        let dragItem = NSMenuItem(title: "Drag: Use ⇧ & ⌘ & MouseMove ", action: nil, keyEquivalent: "")
        dragItem.isEnabled = false
        menu.addItem(dragItem)

        let resizeItem = NSMenuItem(title: "Resize: Use ⇧ & ⌥ & MouseMove", action: nil, keyEquivalent: "")
        resizeItem.isEnabled = false
        menu.addItem(resizeItem)

        menu.addItem(NSMenuItem(title: "Quit OmniDrag Process", action: #selector(menuQuit(_:)), keyEquivalent: ""))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.menu = menu
        if let button = item.button {
            if let image = NSImage(named: "StatusIcon")?.copy() as? NSImage {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            }
            button.imageScaling = .scaleProportionallyDown
            button.imagePosition = .imageOnly
            button.toolTip = "OmniDrag"
        }
        statusItem = item
    }

    private func stateChanged(_ event: NSEvent) {
        updateMode(with: event)

        guard mode != .disabled else {
            clearTrackedWindow()
            return
        }

        if windowRef == nil {
            acquireWindowReference(logFailure: !loggedMissingWindowRef)
            if windowRef == nil {
                loggedMissingWindowRef = true
            }
        }
    }

    private func mouseMoved(_ event: NSEvent) {
        updateMode(with: event)

        guard mode != .disabled else {
            clearTrackedWindow()
            return
        }

        if windowRef == nil {
            acquireWindowReference(logFailure: !loggedMissingWindowRef)
            if windowRef == nil {
                loggedMissingWindowRef = true
                return
            }
        }

        switch mode {
        case .move:
            pendingMovePosition = mousePosition()
        case .resize:
            resizeWindow()
        case .disabled:
            break
        }
    }

    private func updateMode(with event: NSEvent) {
        updateMode(with: event.modifierFlags)
    }

    private func updateMode(with flags: NSEvent.ModifierFlags) {
        let previousMode = mode
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        let enableMove = flags.contains(.command) && flags.contains(.shift)
        let enableResize = flags.contains(.shift) && flags.contains(.option)

        if enableMove {
            mode = .move
        } else if enableResize {
            mode = .resize
        } else {
            mode = .disabled
        }

        let modeDescription: String
        switch mode {
        case .disabled:
            modeDescription = "disabled"
        case .move:
            modeDescription = "move"
        case .resize:
            modeDescription = "resize"
        }

        if modeDescription != lastModeDescription {
            if previousMode != mode {
                windowRef = nil
                offset = .zero
                loggedMissingWindowRef = false
                if previousMode == .move {
                    resetMoveState()
                }
                resetResizeState()
            }

            logger.log("Mode changed to \(modeDescription), flags=\(flags.rawValue)")
            lastModeDescription = modeDescription
            loggedMissingWindowRef = false
        }
    }

    private func clearTrackedWindow() {
        windowRef = nil
        offset = .zero
        loggedMissingWindowRef = false
        resetMoveState()
        resetResizeState()
    }

    private func resetMoveState() {
        pendingMovePosition = nil
        lastAppliedMovePosition = nil
        isMoveInFlight = false
        moveRequestVersion &+= 1
    }

    private func resetResizeState() {
        resizeAnchorMousePosition = nil
        resizeAnchorWindowSize = nil
        lastAppliedResizeSize = nil
    }

    private func logThrottled(key: String, interval: TimeInterval = 2, _ message: @autoclosure () -> String) {
        let now = Date().timeIntervalSinceReferenceDate
        if let last = throttledLogs[key], now - last < interval {
            return
        }
        throttledLogs[key] = now
        logger.log(message())
    }

    @objc
    private func handleScreenParametersChanged() {
        updateDesktopBounds()
    }

    private func setupMoveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.flushPendingMove()
        }
        timer.resume()
        moveTimer = timer
    }

    private func flushPendingMove() {
        guard mode == .move, let pendingMovePosition else {
            return
        }

        guard !isMoveInFlight else {
            return
        }

        if let lastAppliedMovePosition, pointsApproximatelyEqual(lastAppliedMovePosition, pendingMovePosition) {
            self.pendingMovePosition = nil
            return
        }

        self.pendingMovePosition = nil
        isMoveInFlight = true
        moveRequestVersion &+= 1
        let requestVersion = moveRequestVersion
        moveWindow(to: pendingMovePosition, requestVersion: requestVersion, requestedPosition: pendingMovePosition)
    }

    private func updateDesktopBounds() {
        desktopBounds = NSScreen.screens.reduce(into: CGRect.null) { result, screen in
            result = result.union(screen.frame)
        }
    }

    private func acquireWindowReference(logFailure: Bool) {
        let position = mousePosition()

        if let matchedWindow = windowElementByWindowList(at: position) {
            trackWindow(matchedWindow, at: position)
            return
        }

        if let matchedWindow = windowElement(at: position) {
            trackWindow(matchedWindow, at: position)
            return
        }

        if logFailure {
            logThrottled(key: "window-match-miss", "No AX window matched current mouse position")
        }
        windowRef = nil
    }

    private func windowElement(at position: CGPoint) -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(position.x),
            Float(position.y),
            &element
        )
        guard result == .success, let element else {
            return nil
        }

        if let window = copyElementAttribute(kAXWindowAttribute, from: element) {
            return window
        }

        if let topLevelElement = copyElementAttribute(kAXTopLevelUIElementAttribute, from: element) {
            return topLevelElement
        }

        var currentElement: AXUIElement? = element
        for _ in 0..<32 {
            guard let resolvedElement = currentElement else {
                break
            }

            if let role = copyStringAttribute(kAXRoleAttribute, from: resolvedElement),
               role == kAXWindowRole as String {
                return resolvedElement
            }

            currentElement = copyElementAttribute(kAXParentAttribute, from: resolvedElement)
        }

        return nil
    }

    private func windowElementByWindowList(at position: CGPoint) -> AXUIElement? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }

            guard let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }

            guard var bounds = CGRect(dictionaryRepresentation: boundsDictionary), bounds.contains(position) else {
                continue
            }

            if bounds.origin.x == -0 {
                bounds.origin.x = 0
            }
            if bounds.origin.y == -0 {
                bounds.origin.y = 0
            }

            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t else {
                return nil
            }

            return matchWindow(for: pid, bounds: bounds, position: position)
        }

        return nil
    }

    private func trackWindow(_ matchedWindow: AXUIElement, at position: CGPoint) {
        windowRef = matchedWindow
        loggedMissingWindowRef = false
        resetResizeState()
        if let origin = copyCGPointAttribute(kAXPositionAttribute, from: matchedWindow) {
            offset = CGPoint(x: position.x - origin.x, y: position.y - origin.y)
        } else {
            offset = .zero
        }
    }

    private func matchWindow(for pid: pid_t, bounds: CGRect, position: CGPoint) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var appWindowListRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &appWindowListRef)
        guard result == .success, let appWindowListRef else {
            logThrottled(key: "ax-windows-\(pid)", "Failed to read AX windows for pid \(pid): \(result.rawValue)")
            return nil
        }

        let appWindowList = unsafeBitCast(appWindowListRef, to: CFArray.self)
        let count = CFArrayGetCount(appWindowList)
        var bestContainingWindow: AXUIElement?
        var bestContainingScore: CGFloat = .greatestFiniteMagnitude
        for index in 0..<count {
            let element = CFArrayGetValueAtIndex(appWindowList, index)
            let window = unsafeBitCast(element, to: AXUIElement.self)
            guard
                let origin = copyCGPointAttribute(kAXPositionAttribute, from: window),
                let size = copyCGSizeAttribute(kAXSizeAttribute, from: window)
            else {
                continue
            }

            let frame = CGRect(origin: origin, size: size)
            if framesMatch(frame, bounds) {
                return window
            }

            let expandedFrame = frame.insetBy(dx: -12, dy: -12)
            if expandedFrame.contains(position) {
                let score =
                    abs(frame.origin.x - bounds.origin.x)
                    + abs(frame.origin.y - bounds.origin.y)
                    + abs(frame.size.width - bounds.size.width)
                    + abs(frame.size.height - bounds.size.height)
                if score < bestContainingScore {
                    bestContainingScore = score
                    bestContainingWindow = window
                }
            }
        }

        return bestContainingWindow
    }

    private func moveWindow(to position: CGPoint, requestVersion: UInt64, requestedPosition: CGPoint) {
        guard let windowRef else {
            logThrottled(key: "move-without-window", "Move requested without window reference")
            isMoveInFlight = false
            return
        }

        var target = position
        target.x -= offset.x
        target.y -= offset.y

        let retainedWindowRef = windowRef
        guard let value = AXValueCreate(.cgPoint, &target) else {
            isMoveInFlight = false
            return
        }

        axQueue.async { [weak self] in
            guard let self else {
                return
            }

            let shouldProceed = DispatchQueue.main.sync {
                self.moveRequestVersion == requestVersion && self.mode == .move
            }
            guard shouldProceed else {
                return
            }

            let _ = AXUIElementSetMessagingTimeout(retainedWindowRef, self.axTimeoutSeconds)
            let result = AXUIElementSetAttributeValue(retainedWindowRef, kAXPositionAttribute as CFString, value)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.moveRequestVersion == requestVersion else {
                    return
                }

                self.isMoveInFlight = false
                if result != .success {
                    self.logger.log("Failed to move window: \(result.rawValue)")
                    self.lastAppliedMovePosition = nil
                } else {
                    self.lastAppliedMovePosition = requestedPosition
                }

                if self.pendingMovePosition != nil {
                    self.flushPendingMove()
                }
            }
        }
    }

    private func resizeWindow() {
        guard let windowRef else {
            logThrottled(key: "resize-without-window", "Resize requested without window reference or size")
            return
        }

        guard ensureResizeAnchor(for: windowRef) else {
            return
        }

        guard
            let resizeAnchorMousePosition,
            let resizeAnchorWindowSize
        else {
            return
        }

        let currentMousePosition = mousePosition()
        let offsetSize = CGSize(
            width: currentMousePosition.x - resizeAnchorMousePosition.x,
            height: currentMousePosition.y - resizeAnchorMousePosition.y
        )
        if abs(offsetSize.width) < .ulpOfOne, abs(offsetSize.height) < .ulpOfOne {
            return
        }

        var targetSize = CGSize(
            width: max(1, resizeAnchorWindowSize.width + offsetSize.width),
            height: max(1, resizeAnchorWindowSize.height + offsetSize.height)
        )
        if let lastAppliedResizeSize, sizesApproximatelyEqual(lastAppliedResizeSize, targetSize) {
            return
        }

        guard let value = AXValueCreate(.cgSize, &targetSize) else {
            return
        }

        let _ = AXUIElementSetMessagingTimeout(windowRef, axTimeoutSeconds)
        let result = AXUIElementSetAttributeValue(windowRef, kAXSizeAttribute as CFString, value)
        if result != .success {
            logger.log("Failed to resize window: \(result.rawValue)")
            lastAppliedResizeSize = nil
        } else {
            lastAppliedResizeSize = targetSize
        }
    }

    private func ensureResizeAnchor(for windowRef: AXUIElement) -> Bool {
        if resizeAnchorMousePosition != nil, resizeAnchorWindowSize != nil {
            return true
        }

        let _ = AXUIElementSetMessagingTimeout(windowRef, axTimeoutSeconds)
        guard let windowSize = copyCGSizeAttribute(kAXSizeAttribute, from: windowRef) else {
            logThrottled(key: "resize-without-window", "Resize requested without window reference or size")
            return false
        }

        resizeAnchorMousePosition = mousePosition()
        resizeAnchorWindowSize = windowSize
        lastAppliedResizeSize = windowSize
        return true
    }

    private func mousePosition() -> CGPoint {
        let point = NSEvent.mouseLocation
        guard !desktopBounds.isNull else {
            return point
        }
        return CGPoint(x: point.x, y: desktopBounds.maxY - point.y)
    }

    private func copyCGPointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard result == .success, let valueRef else {
            return nil
        }

        let value = unsafeBitCast(valueRef, to: AXValue.self)
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private func copyCGSizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard result == .success, let valueRef else {
            return nil
        }

        let value = unsafeBitCast(valueRef, to: AXValue.self)
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private func copyElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard result == .success, let valueRef else {
            return nil
        }

        return unsafeBitCast(valueRef, to: AXUIElement.self)
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard result == .success, let valueRef else {
            return nil
        }

        return valueRef as? String
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        approximatelyEqual(lhs.origin.x, rhs.origin.x)
            && approximatelyEqual(lhs.origin.y, rhs.origin.y)
            && approximatelyEqual(lhs.size.width, rhs.size.width)
            && approximatelyEqual(lhs.size.height, rhs.size.height)
    }

    private func approximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, tolerance: CGFloat = 1) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    private func pointsApproximatelyEqual(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 0.5) -> Bool {
        approximatelyEqual(lhs.x, rhs.x, tolerance: tolerance)
            && approximatelyEqual(lhs.y, rhs.y, tolerance: tolerance)
    }

    private func sizesApproximatelyEqual(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat = 0.5) -> Bool {
        approximatelyEqual(lhs.width, rhs.width, tolerance: tolerance)
            && approximatelyEqual(lhs.height, rhs.height, tolerance: tolerance)
    }
}
