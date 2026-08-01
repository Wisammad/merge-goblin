//  BarIcon.swift — the thing in the menu bar.
//
//  Everything here exists to make ONE image correct in every appearance macOS can
//  put it in, without a single colour literal:
//
//    * `isTemplate = true` means macOS treats the image as a MASK. It derives
//      light mode, dark mode, the inverted highlight while the menu is open,
//      Increase Contrast, Reduce Transparency and the user's accent colour for
//      free. That is also why the badges are drawn as vector shapes: an emoji
//      renders in its own fixed colours and cannot be masked, so it would stay
//      cheerfully orange on a highlighted black background.
//
//    * the count goes in `button.title` as a PLAIN string. An attributedTitle
//      with an explicit foreground colour does not invert on highlight, so the
//      number vanishes exactly when the menu is open. The font is
//      monospacedDigitSystemFont so the whole menu bar does not shift left when
//      the count goes 9 -> 10.
//
//    * glyph names come from bash (`bar.glyph` in uistate.json). Swift is a
//      name -> NSImage lookup. There is no policy in this file.

import AppKit

/// The vocabulary bash may put in `bar.glyph`. Adding a name here is the whole
/// cost of adding a state to the icon; the decision about WHEN to show it stays
/// in lib/state.sh, where the shell test suite can assert it.
enum BarGlyph: String, CaseIterable {
    case idle
    case reviewing
    case paused
    /// What lib/state.sh emits when the daily cap has stopped the goblin.
    case quota
    /// The old name for `quota`, from when the cap was measured in dollars. Kept
    /// so a state file written before the rename does not fall through to the
    /// derived fallback and render as a plain pause.
    case budget
    case snoozed
    case off
    case error

    /// A sentence fragment for the accessibility label. All of the information in
    /// the menu bar is in an 18-point silhouette, so without this VoiceOver reads
    /// "Merge Goblin" and stops — the state is simply unavailable.
    var spokenState: String {
        switch self {
        case .idle:      return "idle"
        case .reviewing: return "reviewing now"
        case .paused:    return "paused"
        case .quota, .budget: return "stopped, daily cap reached"
        case .snoozed:   return "snoozed"
        case .off:       return "turned off"
        case .error:     return "needs attention"
        }
    }
}

enum BarIcon {

    static let size: CGFloat = 18
    /// 10 fps for the reviewing animation. Fast enough to read as motion, slow
    /// enough that a laptop on battery does not notice.
    static let animationFrames = 10

    // MARK: - Public API

    /// A rendered, template-flagged 18x18 image. Cached: this is called on every
    /// state change and 10x a second while reviewing.
    static func image(for glyph: BarGlyph, frame: Int = 0) -> NSImage {
        let key = "\(glyph.rawValue)#\(glyph == .reviewing ? frame % animationFrames : 0)"
        if let cached = cache[key] { return cached }
        let image = render(glyph: glyph, frame: frame % animationFrames)
        cache[key] = image
        return image
    }

    /// Pre-renders the animation so the first tick of the timer is not a hitch.
    static func warmAnimation() {
        for frame in 0..<animationFrames { _ = image(for: .reviewing, frame: frame) }
        for glyph in BarGlyph.allCases where glyph != .reviewing { _ = image(for: glyph) }
    }

    private static var cache: [String: NSImage] = [:]

    /// The bundled vector goblin. Loaded once; nil is survivable (see fallback).
    private static let pdf: NSPDFImageRep? = {
        guard let url = Bundle.main.resourceURL?
                .appendingPathComponent("ui", isDirectory: true)
                .appendingPathComponent("goblin-bar.pdf"),
              let data = try? Data(contentsOf: url) else { return nil }
        return NSPDFImageRep(data: data)
    }()

    // MARK: - Rendering

    private static func render(glyph: BarGlyph, frame: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }

            // The goblin sits up and to the left, leaving the bottom-right corner
            // for the badge. Both boxes are in the 18x18 image's coordinates.
            let goblinRect = NSRect(x: 0.0, y: 3.0, width: 15.0, height: 15.0)
            let badgeRect = NSRect(x: 9.5, y: 0.0, width: 8.5, height: 8.5)

