import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var windowManager = WindowManager.shared
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create Status Item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "scissors", accessibilityDescription: "iClipboard")
            button.action = #selector(togglePopover(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        windowManager.statusItem = statusItem
        
        // Create Panel
        let contentView = ContentView()
            .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
            .environmentObject(windowManager)
        
        let panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: AppConstants.Panel.width, height: AppConstants.Panel.height),
            backing: .buffered,
            defer: false
        )
        
        panel.contentView = NSHostingView(rootView: contentView)
        windowManager.panel = panel
        
        // Handle focus loss
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey), name: NSWindow.didResignKeyNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidResignActive), name: NSApplication.didResignActiveNotification, object: nil)
    }
    
    @objc func togglePopover(_ sender: AnyObject?) {
        let event = NSApp.currentEvent!
        
        if event.type == .rightMouseUp || (event.type == .leftMouseUp && event.modifierFlags.contains(.control)) {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "退出 iClipboard", action: #selector(terminateApp), keyEquivalent: "q"))
            
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            windowManager.toggleWindow()
        }
    }
    
    @objc func terminateApp() {
        NSApp.terminate(nil)
    }
    
    @objc func windowDidResignKey(_ notification: Notification) {
        windowManager.handleFocusLoss()
    }
    
    @objc func applicationDidResignActive(_ notification: Notification) {
        windowManager.handleFocusLoss()
    }
}
