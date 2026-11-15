#if DEBUG
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// `EXPANSIONLENS_DEBUG_SHORTCUT_EDITOR=<png path>` (trace to `EXPANSIONLENS_DEBUG_TRACE`; run it
/// with `EXPANSIONLENS_DEFAULTS_SUITE` so the installed app's shortcuts stay as they are): shows the
/// Shortcuts pane in a window of its own, without activating, opens the first shortcut's editor,
/// checks typing "+" (⇧ + "="), a bare letter, an F-key alone, then presses Open ExpansionLens's
/// keys there and sets them, so they move; then Clear and Esc. Registers no hot keys. Saves a
/// picture of the editor, then quits.
@MainActor
enum DebugShortcutEditor {
    static func run(snapshot: String) {
        HotKeyCenter.debugNoRegister = true
        let tracePath = ProcessInfo.processInfo.environment["EXPANSIONLENS_DEBUG_TRACE"]
        var lines: [String] = []
        func trace(_ s: String) {
            lines.append(s)
            if let tracePath { try? lines.joined(separator: "\n").appending("\n").write(toFile: tracePath, atomically: true, encoding: .utf8) }
        }
        let prefs = Preferences.shared
        for action in HotKeyAction.allCases { prefs.setHotKey(nil, for: action) }
        prefs.setHotKey(HotKey(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: UInt32(controlKey | optionKey | cmdKey)), for: .openMain)
        prefs.setHotKey(HotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(controlKey | optionKey)), for: .quickSearch)
        trace("start: " + HotKeyAction.allCases.map { "\($0.rawValue)=\(prefs.hotKey($0)?.display ?? "none")" }.joined(separator: " "))

        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 560, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ShortcutSettings().frame(width: 560, height: 420))
        window.orderFrontRegardless()

        func recorders(in view: NSView) -> [ShortcutRecorder.RecorderButton] {
            ((view as? ShortcutRecorder.RecorderButton).map { [$0] } ?? []) + view.subviews.flatMap(recorders)
        }
        func press(_ key: HotKey) -> NSEvent? {
            var flags: NSEvent.ModifierFlags = []
            if key.modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
            if key.modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
            if key.modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
            if key.modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
            return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: window.windowNumber, context: nil, characters: "",
                                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(key.keyCode))
        }
        func wait(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                let buttons = recorders(in: window.contentView!)
                trace("recorders: \(buttons.count) titles \(buttons.map(\.debugTitle))")
                guard let button = buttons.first else { trace("no recorder"); QuitConfirmation.quitNow(); return }
                button.performClick(nil)
                wait(0.4)
                guard let model = button.debugModel else { trace("editor did not open"); QuitConfirmation.quitNow(); return }
                trace("open: title \(button.debugTitle)")
                model.typed("+")
                trace("plus→\(model.keyText) shift \(model.shift) combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
                model.control = false; model.option = false; model.shift = false; model.command = false
                model.typed("k")
                trace("bare k: key \(model.keyText) combo \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
                model.choose(kVK_F6)
                trace("F6 alone: \(model.combo?.display ?? "-") problem \(model.problem ?? "-")")
                model.command = true
                model.typed("q")
                trace("⌘Q: \(model.combo?.display ?? "-") system \(model.systemUse ?? "-")")
                if let key = prefs.hotKey(.openMain), let event = press(key) {
                    trace("press handled \(model.handle(event))")
                }
                trace("pressed \(model.combo?.display ?? "-") moves from \(model.movesFrom)")
                wait(0.4)
                if let view = button.debugPopoverView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshot))
                }
                model.finish?(.set(model.combo))
                wait(0.4)
                trace("after set: toggle \(prefs.hotKey(.toggleExpansion)?.display ?? "none"), openMain \(prefs.hotKey(.openMain)?.display ?? "none"), title \(button.debugTitle), open \(button.debugModel != nil)")

                // Esc cancels, leaving the keys.
                button.performClick(nil)
                wait(0.4)
                if let m = button.debugModel, let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                                          windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                                          charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: UInt16(kVK_Escape)) {
                    m.typed("j")
                    _ = m.handle(esc)
                }
                wait(0.4)
                trace("after Esc: toggle \(prefs.hotKey(.toggleExpansion)?.display ?? "none"), open \(button.debugModel != nil)")

                // A caught hot key (what RecordingCatcher hands over) fills it in too.
                button.performClick(nil)
                wait(0.4)
                if let m = button.debugModel, let k = HotKey(keyCode: UInt32(kVK_F12), carbonModifiers: UInt32(shiftKey)) {
                    m.caught(k)
                    trace("caught ⇧F12: \(m.combo?.display ?? "-") problem \(m.problem ?? "-")")
                    m.finish?(.cancel)
                }
                wait(0.4)

                // Clear.
                button.performClick(nil)
                wait(0.4)
                button.debugModel?.finish?(.set(nil))
                wait(0.4)
                trace("after Clear: toggle \(prefs.hotKey(.toggleExpansion)?.display ?? "none"), title \(button.debugTitle)")
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: snapshot + ".pane.png"))
                }
                trace("done")
                QuitConfirmation.quitNow()
            }
        }
    }
}
#endif
