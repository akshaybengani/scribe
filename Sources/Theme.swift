import SwiftUI
import AppKit
import CoreText

// MARK: - Graphite tokens
//
// Every colour is a dynamic colour: it resolves against the effective appearance of the window it is drawn in,
// so the whole app follows the system light or dark setting without any state. The values come from
// docs/design/GRAPHITE.md. Never write a raw hex inside a screen, add a token here instead.

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    /// A colour that switches between a dark and a light value with the effective appearance.
    static func graphite(dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        }))
    }
}

enum G {
    static let bg = Color.graphite(dark: 0x0D0E11, light: 0xF5F6F8)
    static let sidebar = Color.graphite(dark: 0x111317, light: 0xEDEFF2)
    static let surface = Color.graphite(dark: 0x16181D, light: 0xFFFFFF)
    static let surface2 = Color.graphite(dark: 0x1C1F25, light: 0xF1F3F6)
    static let surface3 = Color.graphite(dark: 0x262B33, light: 0xE3E7EC)
    static let border = Color.graphite(dark: 0x272B33, light: 0xDDE1E7)
    static let borderStrong = Color.graphite(dark: 0x333944, light: 0xC7CDD6)
    static let text = Color.graphite(dark: 0xECEEF1, light: 0x14171C)
    static let text2 = Color.graphite(dark: 0xA0A7B2, light: 0x4A525E)
    static let text3 = Color.graphite(dark: 0x8A929E, light: 0x5F6875)
    static let accent = Color.graphite(dark: 0xC6F135, light: 0xC6F135)
    static let onAccent = Color.graphite(dark: 0x0D0E11, light: 0x14171C)
    static let accentSoft = Color.graphite(dark: 0x1C2410, light: 0xEEF8CC)
    static let accentText = Color.graphite(dark: 0xC6F135, light: 0x456000)
    static let focus = Color.graphite(dark: 0xC6F135, light: 0x456000)
    static let blue = Color.graphite(dark: 0x6EA8FE, light: 0x1F5FD1)
    static let bar = Color.graphite(dark: 0x6B7585, light: 0x9AA3B0)
    static let warnBg = Color.graphite(dark: 0x2E1A08, light: 0xFFF1DE)
    static let warnBorder = Color.graphite(dark: 0xB8661B, light: 0xD98324)
    static let warnText = Color.graphite(dark: 0xFFE2BF, light: 0x5C3300)
    static let warnIcon = Color.graphite(dark: 0xFFA94D, light: 0xB25E00)
    static let danger = Color.graphite(dark: 0xFF6B6B, light: 0xC62828)
    static let dangerSoft = Color.graphite(dark: 0x2A1214, light: 0xFDECEC)
    static let success = Color.graphite(dark: 0x5FD38D, light: 0x1B7F43)
    static let scrim = Color.graphite(dark: 0x000000, light: 0x14171C, darkAlpha: 0.6, lightAlpha: 0.35)
    static let shadow = Color.graphite(dark: 0x000000, light: 0x14171C, darkAlpha: 0.35, lightAlpha: 0.16)

    static let folderRed = Color.graphite(dark: 0xFF6B6B, light: 0xD64545)
    static let folderOrange = Color.graphite(dark: 0xFFA94D, light: 0xC9700F)
    static let folderYellow = Color.graphite(dark: 0xFFD43B, light: 0xA67C00)
    static let folderGreen = Color.graphite(dark: 0x5FD38D, light: 0x1B7F43)
    static let folderTeal = Color.graphite(dark: 0x3CC9C0, light: 0x0F8A83)
    static let folderBlue = Color.graphite(dark: 0x6EA8FE, light: 0x1F5FD1)
    static let folderPurple = Color.graphite(dark: 0xB197FC, light: 0x6F4BD8)
    static let folderPink = Color.graphite(dark: 0xF783AC, light: 0xC2255C)
    static let folderGray = Color.graphite(dark: 0x8A929E, light: 0x5F6875)
}

extension FolderColor {
    var swiftUI: Color {
        switch self {
        case .red: return G.folderRed
        case .orange: return G.folderOrange
        case .yellow: return G.folderYellow
        case .green: return G.folderGreen
        case .teal: return G.folderTeal
        case .blue: return G.folderBlue
        case .purple: return G.folderPurple
        case .pink: return G.folderPink
        case .gray: return G.folderGray
        }
    }

    var label: String { rawValue.capitalized }
}

// MARK: - Fonts

