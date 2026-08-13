/// AccessibilityElement.swift

import Foundation

class AccessibilityElement {
    fileprivate let wrappedElement: AXUIElement
    
    init(_ element: AXUIElement) {
        wrappedElement = element
    }
    
    convenience init(_ pid: pid_t) {
        self.init(AXUIElementCreateApplication(pid))
    }
    
    convenience init?(_ bundleIdentifier: String) {
        guard let app = (NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleIdentifier }) else { return nil }
        self.init(app.processIdentifier)
    }
    
    convenience init?(_ position: CGPoint) {
        guard let element = AXUIElement.systemWide.getElementAtPosition(position) else { return nil }
        self.init(element)
    }
    
    private func getElementValue(_ attribute: NSAccessibility.Attribute) -> AccessibilityElement? {
        guard let value = wrappedElement.getValue(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AccessibilityElement(value as! AXUIElement)
    }
    
    private func getElementsValue(_ attribute: NSAccessibility.Attribute) -> [AccessibilityElement]? {
        guard let value = wrappedElement.getValue(attribute), let array = value as? [AXUIElement] else { return nil }
        return array.map { AccessibilityElement($0) }
    }
    
    private var role: NSAccessibility.Role? {
        guard let value = wrappedElement.getValue(.role) as? String else { return nil }
        return NSAccessibility.Role(rawValue: value)
    }
    
    private var isApplication: Bool? {
        guard let role = role else { return nil }
        return role == .application
    }
    
    var isWindow: Bool? {
        guard let role = role else { return nil }
        return role == .window
    }
    
    var isSheet: Bool? {
        guard let role = role else { return nil }
        return role == .sheet
    }
    
    var isToolbar: Bool? {
        guard let role = role else { return nil }
        return role == .toolbar
    }
    
    var isGroup: Bool? {
        guard let role = role else { return nil }
        return role == .group
    }
    
    var isTabGroup: Bool? {
        guard let role = role else { return nil }
        return role == .tabGroup
    }
    
    var isStaticText: Bool? {
        guard let role = role else { return nil }
        return role == .staticText
    }
    
    private var subrole: NSAccessibility.Subrole? {
        guard let value = wrappedElement.getValue(.subrole) as? String else { return nil }
        return NSAccessibility.Subrole(rawValue: value)
    }
    
    var isSystemDialog: Bool? {
        guard let subrole = subrole else { return nil }
        return subrole == .systemDialog
    }

    var isFullScreenButton: Bool? {
        guard let subrole = subrole else { return nil }
        return subrole == .fullScreenButton
    }
    
    private var position: CGPoint? {
        get {
            wrappedElement.getWrappedValue(.position)
        }
        set {
            guard let newValue = newValue else { return }
            wrappedElement.setValue(.position, newValue)
            Logger.log("AX position proposed: \(newValue.debugDescription), result: \(position?.debugDescription ?? "N/A")")
        }
    }
    
    func isResizable() -> Bool {
        if let isResizable = wrappedElement.isValueSettable(.size) {
            return isResizable
        }
        Logger.log("Unable to determine if window is resizeable. Assuming it is.")
        return true
    }
    
    var size: CGSize? {
        get {
            wrappedElement.getWrappedValue(.size)
        }
        set {
            guard let newValue = newValue else { return }
            wrappedElement.setValue(.size, newValue)
            Logger.log("AX sizing proposed: \(newValue.debugDescription), result: \(size?.debugDescription ?? "N/A")")
        }
    }

    var minimumSize: CGSize? {
        wrappedElement.getWrappedValue(.minSize)
            ?? wrappedElement.getWrappedValue(.minimumSize)
    }
    
    var frame: CGRect {
        guard let position = position, let size = size else { return .null }
        return .init(origin: position, size: size)
    }
    
    /// The Accessebility API only allows size & position adjustments individually.
    /// To handle moving to different displays, we have to adjust the size then the position, then the size again since macOS will enforce sizes that fit on the current display.
    /// When windows take a long time to adjust size & position, there is some visual stutter with doing each of these actions. The stutter can be slightly reduced by removing the initial size adjustment, which can make unsnap restore appear smoother.
    func setFrame(_ frame: CGRect, adjustSizeFirst: Bool = true) {
        let appElement = applicationElement
        var enhancedUI: Bool? = nil

        if let appElement = appElement {
            enhancedUI = appElement.enhancedUserInterface
            if enhancedUI == true {
                Logger.log("AXEnhancedUserInterface was enabled, will disable before resizing")
                appElement.enhancedUserInterface = false
            }
        }

        if adjustSizeFirst {
            size = frame.size
        }
        position = frame.origin
        size = frame.size

        // If "enhanced user interface" was originally enabled for the app, turn it back on
        if Defaults.enhancedUI.value == .disableEnable, let appElement = appElement, enhancedUI == true {
            appElement.enhancedUserInterface = true
        }
    }
    
    private var childElements: [AccessibilityElement]? {
        getElementsValue(.children)
    }
    
    func getChildElement(_ role: NSAccessibility.Role) -> AccessibilityElement? {
        return childElements?.first { $0.role == role }
    }
    
    func getChildElements(_ role: NSAccessibility.Role) -> [AccessibilityElement]? {
        guard let elements = (childElements?.filter { $0.role == role }), elements.count > 0 else {
            return nil
        }
        return elements
    }
    
    func getChildElement(_ subrole: NSAccessibility.Subrole) -> AccessibilityElement? {
        return childElements?.first { $0.subrole == subrole }
    }
    
    func getChildElements(_ subrole: NSAccessibility.Subrole) -> [AccessibilityElement]? {
        guard let elements = (childElements?.filter { $0.subrole == subrole }), elements.count > 0 else {
            return nil
        }
        return elements
    }
    
    func getSelfOrChildElementRecursively(_ position: CGPoint) -> AccessibilityElement? {
        func getChildElement() -> AccessibilityElement? {
            return element.childElements?
                .map { (element: $0, frame: $0.frame) }
                .filter { $0.frame.contains(position) }
                .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?
                .element
        }
        var element = self
        var elements = Set<AccessibilityElement>()
        while let childElement = getChildElement(), elements.insert(childElement).inserted {
            element = childElement
        }
        return element
    }
    
    var windowId: CGWindowID? {
        wrappedElement.getWindowId()
    }

    func getWindowId() -> CGWindowID? {
        if let windowId = windowId {
            return windowId
        }
        let frame = frame
        // Take the first match because there's no real way to guarantee which window we're actually getting
        if let pid = pid, let info = (WindowUtil.getWindowList().first { $0.pid == pid && $0.frame == frame }) {
            return info.id
        }
        if !frame.isNull {
            // Last resort (#640): derive a stand-in id from the accessibility
            // element's identity so window-id-keyed bookkeeping keeps working
            // when macOS isn't vending real window ids. CFHash is constant for
            // the same window across fetches and unaffected by moves/resizes.
            Logger.log("Using a derived window id for bookkeeping")
            return AccessibilityElement.deriveWindowId(fromElementHash: CFHash(wrappedElement))
        }
        Logger.log("Unable to obtain window id")
        return nil
    }

    /// The high bit keeps derived ids out of the real window id space;
    /// real ids are assigned incrementally by the window server.
    static func deriveWindowId(fromElementHash hash: CFHashCode) -> CGWindowID {
        CGWindowID(0x8000_0000) | (CGWindowID(truncatingIfNeeded: hash) & 0x7FFF_FFFF)
    }
    
    var pid: pid_t? {
        wrappedElement.getPid()
    }
    
    var windowElement: AccessibilityElement? {
        if isWindow == true { return self }
        return getElementValue(.window)
    }
    
    private var isMainWindow: Bool? {
        get {
            windowElement?.wrappedElement.getValue(.main) as? Bool
        }
        set {
            guard let newValue = newValue else { return }
            windowElement?.wrappedElement.setValue(.main, newValue)
        }
    }
    
    var isMinimized: Bool? {
        windowElement?.wrappedElement.getValue(.minimized) as? Bool
    }

    var title: String? {
        wrappedElement.getValue(.title) as? String
    }

    /// Caps how long AX calls through this element can block on an
    /// unresponsive app (the systemwide default is several seconds).
    func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(wrappedElement, seconds)
    }
    
    var isFullScreen: Bool? {
        guard let subrole = windowElement?.getElementValue(.fullScreenButton)?.subrole else { return nil }
        return subrole == .zoomButton
    }
    
    var titleBarFrame: CGRect? {
        guard
            let windowElement,
            case let windowFrame = windowElement.frame,
            windowFrame != .null,
            let closeButtonFrame = windowElement.getChildElement(.closeButton)?.frame,
            closeButtonFrame != .null
        else {
            return nil
        }
        let gap = closeButtonFrame.minY - windowFrame.minY
        let height = 2 * gap + closeButtonFrame.height
        return CGRect(origin: windowFrame.origin, size: CGSize(width: windowFrame.width, height: height))
    }
    
    private var applicationElement: AccessibilityElement? {
        if isApplication == true { return self }
        guard let pid = pid else { return nil }
        return AccessibilityElement(pid)
    }
    
    private var focusedWindowElement: AccessibilityElement? {
        applicationElement?.getElementValue(.focusedWindow)
    }
    
    var windowElements: [AccessibilityElement]? {
        guard let applicationElement else { return nil }
        if let windows = applicationElement.getElementsValue(.windows), !windows.isEmpty {
            return windows
        }
        // Some apps (e.g. Finder) don't expose kAXWindowsAttribute, but their
        // windows are still reachable as direct children.
        if let children = applicationElement.getElementsValue(.children) {
            let windowChildren = children.filter { $0.isWindow == true }
            if !windowChildren.isEmpty {
                return windowChildren
            }
        }
        return nil
    }
    
    var isHidden: Bool? {
        applicationElement?.wrappedElement.getValue(.hidden) as? Bool
    }
    
    var enhancedUserInterface: Bool? {
        get {
            applicationElement?.wrappedElement.getValue(.enhancedUserInterface) as? Bool
        }
        set {
            guard let newValue = newValue else { return }
            applicationElement?.wrappedElement.setValue(.enhancedUserInterface, newValue)
        }
    }
    
    // Only for Stage Manager
    var windowIds: [CGWindowID]? {
        wrappedElement.getValue(.windowIds) as? [CGWindowID]
    }
    
    func bringToFront(force: Bool = false) {
        if isMainWindow != true {
            isMainWindow = true
        }
        if let pid = pid, let app = NSRunningApplication(processIdentifier: pid), !app.isActive || force {
            app.activate(options: .activateIgnoringOtherApps)
        }
    }
}

