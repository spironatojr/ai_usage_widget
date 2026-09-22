import SwiftUI
import AppKit

// MARK: - Modern macOS Design System Tokens

enum MacTheme {
    // Graphite Frost surfaces. These intentionally stay opaque so content behind
    // the menu-bar window never changes the contrast of the interface.
    static let canvasBackground = Color(red: 0.086, green: 0.094, blue: 0.114)
    static let navigationBackground = Color(red: 0.125, green: 0.137, blue: 0.165)
    static let cardBackground = Color(red: 0.141, green: 0.157, blue: 0.188)
    static let raisedCardBackground = Color(red: 0.161, green: 0.180, blue: 0.220)
    static let controlBackground = Color(red: 0.196, green: 0.216, blue: 0.255)
    static let border = Color(red: 0.227, green: 0.251, blue: 0.298)
    static let separator = Color(red: 0.204, green: 0.227, blue: 0.271)
    static let progressTrack = Color(red: 0.224, green: 0.247, blue: 0.286)

    // High-contrast typography used throughout the fixed dark presentation.
    static let textPrimary = Color(red: 0.957, green: 0.965, blue: 0.973)
    static let textSecondary = Color(red: 0.702, green: 0.729, blue: 0.776)
    static let textTertiary = Color(red: 0.522, green: 0.553, blue: 0.608)

    // Brand Gradients & Colors
    static let claudePrimary = Color(red: 0.95, green: 0.48, blue: 0.22)
    static let claudeSecondary = Color(red: 0.88, green: 0.32, blue: 0.18)
    static let claudeGradient = LinearGradient(
        colors: [claudePrimary, claudeSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let codexPrimary = Color(red: 0.12, green: 0.78, blue: 0.54)
    static let codexSecondary = Color(red: 0.05, green: 0.60, blue: 0.55)
    static let codexGradient = LinearGradient(
        colors: [codexPrimary, codexSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let antigravityPrimary = Color(red: 0.36, green: 0.48, blue: 0.98)
    static let antigravitySecondary = Color(red: 0.67, green: 0.34, blue: 0.95)
    static let antigravityGradient = LinearGradient(
        colors: [antigravityPrimary, antigravitySecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    static let accentBlue = Color(red: 0.22, green: 0.52, blue: 0.95)
    static let accentPurple = Color(red: 0.58, green: 0.36, blue: 0.94)
    
    // Status Colors
    static let success = Color(red: 0.259, green: 0.827, blue: 0.573)
    static let warning = Color(red: 0.961, green: 0.725, blue: 0.259)
    static let danger = Color(red: 1.000, green: 0.420, blue: 0.420)
}

// MARK: - Graphite Card Container

struct GlassCard<Content: View>: View {
    let cornerRadius: CGFloat
    let padding: CGFloat
    let content: Content
    
    init(cornerRadius: CGFloat = 12, padding: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(MacTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(MacTheme.border, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.22), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Branded Graphite Card

struct BrandedGraphiteCard<Content: View>: View {
    let brandGradient: LinearGradient
    let cornerRadius: CGFloat
    let content: Content
    
    init(brandGradient: LinearGradient, cornerRadius: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.brandGradient = brandGradient
        self.cornerRadius = cornerRadius
        self.content = content()
    }
    
    var body: some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(MacTheme.raisedCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(MacTheme.border, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(brandGradient)
                    .frame(width: 3)
                    .padding(.vertical, 13)
                    .padding(.leading, 6)
            }
            .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 5)
    }
}

// MARK: - Pulsing Live Indicator

struct PulsingLiveBadge: View {
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(MacTheme.success)
                .frame(width: 6, height: 6)
            
            Text("LIVE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(MacTheme.success)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(MacTheme.success.opacity(0.12))
        )
        .overlay(
            Capsule()
                .strokeBorder(MacTheme.success.opacity(0.3), lineWidth: 0.75)
        )
    }
}

// MARK: - Modern Animated Progress Bar

struct ModernProgressBar: View {
    let valuePct: Double
    let accentGradient: LinearGradient
    let height: CGFloat
    
    init(valuePct: Double, accentGradient: LinearGradient, height: CGFloat = 6) {
        self.valuePct = valuePct
        self.accentGradient = accentGradient
        self.height = height
    }
    
    var clampedPct: Double {
        max(0, min(100, valuePct))
    }
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(MacTheme.progressTrack)
                
                if clampedPct > 0 {
                    Capsule()
                        .fill(accentGradient)
                        .frame(width: geo.size.width * CGFloat(clampedPct / 100.0))
                        .shadow(color: Color.black.opacity(0.18), radius: 2, x: 0, y: 1)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Glass Segmented Control Button

private final class GlassSegmentButtonState: ObservableObject {
    @Published var isHovered = false
}

struct GlassSegmentButton: View {
    let title: String
    let icon: String
    var brandImage: NSImage? = nil
    let isSelected: Bool
    let action: () -> Void
    
    @StateObject private var buttonState = GlassSegmentButtonState()
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3.5) {
                if let brandImg = brandImage {
                    Image(nsImage: brandImg)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 11, height: 11)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                }
                
                Text(title)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4.5)
            .frame(maxWidth: .infinity)
            .foregroundColor(isSelected ? MacTheme.textPrimary : MacTheme.textSecondary)
            .background(
                ZStack {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(MacTheme.controlBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(MacTheme.accentBlue.opacity(0.75), lineWidth: 1)
                            )
                            .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 2)
                    } else if buttonState.isHovered {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(MacTheme.controlBackground.opacity(0.75))
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                buttonState.isHovered = hovering
            }
        }
    }
}

// MARK: - High-contrast Divider

struct GraphiteDivider: View {
    var body: some View {
        Rectangle()
            .fill(MacTheme.separator)
            .frame(height: 1)
    }
}
