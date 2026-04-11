import SwiftUI
import AppKit
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
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
        
        // Setup Notifications
        setupNotifications()
        
        // Start notch drop zone for AirDrop
        NotchDropManager.shared.startMonitoring()
    }
    
    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                print("Notification authorization failed: \(error)")
            }
        }
        
        let viewAction = UNNotificationAction(identifier: "VIEW_EXPORT", title: "查看", options: .foreground)
        let category = UNNotificationCategory(identifier: "EXPORT_CATEGORY", actions: [viewAction], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
    }
    
    // Show notification even when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    // Handle notification response
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == "VIEW_EXPORT" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let userInfo = response.notification.request.content.userInfo
            if let path = userInfo["path"] as? String {
                let url = URL(fileURLWithPath: path)
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
            }
        }
        completionHandler()
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
