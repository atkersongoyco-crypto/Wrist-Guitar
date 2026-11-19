import Accessibility
import AirGuitarCore
import Combine
import Foundation
import SwiftUI
import WatchKit

enum WristCalibrationStore {
    static let key = "AirGuitar.wristCalibration.v1"

    static func load(defaults: UserDefaults = .standard) -> MotionCalibrationProfile? {
        guard let data = defaults.data(forKey: key),
              let profile = try? JSONDecoder().decode(MotionCalibrationProfile.self, from: data),
              profile.isValid else { return nil }
        return profile
    }

    @discardableResult
    static func save(_ profile: MotionCalibrationProfile, defaults: UserDefaults = .standard) -> Bool {
        guard profile.isValid, let data = try? JSONEncoder().encode(profile) else { return false }
        defaults.set(data, forKey: key)
        return load(defaults: defaults) == profile
    }

    static func reset(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

@MainActor
final class WristCalibration: ObservableObject {
    enum Phase { case intro, baseline, light, heavy, trial }
    enum Audition { case preparing, ready, unavailable }

    @Published private(set) var phase: Phase = .intro
    @Published private(set) var completedSwings = 0
    @Published private(set) var trialCount = 0
    @Published private(set) var lastPickStrength: Double?
    @Published private(set) var telemetry = MotionTelemetry.idle
    @Published private(set) var feedback = ""
    @Published private(set) var audition: Audition = .preparing
    @Published private(set) var auditionHint: String?
    let savedProfile = WristCalibrationStore.load()
    private let model: PerformanceModel
    private let driver = MotionDriver()
    private var candidate: MotionCalibrationProfile?
    private var runID = UUID()
    private var auditionTask: Task<Void, Never>?
    private var ownsAudition = false
    private var lastAnnouncement = ""
    private var recordedTotal = 0

    init(model: PerformanceModel) {
        self.model = model
    }

    func start() {
        stop()
        phase = .baseline
        completedSwings = 0
        recordedTotal = 0
        trialCount = 0
        lastPickStrength = nil
        candidate = nil
        telemetry = .idle
        feedback = "手腕放松，静止一小会儿。"
        announce(feedback)
        let id = runID
        driver.startCalibration(update: { [weak self] update in
            guard let self, self.runID == id else { return }
            self.apply(update)
        }, failure: { [weak self] message in
            guard let self, self.runID == id else { return }
            self.fail(message)
        })
    }

    private func apply(_ update: WristLearningUpdate) {
        telemetry = update.telemetry
        if let profile = update.candidate, profile.isValid {
            beginTrial(profile)
            return
        }
        switch update.stage {
        case .baseline: phase = .baseline
        case .collecting: phase = .light
        case .collectingAccents: phase = .heavy
        case .completed: return
        }
        if update.completedSwings > recordedTotal, model.round.haptics,
           WKApplication.shared().applicationState == .active {
            driver.suppressGestures(for: 0.30)
            model.round.touch(.click)
        }
        recordedTotal = update.completedSwings
        completedSwings = max(0, update.completedSwings - (phase == .heavy ? 3 : 0))
        switch update.feedback {
        case .holdStill: feedback = "手腕放松，静止一小会儿。"
        case .moveComfortably, .complete:
            feedback = phase == .heavy ? "用舒服的大幅度挥一下，再放松。" : "像轻轻拨一下弦，挥完就放松。"
        case .relaxBetween: feedback = "挥完放松，等这一挥记下来。"
        case .tooSmall: feedback = "再稍微挥大一些，让手表看清这一下。"
        case .recorded:
            feedback = completedSwings == 0 ? "接下来试一试舒服的大幅度。" : "记住了，再来一下。"
        case .needsMoreContrast: feedback = "轻重幅度太接近。保留轻挥，请把这组三次挥得稍大些。"
        }
        announce(feedback)
    }

    private func beginTrial(_ profile: MotionCalibrationProfile) {
        candidate = profile
        phase = .trial
        runID = UUID()
        let id = runID
        feedback = "交替试试轻拨和重拨。"
        announce(feedback)
        prepareAudition()
        driver.start(sensitivity: model.sensitivity, assisted: model.assisted, calibration: profile,
                     allowsWristReversals: model.usesSongPick, state: { _, _ in }, strum: { [weak self] event in
            guard let self, self.runID == id, self.phase == .trial else { return }
            self.preview(event)
        }, failure: { [weak self] message in
            guard let self, self.runID == id else { return }
            self.fail(message)
        }, telemetry: { [weak self] value in
            guard let self, self.runID == id, self.phase == .trial else { return }
            self.telemetry = value
        })
    }

    func prepareAudition() {
        guard phase == .trial else { return }
        let id = runID
        audition = .preparing
        auditionHint = "正在准备琴声…"
        ownsAudition = true
        auditionTask?.cancel()
        auditionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.model.beginCalibrationAudition()
                guard !Task.isCancelled, self.runID == id else { return }
                self.audition = .ready
                self.auditionHint = self.model.guitarVolume == 0 ? "演奏音量为零，可在「更多」中调整。" : nil
            } catch {
                guard !Task.isCancelled, self.runID == id else { return }
                self.audition = .unavailable
                self.auditionHint = self.model.guitarVolume == 0
                    ? "演奏音量为零。仍可看力度并保存。"
                    : "试听声音暂不可用。仍可看力度并保存。"
            }
        }
    }