extension AccessibilityElement {
    static func getFrontApplicationElement() -> AccessibilityElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AccessibilityElement(app.processIdentifier)
    }
    
    static func getFrontWindowElement() -> AccessibilityElement? {
        guard let appElement = getFrontApplicationElement() else {
            Logger.log("Failed to find the application that currently has focus.")
            return nil
        }
        if let focusedWindowElement = appElement.focusedWindowElement {
            return focusedWindowElement
        }
        if let firstWindowElement = appElement.windowElements?.first {
            return firstWindowElement
        }
        Logger.log("Failed to find frontmost window.")
        return nil
    }
    
    private static func getWindowInfo(_ location: CGPoint) -> WindowInfo? {
        WindowUtil.getWindowList().first(where: {windowInfo in
            windowInfo.level < 21 // 21 is the level of the Notification Center
            && !["Dock", "WindowManager"].contains(windowInfo.processName)
            && windowInfo.frame.contains(location)
        })
    }

    static func getWindowElementUnderCursor() -> AccessibilityElement? {
        let position = NSEvent.mouseLocation.screenFlipped
        
        var systemWideFirst = Defaults.systemWideMouseDown.userEnabled
        if Defaults.systemWideMouseDown.notSet, let frontAppId = ApplicationToggle.frontAppId {
            systemWideFirst = Defaults.systemWideMouseDownApps.typedValue?.contains(frontAppId) == true
        }
        
        if systemWideFirst,
            let element = AccessibilityElement(position),
            let windowElement = element.windowElement {
                return windowElement
        }

        if let info = getWindowInfo(position) {
            if !Defaults.dragFromStage.userDisabled {
                if StageUtil.stageCapable && StageUtil.stageEnabled,
                   let group = StageUtil.getStageStripWindowGroup(info.id),
                   let windowId = group.first,
                   windowId != info.id,
                   let element = StageWindowAccessibilityElement(windowId) {
                    return element
                }
            }
            if let windowElements = AccessibilityElement(info.pid).windowElements {
                if let windowElement = (windowElements.first { $0.windowId == info.id }) {
                    return windowElement
                }
                if let windowElement = (windowElements.first { $0.frame == info.frame }) {
                    return windowElement
                }
            }
        }
        
        if !systemWideFirst,
           let element = AccessibilityElement(position),
           let windowElement = element.windowElement {
            
            if Logger.logging, let pid = windowElement.pid {
                let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
                Logger.log("Window under cursor fallback matched: \(appName)")
            }
            return windowElement
        }

        // Last resort for when the window server isn't vending window info (#640):
        // the frontmost app's own accessibility windows don't depend on it.
        if let frontAppElement = getFrontApplicationElement(),
           let windowElements = frontAppElement.windowElements {
            let windowElement = windowElements
                .map { (element: $0, frame: $0.frame) }
                .filter { !$0.frame.isNull && $0.frame.contains(position) }
                .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?
                .element
            if let windowElement {
                if Logger.logging, let pid = windowElement.pid {
                    let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
                    Logger.log("Window under cursor frontmost app fallback matched: \(appName)")
                }
                return windowElement
            }
        }

        Logger.log("Unable to obtain the accessibility element with the specified attribute at mouse location")
        return nil
    }
    
    static func getWindowElement(_ windowId: CGWindowID) -> AccessibilityElement? {
        guard let pid = WindowUtil.getWindowList(ids: [windowId]).first?.pid else { return nil }
        return AccessibilityElement(pid).windowElements?.first { $0.windowId == windowId }
    }
    
    private static let excludedProcessNames: Set<String> = ["Dock", "WindowManager", "Notification Center"]

    static func getAllWindowElements(all: Bool = false) -> [AccessibilityElement] {
        let windowInfos = WindowUtil.getWindowList(all: all)
            .filter { !excludedProcessNames.contains($0.processName ?? "") }
            .filter { $0.level < 21 }

        var result: [AccessibilityElement] = []
        var seenElements: Set<AccessibilityElement> = []
        var pidsWithoutAXWindows: Set<pid_t> = []
        var seenPids: Set<pid_t> = []

        for info in windowInfos {
            let pid = info.pid
            guard !seenPids.contains(pid) else { continue }
            seenPids.insert(pid)

            if let windows = AccessibilityElement(pid).windowElements {
                for window in windows where !seenElements.contains(window) {
                    seenElements.insert(window)
                    result.append(window)
                }
            } else {
                pidsWithoutAXWindows.insert(pid)
            }
        }

        // Fallback for apps that expose no windows through the app element
        // (e.g. WeChat, Raycast): resolve each window by its on-screen position.
        var seenFrames: Set<String> = []
        for info in windowInfos where pidsWithoutAXWindows.contains(info.pid) {
            let frame = info.frame
            guard frame.width > 30, frame.height > 30 else { continue }
            let key = "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
            guard !seenFrames.contains(key) else { continue }
            seenFrames.insert(key)

            if let element = AccessibilityElement(CGPoint(x: frame.midX, y: frame.midY))?.windowElement {
                let eframe = element.frame
                if abs(eframe.origin.x - frame.origin.x) < 10, abs(eframe.origin.y - frame.origin.y) < 10,
                   abs(eframe.width - frame.width) < 10, abs(eframe.height - frame.height) < 10,
                   !seenElements.contains(element) {
                    seenElements.insert(element)
                    result.append(element)
                }
            }
        }
        return result
    }
}

extension AccessibilityElement: Equatable {
    static func == (lhs: AccessibilityElement, rhs: AccessibilityElement) -> Bool {
        return lhs.wrappedElement == rhs.wrappedElement
    }
}

extension AccessibilityElement: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(wrappedElement)
    }
}

class StageWindowAccessibilityElement: AccessibilityElement {
    private let _windowId: CGWindowID
    
    init?(_ windowId: CGWindowID) {
        guard let element = AccessibilityElement.getWindowElement(windowId) else { return nil }
        _windowId = windowId
        super.init(element.wrappedElement)
    }
    
    override var frame: CGRect {
        let frame = super.frame
        guard !frame.isNull, let windowId = windowId, let info = WindowUtil.getWindowList(ids: [windowId]).first else { return frame }
        return .init(origin: info.frame.origin, size: frame.size)
    }
    
    override var windowId: CGWindowID? {
        _windowId
    }
}

enum EnhancedUI: Int {
    case disableEnable = 1 /// The default behavior - disable Enhanced UI on every window move/resize
    case disableOnly = 2 /// Don't re-enable enhanced UI after it gets disabled
    case frontmostDisable = 3 /// Disable enhanced UI every time the frontmost app gets changed
}
