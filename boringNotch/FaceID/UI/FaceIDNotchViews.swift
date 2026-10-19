//
//  FaceIDNotchViews.swift
//  boringNotch
//
//  The Face ID surfaces inside the notch:
//  • FaceIDActivityOverlay — the closed notch itself grows down while scanning
//    (one shape, no separate box), shows the scan, then the result.
//  • FaceIDPageView — the page opened by the Face ID header button.
//

import SwiftUI

// MARK: - Expanding notch activity

/// Layout of the scan panel. Three candidates are built in so they can be
/// compared on the real notch; `faceIDLayout` in Boring Notch's defaults picks one.
struct FaceIDLayout: Equatable {
    var stacked: Bool          // glyph above text (true) or beside it (false)
    var glyph: CGFloat
    var titleSize: CGFloat
    var subtitleSize: CGFloat
    var spacing: CGFloat
    var gap: CGFloat           // equal gap on all four sides (top from the camera housing)
    var fixedSize: CGSize?     // when set, the panel is this size and content is centred
    var weight: Font.Weight = .semibold
    var titleOpacity: Double = 1
    var label: Bool = false    // small "FACE ID" label above the status
    var labelSize: CGFloat = 13

    static let wide = FaceIDLayout(stacked: false, glyph: 88, titleSize: 28, subtitleSize: 16, spacing: 20, gap: 30, fixedSize: nil)
    static let panel = FaceIDLayout(stacked: false, glyph: 112, titleSize: 96, subtitleSize: 0, spacing: 28, gap: 24, fixedSize: CGSize(width: 640, height: 190))

    // Text treatments for the panel (round 4): the icon stays big, the text calms down.
    static let refined = FaceIDLayout(stacked: false, glyph: 112, titleSize: 34, subtitleSize: 0, spacing: 26, gap: 24, fixedSize: CGSize(width: 640, height: 190), weight: .medium, titleOpacity: 0.92)
    static let light = FaceIDLayout(stacked: false, glyph: 112, titleSize: 44, subtitleSize: 0, spacing: 26, gap: 24, fixedSize: CGSize(width: 640, height: 190), weight: .light, titleOpacity: 0.95)
    static let labelled = FaceIDLayout(stacked: false, glyph: 112, titleSize: 30, subtitleSize: 0, spacing: 26, gap: 24, fixedSize: CGSize(width: 640, height: 190), weight: .medium, titleOpacity: 0.95, label: true, labelSize: 13)
    static let iconLed = FaceIDLayout(stacked: true, glyph: 96, titleSize: 15, subtitleSize: 0, spacing: 10, gap: 24, fixedSize: CGSize(width: 640, height: 190), weight: .regular, titleOpacity: 0.7)

    static var current: FaceIDLayout {
        switch UserDefaults.standard.string(forKey: "faceIDText") {
        case "refined": return .refined
        case "light": return .light
        case "labelled": return .labelled
        case "iconLed": return .iconLed
        default: break
        }
        switch UserDefaults.standard.string(forKey: "faceIDLayout") {
        case "wide": return .wide
        case "big": return .panel
        default: return .labelled   // chosen 2026-10-19: big icon, "FACE ID" label + status
        }
    }
}

enum FaceIDActivityMetrics {
    static let bottomRadius: CGFloat = 32
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0)
}

/// Free layouts size the panel around their content; the fixed panel instead
/// gives the content its width (minus the side gap) so long titles shrink to fit.
private struct FitContent: ViewModifier {
    let layout: FaceIDLayout
    func body(content: Content) -> some View {
        if let fixed = layout.fixedSize {
            content
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: fixed.width - 2 * layout.gap)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            content.fixedSize()
        }
    }
}