    private func preview(_ event: StrumEvent) {
        guard audition != .preparing, WKApplication.shared().applicationState == .active else { return }
        trialCount += 1
        let previous = lastPickStrength
        lastPickStrength = event.pickStrength
        if audition == .ready {
            let played = model.playCalibrationStroke(event, onHaptic: { [weak self] kind in
                self?.driver.prepareForBeatHaptic(window: kind == .click ? 0.12 : 0.18)
            })
            if !played && model.guitarVolume > 0 {
                audition = .unavailable
                auditionHint = "试听中断。可重新打开声音，或先保存手感。"
            }
        }
        let isHeavy = event.pickStrength >= SongPickVoice.accentThreshold
        if previous.map({ $0 >= SongPickVoice.accentThreshold }) != isHeavy {
            announce(isHeavy ? "重拨" : "轻拨")
        }
    }

    func save() -> MotionCalibrationProfile? {
        guard phase == .trial, trialCount > 0, let candidate else { return nil }
        guard WristCalibrationStore.save(candidate) else {
            feedback = "保存失败，请再试一次。"
            announce(feedback)
            return nil
        }
        stop()
        return candidate
    }

    func stop() {
        runID = UUID()
        driver.stop()
        auditionTask?.cancel()
        auditionTask = nil
        if ownsAudition {
            ownsAudition = false
            model.endCalibrationAudition()
        }
    }

    func interrupted() {
        guard phase != .intro else { return }
        fail("已暂停校准，准备好后重新开始。")
    }

    private func fail(_ message: String) {
        stop()
        phase = .intro
        telemetry = .idle
        candidate = nil
        feedback = message
        announce(message)
    }

    private func announce(_ message: String) {
        guard message != lastAnnouncement else { return }
        lastAnnouncement = message
        AccessibilityNotification.Announcement(message).post()
    }
}

