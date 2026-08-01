//  StatusItemController.swift — the status item and its click behaviour.
//
//  Two things here are load-bearing and easy to get wrong:
//
//  1. `statusItem.menu` stays nil FOREVER. The usual recipe for "left click opens
//     a panel, right click opens a menu" is to assign statusItem.menu, call
//     performClick, then set it back to nil. That leaves the item stuck in its
//     highlighted state whenever the timing is unlucky, and the only cure is
//     relaunching. Instead the button sends its action on both mouse-ups and we
//     branch on NSApp.currentEvent, popping the menu up manually.
//
//  2. `autosaveName` makes macOS remember where the user dragged the item to.
//     Without it the goblin jumps back to the right-hand end of the menu bar on
//     every launch, which for a login item means every morning.

import AppKit

final class StatusItemController: NSObject {

    private let statusItem: NSStatusItem
    private var animationTimer: Timer?
    private var animationFrame = 0
    private var currentGlyph: BarGlyph = .idle
    private var haveDrawnOnce = false

    var onLeftClick: (() -> Void)?
    var onRightClick: ((NSStatusBarButton) -> Void)?

    var button: NSStatusBarButton? { statusItem.button }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.autosaveName = "goblin.bar"
        statusItem.behavior = [.terminationOnRemoval]

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeft
            button.imageHugsTitle = true
            // Monospaced digits: proportional digits make the whole menu bar
            // shuffle sideways every time the count crosses 9 -> 10.
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
            button.image = BarIcon.image(for: .idle)
            button.setAccessibilityLabel("Merge Goblin, starting up")
        }
    }

    deinit {
        animationTimer?.invalidate()
    }

    // MARK: - Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            onRightClick?(sender)
        } else {
            onLeftClick?()
        }
    }

    // MARK: - Drawing

    func update(with state: GoblinState) {
        guard let button = statusItem.button else { return }

        let glyph = state.glyph
        if glyph != currentGlyph || !haveDrawnOnce {
            currentGlyph = glyph
            haveDrawnOnce = true
            // The timer exists only while it is needed. A permanently running
            // 10 Hz timer in a login item is a battery bug that nobody would ever
            // trace back to a menu bar icon.
            if glyph == .reviewing {
                startAnimating()
            } else {
                stopAnimating()
            }
        }

        button.image = BarIcon.image(for: glyph, frame: animationFrame)

        let count = state.barCount
        // A plain title, never attributedTitle: see the note in BarIcon.swift.
        button.title = count > 0 ? " \(count)" : ""
        button.toolTip = state.tooltip
        button.setAccessibilityLabel(accessibilityLabel(for: state))
    }

    /// A full sentence, rebuilt on every update. All the information in the menu
    /// bar lives in a silhouette and a numeral, so this is not a nicety — it is
    /// the only way VoiceOver can convey the state at all.
    private func accessibilityLabel(for state: GoblinState) -> String {
        var parts = [state.shortName]
        let count = state.barCount
        switch count {
        case 0: break
        case 1: parts.append("1 pull request waiting")
        default: parts.append("\(count) pull requests waiting")
        }
        parts.append(state.glyph.spokenState)
        if !state.setupComplete { parts.append("set-up is not finished") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Animation

    private func startAnimating() {
        guard animationTimer == nil else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // One static busy frame, no timer at all.
            animationFrame = 0
            return
        }
        BarIcon.warmAnimation()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            self.animationFrame = (self.animationFrame + 1) % BarIcon.animationFrames
            button.image = BarIcon.image(for: .reviewing, frame: self.animationFrame)
        }
        // Tolerance lets the system coalesce our wakeups with others it already
        // has scheduled, which is most of the cost of a 10 Hz timer.
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationFrame = 0
    }
}
