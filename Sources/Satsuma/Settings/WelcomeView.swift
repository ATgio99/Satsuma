import ServiceManagement
import SwiftUI

/// Onboarding (`WelcomeView`): a capsule window drawn on an 875×565 canvas scaled 0.8 to 700×452.
/// The first page is orange (#FF6A00) with a yellow glow. The others are white (dark in Dark Mode), with an
/// illustration on the left, Back / title / steps / Continue on the right, and page dots at the bottom.
/// Positions are in canvas points, measured from the original app's windows.
struct OnboardingView: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject private var folders = FolderAccessStore.shared
    @Environment(\.colorScheme) private var systemScheme
    @State private var page: Page
    @State private var direction: CGFloat = 1
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status
    /// True once access is granted on this page, so the checkmark draws itself instead of appearing static.
    @State private var accessJustGranted = false
    @State private var grantedFolder: URL?
    let onDismiss: () -> Void
    let onMinimize: () -> Void
    /// Called after each page change (used by `--test-welcome`).
    var onPageChange: (Page) -> Void = { _ in }

    enum Page: Int, CaseIterable { case welcome, converter, tools, actions, folders, setup }

    static let canvas = CGSize(width: 875, height: 565)
    static let scale: CGFloat = 0.8
    static let buttonOrange = Color(red: 1, green: 0.47451, blue: 0.0039)
    private static let middle = canvas.height / 2

    init(settings: SettingsModel, page: Page = .welcome, onMinimize: @escaping () -> Void = {}, onDismiss: @escaping () -> Void) {
        self.settings = settings
        _page = State(initialValue: page)
        self.onMinimize = onMinimize
        self.onDismiss = onDismiss
    }

    var body: some View {
        ZStack {
            if page == .welcome {
                WelcomeBackground().transition(.opacity)
            } else {
                Color(nsColor: .textBackgroundColor).transition(.opacity)
            }
            content
                .id(page)
                .transition(.asymmetric(insertion: .offset(x: 12 * direction).combined(with: .opacity),
                                        removal: .offset(x: -10 * direction).combined(with: .opacity)))
            if page != .welcome {
                PageDots(count: Page.allCases.count, current: page.rawValue)
                    .position(x: Self.canvas.width / 2, y: 527)
            }
            WelcomeWindowControls(onClose: onDismiss, onMinimize: onMinimize)
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .environment(\.colorScheme, page == .welcome ? .dark : systemScheme)
        .clipShape(Capsule(style: .circular))
        .scaleEffect(Self.scale)
        .frame(width: Self.canvas.width * Self.scale, height: Self.canvas.height * Self.scale)
        .tint(.satsumaAccent)
    }

    // MARK: Pages

    @ViewBuilder private var content: some View {
        switch page {
        case .welcome:
            welcomePage
        case .converter:
            wheelPage(title: "File Converter", mask: settings.conversionMask,
                      actions: [.png, .webp, .heic, .tiff, .avif, .bmp, .pdf].map { .convert($0) })
        case .tools:
            wheelPage(title: "File Tools", mask: settings.toolsMask,
                      actions: [.compress, .removeMetadata, .editImage, .annotateImage, .frameImage, .cropImage, .redactImage].map { .fileTool($0) })
        case .actions:
            wheelPage(title: "File Actions", mask: settings.actionsMask, actions: ConversionFanAction.fileActions)
        case .folders:
            foldersPage
        case .setup:
            setupPage
        }
    }

    private var welcomePage: some View {
        ZStack {
            VStack(spacing: -19) {
                Text("Welcome to")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.49))
                Text("Satsuma")
                    .font(.system(size: 96, weight: .medium))
                    .tracking(-1.5)
                    .foregroundStyle(LinearGradient(stops: [.init(color: .white.opacity(0.8), location: 0),
                                                            .init(color: .white.opacity(0.8), location: 0.1236),
                                                            .init(color: .white.opacity(0.33), location: 1)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            .position(x: Self.canvas.width / 2, y: 261)
            primaryButton("Continue", fill: .white, text: .black) { go(1) }
                .position(x: Self.canvas.width / 2, y: 408)
        }
    }

    private func wheelPage(title: String, mask: Int, actions: [ConversionFanAction]) -> some View {
        ZStack {
            WelcomeWheelPreview(actions: actions, center: "2.4 MB", diameter: 356)
                .position(x: 281, y: 280)
            column(title: title, leading: 525) {
                VStack(alignment: .leading, spacing: 14.5) {
                    Text("1. Drag files")
                    HStack(spacing: 10) {
                        Text("2. Tap")
                        WelcomeKeys(keys: DragModifierCombination(mask: mask).keys)
                    }
                }
                .font(.system(size: 21.5, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.top, 28)
            } button: {
                primaryButton("Continue") { go(1) }.padding(.top, 31)
            }
        }
    }

    private var foldersPage: some View {
        ZStack {
            VStack(spacing: 0) {
                FolderIllustration().frame(width: 182, height: 141)
                Group {
                    if folders.homeFolderAllowed || grantedFolder != nil {
                        HStack(spacing: 10) {
                            GrantedCheckmark(animated: accessJustGranted).frame(width: 30, height: 30)
                            Text(grantedLabel)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                        .frame(height: 42)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    } else {
                        Button(action: allowHomeFolder) {
                            HStack(spacing: 8) {
                                Image(systemName: "lock.open.fill").font(.system(size: 14, weight: .semibold))
                                Text("Allow Access to Home Folder").font(.system(size: 15, weight: .semibold))
                            }
                            .padding(.horizontal, 22).frame(height: 42)
                        }
                        .buttonStyle(WelcomeCapsuleButtonStyle(fill: Self.buttonOrange, text: .white))
                        .shadow(color: Self.buttonOrange.opacity(0.35), radius: 8, y: 3)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .padding(.top, 26)
                Text(folders.homeFolderAllowed || grantedFolder != nil ? "Manage access in Settings → Folders."
                                               : "In the next window, just click Allow Access.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 260)
                    .padding(.top, 12)
            }
            .position(x: 288, y: 293)
            column(title: "Folder access", leading: 500) {
                bodyText("Results are saved next to the originals. Allow your home folder once so macOS doesn’t ask again.")
            } button: {
                primaryButton("Continue") { go(1) }.padding(.top, 28)
            }
        }
    }

    private var grantedLabel: String {
        if folders.homeFolderAllowed { return "Home folder access enabled" }
        return "Access enabled for “\(grantedFolder?.lastPathComponent ?? "folder")”"
    }

    private func allowHomeFolder() {
        guard let url = folders.requestHomeFolderAccess() else { return }
        // The panel was modal: animate the swap once the welcome window is back in front.
        DispatchQueue.main.async {
            accessJustGranted = true
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { grantedFolder = url }
            NSSound(named: "Glass")?.play()
        }
    }

    private var setupPage: some View {
        ZStack {
            VStack(spacing: 0) {
                MenuBarIllustration()
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.satsumaAccent)
                    .frame(width: 20, height: 16)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 78)
                LaunchAtLoginCard(isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if loginStatus == .requiresApproval {
                    HStack(spacing: 6) {
                        Text("One more step: allow Satsuma in Login Items.").foregroundStyle(.secondary)
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.link)
                    }
                    .font(.system(size: 11))
                    .padding(.top, 10)
                }
            }
            .frame(width: 359)
            .position(x: 288, y: Self.middle)
            column(title: "Finish setup", leading: 500) {
                bodyText("Choose whether Satsuma launches at login. You can change these options and your shortcuts in Settings.")
            } button: {
                primaryButton("Done", action: onDismiss).padding(.top, 26)
            }
        }
    }

    // MARK: Building blocks

    /// Right column: Back, title, page body and the main button, centered vertically.
    private func column(title: String, leading: CGFloat, @ViewBuilder body: () -> some View,
                        @ViewBuilder button: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { go(-1) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left").font(.system(size: 12, weight: .regular))
                    Text("Back").font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(title)
                .font(.system(size: 27.5, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(.primary)
                .padding(.top, 23)
            body()
            button()
        }
        .frame(width: 300, alignment: .leading)
        .position(x: leading + 150, y: Self.middle)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16))
            .lineSpacing(4.5)
            .foregroundStyle(.secondary)
            .frame(width: 270, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 21)
    }

    private func primaryButton(_ title: String, fill: Color = buttonOrange, text: Color = .white,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 169, height: 66)
        }
        .buttonStyle(WelcomeCapsuleButtonStyle(fill: fill, text: text))
        .keyboardShortcut(.defaultAction)
    }

    private func go(_ step: Int) {
        guard let next = Page(rawValue: page.rawValue + step) else { return }
        direction = CGFloat(step)
        withAnimation(.easeOut(duration: 0.22)) { page = next }
        onPageChange(next)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
        loginStatus = SMAppService.mainApp.status
    }
}

/// Orange field with the yellow glow at the bottom center (#FFD900, 638 pt, blur 184).
/// The blurred circle is drawn as an equivalent radial falloff so it looks the same in offscreen snapshots.
private struct WelcomeBackground: View {
    private static let yellow = Color(red: 1, green: 0.85098, blue: 0)

    var body: some View {
        ZStack {
            Color(red: 1, green: 0.41569, blue: 0)
            RadialGradient(stops: [.init(color: Self.yellow, location: 0),
                                   .init(color: Self.yellow.opacity(0.92), location: 0.3),
                                   .init(color: Self.yellow.opacity(0.55), location: 0.58),
                                   .init(color: Self.yellow.opacity(0.18), location: 0.8),
                                   .init(color: Self.yellow.opacity(0), location: 1)],
                           center: UnitPoint(x: 437.5 / OnboardingView.canvas.width, y: 548 / OnboardingView.canvas.height),
                           startRadius: 0, endRadius: 319 + 184)
        }
    }
}

/// Six dots under the content pages; the current one is orange.
private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == current ? Color.satsumaAccent : Color.primary.opacity(0.13))
                    .frame(width: 5, height: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}

/// Close, minimize and a disabled zoom light placed on the capsule's top-left curve at (k·8 − 120)°.
private struct WelcomeWindowControls: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    @State private var hovering = false
    private static let red = Color(red: 0.96, green: 0.03, blue: 0.03)
    private static let yellow = Color(red: 0.97, green: 0.77, blue: 0)

    var body: some View {
        let radius = OnboardingView.canvas.height / 2
        ZStack {
            light(Self.red, symbol: "xmark", label: "Close", action: onClose).position(point(0, radius: radius))
            light(Self.yellow, symbol: "minus", label: "Minimize", action: onMinimize).position(point(1, radius: radius))
            Circle()
                .fill(Color.primary.opacity(0.06))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.6))
                .frame(width: 22, height: 22)
                .position(point(2, radius: radius))
                .allowsHitTesting(false)
        }
    }

    private func point(_ k: Int, radius: CGFloat) -> CGPoint {
        let angle = Double(k * 8 - 120) * .pi / 180
        let distance = radius - 40
        return CGPoint(x: radius + distance * cos(angle), y: radius + distance * sin(angle))
    }

    private func light(_ color: Color, symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle().fill(color)
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black.opacity(0.5))
                    .opacity(hovering ? 1 : 0)
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // Hover is tracked on the lights only: on a full-canvas ZStack it swallowed clicks on the pages.
        .onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

