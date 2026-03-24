// VisualEffectView.swift
// Qcicada
//
// NSViewRepresentable wrapper for NSVisualEffectView.
// Provides real macOS-native translucent blur effects
// identical to Apple TV, Apple Music, Finder sidebars.

import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State
    var isEmphasized: Bool
    
    init(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active,
        isEmphasized: Bool = false
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
        self.isEmphasized = isEmphasized
    }
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
        nsView.isEmphasized = isEmphasized
    }
}

// MARK: - Convenience modifiers

extension View {
    /// Apply a native macOS visual effect as background
    func visualEffectBackground(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) -> some View {
        self.background(
            VisualEffectView(
                material: material,
                blendingMode: blendingMode,
                state: state
            )
        )
    }
    
    /// Apply visual effect that ignores safe area (full window coverage)
    func visualEffectBackgroundFullWindow(
        material: NSVisualEffectView.Material = .sidebar
    ) -> some View {
        self.background(
            VisualEffectView(
                material: material,
                blendingMode: .behindWindow,
                state: .active
            )
            .ignoresSafeArea()
        )
    }
}
