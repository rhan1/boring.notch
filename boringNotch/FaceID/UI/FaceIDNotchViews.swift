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

enum FaceIDActivityMetrics {
    /// Approved 2026-10-19: grow past the physical notch to catch the eye.
    static let expandedWidth: CGFloat = 260
    static let expandedHeight: CGFloat = 132
    static let bottomRadius: CGFloat = 26
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0)
}

struct FaceIDActivityOverlay: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var faceID = FaceIDModel.shared

    var body: some View {
        let visible = faceID.activity.isVisible
        let closed = vm.closedNotchSize
        let width = visible ? max(FaceIDActivityMetrics.expandedWidth, closed.width) : closed.width
        let height = visible ? FaceIDActivityMetrics.expandedHeight : closed.height

        NotchShape(
            topCornerRadius: cornerRadiusInsets.closed.top,
            bottomCornerRadius: visible ? FaceIDActivityMetrics.bottomRadius : cornerRadiusInsets.closed.bottom
        )
        .fill(.black)
        .frame(width: width, height: height)
        .overlay(alignment: .top) {
            // Content sits in the band below the camera housing, centred in it.
            VStack(spacing: 0) {
                Color.clear.frame(height: closed.height)
                ZStack {
                    if visible {
                        FaceIDActivityContent(activity: faceID.activity, showsText: faceID.showMatchText)
                            .transition(.opacity.combined(with: .scale(scale: 0.88)))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: width, height: height)
        }
        .opacity(visible ? 1 : 0)
        .animation(FaceIDActivityMetrics.spring, value: faceID.activity)
        .allowsHitTesting(false)
    }
}

struct FaceIDActivityContent: View {
    let activity: FaceIDModel.Activity
    let showsText: Bool

    var body: some View {
        switch activity {
        case .hidden:
            EmptyView()

        case .scanning:
            FaceScanView()

        case .matched(let similarity):
            HStack(spacing: 12) {
                SuccessMorph()
                if showsText {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.t("notch.itsYou"))
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(String(format: L10n.t("notch.match"), Int((similarity * 100).rounded())))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .fixedSize()
                }
            }

        case .failed(let reason):
            resultRow(tint: .orange, text: reason.isEmpty ? L10n.t("notch.notRecognised") : reason, textColor: .white)

        case .rejected(let reason):
            resultRow(tint: .red, text: reason.isEmpty ? L10n.t("notch.notYou") : reason, textColor: .red)
        }
    }

    private func resultRow(tint: Color, text: String, textColor: Color) -> some View {
        HStack(spacing: 10) {
            FaceScanView(tint: tint, showsSweep: false)
                .scaleEffect(0.78)
                .frame(width: 44, height: 44)
            if showsText {
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(textColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 150, alignment: .leading)
            }
        }
        .modifier(Shake())
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
