//
//  FaceIDModel.swift
//  boringNotch
//
//  Face ID inside the notch: ties FaceMac's unlock engine to Boring Notch.
//  Ported from FaceMac's AppModel; the menu bar extra, the separate notch
//  panel and the lock-screen retry button are gone — the notch itself shows
//  the scan, and touch-to-scan replaces the button.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class FaceIDModel: ObservableObject {
    static let shared = FaceIDModel()

    /// What the notch is showing for Face ID right now.
    enum Activity: Equatable {
        case hidden
        case scanning
        case matched(similarity: Float)
        case failed(reason: String)
        case rejected(reason: String)

        var isVisible: Bool { self != .hidden }
    }

    @Published private(set) var activity: Activity = .hidden

    @Published private(set) var isEnabled: Bool
    @Published private(set) var statusText: String = "Idle"
    @Published private(set) var hasEnrollment: Bool
    @Published private(set) var hasPassword: Bool
    @Published private(set) var accessibilityTrusted: Bool
    @Published private(set) var lastSimilarity: Float?

    @Published private(set) var showMatchText: Bool
    @Published private(set) var keepDisplayAwake: Bool
    @Published private(set) var touchToScan: Bool
    @Published private(set) var systemPrompts: Bool
    @Published private(set) var uiLanguage: AppLanguage
    @Published private(set) var threshold: Float
    @Published private(set) var requiredFrames: Int
    @Published private(set) var livenessMode: LivenessMode
    @Published private(set) var scanTimeout: Double

    // Enrollment
    @Published private(set) var isEnrolling = false
    @Published private(set) var enrollMessage = "Press Start, then follow the prompts."
    @Published private(set) var enrollStepIndex = 0
    @Published private(set) var enrollStepCount = GuidedEnroller.stepCount
    @Published private(set) var enrollStepProgress: Float = 0
    @Published private(set) var enrollStepTitle = "Look straight at the camera"
    @Published private(set) var enrollStepSymbol = "face.smiling"
    @Published private(set) var enrollSampleCount = 0
    @Published private(set) var enrollJustFinished = false

    // Recognition test
    @Published private(set) var isTesting = false
    @Published private(set) var testSimilarity: Float = -1
    @Published private(set) var testCentroid: Float = -1
    @Published private(set) var testMatched = false
    @Published private(set) var testFaceCount = 0

    let coordinator: UnlockCoordinator
    private let authServer = AuthServer()
    private let promptWatcher = SystemPromptWatcher()

    private let settings: AppSettings
    private let store: EnrollmentStore
    private let keychain: KeychainStore
    private let embedder: FaceEmbedder
    private var guidedEnroller: GuidedEnroller?
    private var tester: RecognitionTester?

    private var hideTask: Task<Void, Never>?
    /// Keeps a result on screen for a minimum time so a fast unlock is still seen.
    private var holdUntil: Date?
    private var previewTask: Task<Void, Never>?

    private init(
        settings: AppSettings = .shared,
        store: EnrollmentStore = .shared,
        keychain: KeychainStore = .shared
    ) {
        let embedder = EmbedderFactory.make()
        settings.applyRecommendedThreshold(from: embedder)

        self.settings = settings
        self.store = store
        self.keychain = keychain
        self.embedder = embedder
        self.isEnabled = settings.isEnabled
        self.showMatchText = settings.showMatchText
        self.keepDisplayAwake = settings.keepDisplayAwake
        self.touchToScan = settings.touchToScan
        self.systemPrompts = settings.systemPrompts
        self.uiLanguage = settings.language
        L10n.language = settings.language
        self.threshold = settings.matchThreshold
        self.requiredFrames = settings.requiredFrames
        self.livenessMode = settings.livenessMode
        self.scanTimeout = settings.scanTimeout
        self.accessibilityTrusted = KeyboardInjector.isAccessibilityTrusted
        self.hasEnrollment = FaceIDModel.validEnrollment(store: store, embedder: embedder)?
            .embeddings.isEmpty == false
        self.hasPassword = ((try? keychain.password()) ?? nil) != nil
        self.coordinator = UnlockCoordinator(
            settings: settings,
            store: store,
            keychain: keychain,
            embedder: embedder
        )

        coordinator.stateHandler = { [weak self] state in
            self?.apply(state)
        }

        authServer.verify = { [weak self] reason, completion in
            guard let self, self.isEnabled, self.systemPrompts else { return completion(false) }
            self.coordinator.verifyUser(reason: reason, completion: completion)
        }
        promptWatcher.verify = authServer.verify
        authServer.cancel = { [weak self] in self?.coordinator.cancelVerify() }
        promptWatcher.cancel = { [weak self] in self?.coordinator.cancelVerify() }
        promptWatcher.password = { [weak self] in
            (try? self?.keychain.password()) ?? nil
        }

        // `notifyutil`-free preview hook for checking the animation by eye:
        // post "com.facemac.previewActivity" as a distributed notification.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.facemac.previewActivity"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.previewActivity() }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.coordinator.stop()
                self?.authServer.stop()
                self?.promptWatcher.stop()
            }
        }
    }

    /// Called once from the app delegate.
    func start() {
        if isEnabled {
            coordinator.start()
        } else {
            statusText = "Disabled"
        }
        applySystemPrompts()
    }

    private func applySystemPrompts() {
        if isEnabled && systemPrompts {
            authServer.start()
            promptWatcher.start()
        } else {
            authServer.stop()
            promptWatcher.stop()
        }
    }

    // MARK: Activity (what the notch shows)

    private func apply(_ state: UnlockCoordinator.State) {
        statusText = FaceIDModel.describe(state)
        switch state {
        case .scanning:
            show(.scanning)
        case .unlocking(let similarity):
            lastSimilarity = similarity
            show(.matched(similarity: similarity), hold: 1.9, hideAfter: 2.3)
        case .timedOut:
            show(.failed(reason: L10n.t("notch.notRecognised")), hold: 1.2, hideAfter: 2.0)
        case .rejected:
            show(.rejected(reason: L10n.t("notch.notYou")), hold: 1.2, hideAfter: 2.2)
        case .spoof:
            show(.rejected(reason: L10n.t("notch.notLive")), hold: 1.2, hideAfter: 2.2)
        case .failed(let reason):
            if activity.isVisible {
                show(.failed(reason: reason), hold: 1.2, hideAfter: 2.0)
            }
        case .idle, .disabled, .armed, .prompted:
            requestHide()
        }
    }

    private func show(_ newActivity: Activity, hold: TimeInterval? = nil, hideAfter: TimeInterval? = nil) {
        hideTask?.cancel()
        activity = newActivity
        if let hold {
            holdUntil = Date().addingTimeInterval(hold)
        } else {
            holdUntil = nil
        }
        if let hideAfter {
            scheduleHide(after: hideAfter)
        }
    }

    private func requestHide() {
        if let until = holdUntil, Date() < until {
            scheduleHide(after: until.timeIntervalSinceNow)
            return
        }
        holdUntil = nil
        activity = .hidden
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.holdUntil = nil
            self?.activity = .hidden
        }
    }

    /// Plays scan → match → not you → not recognised, without locking.
    func previewActivity() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            self?.show(.scanning)
            try? await Task.sleep(for: .seconds(1.8))
            guard !Task.isCancelled else { return }
            self?.show(.matched(similarity: 0.90))
            try? await Task.sleep(for: .seconds(2.3))
            guard !Task.isCancelled else { return }
            self?.show(.rejected(reason: L10n.t("notch.notYou")))
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }
            self?.show(.failed(reason: L10n.t("notch.notRecognised")))
            try? await Task.sleep(for: .seconds(2.0))
            guard !Task.isCancelled else { return }
            self?.activity = .hidden
        }
    }

    private static func validEnrollment(store: EnrollmentStore, embedder: FaceEmbedder) -> Enrollment? {
        guard let enrollment = try? store.load() else { return nil }
        return enrollment.modelTag == embedder.modelTag ? enrollment : nil
    }

    private static func describe(_ state: UnlockCoordinator.State) -> String {
        switch state {
        case .idle: return L10n.t("status.idle")
        case .disabled: return L10n.t("status.disabled")
        case .armed: return L10n.t("status.armed")
        case .prompted: return L10n.t("status.prompted")
        case .scanning: return L10n.t("status.scanning")
        case .unlocking(let similarity): return String(format: L10n.t("status.unlocking"), similarity)
        case .failed(let reason): return reason
        case .timedOut: return L10n.t("status.timedOut")
        case .rejected: return L10n.t("notch.notYou")
        case .spoof: return L10n.t("status.notLive")
        }
    }

    // MARK: Switches

    func setEnabled(_ value: Bool) {
        isEnabled = value
        settings.isEnabled = value
        if value {
            coordinator.start()
        } else {
            coordinator.stop()
            statusText = "Disabled"
        }
        applySystemPrompts()
    }

    func setTouchToScan(_ value: Bool) {
        touchToScan = value
        settings.touchToScan = value
    }

    func setSystemPrompts(_ value: Bool) {
        systemPrompts = value
        settings.systemPrompts = value
        applySystemPrompts()
    }

    func setKeepDisplayAwake(_ value: Bool) {
        keepDisplayAwake = value
        settings.keepDisplayAwake = value
    }

    func setShowMatchText(_ value: Bool) {
        showMatchText = value
        settings.showMatchText = value
    }

    func updateThreshold(_ value: Float) {
        threshold = value
        settings.matchThreshold = value
        settings.thresholdOverridden = true
    }

    func updateRequiredFrames(_ value: Int) {
        requiredFrames = value
        settings.requiredFrames = value
    }

    func setLivenessMode(_ value: LivenessMode) {
        livenessMode = value
        settings.livenessMode = value
    }

    func updateScanTimeout(_ value: Double) {
        scanTimeout = value
        settings.scanTimeout = value
    }

    // MARK: Permissions and password

    func requestAccessibility() {
        KeyboardInjector.requestAccessibility()
        refreshPermissions()
    }

    func refreshPermissions() {
        accessibilityTrusted = KeyboardInjector.isAccessibilityTrusted
        hasPassword = ((try? keychain.password()) ?? nil) != nil
        hasEnrollment = FaceIDModel.validEnrollment(store: store, embedder: embedder)?
            .embeddings.isEmpty == false
    }

    func setPassword() {
        let alert = NSAlert()
        alert.messageText = L10n.t("alert.passwordTitle")
        alert.informativeText = L10n.t("alert.passwordInfo")
        alert.addButton(withTitle: L10n.t("alert.save"))
        alert.addButton(withTitle: L10n.t("alert.cancel"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Login password"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try keychain.setPassword(field.stringValue)
            hasPassword = true
            statusText = "Password saved"
        } catch {
            statusText = "Could not save password: \(error)"
        }
    }

    func forgetFace() {
        try? store.delete()
        hasEnrollment = false
        coordinator.handleEnrollmentChanged()
        statusText = "Face data deleted"
    }

    // MARK: Camera preview

    func previewAcquire() {
        do {
            try CameraCapture.shared.acquire()
        } catch {
            enrollMessage = "Camera unavailable: \(error)"
        }
    }

    func previewRelease() {
        CameraCapture.shared.relinquish()
    }

    // MARK: Enrollment

    func beginEnrollment() {
        guard !isEnrolling else { return }
        isEnrolling = true
        enrollStepIndex = 0
        enrollStepCount = GuidedEnroller.stepCount
        enrollStepProgress = 0
        enrollStepTitle = GuidedEnroller.Step.center.title
        enrollStepSymbol = GuidedEnroller.Step.center.symbol
        enrollSampleCount = 0
        enrollJustFinished = false
        enrollMessage = GuidedEnroller.Step.center.title

        let enroller = GuidedEnroller(embedder: embedder)
        self.guidedEnroller = enroller

        enroller.onProgress = { [weak self] progress in
            guard let self else { return }
            self.enrollStepIndex = progress.stepIndex
            self.enrollStepCount = progress.stepCount
            self.enrollStepProgress = progress.stepProgress
            self.enrollStepTitle = progress.step.title
            self.enrollStepSymbol = progress.step.symbol
            self.enrollSampleCount = progress.samples
            self.enrollMessage = progress.step.title
        }

        enroller.completion = { [weak self] result in
            guard let self else { return }
            self.guidedEnroller = nil
            self.isEnrolling = false
            switch result {
            case .success(let embeddings):
                do {
                    let enrollment = Enrollment(
                        name: NSUserName(),
                        embeddings: embeddings,
                        modelTag: self.embedder.modelTag
                    )
                    try self.store.save(enrollment)

                    // Calibrate the accept threshold against how consistent this
                    // user's own samples are on this camera and in this light.
                    let calibration = ThresholdCalibration.calibrate(from: enrollment)
                    self.threshold = calibration.threshold
                    self.settings.matchThreshold = calibration.threshold
                    self.settings.thresholdOverridden = true

                    self.hasEnrollment = true
                    self.coordinator.handleEnrollmentChanged()
                    self.enrollMessage = String(
                        format: L10n.t("enroll.done"),
                        embeddings.count, calibration.threshold
                    )
                    self.statusText = "Face enrolled"
                    self.enrollSampleCount = embeddings.count
                    self.enrollJustFinished = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.6))
                        self.enrollJustFinished = false
                    }
                } catch {
                    self.enrollMessage = "Could not save: \(error)"
                }
            case .failure(GuidedEnroller.EnrollError.cancelled):
                self.enrollMessage = L10n.t("enroll.cancelled")
            case .failure(GuidedEnroller.EnrollError.notEnoughAngles):
                self.enrollMessage = L10n.t("enroll.notEnoughAngles")
            case .failure(let error):
                self.enrollMessage = String(format: L10n.t("enroll.failed"), "\(error)")
            }
        }

        enroller.start()
    }

    func cancelEnrollment() {
        guidedEnroller?.cancel()
    }

    // MARK: Recognition test

    func beginTest() {
        guard !isTesting else { return }
        isTesting = true
        testSimilarity = -1
        testCentroid = -1
        testMatched = false
        testFaceCount = 0

        let tester = RecognitionTester(embedder: embedder, store: store)
        self.tester = tester
        tester.onReading = { [weak self] reading in
            guard let self else { return }
            self.testFaceCount = reading.faceCount
            self.testSimilarity = reading.similarity
            self.testCentroid = reading.centroidSimilarity
            self.testMatched = reading.isMatch
        }
        tester.onError = { [weak self] error in
            self?.statusText = "Test: \(error)"
            self?.isTesting = false
        }
        tester.start()
    }

    func endTest() {
        tester?.stop()
        tester = nil
        isTesting = false
    }
}
