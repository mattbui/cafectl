import AppKit

@MainActor
final class MenuBar: NSObject {
    private static var iconCache: [String: NSImage] = [:]
    private var statusItem: NSStatusItem?
    private var pillView: StatusPillView?
    private let action: (ControlCommand) -> Void
    private var commands: [Int: ControlCommand] = [:]

    init(action: @escaping (ControlCommand) -> Void) {
        self.action = action
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.setAccessibilityLabel("cafectl")
    }

    func update(snapshot: ServiceSnapshot, message: String? = nil) {
        guard let statusItem, let button = statusItem.button else { return }
        let active = Mode.allCases.filter { snapshot.modes[$0.rawValue]?.active == true }
        let image = Self.statusImage(activeModes: active)
        if let image, let color = Self.backgroundColor(activeModes: active) {
            statusItem.length = image.size.width + 14
            button.image = nil
            button.clipsToBounds = false
            let pill = pillView ?? StatusPillView(frame: button.bounds)
            if pillView == nil {
                pill.autoresizingMask = [.width, .height]
                button.addSubview(pill)
                pillView = pill
            }
            // Status buttons can remain 22pt high even when the system's
            // highlighted pills are 24pt. Give our drawing room beyond the
            // button bounds while keeping its center and native hit target.
            pill.frame = button.bounds.insetBy(dx: 0, dy: -max(0, (26 - button.bounds.height) / 2))
            pill.symbolImage = image
            pill.fillColor = color
            pill.needsDisplay = true
        } else {
            pillView?.removeFromSuperview()
            pillView = nil
            statusItem.length = NSStatusItem.variableLength
            button.image = image
        }
        button.attributedTitle = NSAttributedString(string: image == nil ? "cafectl" : "")
        button.imagePosition = image == nil ? .noImage : .imageOnly
        statusItem.button?.toolTip = active.isEmpty ? "Keep awake off" :
            "Keep awake: " + active.map { $0.rawValue.capitalized }.joined(separator: ", ")
        commands.removeAll()
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mode in Mode.allCases {
            guard let state = snapshot.modes[mode.rawValue] else { continue }
            let name = mode.rawValue.capitalized
            let toggle = item("Keep \(mode.rawValue) awake", command: .toggle(mode))
            toggle.state = state.active ? .on : .off
            toggle.image = NSImage(systemSymbolName: Self.symbol(mode), accessibilityDescription: name)
            menu.addItem(toggle)
            if let error = state.error {
                menu.addItem(label("Error: \(error)"))
            } else if let reason = state.blockedReason {
                menu.addItem(label("\(state.automaticStart && !state.active ? "Waiting" : "Blocked"): \(reason)"))
            }
            let settings = NSMenuItem(title: "Automation options", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            let automatic = item("Enable automatically", command: .auto(mode, !state.automaticStart))
            automatic.state = state.automaticStart ? .on : .off
            submenu.addItem(automatic)
            submenu.addItem(.separator())
            let policyHeading = label("Power options")
            policyHeading.indentationLevel = 0
            submenu.addItem(policyHeading)
            for policy in PowerPolicy.allCases {
                let policyItem = item(Self.title(policy), command: .policy(mode, policy))
                policyItem.state = state.policy == policy ? .on : .off
                submenu.addItem(policyItem)
            }
            settings.submenu = submenu
            menu.addItem(settings)
            menu.addItem(.separator())
        }
        if let error = snapshot.error { menu.addItem(label("Error: \(error)")) }
        if let message { menu.addItem(label(message)) }
        menu.addItem(item("Turn off all", command: .offAll))
        menu.addItem(item("Stop cafectl", command: .quit, key: "q"))
        statusItem.menu = menu
    }

    func remove() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        commands.removeAll()
    }

    private func item(_ title: String, command: ControlCommand, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: key)
        item.target = self
        item.tag = commands.count
        commands[item.tag] = command
        return item
    }

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.indentationLevel = 1
        return item
    }

    @objc private func performCommand(_ sender: NSMenuItem) {
        if let command = commands[sender.tag] { action(command) }
    }

    static func symbolNames(activeModes: [Mode]) -> [String] {
        let active = [Mode.display, .disk, .system].filter { activeModes.contains($0) }
        guard let primary = active.first else { return ["cup.and.saucer"] }
        return [symbol(primary)] + (active.count > 1 ? ["\(active.count).circle.fill"] : [])
    }

    static func backgroundColor(activeModes: [Mode]) -> NSColor? {
        if activeModes.contains(.display) {
            return NSColor(srgbRed: 0x12 / 255.0, green: 0x90 / 255.0, blue: 0xFE / 255.0, alpha: 1)
        }
        if activeModes.contains(.disk) {
            return NSColor(srgbRed: 0xFF / 255.0, green: 0x8F / 255.0, blue: 0x0B / 255.0, alpha: 1)
        }
        return nil
    }

    private static func symbol(_ mode: Mode) -> String {
        switch mode { case .display: "display"; case .system: "cup.and.saucer.fill"; case .disk: "internaldrive" }
    }

    private static func title(_ policy: PowerPolicy) -> String {
        switch policy {
        case .allowBattery: "Allow on battery"
        case .pluggedIn: "Only while plugged in"
        case .batteryAbove20: "Only when battery above 20%"
        }
    }

    private static func statusImage(activeModes: [Mode]) -> NSImage? {
        let names = symbolNames(activeModes: activeModes)
        let key = "group:" + names.joined(separator: ",")
        if let cached = iconCache[key] { return cached }
        let icons = names.compactMap(icon)
        guard icons.count == names.count else { return nil }
        if icons.count == 1 { return icons[0] }
        let size = NSSize(width: icons.reduce(0) { $0 + $1.size.width },
                          height: MenuBarGlyph.pointSize.height)
        // All symbols retain their natural canvas size and share one template tint.
        let combined = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for image in icons {
                image.draw(in: NSRect(x: x, y: 0,
                                      width: image.size.width, height: image.size.height),
                           from: .zero, operation: .sourceOver, fraction: 1)
                x += image.size.width
            }
            return true
        }
        combined.isTemplate = true
        iconCache[key] = combined
        return combined
    }

    private static func icon(_ name: String) -> NSImage? {
        if let cached = iconCache[name] { return cached }
        let isCount = name.hasSuffix(".circle.fill")
        // Match the cup's artwork center, including its upstream 1pt drop.
        guard let image = MenuBarGlyph.image(named: name, drop: 1, countBadge: isCount) else { return nil }
        iconCache[name] = image
        return image
    }
}

