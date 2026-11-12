// QcicadaApp.swift
// Qcicada

import SwiftUI

@main
struct QcicadaApp: App {
    @NSApplicationDelegateAdaptor(QcicadaApplicationDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1100, height: 720)
    }
}
