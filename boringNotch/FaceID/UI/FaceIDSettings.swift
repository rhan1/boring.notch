//
//  FaceIDSettings.swift
//  boringNotch
//
//  The "Face ID" section of Boring Notch's settings window: the finer controls
//  that don't fit on the notch page.
//

import SwiftUI

struct FaceIDSettings: View {
    @ObservedObject var faceID = FaceIDModel.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Face") {
                    HStack {
                        Text(faceID.hasEnrollment ? "Enrolled" : "Not enrolled").foregroundStyle(.secondary)
                        Button(faceID.hasEnrollment ? "Re-enroll…" : "Enroll…") { FaceIDWindows.showEnroll() }
                        Button("Test…") { FaceIDWindows.showTest() }
                    }
                }
                LabeledContent("Login password") {
                    HStack {
                        Text(faceID.hasPassword ? "Saved in Keychain" : "Not saved").foregroundStyle(.secondary)
                        Button(faceID.hasPassword ? "Change…" : "Save…") { faceID.setPassword() }
                    }
                }
                LabeledContent("Accessibility") {
                    HStack {
                        Text(faceID.accessibilityTrusted ? "Allowed" : "Needed to type your password").foregroundStyle(.secondary)
                        if !faceID.accessibilityTrusted {
                            Button("Allow…") { faceID.requestAccessibility() }
                        }
                    }
                }
            } header: {
                Text("Setup")
            }

            Section {
                Toggle("Unlock the lock screen with your face", isOn: binding(faceID.isEnabled, faceID.setEnabled))
                Toggle("Scan when a key, trackpad or mouse is touched", isOn: binding(faceID.touchToScan, faceID.setTouchToScan))
                Toggle("Answer sudo and macOS password prompts", isOn: binding(faceID.systemPrompts, faceID.setSystemPrompts))
                Toggle("Show “It's you” text in the notch", isOn: binding(faceID.showMatchText, faceID.setShowMatchText))
                Toggle("Keep the display awake while scanning", isOn: binding(faceID.keepDisplayAwake, faceID.setKeepDisplayAwake))
                Button("Preview the notch animation") { faceID.previewActivity() }
            } header: {
                Text("Face ID")
            }

            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Match strictness")
                        Spacer()
                        Text(String(format: "%.2f", faceID.threshold)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(get: { Double(faceID.threshold) }, set: { faceID.updateThreshold(Float($0)) }),
                        in: 0.30...0.90
                    )
                    Text("Higher is stricter. Re-enrolling sets this for your face and lighting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Stepper(
                    "Matching frames needed: \(faceID.requiredFrames)",
                    value: Binding(get: { faceID.requiredFrames }, set: { faceID.updateRequiredFrames($0) }),
                    in: 1...10
                )
                Picker("Liveness check", selection: Binding(get: { faceID.livenessMode }, set: { faceID.setLivenessMode($0) })) {
                    ForEach(LivenessMode.allCases, id: \.self) { mode in
                        Text(Self.label(for: mode)).tag(mode)
                    }
                }
                VStack(alignment: .leading) {
                    HStack {
                        Text("Camera stays on for")
                        Spacer()
                        Text(String(format: "%.0f s", faceID.scanTimeout)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(get: { faceID.scanTimeout }, set: { faceID.updateScanTimeout($0) }),
                        in: 2...15, step: 1
                    )
                }
            } header: {
                Text("Recognition")
            }

            Section {
                Text(faceID.statusText).foregroundStyle(.secondary)
            } header: {
                Text("Status")
            }
        }
        .onAppear { faceID.refreshPermissions() }
        .navigationTitle("Face ID")
    }

    private static func label(for mode: LivenessMode) -> String {
        switch mode {
        case .off: return "Off"
        case .blink: return "Blink"
        case .motion: return "Head movement"
        case .blinkOrMotion: return "Blink or movement"
        case .blinkAndMotion: return "Blink and movement"
        }
    }

    private func binding(_ value: Bool, _ set: @escaping (Bool) -> Void) -> Binding<Bool> {
        Binding(get: { value }, set: set)
    }
}
