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
    enum Phase { case intro, baseline, collecting, trial }
    @Published private(set) var phase: Phase = .intro
    @Published private(set) var completedSwings = 0
    @Published private(set) var trialCount = 0
    @Published private(set) var telemetry = MotionTelemetry.idle
    @Published private(set) var feedback = "用三次舒服的自然挥动，找到你的挥幅。"
    @Published private(set) var candidate: MotionCalibrationProfile?
    let hapticsEnabled: Bool
    let savedProfile: MotionCalibrationProfile?
    private let driver = MotionDriver()
    private var runID = UUID()
    private var lastAnnouncement = ""

    init(hapticsEnabled: Bool) {
        self.hapticsEnabled = hapticsEnabled
        savedProfile = WristCalibrationStore.load()
    }

    func start() {
        stop()
        phase = .baseline; completedSwings = 0; trialCount = 0; candidate = nil
        telemetry = .idle
        feedback = "先放松手腕，静止片刻。"
        announce(feedback)
        let id = UUID(); runID = id
        driver.startCalibration(update: { [weak self] update in
            guard let self, self.runID == id, self.phase != .trial, self.phase != .intro else { return }
            self.apply(update)
        }, failure: { [weak self] message in
            guard let self, self.runID == id else { return }
            self.fail(message)
        })
    }

    private func apply(_ update: WristLearningUpdate) {
        telemetry = update.telemetry
        let previous = completedSwings
        completedSwings = update.completedSwings
        phase = update.stage == .baseline ? .baseline : .collecting
        switch update.feedback {
        case .holdStill: feedback = "先放松手腕，静止片刻。"
        case .moveComfortably: feedback = "自然挥一下，再放松；不用刻意加大力气。"
        case .relaxBetween: feedback = "这一挥后放松片刻，再做下一次。"
        case .tooSmall: feedback = "这次幅度还不够清楚，稍微动大一点再试。"
        case .recorded: feedback = "已记住第 \(completedSwings) 次 · 放松一下"
        case .complete: feedback = "三次已记住，接下来试挥。"
        }
        if completedSwings > previous { touch(.click) }
        announce(feedback)
        if let profile = update.candidate, profile.isValid { beginTrial(profile) }
    }

    private func beginTrial(_ profile: MotionCalibrationProfile) {
        candidate = profile; phase = .trial; trialCount = 0
        feedback = "先放松一下，再按舒服的幅度试挥。"
        announce(feedback)
        let id = UUID(); runID = id
        driver.start(sensitivity: .high, assisted: true, calibration: profile,
                     state: { _, _ in }, strum: { [weak self] _ in
            guard let self, self.runID == id, self.phase == .trial else { return }
            self.trialCount += 1
            self.feedback = "接住了 · 已试挥 \(self.trialCount) 次"
            self.announce(self.feedback)
            self.touch(.click)
        }, failure: { [weak self] message in
            guard let self, self.runID == id else { return }
            self.fail(message)
        }, telemetry: { [weak self] value in
            guard let self, self.runID == id, self.phase == .trial else { return }
            self.telemetry = value
        })
        // A progress click may still be vibrating while the new detector starts.
        driver.suppressGestures(for: 0.55)
    }

    func save() -> MotionCalibrationProfile? {
        guard trialCount > 0, let candidate, WristCalibrationStore.save(candidate) else {
            feedback = "先试挥成功一次，再保存；保存失败时请重试。"
            announce(feedback)
            return nil
        }
        stop()
        return candidate
    }

    func stop() { runID = UUID(); driver.stop() }

    func interrupted() {
        guard phase != .intro else { return }
        stop(); phase = .intro; candidate = nil; telemetry = .idle
        feedback = "采集已停止，准备好后重新开始。"
        announce(feedback)
    }

    private func fail(_ message: String) {
        stop(); phase = .intro; candidate = nil; telemetry = .idle
        feedback = message; announce(message)
    }

    private func touch(_ kind: WKHapticType) {
        guard hapticsEnabled, WKApplication.shared().applicationState == .active else { return }
        driver.suppressGestures(for: 0.45)
        WKInterfaceDevice.current().play(kind)
    }

    private func announce(_ message: String) {
        guard message != lastAnnouncement else { return }
        lastAnnouncement = message
        AccessibilityNotification.Announcement(message).post()
    }
}