@MainActor
struct WristCalibrationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var calibration: WristCalibration
    @State private var confirmReset = false
    private let onSaved: (MotionCalibrationProfile?) -> Void
    private let hapticsEnabled: Bool

    init(model: PerformanceModel, hapticsEnabled: Bool) {
        _calibration = StateObject(wrappedValue: WristCalibration(model: model))
        self.onSaved = model.applyCalibration
        self.hapticsEnabled = hapticsEnabled
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(spacing: 10) {
                        if calibration.phase == .intro { intro }
                        else if calibration.phase == .trial { trial }
                        else { collecting }
                        if calibration.phase != .intro {
                            Button("重新校准", action: calibration.start)
                                .buttonStyle(SessionSecondaryButtonStyle())
                        }
                        Button("取消") { calibration.stop(); dismiss() }
                            .font(.caption).buttonStyle(.plain).frame(minHeight: 38)
                    }
                    .id("top")
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8).padding(.bottom, 8)
                }
                .onChange(of: calibration.phase) { _, _ in reader.scrollTo("top", anchor: .top) }
            }
            .navigationTitle("手感校准")
            .background { SessionBackdrop(subdued: true) }
        }
        .tint(watchPearl)
        .foregroundStyle(watchPearl)
        .onDisappear { calibration.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { calibration.interrupted() }
        }
        .confirmationDialog("恢复默认手感？", isPresented: $confirmReset) {
            Button("恢复默认", role: .destructive) {
                calibration.stop()
                WristCalibrationStore.reset()
                onSaved(nil)
                dismiss()
            }
            Button("保留个人手感", role: .cancel) {}
        } message: { Text("这会移除已保存的个人校准。") }
    }

    private var intro: some View {
        Group {
            Image(systemName: "hand.wave").font(.system(size: 25, weight: .light)).accessibilityHidden(true)
            Text("找到你的轻重手感")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("先轻挥三次，再用舒服的大幅度挥三次。最后可以听着琴声试拨。")
                .font(.caption).foregroundStyle(watchSilver)
            Button("开始校准", action: calibration.start)
                .buttonStyle(SessionPrimaryButtonStyle())
            if !calibration.feedback.isEmpty {
                Text(calibration.feedback).font(.caption).foregroundStyle(watchPearl)
            }
            if calibration.savedProfile != nil {
                Text("保存时会替换上次的手感。").font(.caption2).foregroundStyle(watchSilver)
                Button("恢复默认手感", role: .destructive) { confirmReset = true }
                    .font(.caption2)
            }
        }
    }

    private var collecting: some View {
        VStack(spacing: 12) {
            Text(calibration.phase == .baseline ? "先静止片刻" : (calibration.phase == .light ? "轻轻挥三次" : "幅度大一些"))
                .font(.system(size: 21, weight: .semibold, design: .rounded))
            if calibration.phase != .baseline {
                HStack(spacing: 9) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(watchPearl.opacity(i < calibration.completedSwings ? 1 : 0.18))
                            .frame(width: 12, height: 12)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("已记录 \(calibration.completedSwings) 次，共三次")
            }
            ProgressView(value: calibration.telemetry.strength)
                .tint(watchSilver)
                .accessibilityLabel("当前手腕动作")
            Text(calibration.feedback).font(.caption).foregroundStyle(watchSilver)
        }
    }

    private var trial: some View {
        VStack(spacing: 8) {
            let strength = calibration.lastPickStrength
            let label = strength.map { $0 >= SongPickVoice.accentThreshold ? "重拨" : "轻拨" } ?? "试拨一下"
            HStack(spacing: 12) {
                Text(label).font(.system(size: 24, weight: .semibold, design: .rounded))
                WristMotionIndicator(rotation: wristTurn, showsStrength: false)
            }
            ProgressView(value: strength ?? 0)
                .tint(watchPearl)
                .accessibilityLabel("上一次拨奏的力度")
                .accessibilityValue("\(Int(((strength ?? 0) * 100).rounded()))%")
            HStack {
                Text("轻")
                Spacer()
                Text("重")
            }.font(.caption2).foregroundStyle(watchSilver)
            Text(calibration.feedback).font(.caption)
            if calibration.trialCount > 0 {
                Text("已试拨 \(calibration.trialCount) 次").font(.caption2).foregroundStyle(watchSilver)
            }
            if let hint = calibration.auditionHint {
                Text(hint).font(.caption2).foregroundStyle(watchSilver)
                if calibration.audition == .unavailable {
                    Button("重试声音", action: calibration.prepareAudition)
                        .font(.caption).buttonStyle(SessionSecondaryButtonStyle())
                }
            }
            Button("保存手感") {
                if let profile = calibration.save() { onSaved(profile); dismiss() }
            }
            .buttonStyle(SessionPrimaryButtonStyle())
            .disabled(calibration.trialCount == 0)
            Text(hapticsEnabled ? "演奏触感已开启" : "演奏触感已关闭")
                .font(.caption2).foregroundStyle(watchSilver)
        }
    }

    private var wristTurn: Double {
        let motion = calibration.telemetry
        let xy = abs(motion.gyroX) > abs(motion.gyroY) ? motion.gyroX : motion.gyroY
        let axis = abs(xy) > abs(motion.gyroZ) ? xy : motion.gyroZ
        return axis < 0 ? -motion.gyroStrength : motion.gyroStrength
    }
}
