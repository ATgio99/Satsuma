import SwiftUI

/// Accent (`AccentColor` in the original app's asset catalog: sRGB 1, 0.322, 0).
enum SatsumaColor {
    static let accent = NSColor(srgbRed: 1.0, green: 0.3216, blue: 0.0, alpha: 1)
    static let accentSoft = NSColor(srgbRed: 1.0, green: 0.42, blue: 0.29, alpha: 1)
}

extension Color {
    static let satsumaAccent = Color(nsColor: SatsumaColor.accent)
    static let satsumaAccentSoft = Color(nsColor: SatsumaColor.accentSoft)
}

/// State behind the wheel (`NativeGlassFanModel`).
final class NativeGlassFanModel: ObservableObject {
    @Published var actions: [ConversionFanAction] = []
    @Published var highlightedSlot: Int?
    @Published var centerLabelText = ""
    @Published var centerLabelUsesCompactStyle = false
    @Published var isCenterLabelVisible = true
    @Published var introRequest = 0
    @Published var closeRequest = 0
    /// Petal that received the drop: it stays lit and swells out while the others fold away.
    @Published var chosenSlot: Int?
    @Published var visualTheme: ConversionFanTheme = SettingsModel.shared.conversionFanTheme
    /// Off only for offscreen rendering, where Liquid Glass cannot draw.
    var allowsLiquidGlass = true
}

/// The conversion wheel (`NativeGlassFanView`): glass petals on a glass ring, with a center capsule.
struct NativeGlassFanView: View {
    @ObservedObject var model: NativeGlassFanModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var bubbleScaleX: CGFloat = 1
    @State private var bubbleScaleY: CGFloat = 1
    @State private var bubbleOpacity: Double = 1
    @Namespace private var glassNamespace

    static let size: CGFloat = PetalGeometry.backdropRadius * 2 + 20

