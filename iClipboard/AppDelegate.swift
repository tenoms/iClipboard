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
        }
        
        windowManager.statusItem = statusItem
        
        // Create Panel
        let contentView = ContentView()
            .environment(\.managedObjectContext, PersistenceController.shared.container.viewContext)
            .environmentObject(windowManager)
        
        let panel = ClipboardPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),
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
        windowManager.toggleWindow()
    }
    
    @objc func windowDidResignKey(_ notification: Notification) {
        windowManager.handleFocusLoss()
    }
    
    @objc func applicationDidResignActive(_ notification: Notification) {
        windowManager.handleFocusLoss()
    }
}
