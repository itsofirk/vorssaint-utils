// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreText
import QuartzCore

/// The keys pressed while one recording is running. Nothing listens at rest.
struct RecorderKeyboardTrack: Codable, Equatable {
    struct Press: Codable, Equatable {
        let time: Double
        let label: String
    }

    struct Overlay: Equatable {
        let labels: [String]
        let opacity: Double
    }

    var presses: [Press] = []

    var isEmpty: Bool { presses.isEmpty }

    func overlay(at time: Double) -> Overlay? {
        overlays(at: [time]).first ?? nil
    }

    /// Export times are ordered, so the key list can be walked once instead
    /// of searched again for every frame of a long recording.
    func overlays(at times: [Double]) -> [Overlay?] {
        let ordered = presses.sorted { $0.time < $1.time }
        var first = 0
        var next = 0
        return times.map { time in
            while next < ordered.count, ordered[next].time <= time { next += 1 }
            while first < next, time - ordered[first].time >= 1.35 { first += 1 }
            guard first < next else { return nil }
            let shown = ordered[max(first, next - 4)..<next]
            let age = time - ordered[next - 1].time
            let opacity = age > 1 ? max(0, 1 - (age - 1) / 0.35) : 1
            return Overlay(labels: shown.map(\.label), opacity: opacity)
        }
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func decoded(_ data: Data?) -> RecorderKeyboardTrack {
        guard let data, let value = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return value
    }
}

/// Local and global monitors cover the app itself and every other app without
/// swallowing input. Both exist only between start and stop.
final class RecorderKeystrokeSampler {
    private var startedAt: CFTimeInterval = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var presses: [RecorderKeyboardTrack.Press] = []

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        startedAt = CACurrentMediaTime()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return event
        }
    }

    func stop() -> RecorderKeyboardTrack {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        return RecorderKeyboardTrack(presses: presses)
    }

    private func record(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        let shortcut = GlobalShortcut(
            keyCode: Int64(event.keyCode),
            modifiers: GlobalShortcutModifiers(eventFlags: event.modifierFlags))
        presses.append(.init(time: max(0, CACurrentMediaTime() - startedAt),
                             label: shortcut.displayString))
    }

    deinit {
        _ = stop()
    }
}

/// Keycaps are cached by label and size, so a held overlay does not redraw text
/// for every exported frame.
enum RecorderKeystrokeRenderer {
    private static let cache = NSCache<NSString, CGImage>()
    private static let lock = NSLock()

    static func image(labels: [String], canvasHeight: CGFloat) -> CGImage? {
        guard !labels.isEmpty else { return nil }
        let fontSize = min(28, max(14, canvasHeight * 0.026))
        let key = "\(Int(fontSize.rounded()))|\(labels.joined(separator: "\u{1F}"))" as NSString
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache.object(forKey: key) { return cached }

        let font = CTFontCreateWithName("SF Pro Display" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]
        let lines = labels.map { CTLineCreateWithAttributedString(
            NSAttributedString(string: $0, attributes: attributes)) }
        let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) + 28 }
        let height = ceil(fontSize + 22)
        let spacing: CGFloat = 8
        let width = ceil(widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1)))
        guard width > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: Int(width),
                                      height: Int(height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        var x: CGFloat = 0
        for (index, line) in lines.enumerated() {
            let rect = CGRect(x: x, y: 0, width: widths[index], height: height)
            context.setFillColor(CGColor(gray: 0.08, alpha: 0.88))
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                                   cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.fillPath()
            context.setStrokeColor(CGColor(gray: 1, alpha: 0.24))
            context.setLineWidth(1.5)
            context.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                                   cornerWidth: 10, cornerHeight: 10, transform: nil))
            context.strokePath()
            let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.textPosition = CGPoint(x: x + (widths[index] - textWidth) / 2,
                                           y: (height - fontSize) / 2 + 1)
            CTLineDraw(line, context)
            x += widths[index] + spacing
        }
        guard let image = context.makeImage() else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