private struct ContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct FaceIDActivityOverlay: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var faceID = FaceIDModel.shared
    @State private var contentSize: CGSize = .zero

    var body: some View {
        let layout = FaceIDLayout.current
        let shown = faceID.activity.isVisible && contentSize != .zero
        let closed = vm.closedNotchSize
        let size = panelSize(layout: layout, closed: closed)
        let width = shown ? size.width : closed.width
        let height = shown ? size.height : closed.height
        let topPad = layout.fixedSize != nil
            ? closed.height + (size.height - closed.height - contentSize.height) / 2
            : closed.height + gap(layout: layout, closed: closed)

        ZStack(alignment: .top) {
            // Solid black at every step of the animation (no fade), so it
            // always matches the notch and Boring Notch's own black.
            NotchShape(
                topCornerRadius: cornerRadiusInsets.closed.top,
                bottomCornerRadius: shown ? FaceIDActivityMetrics.bottomRadius : cornerRadiusInsets.closed.bottom
            )
            .fill(Color.black)
            .frame(width: width, height: height)
            .opacity(faceID.activity.isVisible ? 1 : 0)

            if faceID.activity.isVisible {
                FaceIDActivityContent(activity: faceID.activity, showsText: faceID.showMatchText, layout: layout)
                    .modifier(FitContent(layout: layout))
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ContentSizeKey.self, value: proxy.size)
                    })
                    .padding(.top, topPad)
                    .opacity(shown ? 1 : 0)
                    // Fade in, but vanish at once on the way out so nothing is
                    // left floating outside the shape as it shrinks.
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .frame(width: max(width, closed.width), height: height, alignment: .top)
        // Nothing draws outside the black shape at any point of the animation.
        .mask(alignment: .top) {
            NotchShape(
                topCornerRadius: cornerRadiusInsets.closed.top,
                bottomCornerRadius: shown ? FaceIDActivityMetrics.bottomRadius : cornerRadiusInsets.closed.bottom
            )
            .frame(width: width, height: height)
        }
        .onPreferenceChange(ContentSizeKey.self) { contentSize = $0 }
        .onChange(of: faceID.activity.isVisible) { _, isVisible in
            if !isVisible { contentSize = .zero }
        }
        .animation(FaceIDActivityMetrics.spring, value: faceID.activity)
        .animation(FaceIDActivityMetrics.spring, value: contentSize)
        .allowsHitTesting(false)
    }

    private func gap(layout: FaceIDLayout, closed: CGSize) -> CGFloat {
        max(layout.gap, (closed.width - contentSize.width) / 2)
    }

    private func panelSize(layout: FaceIDLayout, closed: CGSize) -> CGSize {
        if let fixed = layout.fixedSize { return fixed }
        let g = gap(layout: layout, closed: closed)
        return CGSize(width: contentSize.width + 2 * g, height: closed.height + contentSize.height + 2 * g)
    }
}

struct FaceIDActivityContent: View {
    let activity: FaceIDModel.Activity
    let showsText: Bool
    let layout: FaceIDLayout

    var body: some View {
        switch activity {
        case .hidden:
            EmptyView()

        case .scanning:
            arrange {
                FaceScanView(side: layout.glyph)
            } text: {
                title(L10n.t("notch.looking"), color: .white)
            }

        case .matched(let similarity):
            matchedRow(similarity: similarity)
                // The tick sits low in its box and "y" has a descender, so the
                // row reads low when centred by its frame; lift it to centre the ink.
                .offset(y: layout.fixedSize != nil && layout.titleSize > 60 ? -8 : 0)

        case .failed(let reason):
            failedRow(reason: reason)

        case .rejected(let reason):
            rejectedRow(reason: reason)
        }
    }

    /// "Hi, <first name>" — the first name of this Mac's account, so each person sees
    /// their own name; falls back to "It's you".
    static var greeting: String {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? L10n.t("notch.itsYou") : "Hi, \(first)"
    }

    private func matchedRow(similarity: Float) -> some View {
            arrange {
                SuccessMorph(size: layout.glyph)
                    // The tick only fills the middle of its box; trim the empty
                    // sides so the group is visually centred.
                    .padding(.horizontal, layout.stacked ? 0 : -layout.glyph * 0.2)
            } text: {
                VStack(alignment: layout.stacked ? .center : .leading, spacing: 2) {
                    title(Self.greeting, color: .white)
                    // The panel drops the "% match" line so "It's you" can be big.
                    if layout.subtitleSize > 0 {
                    Text(String(format: L10n.t("notch.match"), Int((similarity * 100).rounded())))
                        .font(.system(size: layout.subtitleSize, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }

    }

    private func failedRow(reason: String) -> some View {
            arrange {
                FaceScanView(tint: .orange, showsSweep: false, side: layout.glyph)
            } text: {
                title(reason.isEmpty ? L10n.t("notch.notRecognised") : reason, color: .white)
            }
            .modifier(Shake())

    }

    private func rejectedRow(reason: String) -> some View {
            arrange {
                FaceScanView(tint: .red, showsSweep: false, side: layout.glyph)
            } text: {
                title(reason.isEmpty ? L10n.t("notch.notYou") : reason, color: .red)
            }
            .modifier(Shake())
    }

    @ViewBuilder
    private func arrange<G: View, T: View>(@ViewBuilder glyph: () -> G, @ViewBuilder text: () -> T) -> some View {
        if layout.stacked {
            VStack(spacing: layout.spacing) {
                glyph()
                if showsText { text() }
            }
        } else {
            HStack(spacing: layout.spacing) {
                glyph()
                if showsText {
                    if layout.label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("FACE ID")
                                .font(.system(size: layout.labelSize, weight: .semibold))
                                .tracking(1.4)
                                .foregroundStyle(.white.opacity(0.45))
                            text()
                        }
                    } else {
                        text()
                    }
                }
            }
        }
    }

    private func title(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: layout.titleSize, weight: layout.weight))
            .foregroundStyle(color.opacity(layout.titleOpacity))
            .lineLimit(1)
            .minimumScaleFactor(0.4)
    }
}

