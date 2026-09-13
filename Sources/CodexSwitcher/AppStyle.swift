import AppKit
import SwiftUI

/// 颜色随系统外观变化，状态仍通过文字表达。
enum AppStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.57, green: 0.73, blue: 0.94, alpha: 1)
            : NSColor(red: 0.22, green: 0.41, blue: 0.68, alpha: 1)
    })
    static let background = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.12, green: 0.13, blue: 0.14, alpha: 1)
            : NSColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 1)
    })
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)
}