            ctx.saveGState()
            // "off" reads as a dimmed goblin. The spec asked for an outline; at
            // 18 points a stroked silhouette with cut-out eyes turns to mush, so
            // this is a 40%-alpha fill instead — same "he is not here" read, and
            // it survives Reduce Transparency.
            if glyph == .off { ctx.setAlpha(0.4) }
            drawGoblin(in: goblinRect)
            ctx.restoreGState()

            if let badge = badgePath(for: glyph, in: badgeRect, frame: frame) {
                // Punch a transparent moat so the badge does not merge into the
                // goblin's chin. Legal here because the drawing handler backs a
                // real bitmap with an alpha channel; the result is still a pure
                // mask, so template tinting is unaffected.
                ctx.saveGState()
                ctx.setBlendMode(.clear)
                ctx.fillEllipse(in: badgeRect.insetBy(dx: -1.1, dy: -1.1))
                ctx.restoreGState()

                NSColor.black.setFill()
                badge.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Merge Goblin, \(glyph.spokenState)"
        return image
    }

    private static func drawGoblin(in rect: NSRect) {
        if let pdf {
            // NSPDFImageRep scales its own media box to the destination rect, and
            // it is vector, so this is crisp at 1x, 2x and 3x with no @2x asset.
            pdf.draw(in: rect)
        } else {
            NSColor.black.setFill()
            fallbackGoblin(in: rect).fill()
        }
    }

    // MARK: - The code-drawn fallback
    //
    // A missing or corrupt PDF must never produce an INVISIBLE status item: the
    // app would look like it had failed to launch, and the only way to quit it
    // would be `killall`. This is deliberately simpler than the PDF — it only has
    // to say "goblin" at 18 points.

