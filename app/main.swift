//  main.swift — bootstrap.
//
//  There is no nib and no storyboard, because the tools that build them (ibtool,
//  actool) ship with Xcode and this app must build with the Command Line Tools
//  alone. Everything a nib would have given us is therefore assembled here.
//
//  The main menu is the part that is easy to skip and expensive to skip. An
//  .accessory app never DISPLAYS its main menu — but NSApp still routes command
//  key equivalents through it. With no main menu there is no Edit menu, and with
//  no Edit menu ⌘V does nothing in the panel's text fields: no beep, no error,
//  the field simply stays empty. Every report of that bug blames WebKit. It is
//  this file.

import AppKit

let application = NSApplication.shared
let appDelegate = AppDelegate()

application.delegate = appDelegate
// .accessory: menu bar only. No Dock icon, no app switcher entry, and — unlike
// .prohibited — it can still take keyboard focus, which the wizard's text fields
// need. LSUIElement in the Info.plist says the same thing early enough that the
// Dock never briefly shows an icon at launch.
application.setActivationPolicy(.accessory)
MainMenu.install(into: application)
application.run()

// MARK: - The programmatic main menu

enum MainMenu {

    static func install(into application: NSApplication) {
        let root = NSMenu()
        root.addItem(appMenuItem())
        root.addItem(editMenuItem())
        application.mainMenu = root
    }

    private static func appMenuItem() -> NSMenuItem {
        let name = "Merge Goblin"
        let item = NSMenuItem()
        let menu = NSMenu(title: name)

        menu.addItem(withTitle: "About \(name)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide \(name)",
                     action: #selector(NSApplication.hide(_:)),
                     keyEquivalent: "h")
        menu.addItem(.separator())
        // ⌘Q lives here as well as in the status menu. The status menu's copy is
        // the one a user reads ("Quit — reviews keep running"); this one is what
        // makes the key equivalent work while the popover has focus.
        menu.addItem(withTitle: "Quit \(name)",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    /// Undo/Redo/Cut/Copy/Paste/Select All, with the standard responder-chain
    /// selectors. These are not declared on NSResponder, so they are looked up by
    /// name — that is normal and is exactly what a nib does.
    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        func add(_ title: String, _ selectorName: String, _ key: String,
                 modifiers: NSEvent.ModifierFlags = [.command]) {
            let entry = NSMenuItem(title: title,
                                   action: NSSelectorFromString(selectorName),
                                   keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            menu.addItem(entry)
        }

        add("Undo", "undo:", "z")
        add("Redo", "redo:", "Z", modifiers: [.command, .shift])
        menu.addItem(.separator())
        add("Cut", "cut:", "x")
        add("Copy", "copy:", "c")
        add("Paste", "paste:", "v")
        add("Paste and Match Style", "pasteAsPlainText:", "V", modifiers: [.command, .option, .shift])
        add("Delete", "delete:", "")
        add("Select All", "selectAll:", "a")

        item.submenu = menu
        return item
    }
}