    var body: some View {
        ZStack {
            // The window server lets drags fall through fully transparent pixels, and Liquid Glass leaves the
            // window's own pixels empty: this 1/255 disc makes the whole wheel (not just the labels) a drop target.
            Circle().fill(Color.black.opacity(1.0 / 255)).frame(width: PetalGeometry.backdropRadius * 2, height: PetalGeometry.backdropRadius * 2)
            // Same layer order as the original app's wheel: ring, petal glass in its own
            // container, labels on top (outside the container, so the glass never covers them), center capsule.
            backdrop
            if usesLiquidGlass, #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: Self.glassSpacing) { ZStack { petalFills } }
            } else {
                petalFills
            }
            petalLabels
            centerLabel
        }
        .frame(width: Self.size, height: Self.size)
        .scaleEffect(x: bubbleScaleX, y: bubbleScaleY)
        .opacity(bubbleOpacity)
        .onAppear { open() }
        .onChange(of: model.introRequest) { _, _ in open() }
        .onChange(of: model.closeRequest) { _, _ in close() }
        .animation(.easeOut(duration: 0.13), value: model.highlightedSlot)
    }

    // MARK: Open / close animation

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// How long the close animation runs, so the panel is ordered out only once it has finished.
    static func outroDuration(count: Int) -> TimeInterval { reduceMotion ? 0.14 : 0.25 }

    /// Room the overlay panel leaves around the wheel for the open overshoot (about 20 %).
    static let bubbleMargin: CGFloat = 32

    /// Bubble pop: the whole wheel grows out of the pointer, overshoots and wobbles back. Width and height
    /// use slightly different springs, so it squashes a little on the way in like a soap bubble.
    private func open() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            bubbleScaleX = Self.reduceMotion ? 1 : 0.12
            bubbleScaleY = Self.reduceMotion ? 1 : 0.12
            bubbleOpacity = 0
        }
        DispatchQueue.main.async {
            if Self.reduceMotion {
                withAnimation(.easeOut(duration: 0.14)) { bubbleOpacity = 1 }
                return
            }
            withAnimation(.easeOut(duration: 0.07)) { bubbleOpacity = 1 }
            withAnimation(.spring(response: 0.27, dampingFraction: 0.42)) { bubbleScaleX = 1 }
            withAnimation(.spring(response: 0.32, dampingFraction: 0.4)) { bubbleScaleY = 1 }
        }
    }

    /// The bubble swells for a moment, then shrinks back into the pointer and fades.
    private func close() {
        if Self.reduceMotion {
            withAnimation(.easeIn(duration: 0.14)) { bubbleOpacity = 0 }
            return
        }
        let intro = model.introRequest
        withAnimation(.easeOut(duration: 0.07)) { bubbleScaleX = 1.06; bubbleScaleY = 1.06 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
            // Reopened in the meantime: leave the new bubble alone.
            guard model.introRequest == intro else { return }
            withAnimation(.easeIn(duration: 0.17)) {
                bubbleScaleX = 0.12
                bubbleScaleY = 0.12
                bubbleOpacity = 0
            }
        }
    }

    private var usesLiquidGlass: Bool { model.visualTheme == .glass && model.allowsLiquidGlass }

    /// `GlassEffectContainer(spacing: 0)`.
    static let glassSpacing: CGFloat = 0

    private var petalFills: some View {
        ForEach(Array(model.actions.enumerated()), id: \.offset) { slot, action in
            petalFill(slot: slot, shape: PetalShape(slot: slot, count: model.actions.count),
                      highlighted: model.highlightedSlot == slot)
                .frame(width: Self.size, height: Self.size)
        }
    }

    private var petalLabels: some View {
        ForEach(Array(model.actions.enumerated()), id: \.offset) { slot, action in
            petal(slot: slot, action: action)
        }
    }

    // MARK: Backdrop ring

    @ViewBuilder private var backdrop: some View {
        let ring = RingShape(inner: PetalGeometry.backdropHoleRadius, outer: PetalGeometry.backdropRadius)
        if usesLiquidGlass, #available(macOS 26.0, *) {
            // Clear glass tinted with 50 % grey (black in dark mode), so the desktop shows through.
            let tint = Color(nsColor: colorScheme == .dark ? .black : .gray).opacity(0.5)
            Color.clear.frame(width: Self.size, height: Self.size)
                .glassEffect(.clear.tint(tint), in: ring)
                .opacity(model.actions.isEmpty ? 0 : 1)
        } else if model.visualTheme == .metallic {
            ring.fill(LinearGradient(colors: [Color(white: 0.86), Color(white: 0.62)], startPoint: .top, endPoint: .bottom))
                .overlay(ring.stroke(Color.white.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
        } else {
            ring.fill(Color(red: 192 / 255, green: 201 / 255, blue: 205 / 255).opacity(0.25))
                .background(VisualEffectBackground(material: .hudWindow).clipShape(ring))
                .overlay(ring.stroke(Color.white.opacity(0.33), lineWidth: 1))
        }
    }

    // MARK: Petals

    @ViewBuilder private func petal(slot: Int, action: ConversionFanAction) -> some View {
        let count = model.actions.count
        let shape = PetalShape(slot: slot, count: count)
        let highlighted = model.highlightedSlot == slot
        let angle = PetalGeometry.centerAngle(slot: slot, count: count)
        let center = CGPoint(x: Self.size / 2, y: Self.size / 2)
        let labelPoint = PetalGeometry.labelCenter(center: center, angle: angle)

        ZStack {
            shape.fill(Color.clear)
            PetalLabel(action: action, highlighted: highlighted, theme: model.visualTheme, colorScheme: colorScheme)
                .position(labelPoint)
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityElement()
        .accessibilityLabel(action.accessibilityDescription)
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private func petalFill(slot: Int, shape: PetalShape, highlighted: Bool) -> some View {
        switch model.visualTheme {
        case .glass:
            if model.allowsLiquidGlass, #available(macOS 26.0, *) {
                // Regular interactive glass with a per-petal `glassEffectID`.
                Color.clear
                    .glassEffect(highlighted ? .regular.tint(.satsumaAccent).interactive() : .regular.interactive(), in: shape)
                    .glassEffectID(slot, in: glassNamespace)
            } else {
                shape.fill(highlighted ? AnyShapeStyle(Color.satsumaAccent) : AnyShapeStyle(Self.webGlassFill))
                    .overlay(shape.stroke(highlighted ? Color(red: 194 / 255, green: 101 / 255, blue: 52 / 255).opacity(0.44)
                                                      : Color(red: 93 / 255, green: 102 / 255, blue: 102 / 255).opacity(0.22),
                                          lineWidth: 0.75))
            }
        case .metallic:
            shape.fill(highlighted
                       ? AnyShapeStyle(Color.satsumaAccent)
                       : AnyShapeStyle(LinearGradient(stops: [.init(color: Color(white: 0.878), location: 0),
                                                              .init(color: Color(white: 0.96), location: 0.485577),
                                                              .init(color: Color(white: 0.588), location: 1)],
                                                      startPoint: .top, endPoint: .bottom)))
                .overlay(shape.stroke(Color.white.opacity(highlighted ? 0.9 : 0.75), lineWidth: highlighted ? 1.5 : 1))
        }
    }

    /// Radial glass fill used where Liquid Glass is unavailable (same stops as the original app's own demo).
    static let webGlassFill = RadialGradient(stops: [.init(color: .white.opacity(0.8), location: 0),
                                                     .init(color: Color(red: 0.953, green: 0.965, blue: 0.969).opacity(0.58), location: 0.68),
                                                     .init(color: Color(red: 0.957, green: 0.965, blue: 0.965).opacity(0.75), location: 1)],
                                             center: .center, startRadius: 0, endRadius: PetalGeometry.outerRadius)

    // MARK: Center capsule

    @ViewBuilder private var centerLabel: some View {
        if model.isCenterLabelVisible && !model.centerLabelText.isEmpty {
            let text = Text(model.centerLabelText)
                .font(.system(size: model.centerLabelUsesCompactStyle ? 8.5 : 12,
                              weight: model.centerLabelUsesCompactStyle ? .semibold : .medium, design: .rounded))
                .tracking(model.centerLabelUsesCompactStyle ? 0.2 : 0.35)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(width: 74)
                .frame(minHeight: model.centerLabelUsesCompactStyle ? 36 : 32)
            if model.visualTheme == .glass, model.allowsLiquidGlass, #available(macOS 26.0, *) {
                text.glassEffect(.regular, in: Capsule())
            } else {
                text.background(Capsule().fill(.white.opacity(0.72)))
                    .background(VisualEffectBackground(material: .popover).clipShape(Capsule()))
                    .overlay(Capsule().stroke(.white.opacity(0.7), lineWidth: 1))
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 2)
            }
        }
    }
}

/// Label (and SF Symbol for tools/actions) inside a petal.
struct PetalLabel: View {
    let action: ConversionFanAction
    let highlighted: Bool
    let theme: ConversionFanTheme
    let colorScheme: ColorScheme

    private var color: Color {
        if highlighted { return .white }
        if theme == .metallic { return Color(white: 0.141) }
        return colorScheme == .dark ? .white : .black
    }

    var body: some View {
        if let symbol = action.symbolName {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: 12.6, weight: .medium))
                Text(action.title)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .tracking(0.2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(color)
            .frame(width: 82, height: 36)
        } else {
            Text(action.title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .tracking(0.35)
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: 82, height: 24)
        }
    }
}

/// NSVisualEffectView wrapper for SwiftUI backgrounds.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