struct WelcomeCapsuleButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(text)
            .background(Capsule(style: .circular).fill(fill))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Green disc whose checkmark draws itself (`animated`) after access is granted.
struct GrantedCheckmark: View {
    let animated: Bool
    @State private var disc: CGFloat = 0
    @State private var stroke: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().fill(Color(nsColor: .systemGreen)).scaleEffect(disc)
                CheckmarkShape()
                    .trim(from: 0, to: stroke)
                    .stroke(.white, style: StrokeStyle(lineWidth: side * 0.11, lineCap: .round, lineJoin: .round))
                    .padding(side * 0.27)
            }
            .frame(width: side, height: side)
        }
        .onAppear {
            guard animated else { disc = 1; stroke = 1; return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) { disc = 1 }
            withAnimation(.easeOut(duration: 0.32).delay(0.18)) { stroke = 1 }
        }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.04))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.36, y: rect.maxY - rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.12))
        return path
    }
}

/// Dark modifier keys that press in turn, like tapping the shortcut while dragging.
private struct WelcomeKeys: View {
    let keys: [(symbol: String, name: String)]
    @State private var pressed = false

    var body: some View {
        HStack(spacing: 10) {
            ForEach(keys, id: \.symbol) { key in
                KeyCap(symbol: key.symbol, name: key.name, pressed: pressed)
            }
        }
        .onAppear { pulse() }
    }

