import Cocoa
import SwiftUI
import Carbon.HIToolbox
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private var store = TodoStore()
    private var globalHotKey: GlobalHotKey?

    private var isShowing = false
    private var isAnimating = false
    private var isUserInteracting = false

    // Collapse polling
    private var collapsePoll: DispatchSourceTimer?
    private var outsideCount = 0

    private let panelWidth: CGFloat = 430
    private let panelMaxHeight: CGFloat = 430

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        setupStatusItem()
        setupPanel()
        setupEditMenu()
        setupGlobalHotKey()
        
        // 自动弹出版面，避免图标被状态栏挡住而找不到
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.showPanel()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveImmediately()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !self.isShowing {
                self.showPanel(activateApp: true)
            }
        }
        completionHandler()
    }

    private func setupEditMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "退出 FloatingTodo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Global shortcut

    private func setupGlobalHotKey() {
        do {
            globalHotKey = try GlobalHotKey(
                keyCode: UInt32(kVK_ANSI_S),
                modifiers: UInt32(optionKey | cmdKey)
            ) { [weak self] in
                DispatchQueue.main.async {
                    self?.togglePanelVisibility()
                }
            }
        } catch {
            print("Failed to register global shortcut: \(error.localizedDescription)")
        }
    }

    // MARK: - Status Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let iconURL = AppResources.url(forResource: "StatusBarIcon", withExtension: "png"),
               let icon = NSImage(contentsOf: iconURL) {
                // 保留原始图钉造型，只让系统接管颜色与高亮状态。
                icon.isTemplate = true
                icon.size = NSSize(width: 11.3, height: 16)
                button.image = icon
            } else {
                button.title = "●"
            }
            button.imagePosition = .imageOnly
            button.action = #selector(statusBarClicked)
            button.target = self
            // Left click to toggle, right click for menu
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        // Right click -> show menu
        if event?.type == .rightMouseUp {
            let menu = NSMenu()
            let toggleItem = NSMenuItem(title: "显示/隐藏（⌥⌘S）", action: #selector(togglePanelVisibility), keyEquivalent: "")
            toggleItem.target = self
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem(title: "复制待办 Markdown", action: #selector(copyMarkdown), keyEquivalent: "c"))
            if let syncErrorMessage = store.syncErrorMessage {
                let errorItem = NSMenuItem(title: syncErrorMessage, action: nil, keyEquivalent: "")
                errorItem.isEnabled = false
                menu.addItem(errorItem)
            }
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "退出 FloatingTodo", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            // Clear menu so left click works again
            DispatchQueue.main.async { self.statusItem.menu = nil }
        } else {
            // Left click -> toggle panel
            if isShowing {
                hidePanel()
            } else {
                showPanel()
            }
        }
    }

    // MARK: - Panel

    private func setupPanel() {
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelMaxHeight),
            styleMask: [], backing: .buffered, defer: false
        )

        // NOTE: 使用自定义 HostingView，让首次鼠标点击直接穿透到 SwiftUI 按钮，
        // 而不是被 nonActivatingPanel 的窗口激活行为吞掉
        let hostView = ClickThroughHostingView(
            rootView: ContentView(store: store, onInteractionChange: { [weak self] isInteracting in
                self?.isUserInteracting = isInteracting
            })
        )
        let container = PanelContainerView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: panelMaxHeight))
        container.addSubview(hostView)
        hostView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostView.topAnchor.constraint(equalTo: container.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        panel.contentView = container
        panel.orderOut(nil)
    }

    // MARK: - Show / Hide

    private func showPanel(activateApp: Bool = false) {
        guard !isShowing, !isAnimating else { return }

        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
        }

        let buttonWin = statusItem.button?.window
        guard let screen = buttonWin?.screen ?? NSScreen.main else { return }

        // Position below the status bar icon if possible, otherwise center
        var x = screen.frame.midX - panelWidth / 2
        if let buttonWin = buttonWin {
            x = buttonWin.frame.midX - panelWidth / 2
        }
        
        // Clamp firmly to visible screen frame (avoids edges & Dock)
        x = max(screen.visibleFrame.minX + 8, min(x, screen.visibleFrame.maxX - panelWidth - 8))
        
        // strictly position right below the menu bar
        let yFinal = screen.visibleFrame.maxY - panelMaxHeight - 4

        // Start at final position, just transparent
        panel.setFrame(NSRect(x: x, y: yFinal, width: panelWidth, height: panelMaxHeight), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        isAnimating = true

        // Smooth fade in — no position animation, just appear
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            panel.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.isShowing = true
            self.isAnimating = false
            if activateApp {
                self.panel.makeKey()
            }
            self.startCollapsePoll()
        })
    }

    private func hidePanel() {
        guard isShowing, !isAnimating else { return }

        stopCollapsePoll()
        isAnimating = true

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.25, 1.0)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.panel.orderOut(nil)
            self.isShowing = false
            self.isAnimating = false
        })
    }

    // MARK: - Auto-collapse when mouse leaves

    private func startCollapsePoll() {
        stopCollapsePoll()
        outsideCount = 0
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(800), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.checkMouse() }
        timer.resume()
        collapsePoll = timer
    }

    private func stopCollapsePoll() {
        collapsePoll?.cancel()
        collapsePoll = nil
        outsideCount = 0
    }

    private func checkMouse() {
        guard isShowing, !isAnimating else { return }
        guard !isUserInteracting else {
            outsideCount = 0
            return
        }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame

        // Also include the status bar button area as "inside"
        var safeZone = frame.insetBy(dx: -20, dy: -20)
        // Extend upward practically to infinity to cover the entire menu bar space safely
        safeZone.size.height += 300

        if safeZone.contains(mouse) {
            outsideCount = 0
        } else {
            outsideCount += 1
            if outsideCount >= 5 {  // 500ms outside
                outsideCount = 0
                hidePanel()
            }
        }
    }

    // MARK: - Actions

    @objc private func togglePanelVisibility() {
        if isShowing {
            hidePanel()
        } else if !isAnimating {
            showPanel(activateApp: true)
        }
    }

    @objc private func copyMarkdown() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(store.markdownContent(), forType: .string)
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
}