/// Inter and JetBrains Mono ship in the app bundle (Contents/Resources/Fonts, SIL OFL, see assets/fonts) and are
/// registered for this process at launch, before the first view exists. If they are missing the helpers fall back
/// to SF Pro and SF Mono, so nothing breaks.
enum GFont {
    /// Registers every TTF/OTF in `Contents/Resources/Fonts` (or `directory`) for this process. Call once, early.
    @discardableResult
    static func registerBundled(from directory: URL? = nil) -> Int {
        let dir = directory ?? Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
        guard let dir,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for f in files where ["ttf", "otf"].contains(f.pathExtension.lowercased()) {
            if CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) { count += 1 }
        }
        return count
    }

    private static func interName(_ w: Font.Weight) -> String {
        switch w {
        case .bold, .heavy, .black: return "Inter-Bold"
        case .semibold: return "Inter-SemiBold"
        case .medium: return "Inter-Medium"
        default: return "Inter-Regular"
        }
    }

    private static func monoName(_ w: Font.Weight) -> String {
        switch w {
        case .medium, .semibold, .bold, .heavy, .black: return "JetBrainsMono-Medium"
        default: return "JetBrainsMono-Regular"
        }
    }

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = interName(weight)
        return NSFont(name: name, size: size) != nil
            ? Font.custom(name, fixedSize: size)
            : Font.system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = monoName(weight)
        return NSFont(name: name, size: size) != nil
            ? Font.custom(name, fixedSize: size)
            : Font.system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Small shared pieces

struct GIcon: View {
    let name: String
    var size: CGFloat = 14
    var weight: Font.Weight = .medium
    init(_ name: String, size: CGFloat = 14, weight: Font.Weight = .medium) {
        self.name = name; self.size = size; self.weight = weight
    }
    var body: some View { Image(systemName: name).font(.system(size: size, weight: weight)) }
}

/// Icon followed by a title, the content of most buttons.
struct IconLabel: View {
    let title: String
    let icon: String?
    var trailing: String? = nil
    init(_ title: String, _ icon: String? = nil, trailing: String? = nil) {
        self.title = title; self.icon = icon; self.trailing = trailing
    }
    var body: some View {
        HStack(spacing: 8) {
            if let icon { GIcon(icon, size: 13) }
            Text(title)
            if let trailing { GIcon(trailing, size: 10, weight: .semibold) }
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(GFont.ui(12, .semibold))
            .tracking(0.72)
            .foregroundStyle(G.text3)
    }
}

struct FolderSwatch: View {
    let color: Color
    var size: CGFloat = 9
    var body: some View {
        RoundedRectangle(cornerRadius: size >= 12 ? 4 : 3, style: .continuous).fill(color).frame(width: size, height: size)
    }
}

struct IconTile: View {
    let icon: String
    var size: CGFloat = 40
    var body: some View {
        GIcon(icon, size: 18)
            .foregroundStyle(G.text2)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.surface2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.border))
    }
}

/// "Caret wave", the approved Scribe mark. The shapes use the 824 pt area of the icon (the macOS icon grid),
/// so the logo is the same drawing as `assets/branding/icon.svg`.
struct CaretWaveBars: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 824
        var p = Path()
        // x, y, height of the four bars in icon space (width 64, fully rounded), origin at the tile corner (100, 100)
        for (x, y, h) in [(222.0, 432.0, 160.0), (330, 362, 300), (438, 292, 440), (546, 392, 240)] {
            let r = CGRect(x: rect.minX + (x - 100) * k, y: rect.minY + (y - 100) * k, width: 64 * k, height: h * k)
            p.addRoundedRect(in: r, cornerSize: CGSize(width: 32 * k, height: 32 * k), style: .continuous)
        }
        return p
    }
}

struct CaretWaveCaret: Shape {
    func path(in rect: CGRect) -> Path {
        let k = rect.width / 824
        func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: Double) -> Path {
            Path(roundedRect: CGRect(x: rect.minX + (x - 100) * k, y: rect.minY + (y - 100) * k, width: w * k, height: h * k),
                 cornerSize: CGSize(width: c * k, height: c * k), style: .continuous)
        }
        var p = Path()
        p.addPath(r(706, 252, 64, 520, 12))
        p.addPath(r(674, 252, 128, 48, 24))
        p.addPath(r(674, 724, 128, 48, 24))
        return p
    }
}

