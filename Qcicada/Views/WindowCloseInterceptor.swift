import SwiftUI
import AppKit

/// Intercepts the macOS window close (red button) and lets SwiftUI decide when to actually close.
struct WindowCloseInterceptor: NSViewRepresentable {
    let onCloseAttempt: (@escaping () -> Void) -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onCloseAttempt: onCloseAttempt)
    }
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(to: window)
            }
        }
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                context.coordinator.attach(to: window)
            }
        }
    }
    
    final class Coordinator: NSObject, NSWindowDelegate {
        private weak var window: NSWindow?
        private var allowCloseOnce = false
        private let onCloseAttempt: (@escaping () -> Void) -> Void
        
        init(onCloseAttempt: @escaping (@escaping () -> Void) -> Void) {
            self.onCloseAttempt = onCloseAttempt
        }
        
        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            window.delegate = self
        }
        
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowCloseOnce {
                allowCloseOnce = false
                return true
            }
            
            onCloseAttempt { [weak self, weak sender] in
                guard let self, let sender else { return }
                self.allowCloseOnce = true
                sender.performClose(nil)
            }
            return false
        }
    }
}
