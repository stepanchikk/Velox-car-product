import Foundation
import UIKit
import CallKit
import AVFoundation

// Anti-Fraud: втрата і повернення активності, відволікання, телефонні дзвінки
extension SensorManager {

    @objc func appLostFocus() {
        DispatchQueue.main.async { [weak self] in
            self?.handleFocusLost()
        }
    }

    // Штрафів немає лише під час першого калібрування поїздки (водій щойно
    // натиснув «Старт»). Перекалібрування в русі не звільняє від штрафу.
    private var distractionsPaused: Bool {
        isCalibrating && !hasCalibrated
    }

    private func handleFocusLost() {
        guard isRecording, !distractionsPaused, pendingFocusLoss == nil else { return }
        // Екран вхідного дзвінка відкривається трохи раніше, ніж CallKit повідомляє
        // про дзвінок, тому причину визначаємо з невеликою затримкою, а час
        // відволікання беремо з моменту втрати активності
        let now = sessionTime()
        pendingFocusLoss = (now, CallPolicy.callWasActive(callStartedAt: callInProgress ? callStartedAt : nil,
                                                         focusLostAt: now))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.resolvePendingFocusLoss()
        }
    }

    // Викликається таймером або поверненням у застосунок, залежно від того, що раніше
    private func resolvePendingFocusLoss() {
        guard let pending = pendingFocusLoss else { return }
        pendingFocusLoss = nil
        guard isRecording else { return }

        switch CallPolicy.cause(for: currentCallState, callWasActive: pending.callWasActive) {
        case .incomingCall:
            appendEventRow(event: "CallIncoming", time: pending.time)
            // Дзвінок відкрито: CallEnd запишеться, коли дзвінків не залишиться
            // (навіть якщо iOS призупинила застосунок на час розмови)
            callInProgress = true
            callStartedAt = pending.time
            phoneState = .onCall
        case .handsFreeCall:
            updateCallState()
        case .distraction:
            if backgroundRecording {
                // Може бути блокування екрана: рішення за ScreenLockTracker
                applyScreenActions(screenTracker.focusLost(at: pending.time))
            } else {
                beginDistraction(at: pending.time)
            }
        }
    }

    private func beginDistraction(at time: TimeInterval) {
        switch distractionTracker.begin(at: time) {
        case .counted:
            distractionCount += 1
            phoneState = .distracted
            liveRoute.addEvent(.distraction, at: time, maxAge: Self.speedMaxAge)
            // Пишемо подію в CSV одразу, а не чекаємо наступного виміру
            appendEventRow(event: "Distraction", time: time)
            triggerHapticFeedback(style: .error)
        case .resumed:
            phoneState = .distracted
            appendEventRow(event: "DistractionResume", time: time)
        case .ignored, .alreadyActive:
            break
        }
    }

    // Водій повернувся: фіксуємо тривалість і штраф за неї (у рядку
    // DistractionEnd колонка Score вже враховує цей штраф)
    func endDistraction(at time: TimeInterval, stopOnError: Bool = true) {
        guard distractionTracker.end(at: time) != nil else { return }
        handheldCallEpisode = false
        distractionSeconds = distractionTracker.totalDuration
        distractionDurationPenalty = distractionTracker.durationPenalty
        appendRow(event: "DistractionEnd", time: time, isSample: false, stopOnError: stopOnError)
    }

    @objc func appEnteredBackground() {
        guard isRecording else { return }
        if let error = csvWriter.flush() {
            stopRecording(reason: error)
        }
    }

    @objc func appGainedFocus() {
        DispatchQueue.main.async { [weak self] in
            self?.handleFocusGained()
        }
    }

    private func handleFocusGained() {
        guard isRecording else { return }
        resolvePendingFocusLoss()
        if backgroundRecording {
            applyScreenActions(screenTracker.focusGained(at: sessionTime()))
            if phoneState == .screenOff {
                phoneState = callInProgress ? .onCall : .recording
            }
        }
        // Відволікання через розмову біля вуха закінчується разом із розмовою
        if !handheldCallEpisode {
            endDistraction(at: sessionTime())
        }
        updateCallState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self = self, self.isRecording, !self.distractionTracker.isActive else { return }
            if self.isCalibrating || self.calibration == nil {
                self.phoneState = .calibrating
            } else {
                self.phoneState = self.callInProgress ? .onCall : .recording
            }
        }
    }

    // MARK: - Запис із вимкненим екраном

    @objc func deviceLocked() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRecording, self.backgroundRecording else { return }
            self.applyScreenActions(self.screenTracker.deviceLocked(at: self.sessionTime()))
        }
    }

    @objc func deviceUnlocked() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRecording, self.backgroundRecording else { return }
            self.applyScreenActions(self.screenTracker.deviceUnlocked(at: self.sessionTime()))
        }
    }

    /// Відкладені рішення ScreenLockTracker; викликається з кожним виміром
    func checkScreenState(time: TimeInterval) {
        guard backgroundRecording else { return }
        applyScreenActions(screenTracker.tick(at: time))
    }

    private func applyScreenActions(_ actions: [ScreenAction]) {
        for action in actions {
            switch action {
            case .screenLocked(let time):
                appendEventRow(event: "ScreenLocked", time: time)
                if !distractionTracker.isActive, !callInProgress {
                    phoneState = .screenOff
                }
            case .screenUnlocked(let time):
                appendEventRow(event: "ScreenUnlocked", time: time)
            case .beginDistraction(let time):
                // Під час першого калібрування штрафів немає (див. distractionsPaused)
                if !distractionsPaused {
                    beginDistraction(at: time)
                }
            case .endDistraction(let time):
                endDistraction(at: time)
                if screenTracker.isLocked, !callInProgress {
                    phoneState = .screenOff
                }
            }
        }
    }

    // MARK: - Дзвінки (CallKit)

    // Звук розмови йде в динамік біля вуха: телефон у руці
    private var isReceiverRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInReceiver }
    }

    private var currentCallState: CallState {
        let calls = callObserver.calls.filter { !$0.hasEnded }
        guard !calls.isEmpty else { return .none }
        if calls.contains(where: { $0.hasConnected || $0.isOutgoing }) {
            return .active(handheld: isReceiverRoute)
        }
        return .incomingRinging
    }

    // Делегат викликається в головній черзі (див. init)
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        updateCallState()
    }

    // Звіряє стан дзвінка із записаним: початок і кінець розмови, телефон біля вуха
    func updateCallState() {
        guard isRecording else {
            callInProgress = false
            callStartedAt = nil
            return
        }
        let now = sessionTime()
        switch currentCallState {
        case .none, .incomingRinging:
            guard callInProgress else { return }
            callInProgress = false
            callStartedAt = nil
            if handheldCallEpisode {
                endDistraction(at: now)
            }
            appendEventRow(event: "CallEnd", time: now)
            if phoneState == .onCall {
                phoneState = .recording
            }
        case .active(let handheld):
            if !callInProgress {
                callInProgress = true
                callStartedAt = now
                appendEventRow(event: handheld ? "CallStart_Handheld" : "CallStart", time: now)
                if phoneState != .distracted, !isCalibrating {
                    phoneState = .onCall
                }
            }
            // Розмова з телефоном біля вуха - відволікання (поки звук не перемкнули
            // на гучний звʼязок чи гарнітуру)
            if handheld, !distractionTracker.isActive, !distractionsPaused {
                beginDistraction(at: now)
                handheldCallEpisode = distractionTracker.isActive
            } else if !handheld, handheldCallEpisode {
                endDistraction(at: now)
                if phoneState == .distracted {
                    phoneState = .onCall
                }
            }
        }
    }
}
