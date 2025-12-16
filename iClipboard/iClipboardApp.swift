//
//  iClipboardApp.swift
//  iClipboard
//
//  Created by tenom on 2025/12/16.
//

import SwiftUI

@main
struct iClipboardApp: App {
    private let persistenceController = PersistenceController.shared

    var body: some Scene {
        MenuBarExtra("iClipboard", systemImage: "scissors") {
            ContentView(context: persistenceController.container.viewContext)
        }
        .menuBarExtraStyle(.window)
    }
}
