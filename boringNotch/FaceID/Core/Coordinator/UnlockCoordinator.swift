// From FaceMac by c1osed1 — https://github.com/c1osed1/FaceMac (GPL-3.0).
// Adapted for Boring Notch.

import Carbon.HIToolbox
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Ties camera, recognition, the Keychain password and key injection together.
///
/// Flow: screen locks -> camera on -> face detected + matched -> password typed ->
/// camera off. Every step falls back to the normal manual login on failure.
public final class UnlockCoordinator {
    public enum State: Equatable {
        case idle
        case disabled
        case armed
        /// Locked, camera off, waiting for the user to tap the scan button.
        case prompted
        case scanning
        case unlocking(similarity: Float)
        case failed(reason: String)
        /// The camera gave up without a match; the lock screen may offer a retry.
        case timedOut
        /// Confidently a different person.
        case rejected
        /// The face matched but looked like a photo — no blink or movement.
        case spoof
    }

    public private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            let state = self.state
            DispatchQueue.main.async { [weak self] in
                self?.stateHandler?(state)
            }
        }
    }

    /// Called on the main queue whenever `state` changes.
    public var stateHandler: ((State) -> Void)?

    private let settings: AppSettings
    private let store: EnrollmentStore
    private let keychain: KeychainStore
    private let detector = FaceDetector()
    private let liveness = LivenessTracker()
    private let embedder: FaceEmbedder
    private let capture: CameraCapture
    private let injector = KeyboardInjector()
    private let lockWatcher = LockWatcher()
    private let inputWatcher = InputActivityWatcher()
    /// When a scan last ended without unlocking. Input right after a failed
    /// scan is usually the user typing their password by hand, so touch-to-scan
    /// waits for a short pause before it re-arms.
    private var lastScanEndedAt = Date.distantPast
    /// Set while a scan is answering an authentication request (sudo, a system
    /// password dialog) instead of unlocking the screen.
    private var verifyCompletion: ((Bool) -> Void)?
    /// Per-scan counters, logged when the scan ends, to diagnose misses.
    private var statFrames = 0, statFaces = 0, statPoseSkipped = 0, statBest: Float = -1

    private var cachedEnrollment: Enrollment?
    private var cachedCentroid: FaceEmbedding?
    private var attempts = 0
    private var frameCounter = 0
    private var lastAttemptAt = Date.distantPast
    private var isScanning = false
    /// When the display last woke; used to tell a lid-open wake apart from a
    /// deliberate lock so we know whether to scan straight away.
    private var lastWakeAt = Date.distantPast

    /// Consecutive matching frames seen so far, and when the streak began.
    private var matchStreak = 0
    private var streakStartedAt: Date?
    private var lowScoreStreak = 0
    private var scanTimeoutWork: DispatchWorkItem?
    /// Set when the face matched but liveness was not proven yet.
    private var livenessBlocked = false

    public init(
        settings: AppSettings = .shared,
        store: EnrollmentStore = .shared,
        keychain: KeychainStore = .shared,
        embedder: FaceEmbedder? = nil,
        capture: CameraCapture = .shared
    ) {
        self.settings = settings
        self.store = store
        self.keychain = keychain
        self.embedder = embedder ?? EmbedderFactory.make()
        self.capture = capture
        self.capture.addDelegate(self)
        self.lockWatcher.delegate = self
        self.inputWatcher.onActivity = { [weak self] idleBefore in
            self?.handleInputWhileLocked(idleBefore: idleBefore)
        }

        settings.applyRecommendedThreshold(from: self.embedder)
    }

    public func start() {
        lockWatcher.start()
        reloadEnrollment()
        state = settings.isEnabled ? .armed : .disabled
        Log.app.info("coordinator started, enabled=\(self.settings.isEnabled, privacy: .public)")
    }

    public func stop() {
        lockWatcher.stop()
        inputWatcher.stop()
        stopScanning()
        state = .idle
    }

    /// Re-emits the current state so localized text updates after a language change.
    public func refreshLocalizedState() {
        reloadEnrollment()
        let current = state
        DispatchQueue.main.async { [weak self] in
            self?.stateHandler?(current)
        }
    }

    public func reloadEnrollment() {
        var enrollment = try? store.load()
        if let loaded = enrollment, loaded.modelTag != embedder.modelTag {
            Log.app.info("enrollment was made with a different model, ignoring it")
            enrollment = nil
        }
        cachedEnrollment = enrollment
        cachedCentroid = enrollment?.centroid
    }

    public func handleEnrollmentChanged() {
        reloadEnrollment()
        let hasFace = cachedEnrollment?.embeddings.isEmpty == false
        Log.app.info("enrollment reloaded, hasFace=\(hasFace, privacy: .public)")
    }

    private func startScanning() {
        guard !isScanning else { return }
        guard settings.isEnabled else {
            state = .disabled
            return
        }
        guard let enrollment = cachedEnrollment, !enrollment.embeddings.isEmpty else {
            state = .failed(reason: L10n.t("failure.noEnrollment"))
            return
        }
        guard injectorReady() else {
            state = .failed(reason: L10n.t("failure.accessibility"))
            return
        }
        guard keychainHasPassword() else {
            state = .failed(reason: L10n.t("failure.noPassword"))
            return
        }

        attempts = 0
        frameCounter = 0
        statFrames = 0; statFaces = 0; statPoseSkipped = 0; statBest = -1
        lowScoreStreak = 0
        livenessBlocked = false
        resetMatchStreak()
        liveness.reset()
        do {
            try capture.acquire()
            if settings.keepDisplayAwake {
                DisplaySleepGuard.shared.hold()
            }
            isScanning = true
            state = .scanning
            scheduleScanTimeout()
        } catch {
            state = .failed(reason: String(format: L10n.t("failure.camera"), "\(error)"))
        }
    }

    /// Sets up a locked-but-idle state: the camera stays off until the user taps
    /// the scan button. Used for a deliberate lock (Ctrl+Cmd+Q, Apple menu).
    private func promptForScan() {
        guard settings.isEnabled else {
            state = .disabled
            return
        }
        guard let enrollment = cachedEnrollment, !enrollment.embeddings.isEmpty else {
            state = .failed(reason: L10n.t("failure.noEnrollment"))
            return
        }
        guard injectorReady() else {
            state = .failed(reason: L10n.t("failure.accessibility"))
            return
        }
        guard keychainHasPassword() else {
            state = .failed(reason: L10n.t("failure.noPassword"))
            return
        }

        stopScanning()
        state = .prompted
        Log.app.info("locked: waiting for the scan button")
    }

    /// Recognises the user for an authentication request outside the lock
    /// screen. `completion` runs once on the main queue with the verdict; the
    /// password is never typed in this mode.
    public func verifyUser(reason: String, completion: @escaping (Bool) -> Void) {
        guard !isScanning, verifyCompletion == nil, !LockWatcher.isScreenLocked else {
            completion(false)
            return
        }
        Log.app.info("verify requested: \(reason, privacy: .public)")
        verifyCompletion = completion
        startScanning()
        if !isScanning {
            finishVerify(false)
        }
    }

    /// Abandons a pending prompt scan — the prompt was answered by hand,
    /// closed, or sudo was cancelled.
    public func cancelVerify() {
        guard verifyCompletion != nil else { return }
        Log.app.info("verify cancelled")
        stopScanning()
        state = settings.isEnabled ? .armed : .disabled
    }

    private func finishVerify(_ ok: Bool) {
        guard let completion = verifyCompletion else { return }
        verifyCompletion = nil
        Log.app.info("verify \(ok ? "granted" : "denied", privacy: .public)")
        completion(ok)
    }

    /// Starts recognising — from the scan button or after a failed attempt.
    public func retryScan() {
        startScanning()
    }

    /// Gives up after `scanTimeout` seconds so the camera light does not stay on.
    private func scheduleScanTimeout() {
        scanTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isScanning else { return }
            self.stopScanning()
            if self.livenessBlocked {
                self.state = .spoof
                Log.app.info("scan timed out: identity matched but no liveness")
            } else {
                self.state = .timedOut
                Log.app.info("scan timed out")
            }
        }
        scanTimeoutWork = work
        let timeout = verifyCompletion != nil ? settings.promptScanTimeout : settings.scanTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
    }

    private func cancelScanTimeout() {
        scanTimeoutWork?.cancel()
        scanTimeoutWork = nil
    }

    private func stopScanning() {
        cancelScanTimeout()
        DisplaySleepGuard.shared.release()
        guard isScanning else {
            finishVerify(false)
            return
        }
        capture.relinquish()
        isScanning = false
        Log.app.info("scan ended: frames=\(self.statFrames, privacy: .public) faces=\(self.statFaces, privacy: .public) poseSkipped=\(self.statPoseSkipped, privacy: .public) best=\(self.statBest, privacy: .public) threshold=\(self.settings.matchThreshold, privacy: .public)")
        lastScanEndedAt = Date()
        resetMatchStreak()
        // Any scan that ends without an explicit grant is a denial.
        finishVerify(false)
    }

    /// Touch to scan: any key, trackpad or mouse input on the lock screen
    /// starts recognising when the camera is not already running.
    private func handleInputWhileLocked(idleBefore: TimeInterval) {
        guard settings.touchToScan, settings.isEnabled, !isScanning, LockWatcher.isScreenLocked else { return }
        switch state {
        case .prompted, .armed:
            break
        case .timedOut, .rejected, .spoof, .failed:
            // Right after a failed scan, keystrokes are usually the password
            // being typed by hand; only re-arm after a pause.
            guard idleBefore >= 3 else { return }
        default:
            return
        }
        guard Date().timeIntervalSince(lastScanEndedAt) >= 1.5 else { return }
        Log.app.info("input on the lock screen: scanning")
        startScanning()
    }

    private func injectorReady() -> Bool {
        KeyboardInjector.isAccessibilityTrusted
    }

    private func keychainHasPassword() -> Bool {
        (try? keychain.password()) ?? nil != nil
    }

    private func process(_ pixelBuffer: CVPixelBuffer) {
        guard isScanning, let enrollment = cachedEnrollment else { return }

        frameCounter += 1
        guard frameCounter % 2 == 0 else { return }
        statFrames += 1

        guard
            let faces = try? detector.detect(in: pixelBuffer),
            let face = faces.max(by: { $0.area < $1.area })
        else {
            resetMatchStreak()
            return
        }

        // Tiny or heavily turned faces produce noisy embeddings — the main
        // source of false accepts. Ignore those frames entirely.
        statFaces += 1
        guard face.area >= 0.02, abs(face.yaw) <= 0.6, abs(face.pitch) <= 0.6 else {
            statPoseSkipped += 1
            resetMatchStreak()
            return
        }

        let now = Date()
        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        liveness.observe(face: face, imageSize: imageSize, at: now)

        guard let embedding = try? embedder.embed(FaceInput(pixelBuffer: pixelBuffer, face: face)) else {
            resetMatchStreak()
            return
        }

        let best = FaceMatcher.match(
            embedding,
            against: enrollment.embeddings,
            threshold: settings.matchThreshold
        )
        statBest = max(statBest, best.similarity)
        let centroid = FaceMatcher.similarity(
            embedding,
            toCentroid: cachedCentroid ?? enrollment.centroid
        )

        // Confidently someone else: fail fast instead of scanning for the full
        // timeout.
        if best.similarity < settings.rejectionThreshold {
            lowScoreStreak += 1
            // A prompt waits for its owner: someone else walking past is ignored.
            if lowScoreStreak >= 3, verifyCompletion == nil {
                stopScanning()
                state = .rejected
                Log.app.info("rejected: best=\(best.similarity, privacy: .public)")
                return
            }
        } else {
            lowScoreStreak = 0
        }

        // Both the closest reference and the centroid must agree.
        guard best.isMatch, centroid >= settings.matchThreshold - 0.06 else {
            Log.vision.debug("no match best=\(best.similarity, privacy: .public) centroid=\(centroid, privacy: .public)")
            resetMatchStreak()
            return
        }

        if let started = streakStartedAt, now.timeIntervalSince(started) > 2.5 {
            matchStreak = 0
            streakStartedAt = nil
        }
        matchStreak += 1
        if streakStartedAt == nil { streakStartedAt = now }

        Log.vision.debug(
            "streak \(self.matchStreak, privacy: .public)/\(self.settings.requiredFrames, privacy: .public) best=\(best.similarity, privacy: .public) centroid=\(centroid, privacy: .public)"
        )

        guard matchStreak >= settings.requiredFrames else { return }

        // Identity alone is not enough: a printed photo matches too. Hold the
        // unlock until the face has proven it is alive.
        if settings.livenessMode.requiresConfirmation,
           !liveness.isConfirmed(for: settings.livenessMode) {
            livenessBlocked = true
            Log.vision.debug("matched but not live yet (mode=\(self.settings.livenessMode.rawValue, privacy: .public))")
            return
        }

        guard settings.autoUnlock, now.timeIntervalSince(lastAttemptAt) >= settings.unlockCooldown else { return }
        lastAttemptAt = now
        attempts += 1
        resetMatchStreak()
        unlock(similarity: best.similarity)
    }

    private func resetMatchStreak() {
        matchStreak = 0
        streakStartedAt = nil
    }

    private func unlock(similarity: Float) {
        state = .unlocking(similarity: similarity)
        Log.app.info("match, similarity=\(similarity, privacy: .public)")

        if verifyCompletion != nil {
            finishVerify(true)
            stopScanning()
            state = .armed
            return
        }

        guard let password = (try? keychain.password()) ?? nil else {
            state = .failed(reason: L10n.t("failure.noPassword"))
            stopScanning()
            return
        }
        stopScanning()
        state = .armed
        typePassword(password, attempt: 1)
    }

    /// Types the password into the lock screen and checks that it worked.
    ///
    /// The lock screen hides its password field until a key arrives, and keys
    /// that land while it is still hidden are dropped (loginwindow logs "View is
    /// hidden password field length = 0"). So: tap Shift to reveal the field,
    /// give it a moment, clear it, type at a steady pace, press Return — then
    /// look again and retry if the session is still locked.
    private func typePassword(_ password: String, attempt: Int) {
        guard LockWatcher.isScreenLocked else { return }
        do {
            try injector.press(virtualKey: CGKeyCode(kVK_Shift))
        } catch {
            state = .failed(reason: String(format: L10n.t("failure.couldNotType"), "\(error)"))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, LockWatcher.isScreenLocked else { return }
            do {
                // Touch-to-scan means a stray space may already be in the field.
                try self.injector.clearFocusedField()
                try self.injector.type(password, interval: 0.012)
                try self.injector.pressReturn()
                Log.app.info("typed password (attempt \(attempt, privacy: .public))")
            } catch {
                self.state = .failed(reason: String(format: L10n.t("failure.couldNotType"), "\(error)"))
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, LockWatcher.isScreenLocked else { return }
                if attempt < 3 {
                    Log.app.info("still locked after typing, retrying")
                    self.typePassword(password, attempt: attempt + 1)
                } else {
                    Log.app.info("still locked after \(attempt, privacy: .public) attempts")
                    self.state = .failed(reason: String(format: L10n.t("failure.giveUp"), attempt))
                }
            }
        }
    }
}

extension UnlockCoordinator: CameraCaptureDelegate {
    public func cameraCapture(_ capture: CameraCapture, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime) {
        DispatchQueue.main.async { [weak self] in
            self?.process(pixelBuffer)
        }
    }
}

extension UnlockCoordinator: LockWatcherDelegate {
    public func lockWatcherDidLock(_ watcher: LockWatcher) {
        inputWatcher.start()
        // If the display just woke (lid opened) the lock is part of waking up,
        // so scan immediately. A deliberate lock just offers the button.
        if Date().timeIntervalSince(lastWakeAt) < 3 {
            startScanning()
        } else {
            promptForScan()
        }
    }

    public func lockWatcherDidWakeLocked(_ watcher: LockWatcher) {
        inputWatcher.start()
        lastWakeAt = Date()
        startScanning()
    }

    public func lockWatcherDidUnlock(_ watcher: LockWatcher) {
        inputWatcher.stop()
        stopScanning()
        state = settings.isEnabled ? .armed : .disabled
    }
}