/// The mark on its graphite tile, at any size. The tile keeps the app icon colours in light and dark.
struct LogoMark: View {
    var size: CGFloat = 28
    var tile = true
    var body: some View {
        ZStack {
            if tile {
                RoundedRectangle(cornerRadius: size * 186 / 824, style: .continuous).fill(Color(red: 0x11 / 255, green: 0x13 / 255, blue: 0x17 / 255))
                RoundedRectangle(cornerRadius: size * 183 / 824, style: .continuous)
                    .strokeBorder(Color(red: 0x27 / 255, green: 0x2B / 255, blue: 0x33 / 255), lineWidth: max(0.5, size * 6 / 824))
            }
            Group {
                CaretWaveBars().fill(Color(red: 0x8B / 255, green: 0x94 / 255, blue: 0xA1 / 255))
                CaretWaveCaret().fill(Color(red: 0xC6 / 255, green: 0xF1 / 255, blue: 0x35 / 255))
            }
            .scaleEffect(tile ? 1 : 1.4)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Scribe")
    }
}

extension View {
    /// Surface card: 14px radius, 1px border. Pass padding 0 for lists that manage their own insets.
    func card(padding: CGFloat = 20, radius: CGFloat = 14, fill: Color = G.surface) -> some View {
        self.padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(G.border, lineWidth: 1))
    }

    /// Same as `card` but clips its content to the rounded corners.
    func clippedCard(radius: CGFloat = 14) -> some View {
        self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(G.surface))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(G.border, lineWidth: 1))
    }
}

// MARK: - Buttons

struct GButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, opinion, quiet }
    var kind: Kind = .secondary
    var height: CGFloat = 34
    var square = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(GFont.ui(13, kind == .primary || kind == .opinion ? .semibold : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, square ? 0 : 12)
            .frame(width: square ? height : nil, height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background(pressed: pressed)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(border, lineWidth: 1))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .primary: return G.onAccent
        case .secondary, .quiet: return G.text
        case .danger: return G.danger
        case .opinion: return G.accentText
        }
    }

    private func background(pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? G.accent.opacity(0.85) : G.accent
        case .secondary: return pressed ? G.surface3 : G.surface2
        case .quiet: return pressed ? G.surface3 : Color.clear
        case .danger: return pressed ? G.dangerSoft : Color.clear
        case .opinion: return pressed ? G.accentSoft : Color.clear
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return G.accent
        case .secondary: return G.borderStrong
        case .quiet: return Color.clear
        case .danger: return G.danger
        case .opinion: return G.accentText
        }
    }
}

extension ButtonStyle where Self == GButtonStyle {
    static var gPrimary: GButtonStyle { GButtonStyle(kind: .primary) }
    static var gSecondary: GButtonStyle { GButtonStyle(kind: .secondary) }
    static var gDanger: GButtonStyle { GButtonStyle(kind: .danger) }
    static var gOpinion: GButtonStyle { GButtonStyle(kind: .opinion) }
    static func g(_ kind: GButtonStyle.Kind, height: CGFloat = 34, square: Bool = false) -> GButtonStyle {
        GButtonStyle(kind: kind, height: height, square: square)
    }
}

/// Menu that looks like a secondary button. Used for folder pickers and the opinions menu.
struct GMenuLabel: View {
    let content: AnyView
    var kind: GButtonStyle.Kind = .secondary
    var height: CGFloat = 34
    var body: some View {
        content
            .font(GFont.ui(13, kind == .opinion ? .semibold : .medium))
            .foregroundStyle(kind == .opinion ? G.accentText : G.text)
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(kind == .opinion ? Color.clear : G.surface2))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(kind == .opinion ? G.accentText : G.borderStrong, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Segmented control and radio card

struct GSegmented<T: Hashable>: View {
    let options: [T]
    @Binding var selection: T
    let title: (T) -> String
    var icon: (T) -> String? = { _ in nil }
    var label: String = ""
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button { selection = option } label: {
                    HStack(spacing: 8) {
                        if let name = icon(option) { GIcon(name, size: 13) }
                        Text(title(option))
                    }
                    .font(GFont.ui(13, .medium))
                    .foregroundStyle(on ? G.text : G.text2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? G.surface3 : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(on ? G.borderStrong : Color.clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.bg))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.border, lineWidth: 1))
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

struct RadioCard<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().strokeBorder(selected ? G.accentText : G.borderStrong, lineWidth: 1.5)
                    if selected { Circle().fill(G.accentText).padding(4) }
                }
                .frame(width: 16, height: 16)
                .padding(.top, 2)
                content
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? G.accentSoft : G.surface2))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? G.accent : G.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct GCheckbox: View {
    @Binding var isOn: Bool
    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(isOn ? G.accentText : G.bg)
                RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(isOn ? G.accentText : G.borderStrong, lineWidth: 1.5)
                if isOn { Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(G.bg) }
            }
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

