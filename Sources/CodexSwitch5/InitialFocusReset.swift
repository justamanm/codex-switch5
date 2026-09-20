import AppKit
import SwiftUI

private struct InitialTextFocusResetter: NSViewRepresentable {
    func makeNSView(context: Context) -> InitialTextFocusResetView {
        InitialTextFocusResetView()
    }

    func updateNSView(_ nsView: InitialTextFocusResetView, context: Context) {}
}

private final class InitialTextFocusResetView: NSView {
    private var hasResetFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasResetFocus else { return }
        hasResetFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window else { return }
            if window.firstResponder is NSTextView || window.firstResponder is NSTextField {
                window.makeFirstResponder(nil)
            }
        }
    }
}

extension View {
    func clearsInitialTextFocus() -> some View {
        background(InitialTextFocusResetter().frame(width: 0, height: 0))
    }
}
