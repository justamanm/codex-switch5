import AppKit
import SwiftUI

/// 为横向图表补充鼠标左键拖动，保留滚轮与触控板滚动。
struct ChartMousePanSupport: NSViewRepresentable {
    func makeNSView(context: Context) -> PanAnchor { PanAnchor() }
    func updateNSView(_ nsView: PanAnchor, context: Context) {}

    final class PanAnchor: NSView {
        private weak var attachedScrollView: NSScrollView?
        private lazy var pan = NSPanGestureRecognizer(target: self, action: #selector(dragChart(_:)))

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }

        private func attach() {
            guard let scroll = enclosingScrollView, scroll !== attachedScrollView else { return }
            attachedScrollView?.removeGestureRecognizer(pan)
            pan.buttonMask = 1
            scroll.addGestureRecognizer(pan)
            attachedScrollView = scroll
        }

        @objc private func dragChart(_ gesture: NSPanGestureRecognizer) {
            guard let scroll = attachedScrollView, let document = scroll.documentView else { return }
            let clip = scroll.contentView
            let delta = gesture.translation(in: clip)
            gesture.setTranslation(.zero, in: clip)
            let maximum = max(0, document.bounds.width - clip.bounds.width)
            let x = min(maximum, max(0, clip.bounds.origin.x - delta.x))
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.origin.y))
            scroll.reflectScrolledClipView(clip)
        }
    }
}