    private func pulse() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.12)) { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeOut(duration: 0.18)) { pressed = false }
                pulse()
            }
        }
    }
}

/// Keyboard key (`WelcomeKeyboardKey`): 56 pt high, 56 wide (70 for command, 108 for shift), dark gradient,
/// symbol top right and name bottom left. Shift shows only its name, as on the original.
struct KeyCap: View {
    let symbol: String
    let name: String
    var pressed = false

    private var width: CGFloat {
        switch name {
        case "shift": return 108
        case "command": return 70
        default: return 56
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.09)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(pressed ? 0.22 : 0.1), lineWidth: 0.7)
            if name != "shift" {
                Text(symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 7).padding(.top, 5)
            }
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.95))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.leading, 7).padding(.bottom, 6)
        }
        .frame(width: width, height: 56)
        .shadow(color: .black.opacity(pressed ? 0.1 : 0.22), radius: 1.5, y: pressed ? 0.5 : 2)
        .offset(y: pressed ? 1.5 : 0)
        .environment(\.colorScheme, .dark)
    }
}

extension DragModifierCombination {
    var keys: [(symbol: String, name: String)] {
        var keys: [(String, String)] = []
        if mask & Self.control != 0 { keys.append(("⌃", "control")) }
        if mask & Self.option != 0 { keys.append(("⌥", "option")) }
        if mask & Self.shift != 0 { keys.append(("⇧", "shift")) }
        if mask & Self.command != 0 { keys.append(("⌘", "command")) }
        return keys
    }
}

