/// ZoneLayout.swift
///
/// Zone-based layout system: the screen's visible frame is divided into a grid
/// of zones. Two features share this single layout definition:
///
///  * drag-to-zone — hold the configured modifier while dragging a window to see
///    the zone under the cursor and drop into it (see ``SnappingManager``), and
///  * auto-arrange — tile every window on the current screen into the zones.
///
/// A screen's grid is resolved one of two ways:
///
///  * ``ZoneMode/auto`` (default) — pick the grid whose tiles stay above the
///    minimum comfortable size, so wide screens get more columns and tall or
///    portrait screens get more rows (see ``smartGrid(width:height:)``).
///  * ``ZoneMode/manual`` — a user-selected rows x cols from ``candidates``.
///
/// The mode and the manual grid are global by default but can be overridden per
/// monitor. All configuration lives in `UserDefaults.standard` (the app's own
/// domain), so it can be set from the status menu or via `defaults write`.
///
/// Zones are returned in AppKit screen coordinates (bottom-left origin), which
/// is what ``FootprintWindow`` consumes directly; convert with ``CGRect``'s
/// `screenFlipped` before feeding a zone to the Accessibility API.

import Cocoa

enum ZoneMode: String {
    case auto
    case manual
}

enum ZoneLayout {

    // MARK: - Configuration keys (UserDefaults)

    static let enabledKey = "fancyZonesEnabled"
    static let modeKey = "fancyZonesMode"
    static let rowsKey = "fancyZonesRows"
    static let colsKey = "fancyZonesCols"
    static let gridCycleKey = "cycleFancyZonesGrid"

    /// Manual layouts selectable from the status menu, as (rows, cols).
    static let candidates: [(rows: Int, cols: Int)] = [
        (1, 2), (2, 2), (1, 3), (2, 3), (1, 4), (2, 4), (3, 3), (3, 4)
    ]

    /// Minimum comfortable tile size (points) used by the smart layout.
    /// Below these, most apps' content starts to feel cramped.
    static let minTileWidth: CGFloat = 640
    static let minTileHeight: CGFloat = 600

    /// Upper bound on rows and columns for the smart layout (max 16 zones).
    static let maxGridCount = 4

    // MARK: - Feature + mode

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Modifier held while dragging to activate zone snapping (instead of the
    /// normal edge snapping). Shift is free of system window-drag meaning.
    static let modifierFlags: NSEvent.ModifierFlags = [.shift]

    static func screenKey(_ screen: NSScreen) -> String {
        screen.localizedName
    }

    static func mode(for screen: NSScreen) -> ZoneMode {
        if let raw = UserDefaults.standard.string(forKey: perMonitorKey(modeKey, screen)),
           let mode = ZoneMode(rawValue: raw) {
            return mode
        }
        if let raw = UserDefaults.standard.string(forKey: modeKey),
           let mode = ZoneMode(rawValue: raw) {
            return mode
        }
        return .auto
    }

    // MARK: - Grid resolution

    static func grid(for screen: NSScreen) -> (rows: Int, cols: Int) {
        switch mode(for: screen) {
        case .manual:
            return (manualRows(for: screen), manualCols(for: screen))
        case .auto:
            let vf = screen.adjustedVisibleFrame()
            return smartGrid(width: vf.width, height: vf.height)
        }
    }

    static func manualRows(for screen: NSScreen) -> Int {
        let perMon = UserDefaults.standard.integer(forKey: perMonitorKey(rowsKey, screen))
        if perMon > 0 { return perMon }
        let global = UserDefaults.standard.integer(forKey: rowsKey)
        return global > 0 ? global : 2
    }

    static func manualCols(for screen: NSScreen) -> Int {
        let perMon = UserDefaults.standard.integer(forKey: perMonitorKey(colsKey, screen))
        if perMon > 0 { return perMon }
        let global = UserDefaults.standard.integer(forKey: colsKey)
        return global > 0 ? global : 3
    }

    // MARK: - Per-monitor writes

    static func setManualGrid(rows: Int, cols: Int, for screen: NSScreen) {
        UserDefaults.standard.set(rows, forKey: perMonitorKey(rowsKey, screen))
        UserDefaults.standard.set(cols, forKey: perMonitorKey(colsKey, screen))
    }

    /// Snapshots every screen's current grid into its per-monitor keys, so
    /// switching from auto to manual mode doesn't change any screen's layout.
    static func snapshotGridsForAllScreens() {
        for screen in NSScreen.screens {
            let current = grid(for: screen)
            setManualGrid(rows: current.rows, cols: current.cols, for: screen)
        }
    }

    /// Smart layout: the largest grid whose tiles stay at or above the minimum
    /// comfortable size, bounded by ``maxGridCount``. Pure and deterministic
    /// (no UserDefaults) so it can be unit-tested.
    ///
    /// Derivation: `cols = clamp(floor(width / minTileWidth), 1, max)`. A tile
    /// narrower than 640pt (or shorter than 600pt) is uncomfortable to use, so
    /// we stop adding columns/rows once the next one would dip below that.
    static func smartGrid(width: CGFloat, height: CGFloat) -> (rows: Int, cols: Int) {
        guard width > 0, height > 0 else { return (1, 1) }
        let cols = min(maxGridCount, max(1, Int(floor(width / minTileWidth))))
        let rows = min(maxGridCount, max(1, Int(floor(height / minTileHeight))))
        return (rows, cols)
    }

    // MARK: - Zone computation (AppKit coordinates, bottom-left origin)

    static func zones(for screen: NSScreen) -> [CGRect] {
        let vf = screen.adjustedVisibleFrame()
        let (rows, cols) = grid(for: screen)
        return gridZones(rows: rows, cols: cols, in: vf)
    }

    /// Grid of zone rects in AppKit screen coordinates. Zone 0 is top-left,
    /// then left-to-right, top-to-bottom. Pure and deterministic.
    static func gridZones(rows: Int, cols: Int, in frame: CGRect) -> [CGRect] {
        guard rows > 0, cols > 0, frame.width > 0, frame.height > 0 else { return [] }
        var out: [CGRect] = []
        out.reserveCapacity(rows * cols)
        let tileWidth = frame.width / CGFloat(cols)
        let tileHeight = frame.height / CGFloat(rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let xOrigin = frame.minX + CGFloat(col) * tileWidth
                let yOrigin = frame.maxY - CGFloat(row + 1) * tileHeight
                out.append(CGRect(x: xOrigin, y: yOrigin, width: tileWidth, height: tileHeight))
            }
        }
        return out
    }

    /// Index of the zone containing `location` (AppKit coords), or nil.
    /// When zones tile the frame exactly, this returns the first match.
    static func zoneIndex(at location: CGPoint, for screen: NSScreen) -> Int? {
        let zones = zones(for: screen)
        for (index, zone) in zones.enumerated() where zone.contains(location) {
            return index
        }
        return nil
    }

    /// Screen, zone index, and zone rect (AppKit coords) containing `location`,
    /// or nil when the cursor is outside every screen or between zones.
    static func zone(at location: CGPoint) -> (screen: NSScreen, index: Int, rect: CGRect)? {
        for screen in NSScreen.screens where screen.frame.contains(location) {
            if let index = zoneIndex(at: location, for: screen) {
                return (screen, index, zones(for: screen)[index])
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func perMonitorKey(_ base: String, _ screen: NSScreen) -> String {
        base + "_" + screenKey(screen)
    }
}
