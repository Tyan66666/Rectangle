/// ZoneLayout.swift
///
/// Zone-based layout system: the screen's visible frame is divided into a grid
/// of zones. Two features share this single layout definition:
///
///  * drag-to-zone — hold Shift while dragging a window to see the zone under
///    the cursor and drop into it (see ``SnappingManager``), and
///  * auto-arrange — tile every window on the current screen into the zones.
///
/// A screen's grid is the user-selected rows x cols from ``candidates``, global
/// by default but overridable per monitor. All configuration lives in
/// `UserDefaults.standard` (the app's own domain), so it can be set from the
/// status menu or via `defaults write`.
///
/// Zones are returned in AppKit screen coordinates (bottom-left origin), which
/// is what ``FootprintWindow`` consumes directly; convert with ``CGRect``'s
/// `screenFlipped` before feeding a zone to the Accessibility API.

import Cocoa

enum ZoneLayout {

    // MARK: - Configuration keys (UserDefaults)

    static let enabledKey = "fancyZonesEnabled"
    static let rowsKey = "fancyZonesRows"
    static let colsKey = "fancyZonesCols"
    static let gridCycleKey = "cycleFancyZonesGrid"
    static let colorKey = "fancyZonesColor"
    static let cycleSquareOnlyKey = "cycleSquareFancyZonesOnly"
    static let cycleGridsKey = "cycleSquareFancyZonesGrids"

    /// Manual layouts selectable from the status menu, as (rows, cols).
    static let candidates: [(rows: Int, cols: Int)] = [
        (1, 2), (1, 3), (1, 4),
        (2, 2), (2, 3), (2, 4),
        (3, 1), (3, 2), (3, 3), (3, 4)
    ]

    /// Default selection for restricted cycling: every candidate grid.
    static let defaultCycleSquareGridMask = (1 << candidates.count) - 1

    // MARK: - Feature

    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Modifier held while dragging to activate zone snapping (instead of the
    /// normal edge snapping). Shift is free of system window-drag meaning.
    static let modifierFlags: NSEvent.ModifierFlags = [.shift]

    static func screenKey(_ screen: NSScreen) -> String {
        screen.localizedName
    }

    // MARK: - Grid resolution

    static func grid(for screen: NSScreen) -> (rows: Int, cols: Int) {
        (manualRows(for: screen), manualCols(for: screen))
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

    // MARK: - Cycle grid restriction

    /// When true, the Cycle Grid shortcut only cycles through the grids
    /// selected for the current display (instead of every candidate), and the
    /// status-menu submenu for a display only shows those grids.
    static var cycleSquareOnly: Bool {
        get { Defaults.zoneCycleSquareOnly.enabled }
        set { Defaults.zoneCycleSquareOnly.enabled = newValue }
    }

    /// Global default bitmask of enabled candidate grids (bit `i` =
    /// ``candidates``[i] participates), used for displays without their own
    /// selection.
    static var cycleGridMask: Int {
        get { Defaults.zoneCycleSquareGridMask.value }
        set { Defaults.zoneCycleSquareGridMask.value = newValue }
    }

    /// A display's selection: its own per-display mask when one has been set
    /// (via the Settings popover or `defaults write`), otherwise the global
    /// ``cycleGridMask``.
    static func cycleGridMask(for screen: NSScreen) -> Int {
        let key = perMonitorKey(cycleGridsKey, screen)
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.integer(forKey: key)
        }
        return cycleGridMask
    }

    /// Stores a per-display grid selection (bit `i` set means candidates[i]
    /// participates).
    static func setCycleGridMask(_ mask: Int, for screen: NSScreen) {
        UserDefaults.standard.set(mask, forKey: perMonitorKey(cycleGridsKey, screen))
    }

    /// Grids the Cycle Grid shortcut steps through for `screen` — and the grids
    /// shown in that screen's status-menu submenu: every candidate by default,
    /// or exactly the display's checked grids when restriction is enabled.
    static func cycleCandidates(for screen: NSScreen) -> [(rows: Int, cols: Int)] {
        cycleCandidates(restricted: cycleSquareOnly, mask: cycleGridMask(for: screen))
    }

    /// Pure: every candidate, or only the candidates enabled by `mask` (bit `i`
    /// = candidates[i]). Used by the display-aware variant and by unit tests.
    static func cycleCandidates(restricted: Bool, mask: Int) -> [(rows: Int, cols: Int)] {
        guard restricted else { return candidates }
        return candidates.enumerated().compactMap { index, grid in
            guard mask & (1 << index) != 0 else { return nil }
            return grid
        }
    }

    /// Index of `grid` in ``candidates`` (used for menu tags), or nil.
    static func candidateIndex(_ grid: (rows: Int, cols: Int)) -> Int? {
        candidates.firstIndex { $0.rows == grid.rows && $0.cols == grid.cols }
    }

    /// Starting index within the display's cycle candidates for the current
    /// grid of `screen`: the grid itself when listed, otherwise the nearest
    /// grid by tile count (ties resolve to the larger grid) so cycling is
    /// well-defined.
    static func cycleIndex(for screen: NSScreen) -> Int {
        let grid = grid(for: screen)
        return cycleIndex(rows: grid.rows, cols: grid.cols, in: cycleCandidates(for: screen))
    }

    /// Pure variant over an explicit candidate list (used by unit tests).
    static func cycleIndex(rows: Int, cols: Int, in grids: [(rows: Int, cols: Int)]) -> Int {
        if let index = grids.firstIndex(where: { $0.rows == rows && $0.cols == cols }) {
            return index
        }
        guard !grids.isEmpty else { return 0 }
        var best = 0
        var bestDistance = Int.max
        let currentArea = rows * cols
        for (index, candidate) in grids.enumerated() {
            let distance = abs(candidate.rows * candidate.cols - currentArea)
            let candidateArea = candidate.rows * candidate.cols
            if distance < bestDistance
                || (distance == bestDistance && candidateArea > grids[best].rows * grids[best].cols) {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    // MARK: - Per-display zone color

    /// Custom zone-preview color for `screen`, or nil to fall back to the
    /// global footprint color.
    static func color(for screen: NSScreen) -> NSColor? {
        guard let raw = UserDefaults.standard.string(forKey: perMonitorKey(colorKey, screen)),
              let data = raw.data(using: .utf8),
              let color = try? JSONDecoder().decode(CodableColor.self, from: data) else {
            return nil
        }
        return color.nsColor
    }

    /// Stores a per-display zone color (nil removes the override).
    static func setColor(_ color: NSColor?, for screen: NSScreen) {
        let key = perMonitorKey(colorKey, screen)
        if let color {
            let sRGB = color.usingColorSpace(.sRGB) ?? color
            let codable = CodableColor(nsColor: sRGB)
            if let data = try? JSONEncoder().encode(codable),
               let raw = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(raw, forKey: key)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
