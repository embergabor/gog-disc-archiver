import AppKit
import SwiftUI

/// Visual tokens from the design canvas: Film Companion's warm neutrals with a lavender accent.
/// Text on the accent is always dark.
enum Theme {
    static let accent = Color(hex: 0xC3B4E6)
    static let onAccent = Color(hex: 0x1D1C1A)
    static let ink = Color.dynamic(light: 0x5A3E9A, dark: 0xC9B8F0)
    static let tint = Color.dynamic(light: 0xEEE9F8, dark: 0x3A3150)

    static let window = Color.dynamic(light: 0xF6F5F2, dark: 0x1F1E1C)
    static let list = Color.dynamic(light: 0xFBFAF8, dark: 0x23221F)
    static let card = Color.dynamic(light: 0xFFFFFF, dark: 0x2C2B28)
    static let cardBorder = Color.dynamic(light: 0xE2DFD9, dark: 0x3D3B37)
    static let divider = Color.dynamic(light: 0xDEDBD4, dark: 0x3A3834)
    static let rowDivider = Color.dynamic(light: 0xEEEBE6, dark: 0x302F2C)
    static let controlBorder = Color.dynamic(light: 0xD6D3CC, dark: 0x4A4843)
    static let track = Color.dynamic(light: 0xECEAE6, dark: 0x3A3834)
    static let segment = Color.dynamic(light: 0xE2DFD9, dark: 0x3A3834)

    static let text = Color.dynamic(light: 0x1D1C1A, dark: 0xECEAE6)
    static let secondary = Color.dynamic(light: 0x5F5B54, dark: 0xA9A49B)
    static let muted = Color.dynamic(light: 0x4A463F, dark: 0xCFCBC4)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Foreground/background pairs for status pills.
enum Tone {
    case ok, warn, bad, neutral

    var foreground: Color {
        switch self {
        case .ok: .dynamic(light: 0x2F6B3A, dark: 0x8FCB98)
        case .warn: .dynamic(light: 0x7A5208, dark: 0xE8C06A)
        case .bad: .dynamic(light: 0xB42318, dark: 0xF2867C)
        case .neutral: .dynamic(light: 0x4A463F, dark: 0xCFCBC4)
        }
    }

    var background: Color {
        switch self {
        case .ok: .dynamic(light: 0xE8F3EA, dark: 0x1F3A24)
        case .warn: .dynamic(light: 0xFBF0D9, dark: 0x3F3216)
        case .bad: .dynamic(light: 0xFDECEA, dark: 0x4A1E1A)
        case .neutral: .dynamic(light: 0xECEAE6, dark: 0x3A3834)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Shared pieces

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.cardBorder))
    }
}

/// Pill buttons: the accent one for the main action, outlined for the rest.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: prominent ? .semibold : .regular))
            .foregroundStyle(foreground)
            .padding(.horizontal, prominent ? 18 : 16)
            .frame(minHeight: 32)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.controlBorder))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        if !isEnabled { return Theme.secondary }
        if destructive { return Tone.bad.foreground }
        return prominent ? Theme.onAccent : Theme.text
    }

    private var background: Color {
        if prominent { return isEnabled ? Theme.accent : Theme.segment }
        return Theme.card
    }
}

/// The rounded segmented control from the design.
struct PillPicker<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { option in
                let on = option.0 == selection
                Button { selection = option.0 } label: {
                    Text(option.1)
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 28)
                        .background(on ? Theme.card : Color.clear, in: Capsule())
                        .shadow(color: on ? .black.opacity(0.14) : .clear, radius: 1, y: 1)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Theme.segment, in: Capsule())
    }
}

struct StatusPill: View {
    var text: String
    var tone: Tone

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(tone.background, in: Capsule())
    }
}

extension DiscRecord.Health {
    var label: String {
        switch self {
        case .ok: "OK"
        case .due: "Due"
        case .damaged: "Damaged"
        case .neverChecked: "Not checked"
        }
    }

    var tone: Tone {
        switch self {
        case .ok: .ok
        case .due: .warn
        case .damaged: .bad
        case .neverChecked: .neutral
        }
    }
}
