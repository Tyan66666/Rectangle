/// MultiWindowManager.swift

import Cocoa
import MASShortcut

class MultiWindowManager {
    static func execute(parameters: ExecutionParameters) -> Bool {
        // TODO: Protocol and factory for all multi-window positioning algorithms
        switch parameters.action {
        case .reverseAll:
            ReverseAllManager.reverseAll(windowElement: parameters.windowElement)
            return true
        case .tileAll:
            tileAllWindowsOnScreen(windowElement: parameters.windowElement)
            return true
        case .cascadeAll:
            cascadeAllWindowsOnScreen(windowElement: parameters.windowElement)
            return true
        case .cascadeActiveApp:
            cascadeActiveAppWindowsOnScreen(windowElement: parameters.windowElement)
            return true
        case .tileActiveApp:
            tileActiveAppWindowsOnScreen(windowElement: parameters.windowElement)
            return true
        case .arrangeWindowsInZones:
            arrangeWindowsIntoZones(windowElement: parameters.windowElement)
            return true
        default:
            return false
        }
    }

    private static func allWindowsOnScreen(windowElement: AccessibilityElement? = nil, screen: NSScreen? = nil, sortByPID: Bool = false, allWindows: Bool = false) -> (screens: UsableScreens, windows: [AccessibilityElement])? {
        let screenDetection = ScreenDetection()

        // Prefer the cursor's screen for global hotkeys: they don't change the
        // focused app, so the cursor is the most reliable intent signal. Fall
        // back to the focused window when the cursor can't be resolved.
        let screens: UsableScreens?
        if let screen {
            screens = UsableScreens(currentScreen: screen, adjacentScreens: nil, numScreens: NSScreen.screens.count, screensOrdered: NSScreen.screens)
        } else if let windowElement {
            screens = screenDetection.detectScreens(using: windowElement)
        } else {
            screens = screenDetection.detectScreensAtCursor() ?? screenDetection.detectScreens(using: AccessibilityElement.getFrontWindowElement())
        }
        guard let screens else {
            NSSound.beep()
            Logger.log("Can't detect screen for multiple windows")
            return nil
        }

        let currentScreen = screens.currentScreen

        var windows = AccessibilityElement.getAllWindowElements(all: allWindows, screen: currentScreen)
        if sortByPID {
            windows.sort(by: { (w1: AccessibilityElement, w2: AccessibilityElement) -> Bool in
                w1.pid ?? pid_t(0) > w2.pid ?? pid_t(0)
            })
        }

        let screensOrdered = screens.screensOrdered
        var actualWindows = [AccessibilityElement]()
        for w in windows {
            if Defaults.todo.userEnabled, TodoManager.isTodoWindow(w) { continue }
            let snap = w.windowFilterSnapshot
            let onScreen = screenDetection.screenContaining(snap.frame, screens: screensOrdered) == currentScreen
            if onScreen, snap.isWindow, !snap.isSheet, !snap.isMinimized, !snap.isHidden, !snap.isSystemDialog {
                actualWindows.append(w)
            }
        }

        return (screens, actualWindows)
    }

    static func tileAllWindowsOnScreen(windowElement: AccessibilityElement? = nil) {
        guard let (screens, windows) = allWindowsOnScreen(windowElement: windowElement, sortByPID: true) else {
            return
        }

        let screenFrame = screens.currentScreen.adjustedVisibleFrame().screenFlipped
        let count = windows.count

        let columns = Int(ceil(sqrt(CGFloat(count))))
        let rows = Int(ceil(CGFloat(count) / CGFloat(columns)))
        let size = CGSize(width: (screenFrame.maxX - screenFrame.minX) / CGFloat(columns), height: (screenFrame.maxY - screenFrame.minY) / CGFloat(rows))

        for (ind, w) in windows.enumerated() {
            let column = ind % Int(columns)
            let row = ind / Int(columns)
            tileWindow(w, screenFrame: screenFrame, size: size, column: column, row: row)
        }
    }

    static func arrangeWindowsIntoZones(windowElement: AccessibilityElement? = nil, screen: NSScreen? = nil) {
        guard ZoneLayout.enabled else { return }
        guard let (screens, windows) = allWindowsOnScreen(windowElement: windowElement, screen: screen, sortByPID: true, allWindows: true) else {
            return
        }
        let zones = ZoneLayout.zones(for: screens.currentScreen)
        guard !zones.isEmpty else {
            return
        }
        let lastZone = zones[zones.count - 1]

        // Toggle enhanced UI once per app (not per window): the per-window
        // disable/enable is a system-preference round-trip that dominates the
        // cost when arranging many windows of the same app.
        var enhancedUIRestore: [AccessibilityElement] = []
        var seenAppPids: Set<pid_t> = []
        for w in windows {
            guard let pid = w.pid, !seenAppPids.contains(pid) else { continue }
            seenAppPids.insert(pid)
            if w.enhancedUserInterface == true {
                w.enhancedUserInterface = false
                enhancedUIRestore.append(w)
            }
        }

        for (ind, w) in windows.enumerated() {
            let zone = ind < zones.count ? zones[ind] : lastZone
            let target = zone.screenFlipped
            // Skip the AX round-trip when the window is already in its zone.
            let current = w.frame
            if abs(current.origin.x - target.origin.x) > 1 || abs(current.origin.y - target.origin.y) > 1 ||
               abs(current.width - target.width) > 1 || abs(current.height - target.height) > 1 {
                // Enhanced UI is already toggled once per app above, so set the
                // frame directly to skip setFrame's per-window app resolution.
                w.setFrameDirect(target)
            }
        }

        if Defaults.enhancedUI.value == .disableEnable {
            for w in enhancedUIRestore {
                w.enhancedUserInterface = true
            }
        }
        // Only stacked (overflow) windows need z-ordering; the rest land in
        // non-overlapping zones.
        if windows.count > zones.count {
            for w in windows[zones.count...].reversed() {
                w.bringToFront()
            }
        }
    }