/// Static wheel preview (`WelcomeWheelPreview`) showing the petals around a "2.4 MB" center.
struct WelcomeWheelPreview: View {
    let actions: [ConversionFanAction]
    var center = ""
    /// Outer diameter of the ring, in the caller's points.
    var diameter: CGFloat = PetalGeometry.backdropRadius * 2
    var allowsLiquidGlass = !DebugRender.active
    @StateObject private var model = NativeGlassFanModel()

    var body: some View {
        let scale = diameter / (PetalGeometry.backdropRadius * 2)
        NativeGlassFanView(model: model)
            .scaleEffect(scale)
            .frame(width: NativeGlassFanView.size * scale, height: NativeGlassFanView.size * scale)
            .allowsHitTesting(false)
            .onAppear {
                model.allowsLiquidGlass = allowsLiquidGlass
                model.actions = actions
                model.centerLabelText = center
                model.introRequest += 1
            }
    }
}

/// Satsuma's own orange folder drawing with a house, for the folder-access page.
private struct FolderIllustration: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            ZStack(alignment: .topLeading) {
                FolderBackShape()
                    .fill(Color(red: 1, green: 0.70, blue: 0.33))
                RoundedRectangle(cornerRadius: w * 0.085, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 1, green: 0.72, blue: 0.33), Color(red: 1, green: 0.36, blue: 0.08)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: w, height: h * 0.9)
                    .offset(y: h * 0.1)
                Image(systemName: "house.fill")
                    .font(.system(size: w * 0.24))
                    .foregroundStyle(Color(red: 0.86, green: 0.38, blue: 0.1).opacity(0.85))
                    .frame(width: w, height: h * 0.9)
                    .offset(y: h * 0.13)
            }
            .shadow(color: .black.opacity(0.14), radius: 14, y: 8)
        }
        .accessibilityHidden(true)
    }
}

private struct FolderBackShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.width * 0.06
        let tabWidth = rect.width * 0.3, tabHeight = rect.height * 0.12
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: tabWidth, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: tabWidth + r * 1.4, y: rect.minY + tabHeight), control: CGPoint(x: tabWidth + r * 0.6, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY + tabHeight))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tabHeight + r), control: CGPoint(x: rect.maxX, y: rect.minY + tabHeight))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY * 0.5))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY * 0.5))
        path.closeSubpath()
        return path
    }
}

/// A miniature menu bar with Satsuma's icon highlighted between Wi-Fi and the clock.
private struct MenuBarIllustration: View {
    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            Image(systemName: "wifi")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 30)
            Image(nsImage: MenuBarIcon.image())
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .frame(width: 35, height: 35)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.satsumaAccent.opacity(0.14)))
                .padding(.leading, 15)
            Text("9:41")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .padding(.leading, 17)
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.trailing, 20)
        .frame(height: 59)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Find the Satsuma icon near the clock in your menu bar")
    }
}

/// "Launch at login" row with its orange switch.
private struct LaunchAtLoginCard: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Launch at login").font(.system(size: 14, weight: .medium)).foregroundStyle(.primary)
                Text("Ready whenever you turn on your Mac.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Launch at login", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.large)
        }
        .padding(.horizontal, 16)
        .frame(height: 65)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
    }
}

/// Satsuma's mark: the app icon, or a segmented wheel when running outside the bundle.
struct SatsumaMark: View {
    var body: some View {
        if Bundle.main.path(forResource: "AppIcon", ofType: "icns") != nil, let icon = NSApp?.applicationIconImage {
            Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit).scaleEffect(1.3)
        } else {
            fallback
        }
    }

    private var fallback: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            ZStack {
                Circle().fill(Color.satsumaAccent)
                ZStack {
                    ForEach(0..<7, id: \.self) { slot in
                        PetalShape(slot: slot, count: 7, outer: PetalGeometry.outerRadius).fill(Color.white.opacity(0.9))
                    }
                }
                .scaleEffect(0.78)
            }
            .frame(width: 256, height: 256)
            .scaleEffect(side / 256)
            .frame(width: side, height: side)
        }
    }
}

/// Borderless capsule window (`styleMask` closable | miniaturizable, clear, shadowed, corner radius 226).
final class WelcomeWindow: NSWindow {
    init(rootView: some View) {
        let size = NSSize(width: OnboardingView.canvas.width * OnboardingView.scale, height: OnboardingView.canvas.height * OnboardingView.scale)
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .closable, .miniaturizable], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        animationBehavior = .documentWindow
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        title = "Getting Started"
        contentMinSize = size
        contentMaxSize = size
        let host = NSHostingView(rootView: rootView)
        host.wantsLayer = true
        host.layer?.cornerRadius = size.height / 2
        host.layer?.masksToBounds = true
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
