//
//  iClipboardApp.swift
//  iClipboard
//
//  Created by tenom on 2025/12/16.
//

import SwiftUI

@main
struct iClipboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