// MARK: - Status

struct StatusPill: View {
    enum Kind { case ready, warn, bad, neutral }
    let kind: Kind
    let text: String
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let name = icon ?? defaultIcon { GIcon(name, size: 11, weight: .bold) }
            Text(text)
        }
        .font(GFont.ui(12, .semibold))
        .foregroundStyle(foreground)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(background).overlay(Capsule().inset(by: 0.5).stroke(border, lineWidth: kind == .ready ? 0 : 1)))
    }

    private var defaultIcon: String? {
        switch kind {
        case .ready: return "checkmark"
        case .warn: return "exclamationmark.triangle.fill"
        case .bad: return "exclamationmark.circle.fill"
        case .neutral: return nil
        }
    }
    private var foreground: Color {
        switch kind {
        case .ready: return G.success
        case .warn: return G.warnText
        case .bad: return G.danger
        case .neutral: return G.text2
        }
    }
    private var background: Color {
        switch kind {
        case .ready: return G.accentSoft
        case .warn: return G.warnBg
        case .bad: return G.dangerSoft
        case .neutral: return Color.clear
        }
    }
    private var border: Color {
        switch kind {
        case .ready: return Color.clear
        case .warn: return G.warnBorder
        case .bad: return G.danger
        case .neutral: return G.borderStrong
        }
    }
}

/// Small outlined chip, for language and format labels.
struct Chip: View {
    let text: String
    var mono = false
    var body: some View {
        Text(text)
            .font(mono ? GFont.mono(12) : GFont.ui(11, .semibold))
            .foregroundStyle(G.text2)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Capsule().fill(Color.clear))
            .overlay(Capsule().strokeBorder(G.borderStrong, lineWidth: 1))
            .fixedSize()
    }
}

/// The cloud warning banner. The copy is built by the caller and always starts "Cloud model in use:".
struct WarningBanner: View {
    let text: String

    private var parts: (lead: String, rest: String) {
        if let range = text.range(of: ":") {
            return (String(text[..<range.upperBound]), String(text[range.upperBound...]))
        }
        return ("", text)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(G.warnIcon)
            (Text(parts.lead).fontWeight(.semibold) + Text(parts.rest))
                .font(GFont.ui(13))
                .foregroundStyle(G.warnText)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(G.warnBg))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(G.warnBorder, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Fields

struct GField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false
    var secure = false
    var height: CGFloat = 40
    var autofocus = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
        }
        .textFieldStyle(.plain)
        .onSubmit(onSubmit)
        .onAppear { if autofocus { DispatchQueue.main.async { focused = true } } }
        .font(mono ? GFont.mono(13) : GFont.ui(14))
        .foregroundStyle(G.text)
        .focused($focused)
        .focusEffectDisabled()
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(G.bg))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(G.borderStrong, lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(G.focus, lineWidth: 2).padding(-2).opacity(focused ? 1 : 0))
    }
}

/// A label above a field, the way every settings row is laid out.
struct FieldRow<Content: View>: View {
    let title: String
    var caption: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(GFont.ui(13, .semibold)).foregroundStyle(G.text)
            content
            if let caption {
                Text(caption).font(GFont.ui(12)).foregroundStyle(G.text3).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Waveform lanes

/// One 72px well with 3px bars and 3px gaps. Live bars grow from the right, the newest few are "hot"
/// in the lane colour; idle or paused bars use the neutral bar colour.
struct LaneWell: View {
    let levels: [Float]
    let active: Bool
    let tint: Color
    var idleSeed: Double = 1.3

    var body: some View {
        Canvas { ctx, size in
            let barW: CGFloat = 3, gap: CGFloat = 3, step = barW + gap
            let inset: CGFloat = 12
            let fit = max(1, Int((size.width - inset * 2) / step))
            let maxH = size.height - 24

            func draw(_ heights: [CGFloat], alignRight: Bool, hot: Int) {
                let total = CGFloat(heights.count) * step - gap
                var x = alignRight ? size.width - inset - total : inset
                for (i, h) in heights.enumerated() {
                    let height = max(4, h)
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: barW, height: height)
                    let isHot = active && i >= heights.count - hot
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(isHot ? tint : G.bar))
                    x += step
                }
            }

            if levels.isEmpty {
                let heights = (0..<fit).map { i -> CGFloat in
                    let v = abs(sin(Double(i) * 0.55 + idleSeed) * cos(Double(i) * 0.17 + idleSeed * 2)) * 0.7
                        + 0.25 * abs(sin(Double(i) * 1.9 + idleSeed))
                    return CGFloat(v) * 12
                }
                draw(heights, alignRight: false, hot: 0)
            } else {
                let shown = levels.suffix(fit)
                draw(shown.map { CGFloat(min(1, max(0, $0))) * maxH }, alignRight: true, hot: 14)
            }
        }
        .frame(height: 72)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.bg))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Audio level waveform")
    }
}