@MainActor
final class StatusPillView: NSView {
    var symbolImage: NSImage?
    var fillColor: NSColor = .clear

    // The native status button continues to own clicks and menu tracking.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let symbolImage else { return }
        Self.drawContents(image: symbolImage, color: fillColor, in: bounds)
    }

    static func drawContents(image: NSImage, color: NSColor, in bounds: NSRect) {
        let height = min(24, bounds.height - 2)
        let pill = NSRect(x: bounds.minX, y: bounds.midY - height / 2,
                          width: bounds.width, height: height)
        color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: height / 2, yRadius: height / 2).fill()
        // Keep the symbol canvas at its native size. Only the background adapts
        // to menu bar height, so the SF artwork is never resized to fit the pill.
        let target = NSRect(x: bounds.midX - image.size.width / 2,
                            y: bounds.midY - image.size.height / 2,
                            width: image.size.width, height: image.size.height)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        NSColor.white.setFill()
        target.fill()
        image.draw(in: target, from: .zero, operation: .destinationIn, fraction: 1)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

// Adapted from vorssaint-utils, StatusItemController.swift at revision f4b1aa6.
// Copyright (C) 2026 Vorssaint. SPDX-License-Identifier: GPL-3.0-or-later
// See THIRD_PARTY_NOTICES.md and LICENSES.md.
@MainActor
enum MenuBarGlyph {
    static let pointSize = NSSize(width: 26, height: 20)

    static func image(named name: String, drop: CGFloat = 0, countBadge: Bool = false) -> NSImage? {
        fixedSizeSymbol(named: name, drop: drop,
                        pointSize: countBadge ? NSSize(width: 14, height: 20) : pointSize,
                        symbolHeight: countBadge ? 12 : 16)
    }

    static func labelImage(_ image: NSImage) -> NSImage? {
        tintedImage(image, color: .labelColor)
    }

    private static func fixedSizeSymbol(named name: String, drop: CGFloat = 0,
                                        pointSize: NSSize, symbolHeight: CGFloat) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)),
              symbol.size.width > 0,
              symbol.size.height > 0,
              let ink = inkBounds(of: symbol),
              ink.width > 0, ink.height > 0 else { return nil }
        let scale = min(symbolHeight / ink.height, (pointSize.width - 2) / ink.width)
        let drawSize = NSSize(width: symbol.size.width * scale,
                              height: symbol.size.height * scale)
        // Offsets used to center the ink rather than the padded box.
        let inkOrigin = NSPoint(x: ink.minX * scale, y: ink.minY * scale)
        let inkSize = NSSize(width: ink.width * scale, height: ink.height * scale)
        let image = NSImage(size: pointSize, flipped: false) { rect in
            let target = NSRect(x: rect.midX - inkOrigin.x - inkSize.width / 2,
                                y: rect.midY - inkOrigin.y - inkSize.height / 2 - drop,
                                width: drawSize.width,
                                height: drawSize.height)
            symbol.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func inkBounds(of image: NSImage) -> NSRect? {
        let sampling = 2
        let wide = Int(ceil(image.size.width)) * sampling
        let high = Int(ceil(image.size.height)) * sampling
        guard wide > 0, high > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: high,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // The context comes from the rep's pixel dimensions, so it draws in
        // pixels; fill the whole bitmap and scale the bounds back down. A
        // point-sized rect here would only cover a corner of it.
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(wide), height: CGFloat(high)))
        NSGraphicsContext.restoreGraphicsState()

        var minX = wide, minY = high, maxX = -1, maxY = -1
        for y in 0..<high {
            for x in 0..<wide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // colorAt() reads top-down; NSImage coordinates run bottom-up.
        let unit = CGFloat(sampling)
        return NSRect(x: CGFloat(minX) / unit,
                      y: CGFloat(high - 1 - maxY) / unit,
                      width: CGFloat(maxX - minX + 1) / unit,
                      height: CGFloat(maxY - minY + 1) / unit)
    }

    private static func tintedImage(_ source: NSImage, color: NSColor) -> NSImage? {
        let tinted = NSImage(size: source.size, flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            color.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        return tinted
    }

}