// MARK: - Header button

struct FaceIDHeaderButton: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @ObservedObject var faceID = FaceIDModel.shared

    var body: some View {
        let selected = coordinator.currentView == .faceID
        Button {
            withAnimation(.smooth) {
                coordinator.currentView = selected ? .home : .faceID
            }
        } label: {
            Capsule()
                .fill(selected ? Color(nsColor: .secondarySystemFill) : .black)
                .frame(width: 30, height: 30)
                .overlay {
                    Image(systemName: "faceid")
                        .foregroundColor(faceID.isEnabled ? NotchPalette.green : .white)
                        .imageScale(.medium)
                }
        }
        .buttonStyle(PlainButtonStyle())
        .help("Face ID")
    }
}

// MARK: - Face ID page (inside the open notch)

struct FaceIDPageView: View {
    @ObservedObject var faceID = FaceIDModel.shared

    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 8) {
                FaceScanShape()
                    .stroke(
                        faceID.isEnabled && faceID.hasEnrollment ? NotchPalette.green : Color.gray,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: 58, height: 58)
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .frame(width: 150)

            VStack(spacing: 9) {
                PageToggle(title: "Unlock the lock screen", isOn: faceID.isEnabled) { faceID.setEnabled($0) }
                PageToggle(title: "Scan when a key is pressed", isOn: faceID.touchToScan) { faceID.setTouchToScan($0) }
                PageToggle(title: "sudo and password prompts", isOn: faceID.systemPrompts) { faceID.setSystemPrompts($0) }
                HStack(spacing: 6) {
                    PagePill(title: "Test", icon: "viewfinder") { FaceIDWindows.showTest() }
                    PagePill(title: "Re-enroll", icon: "person.crop.square") { FaceIDWindows.showEnroll() }
                    PagePill(title: "Password", icon: "key.fill") { faceID.setPassword() }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: 330)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { faceID.refreshPermissions() }
    }

    private var headline: String {
        if !faceID.hasEnrollment { return "No face enrolled" }
        if !faceID.hasPassword { return "Password not saved" }
        if !faceID.accessibilityTrusted { return "Needs Accessibility" }
        return faceID.isEnabled ? "Face ID ready" : "Face ID off"
    }

    private var detail: String {
        if let similarity = faceID.lastSimilarity {
            return String(format: "Enrolled · last match %.2f", similarity)
        }
        return faceID.hasEnrollment ? "Enrolled" : "Press Re-enroll"
    }
}

private struct PageToggle: View {
    let title: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Button {
            set(!isOn)
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Capsule()
                    .fill(isOn ? NotchPalette.green : Color.white.opacity(0.18))
                    .frame(width: 30, height: 18)
                    .overlay(alignment: isOn ? .trailing : .leading) {
                        Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                    }
                    .animation(.smooth(duration: 0.2), value: isOn)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct PagePill: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.12)))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Windows (enrollment and test)

@MainActor
enum FaceIDWindows {
    private static var windows: [String: NSWindow] = [:]

    static func showEnroll() {
        show(id: "enroll", title: L10n.t("window.enroll")) { EnrollView(model: FaceIDModel.shared) }
    }

    static func showTest() {
        show(id: "test", title: L10n.t("window.test")) { TestRecognitionView(model: FaceIDModel.shared) }
    }

    private static func show<V: View>(id: String, title: String, @ViewBuilder content: () -> V) {
        if let existing = windows[id] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content()))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        windows[id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { windows[id] = nil }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
