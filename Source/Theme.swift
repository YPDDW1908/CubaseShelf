import SwiftUI
import AppKit

// Dynamic NSColors follow the window's effective appearance, including a running
// system appearance change. No application-level light/dark override is applied.
enum ShelfTheme {
    static let logo: NSImage = Bundle.main.url(forResource:"BrandLogo",withExtension:"png")
        .flatMap { NSImage(contentsOf:$0) } ?? NSImage(size:NSSize(width:1,height:1))
    private static func adaptive(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name:nil) { appearance in
            let value = appearance.bestMatch(from:[.aqua,.darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed:value.0,green:value.1,blue:value.2,alpha:1)
        })
    }
    static let background = adaptive((0.96,0.97,0.97),(0.16,0.18,0.20))
    static let sidebar = adaptive((0.91,0.94,0.94),(0.20,0.23,0.25))
    static let surface = adaptive((1,1,1),(0.23,0.26,0.28))
    static let field = adaptive((0.97,0.98,0.98),(0.18,0.21,0.23))
    static let accent = adaptive((0.17,0.40,0.41),(0.49,0.74,0.73))
    static let onAccent = adaptive((1,1,1),(0.10,0.18,0.18))
    static let selection = adaptive((0.85,0.93,0.92),(0.25,0.36,0.37))
    static let border = adaptive((0.79,0.84,0.84),(0.34,0.39,0.41))
    static let warning = adaptive((0.63,0.33,0.04),(1,0.73,0.38))
    static let rating = adaptive((0.56,0.37,0.06),(0.95,0.77,0.38))
}
