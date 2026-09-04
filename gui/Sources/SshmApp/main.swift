import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var main: MainWindowController?

    func applicationDidFinishLaunching(_ n: Notification) {
        // the whole app, not just the window — otherwise popovers, menus and
        // open panels render light
        Theme.apply(mode: AppModel.shared.settings.theme)
        Theme.terminalFontSize = CGFloat(AppModel.shared.settings.fontSize)

        buildMenu()
        Updater.shared.start()
        let c = MainWindowController()
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        main = c
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ n: Notification) {
        main?.root.shell.terminals.closeAll()
        MetaStore.shared.saveNow()
    }

    /// target: nil so every command walks the responder chain and whichever page
    /// or window controller can handle it, does.
    private func item(_ title: String, _ sel: Selector?, _ key: String,
                      _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = nil
        return i
    }

    private func buildMenu() {
        let bar = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(item("About ArkConnect", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        app.addItem(item("Check for Updates…", #selector(MainWindowController.checkForUpdates(_:)), ""))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(MainWindowController.showSettings(_:)), ","))
        app.addItem(.separator())
        app.addItem(item("Hide sshm", #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item("Quit sshm", #selector(NSApplication.terminate(_:)), "q"))
        appItem.submenu = app
        bar.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(item("New…", #selector(MainWindowController.newItem(_:)), "n"))
        file.addItem(item("New Server…", #selector(MainWindowController.newServer(_:)), "n",
                          [.command, .shift]))
        file.addItem(.separator())
        file.addItem(item("Reload Config", #selector(MainWindowController.reloadConfig(_:)), "r"))
        file.addItem(.separator())
        file.addItem(item("Command Palette…", #selector(MainWindowController.commandPalette(_:)), "k"))
        fileItem.submenu = file
        bar.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        editItem.submenu = edit
        bar.addItem(editItem)

        let goItem = NSMenuItem()
        let go = NSMenu(title: "Go")
        go.addItem(item("Dashboard", #selector(MainWindowController.showDashboard(_:)), "1"))
        go.addItem(item("Projects", #selector(MainWindowController.showProjects(_:)), "2"))
        go.addItem(item("Servers", #selector(MainWindowController.showServers(_:)), "3"))
        go.addItem(item("Sessions", #selector(MainWindowController.showSessions(_:)), "4"))
        go.addItem(item("Settings", #selector(MainWindowController.showSettings(_:)), "5"))
        go.addItem(.separator())
        go.addItem(item("Toggle Appearance", #selector(MainWindowController.toggleTheme(_:)), "t",
                        [.command, .shift]))
        goItem.submenu = go
        bar.addItem(goItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(item("Close Session", #selector(MainWindowController.closeSession(_:)), "w"))
        win.addItem(item("Next Session", #selector(MainWindowController.nextSession(_:)), "]",
                         [.command, .shift]))
        win.addItem(item("Previous Session", #selector(MainWindowController.prevSession(_:)), "[",
                         [.command, .shift]))
        win.addItem(.separator())
        win.addItem(item("Focus Mode", #selector(MainWindowController.toggleFocusMode(_:)), "f",
                         [.command, .control]))
        win.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f",
                         [.command, .control, .shift]))
        win.addItem(.separator())
        win.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        winItem.submenu = win
        bar.addItem(winItem)

        NSApp.mainMenu = bar
        NSApp.windowsMenu = win
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