/// One lane with its small header row (icon, name, state).
struct CaptureLane: View {
    let title: String
    let icon: String
    let iconColor: Color
    let state: String
    let levels: [Float]
    let active: Bool
    let tint: Color
    var seed: Double = 1.3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                GIcon(icon, size: 13).foregroundStyle(iconColor)
                Text(title).font(GFont.ui(13, .semibold))
                Spacer()
                Text(state).font(GFont.mono(12)).foregroundStyle(G.text3)
            }
            LaneWell(levels: levels, active: active, tint: tint, idleSeed: seed)
        }
    }
}

// MARK: - Folder tree row

struct TreeRow: View {
    var depth = 0
    /// nil = no disclosure triangle, true = open, false = closed.
    var chevron: Bool? = nil
    var onToggle: () -> Void = {}
    var swatch: Color? = nil
    var icon: String? = nil
    let title: String
    var count: Int? = nil
    var selected = false
    var dropTarget = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if let chevron {
                    Image(systemName: chevron ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(G.text3)
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onToggle)
                }
            }
            .frame(width: 14, height: 14)
            if let swatch { FolderSwatch(color: swatch) }
            else if let icon { GIcon(icon, size: 12).foregroundStyle(G.text3).frame(width: 9) }
            Text(title)
                .font(GFont.ui(13, .medium))
                .foregroundStyle(selected || dropTarget ? G.text : G.text2)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let count { Text("\(count)").font(GFont.mono(11)).foregroundStyle(G.text3) }
        }
        .padding(.leading, 8 + CGFloat(depth) * 16)
        .padding(.trailing, 8)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(dropTarget ? G.accentSoft : (selected ? G.surface3 : Color.clear)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(dropTarget ? G.accent : (selected ? G.borderStrong : Color.clear), lineWidth: 1))
        .contentShape(Rectangle())
    }
}

// MARK: - Modal and toast

/// Dialog card, 480 wide, over a scrim. Click the scrim or press Escape to cancel.
struct ModalScrim<Content: View>: View {
    let onCancel: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            G.scrim
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)
            content
                .padding(24)
                .frame(width: 480)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(G.surface))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(G.borderStrong, lineWidth: 1))
                .shadow(color: G.shadow, radius: 16, y: 12)
        }
        .onExitCommand(perform: onCancel)
        .transition(.opacity)
    }
}

struct ToastItem: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var icon: String? = "checkmark.circle"
    var swatch: Color? = nil
    /// Optional single action, for example "Show in Finder".
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    static func == (a: ToastItem, b: ToastItem) -> Bool { a.id == b.id }
}

struct ToastView: View {
    let item: ToastItem
    var body: some View {
        HStack(spacing: 12) {
            if let swatch = item.swatch { FolderSwatch(color: swatch) }
            else if let icon = item.icon { GIcon(icon, size: 16, weight: .semibold).foregroundStyle(G.success) }
            Text(item.text).font(GFont.ui(14, .medium)).foregroundStyle(G.text)
            if let title = item.actionTitle, let action = item.action {
                Button(title, action: action)
                    .buttonStyle(.plain)
                    .font(GFont.ui(14, .semibold)).foregroundStyle(G.accentText)
                    .padding(.horizontal, 6).frame(height: 28)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(G.surface2))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(G.borderStrong, lineWidth: 1))
        .shadow(color: G.shadow, radius: 14, y: 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Formatting helpers

/// 00:00:00 for the big timer.
func clockString(_ t: Double) -> String {
    let s = Int(max(0, t).rounded(.down))
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

/// "1 h 51 min", "12 min", "45 s".
func humanDuration(_ t: Double) -> String {
    let s = Int(max(0, t).rounded())
    let h = s / 3600, m = (s % 3600) / 60
    if h > 0 { return "\(h) h \(m) min" }
    if m > 0 { return "\(m) min" }
    return "\(s) s"
}

func shortDate(_ d: Date) -> String {
    d.formatted(.dateTime.day().month(.abbreviated).year())
}
