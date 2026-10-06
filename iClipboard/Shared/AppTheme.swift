import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .system: return "display"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
    
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色模式"
        case .dark: return "深色模式"
        }
    }
    
    var next: AppTheme {
        switch self {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }
}

/// Semantic colors shared by the panel, its controls, and its sheets.
/// Resolve from SwiftUI's effective scheme so an explicit theme also works
/// when the system appearance differs from the app's preference.
struct AppPalette {
    let isActive: Bool
    let hasIncreasedContrast: Bool
    let panel: Color
    let sidebar: Color
    let surface: Color
    let surfaceHover: Color
    let control: Color
    let controlHover: Color
    let border: Color
    let separator: Color
    let text: Color
    let secondaryText: Color
    let accent: Color
    let selection: Color
    let selectionText: Color
    let selectionBorder: Color
    let favorite: Color
    let favoriteSurface: Color
    let favoriteBorder: Color
    let destructive: Color
    let success: Color
    let panelEdge: Color

    init(
        colorScheme: ColorScheme,
        contrast: ColorSchemeContrast = .standard,
        activeState: ControlActiveState = .key
    ) {
        let isDark = colorScheme == .dark
        isActive = activeState != .inactive
        hasIncreasedContrast = contrast == .increased
        func color(_ light: UInt32, _ dark: UInt32) -> Color {
            let hex = isDark ? dark : light
            return Color(
                .sRGB,
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255,
                opacity: 1
            )
        }

        let ink = isDark ? Color.white : Color.black
        panel = color(0xF5F5F7, 0x262628) // Opaque accessibility fallback only.
        sidebar = ink.opacity(isDark ? 0.025 : 0.022)
        surface = Color.white.opacity(isDark ? (isActive ? 0.035 : 0.05) : (isActive ? 0.22 : 0.32))
        surfaceHover = Color.white.opacity(isDark ? 0.065 : (isActive ? 0.30 : 0.40))
        control = ink.opacity(isDark ? 0.065 : 0.035)
        controlHover = ink.opacity(isDark ? 0.12 : 0.07)
        border = ink.opacity(hasIncreasedContrast ? 0.42 : (isDark ? 0.085 : 0.055))
        separator = ink.opacity(hasIncreasedContrast ? 0.3 : 0.065)
        text = color(0x242426, 0xF4F4F5)
        secondaryText = color(0x45454D, 0xB6B6BE)
        accent = isActive ? color(0x005FCF, 0x7DB3FF) : secondaryText
        selection = accent.opacity(isActive ? (isDark ? 0.18 : 0.10) : 0.09)
        selectionText = isActive ? color(0x00449A, 0xA5CAFF) : secondaryText
        selectionBorder = accent.opacity(hasIncreasedContrast ? 0.65 : 0.20)
        favorite = hasIncreasedContrast ? color(0x9B7000, 0xFFD60A) : color(0xFFCC00, 0xFFD60A)
        favoriteSurface = ink.opacity(isDark ? 0.045 : 0.025)
        favoriteBorder = hasIncreasedContrast ? border : .clear
        destructive = color(0xC43B43, 0xFF929A)
        success = color(0x287A50, 0x88D5A7)
        panelEdge = hasIncreasedContrast ? border : Color.white.opacity(isDark ? 0.14 : 0.52)
    }
}

extension EnvironmentValues {
    var appPalette: AppPalette {
        AppPalette(colorScheme: colorScheme, contrast: colorSchemeContrast, activeState: controlActiveState)
    }
}

/// AppKit supplies behind-window blending and the native inactive appearance.
/// SwiftUI's ordinary material backgrounds stay active on this deployment target.
struct PanelMaterial: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        view.wantsLayer = true
        view.layer?.cornerRadius = 16
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        let name: NSAppearance.Name
        if contrast == .increased {
            name = colorScheme == .dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua
        } else {
            name = colorScheme == .dark ? .darkAqua : .aqua
        }
        view.appearance = NSAppearance(named: name)
    }
}

struct PanelBackground: View {
    @Environment(\.appPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var material: NSVisualEffectView.Material = .popover

    var body: some View {
        Group {
            if reduceTransparency {
                palette.panel
            } else {
                PanelMaterial(material: material)
            }
        }
        .allowsHitTesting(false)
    }
}

struct PanelThemeStyle: ViewModifier {
    @Environment(\.appPalette) private var palette

    func body(content: Content) -> some View {
        content
            .foregroundStyle(palette.text)
            .tint(palette.accent)
            .background(PanelBackground())
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(palette.panelEdge, lineWidth: 0.5)
                    .allowsHitTesting(false)
            )
    }
}

struct ThemeDivider: View {
    @Environment(\.appPalette) private var palette
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(palette.separator)
            .frame(width: vertical ? 0.5 : nil, height: vertical ? nil : 0.5)
            .accessibilityHidden(true)
    }
}