    private static func tileWindow(_ w: AccessibilityElement, screenFrame: CGRect, size: CGSize, column: Int, row: Int) {
        var rect = w.frame

        // TODO: save previous position in history

        rect.origin.x = screenFrame.origin.x + size.width * CGFloat(column)
        rect.origin.y = screenFrame.origin.y + size.height * CGFloat(row)
        rect.size = size

        w.setFrame(rect)
    }

    static func cascadeAllWindowsOnScreen(windowElement: AccessibilityElement? = nil) {
        guard let (screens, windows) = allWindowsOnScreen(windowElement: windowElement, sortByPID: true) else {
            return
        }

        let screenFrame = screens.currentScreen.adjustedVisibleFrame().screenFlipped

        let delta = CGFloat(Defaults.cascadeAllDeltaSize.value)

        for (ind, w) in windows.enumerated() {
            cascadeWindow(w, screenFrame: screenFrame, delta: delta, index: ind)
        }
    }

    private struct CascadeActiveAppParameters {
        let right: Bool
        let bottom: Bool
        let numWindows: Int
        let size: CGSize

        init(windowFrame: CGRect, screenFrame: CGRect, numWindows: Int, size: CGSize, delta: CGFloat) {
            right = windowFrame.midX > screenFrame.midX
            bottom = windowFrame.midY > screenFrame.midY
            self.numWindows = numWindows
            let maxSize = CGSize(width: screenFrame.width - CGFloat(numWindows - 1) * delta, height: screenFrame.height - CGFloat(numWindows - 1) * delta)
            self.size = CGSize(width: min(size.width, maxSize.width), height: min(size.height, maxSize.height))
        }
    }

    static func cascadeActiveAppWindowsOnScreen(windowElement: AccessibilityElement? = nil) {
        guard let (screens, windows) = allWindowsOnScreen(windowElement: windowElement, sortByPID: true),
              let frontWindowElement = AccessibilityElement.getFrontWindowElement()
        else {
            return
        }

        let screenFrame = screens.currentScreen.adjustedVisibleFrame().screenFlipped

        let delta = CGFloat(Defaults.cascadeAllDeltaSize.value)

        // keep windows with a pid equal to the front window's pid
        var filtered = windows.filter(hasFrontWindowPid(_:))

        // parameters for cascading active app windows
        var cascadeParameters: CascadeActiveAppParameters?

        if let first = filtered.first {
            // move the first to become the last (top)
            filtered.append(filtered.removeFirst())
            // set up parameters
            cascadeParameters = CascadeActiveAppParameters(windowFrame: first.frame, screenFrame: screenFrame, numWindows: filtered.count, size: first.size!, delta: delta)
        }

        // cascade the filtered windows
        for (ind, w) in filtered.enumerated() {
            cascadeWindow(w, screenFrame: screenFrame, delta: delta, index: ind, cascadeParameters: cascadeParameters)
        }

        // return true for a w pid equal to the front window's pid
        func hasFrontWindowPid(_ w: AccessibilityElement) -> Bool {
            return w.pid == frontWindowElement.pid
        }
    }

    private static func cascadeWindow(_ w: AccessibilityElement, screenFrame: CGRect, delta: CGFloat, index: Int, cascadeParameters: CascadeActiveAppParameters? = nil) {
        var rect = w.frame

        // TODO: save previous position in history

        rect.origin.x = screenFrame.origin.x + delta * CGFloat(index)
        rect.origin.y = screenFrame.origin.y + delta * CGFloat(index)

        if let cascadeParameters {
            rect.size.width = cascadeParameters.size.width
            rect.size.height = cascadeParameters.size.height

            if cascadeParameters.right {
                rect.origin.x = screenFrame.origin.x + screenFrame.size.width - cascadeParameters.size.width - delta * CGFloat(index)
            }
            if cascadeParameters.bottom {
                rect.origin.y = screenFrame.origin.y + screenFrame.size.height - cascadeParameters.size.height - delta * CGFloat(cascadeParameters.numWindows - 1 - index)
            }
        }

        w.setFrame(rect)
        w.bringToFront()
    }

    static func tileActiveAppWindowsOnScreen(windowElement: AccessibilityElement? = nil) {
        guard let (screens, windows) = allWindowsOnScreen(windowElement: windowElement, sortByPID: true),
              let frontWindowElement = AccessibilityElement.getFrontWindowElement()
        else {
            return
        }

        let screenFrame = screens.currentScreen.adjustedVisibleFrame().screenFlipped

        // keep windows with a pid equal to the front window's pid
        let filtered = windows.filter { $0.pid == frontWindowElement.pid }

        let count = filtered.count

        let columns = Int(ceil(sqrt(CGFloat(count))))
        let rows = Int(ceil(CGFloat(count) / CGFloat(columns)))
        let size = CGSize(width: (screenFrame.maxX - screenFrame.minX) / CGFloat(columns), height: (screenFrame.maxY - screenFrame.minY) / CGFloat(rows))

        for (ind, w) in filtered.enumerated() {
            let column = ind % Int(columns)
            let row = ind / Int(columns)
            tileWindow(w, screenFrame: screenFrame, size: size, column: column, row: row)
        }
    }
}