    private static func fallbackGoblin(in rect: NSRect) -> NSBezierPath {
        // Design space is 64x64 with y pointing DOWN, matching share/ui/goblin.svg
        // and the generator that produced goblin-bar.pdf, so the two shapes agree.
        let path = NSBezierPath()
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: rect.minX + (x / 64.0) * rect.width,
                    y: rect.maxY - (y / 64.0) * rect.height)
        }

        path.move(to: p(32, 56))
        path.curve(to: p(13.5, 33), controlPoint1: p(20, 56), controlPoint2: p(12, 47))
        path.line(to: p(6, 17))                    // left ear
        path.line(to: p(12.5, 25))
        path.curve(to: p(51.5, 25), controlPoint1: p(14, 5), controlPoint2: p(50, 5))
        path.line(to: p(58, 17))                   // right ear
        path.line(to: p(50.5, 33))
        path.curve(to: p(32, 56), controlPoint1: p(52, 47), controlPoint2: p(44, 56))
        path.close()

        // Eyes and grin are holes, punched by the even-odd rule. The outline above
        // is one non-self-intersecting subpath precisely so that works.
        path.appendOval(in: NSRect(x: p(23, 34).x - rect.width * 0.072,
                                   y: p(23, 34).y - rect.height * 0.072,
                                   width: rect.width * 0.144, height: rect.height * 0.144))
        path.appendOval(in: NSRect(x: p(41, 34).x - rect.width * 0.072,
                                   y: p(41, 34).y - rect.height * 0.072,
                                   width: rect.width * 0.144, height: rect.height * 0.144))
        path.move(to: p(21, 44))
        path.curve(to: p(43, 44), controlPoint1: p(26, 52.5), controlPoint2: p(38, 52.5))
        path.curve(to: p(21, 44), controlPoint1: p(38, 47.5), controlPoint2: p(26, 47.5))
        path.close()

        path.windingRule = .evenOdd
        return path
    }

    // MARK: - Badges

    private static func badgePath(for glyph: BarGlyph, in rect: NSRect, frame: Int) -> NSBezierPath? {
        switch glyph {
        case .idle, .off:
            return nil
        case .reviewing:
            return spinner(in: rect, frame: frame)
        case .paused:
            return pauseBars(in: rect)
        case .quota, .budget:
            return coin(in: rect)
        case .snoozed:
            return crescent(in: rect)
        case .error:
            return warningTriangle(in: rect)
        }
    }

    /// Four dots on a circle, one of them missing, rotating. Dots rather than an
    /// arc because a 1-point-wide arc disappears at 1x on a non-Retina display.
    private static func spinner(in rect: NSRect, frame: Int) -> NSBezierPath {
        let path = NSBezierPath()
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width * 0.33
        let dots = 8
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Reduce Motion gets one static "busy" frame: a full ring. Never a timer.
        let lead = reduceMotion ? -1 : (frame * dots / animationFrames) % dots

        for index in 0..<dots {
            // The two dots behind the leading edge are dropped, which is what
            // makes the ring read as rotating rather than pulsing.
            if !reduceMotion {
                let behind = (index - lead + dots) % dots
                if behind == dots - 1 || behind == dots - 2 { continue }
            }
            let angle = (Double(index) / Double(dots)) * 2 * .pi - .pi / 2
            let dotRadius = rect.width * 0.115
            let x = centre.x + CGFloat(cos(angle)) * radius
            let y = centre.y - CGFloat(sin(angle)) * radius
            path.appendOval(in: NSRect(x: x - dotRadius, y: y - dotRadius,
                                       width: dotRadius * 2, height: dotRadius * 2))
        }
        return path
    }

    private static func pauseBars(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let barWidth = rect.width * 0.22
        let inset = rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.12)
        path.appendRoundedRect(NSRect(x: inset.minX, y: inset.minY, width: barWidth, height: inset.height),
                               xRadius: barWidth / 2, yRadius: barWidth / 2)
        path.appendRoundedRect(NSRect(x: inset.maxX - barWidth, y: inset.minY,
                                      width: barWidth, height: inset.height),
                               xRadius: barWidth / 2, yRadius: barWidth / 2)
        return path
    }

    /// A coin with a slot: a filled disc with a bar cut out of it. Reads as money
    /// at 8 points, where a "$" glyph is one indistinct smudge.
    private static func coin(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendOval(in: rect.insetBy(dx: rect.width * 0.07, dy: rect.height * 0.07))
        let slot = NSRect(x: rect.midX - rect.width * 0.05,
                          y: rect.minY + rect.height * 0.18,
                          width: rect.width * 0.10,
                          height: rect.height * 0.64)
        path.appendRoundedRect(slot, xRadius: slot.width / 2, yRadius: slot.width / 2)
        path.appendRect(NSRect(x: rect.midX - rect.width * 0.22, y: rect.midY - rect.height * 0.30,
                               width: rect.width * 0.44, height: rect.height * 0.09))
        path.appendRect(NSRect(x: rect.midX - rect.width * 0.22, y: rect.midY + rect.height * 0.20,
                               width: rect.width * 0.44, height: rect.height * 0.09))
        path.windingRule = .evenOdd
        return path
    }

    /// A crescent moon: one disc minus a second, offset disc.
    private static func crescent(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let disc = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.06)
        path.appendOval(in: disc)
        path.appendOval(in: disc.offsetBy(dx: disc.width * 0.34, dy: disc.height * 0.26))
        path.windingRule = .evenOdd
        return path
    }

    /// A rounded triangle with an exclamation mark cut out of it, so the "!" is
    /// transparent and therefore takes the menu bar's background in every theme.
    private static func warningTriangle(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        let r = rect.insetBy(dx: rect.width * 0.02, dy: rect.height * 0.06)
        let apex = NSPoint(x: r.midX, y: r.maxY)
        let left = NSPoint(x: r.minX, y: r.minY)
        let right = NSPoint(x: r.maxX, y: r.minY)
        let round = r.width * 0.14

        path.move(to: NSPoint(x: left.x + round, y: left.y))
        path.line(to: NSPoint(x: right.x - round, y: right.y))
        path.appendArc(from: right, to: NSPoint(x: apex.x + round * 0.5, y: apex.y - round), radius: round)
        path.line(to: NSPoint(x: apex.x + round * 0.5, y: apex.y - round))
        path.appendArc(from: apex, to: NSPoint(x: left.x + round, y: left.y), radius: round)
        path.line(to: NSPoint(x: left.x + round, y: left.y))
        path.appendArc(from: left, to: NSPoint(x: right.x - round, y: right.y), radius: round)
        path.close()

        let stemWidth = r.width * 0.13
        path.appendRect(NSRect(x: r.midX - stemWidth / 2, y: r.minY + r.height * 0.38,
                               width: stemWidth, height: r.height * 0.30))
        path.appendOval(in: NSRect(x: r.midX - stemWidth * 0.72, y: r.minY + r.height * 0.18,
                                   width: stemWidth * 1.44, height: stemWidth * 1.44))
        path.windingRule = .evenOdd
        return path
    }
}