/// Present as a sheet only after pausing PerformanceModel. A cancelled sheet
/// never modifies saved thresholds; a successful save/reset calls onSaved.
@MainActor
struct WristCalibrationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var calibration: WristCalibration
    @State private var confirmReset = false
    @State private var showingMotion = false
    private let onSaved: (MotionCalibrationProfile?) -> Void

    init(hapticsEnabled: Bool, onSaved: @escaping (MotionCalibrationProfile?) -> Void) {
        _calibration = StateObject(wrappedValue: WristCalibration(hapticsEnabled: hapticsEnabled))
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 13) {
                    if calibration.phase == .intro { intro }
                    else { activeCalibration }
                    Text(calibration.hapticsEnabled ? "演奏振动已开启" : "演奏振动已关闭")
                        .font(.system(size: 11)).foregroundStyle(watchSilver)
                    if calibration.phase != .intro {
                        Button("重新来三次", action: calibration.start)
                            .font(.system(size: 12, weight: .medium))
                            .buttonStyle(SessionSecondaryButtonStyle())
                    }
                    Button("取消") { calibration.stop(); dismiss() }
                        .font(.system(size: 12)).frame(minHeight: 38).buttonStyle(.plain)
                }
                .padding(.horizontal, 9).padding(.bottom, 12)
            }
            .navigationTitle("个人挥幅")
            .background { SessionBackdrop(subdued: true) }
        }
        .tint(watchPearl)
        .foregroundStyle(watchPearl)
        .onDisappear { calibration.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { calibration.interrupted() }
        }
        .confirmationDialog("恢复默认挥幅？", isPresented: $confirmReset) {
            Button("恢复默认", role: .destructive) {
                calibration.stop(); WristCalibrationStore.reset(); onSaved(nil); dismiss()
            }
            Button("保留个人挥幅", role: .cancel) {}
        } message: { Text("这会移除已保存的个人校准。") }
    }

    private var intro: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.wave")
                .font(.system(size: 30, weight: .light)).padding(.top, 5)
                .accessibilityHidden(true)
            Text("找到舒服的挥幅")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("按平时的方式戴好手表。自然挥三次，每次之间放松一下。")
                .font(.system(size: 12)).foregroundStyle(watchSilver)
                .multilineTextAlignment(.center)
            Button("开始校准", action: calibration.start)
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(SessionPrimaryButtonStyle())
            Text(calibration.savedProfile == nil ? "保存后，两种弹奏模式都能用。" : "已有个人挥幅；保存新的校准后才会替换。")
                .font(.system(size: 11)).foregroundStyle(watchSilver)
                .multilineTextAlignment(.center)
            if calibration.savedProfile != nil {
                Button("恢复默认挥幅", role: .destructive) { confirmReset = true }
                    .font(.system(size: 11)).frame(minHeight: 36)
            }
            if !calibration.feedback.isEmpty {
                Text(calibration.feedback).font(.system(size: 11)).foregroundStyle(watchSilver)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var activeCalibration: some View {
        VStack(spacing: 12) {
            Text(calibration.phase == .baseline ? "先放松手腕" : (calibration.phase == .trial ? "试挥看看" : "自然挥一下"))
                .font(.system(size: 21, weight: .semibold, design: .rounded))
            if calibration.phase == .trial {
                Text("已接住 \(calibration.trialCount) 次")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .accessibilityLabel("已试挥成功 \(calibration.trialCount) 次")
            } else {
                HStack(spacing: 11) {
                    ForEach(0..<3) { index in
                        ZStack {
                            Circle().fill(watchPearl.opacity(index < calibration.completedSwings ? 1 : 0.12))
                            if index < calibration.completedSwings {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                            } else {
                                Text("\(index + 1)").font(.system(size: 13, weight: .medium))
                            }
                        }.frame(width: 32, height: 32)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("三次校准，已完成 \(calibration.completedSwings) 次")
            }

            WristStrings(energy: calibration.telemetry.strength, rotation: wristTurn)
                .frame(height: 28).padding(.horizontal, 6)
            Text(calibration.feedback)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.center)
                .accessibilityLabel("校准提示，\(calibration.feedback)")

            if calibration.phase == .trial {
                Button("保存这个手感") {
                    if let profile = calibration.save() { onSaved(profile); dismiss() }
                }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(SessionPrimaryButtonStyle())
                .disabled(calibration.trialCount == 0)
                .opacity(calibration.trialCount == 0 ? 0.45 : 1)
                Text("先试挥一次，满意再保存。两种弹奏模式都会使用这个挥幅。")
                    .font(.system(size: 11)).foregroundStyle(watchSilver).multilineTextAlignment(.center)
            }

            SessionDisclosure("动作反馈", isExpanded: $showingMotion) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("手腕转动")
                        Spacer(minLength: 2)
                        Text(String(format: "%.2f rad/s", calibration.telemetry.gyroMagnitude)).monospacedDigit()
                    }.font(.system(size: 11))
                    ProgressView(value: calibration.telemetry.gyroStrength)
                        .tint(watchPearl)
                        .accessibilityLabel("陀螺仪转动强度")
                        .accessibilityValue("\(Int(calibration.telemetry.gyroStrength * 100))%，每秒 \(String(format: "%.2f", calibration.telemetry.gyroMagnitude)) 弧度")
                    HStack {
                        Text("挥动力度")
                        Spacer(minLength: 2)
                        Text("\(Int(calibration.telemetry.strength * 100))%")
                    }.font(.system(size: 11))
                    ProgressView(value: calibration.telemetry.strength).accessibilityLabel("挥动用力反馈")
                }.padding(.top, 7)
            }
            .font(.system(size: 11)).foregroundStyle(watchSilver)
        }
    }

    private var wristTurn: Double {
        let readings = [calibration.telemetry.gyroX, calibration.telemetry.gyroY, calibration.telemetry.gyroZ]
        let strongest = readings.max(by: { abs($0) < abs($1) }) ?? 0
        return min(1, max(-1, strongest / 2.5))
    }
}
