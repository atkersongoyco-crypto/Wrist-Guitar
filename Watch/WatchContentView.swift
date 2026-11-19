import AirGuitarCore
import SwiftUI

let watchSilver = Color(red: 0.78, green: 0.80, blue: 0.84)
let watchPearl = Color(red: 0.93, green: 0.94, blue: 0.96)

/// A quiet cover treatment shared by the player and its supporting sheets.
struct SessionBackdrop: View {
    var fileURL: URL? = nil
    var subdued = false

    var body: some View {
        GeometryReader { geometry in
            LocalTrackArtwork(fileURL: fileURL) {
                Image("SessionCover").resizable().scaledToFill()
            }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay(Color.black.opacity(subdued ? 0.78 : 0.48))
                .overlay {
                    LinearGradient(colors: [SessionPalette.kleinBlue.opacity(subdued ? 0.12 : 0.24), .black.opacity(0.42), .black.opacity(0.92)],
                                   startPoint: .top, endPoint: .bottom)
                }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct SessionPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(SessionPalette.sage.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}

struct SessionSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(watchPearl)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.white.opacity(configuration.isPressed ? 0.20 : 0.10), in: RoundedRectangle(cornerRadius: 17))
    }
}

/// watchOS has no DisclosureGroup; this keeps supporting details reachable
/// without adding another permanent instrument panel to the player.
struct SessionDisclosure<Content: View>: View {
    let title: String
    @Binding private var isExpanded: Bool
    private let content: Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button { isExpanded.toggle() } label: {
                HStack {
                    Text(title)
                    Spacer(minLength: 2)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            if isExpanded { content }
        }
    }
}

struct WatchContentView: View {
    @EnvironmentObject private var game: WatchGameController
    @EnvironmentObject private var model: PerformanceModel
    @EnvironmentObject private var round: RhythmRound
    @EnvironmentObject private var library: WatchSongLibrary
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var page = 0
    @State private var choosingForChallenge = false
    @State private var presentedSheet: PlayerSheet?
    @State private var feelOpenedFromSettings = false
    @State private var restoredSelection = false
    @State private var requestDuringSong: SongPreparation?
    @AppStorage("WristGuitar.crownVolumeEnabled") private var crownVolumeEnabled = true

    private enum PlayerSheet: String, Identifiable {
        case library, settings, feel, calibration
        var id: String { rawValue }
    }

    private var playingRequest: SongPreparation? {
        guard model.isRunning || model.isStarting, library.preparation?.state == .waiting else { return nil }
        return library.preparation?.request
    }

    private var pendingSelection: SongPreparation? {
        guard !game.presented, scenePhase == .active, presentedSheet == nil, !model.isRunning, !model.isStarting,
              let preparation = library.preparation, preparation.state == .waiting,
              library.songs.contains(where: { $0.id == preparation.request.id }) else { return nil }
        switch round.phase {
        case .ready:
            // Keep a song that was playing when the request arrived resumable.
            // An explicit phone selection made after the player was already idle
            // can replace an old paused song immediately.
            guard requestDuringSong != preparation.request || model.elapsed == 0 || !model.automaticBacking
            else { return nil }
        case .finished:
            guard page == 0 else { return nil }
        case .paused:
            guard page == 0, requestDuringSong != preparation.request else { return nil }
        default: return nil
        }
        return preparation.request
    }

    var body: some View {
        Group {
            if game.presented { WatchGameScreen(game: game) }
            else { playerPages }
        }
        .onChange(of: game.presented) { _, opened in
            if opened { presentedSheet = nil; model.error = nil }
        }
    }

    private var playerPages: some View {
        let wristDown = isLuminanceReduced && presentedSheet == nil
        let canAdjustVolume = crownVolumeEnabled && scenePhase == .active
            && !wristDown && presentedSheet == nil && model.error == nil
        return TabView(selection: $page) {
            PerformancePage(isFrontmost: page == 0 && presentedSheet == nil && !wristDown && scenePhase == .active,
                            showsCrownVolume: canAdjustVolume && page == 0 && model.isRunning,
                            chooseSong: { openLibrary(forChallenge: false) },
                            settings: { presentedSheet = .settings }, feel: { openFeel(fromSettings: false) },
                            challenge: { page = 1 }, liveGame: game.open).tag(0)
            RhythmChallengePage(isFrontmost: page == 1 && presentedSheet == nil,
                                showsCrownVolume: canAdjustVolume && page == 1 &&
                                    (round.phase == .countdown || round.phase == .playing),
                                chooseSong: { openLibrary(forChallenge: true) },
                                returnToPlayer: { page = 0 }, settings: { presentedSheet = .settings }).tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .tint(watchPearl)
        .background(Color.black)
        .opacity(wristDown ? 0 : 1)
        .allowsHitTesting(!wristDown)
        .accessibilityHidden(wristDown)
        .overlay {
            if wristDown {
                WristDownPlayer(isChallenge: page == 1)
            }
        }
        .onAppear {
            guard !restoredSelection else { return }
            restoredSelection = true
            if let preparation = library.preparation, preparation.state == .ready,
               let song = library.songs.first(where: { $0.id == preparation.request.id }),
               !model.isRunning, !model.isStarting, model.song?.id != song.id { model.select(song) }
        }
        .onChange(of: playingRequest, initial: true) { _, request in
            if let request { requestDuringSong = request }
        }
        .onChange(of: pendingSelection, initial: true) { _, request in
            guard let request, request == pendingSelection,
                  let song = library.songs.first(where: { $0.id == request.id }) else { return }
            model.select(song)
            page = 0
            library.finishPreparation(request)
        }
        .onChange(of: page) { previous, next in
            if (model.isRunning || model.isStarting), previous == 1 || next == 1 {
                model.pause(reason: "已暂停 · 点击继续")
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .library:
                SongPage(choosingForChallenge: choosingForChallenge, onSelect: {
                    library.manualSelection(model.song?.id)
                    page = choosingForChallenge ? 1 : 0
                    choosingForChallenge = false
                    presentedSheet = nil
                })
            case .settings:
                SettingsPage(calibrate: openCalibration, editFeel: { openFeel(fromSettings: true) },
                             crownVolumeEnabled: $crownVolumeEnabled)
            case .feel:
                RecordWatchFeelPanel(assisted: model.assisted, followsRecording: model.usesRecordingControls,
                                     calibrated: model.calibration != nil, close: closeFeel, choose: { assisted in
                    model.setAssisted(assisted)
                    closeFeel()
                }, calibrate: openCalibration)
            case .calibration:
                WristCalibrationView(model: model, hapticsEnabled: round.haptics)
            }
        }
        .alert("Wrist Guitar", isPresented: Binding(get: { model.error != nil }, set: {
            if !$0 { model.error = nil }
        })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func openLibrary(forChallenge: Bool) {
        choosingForChallenge = forChallenge
        presentedSheet = .library
    }

    private func openFeel(fromSettings: Bool) {
        feelOpenedFromSettings = fromSettings
        presentedSheet = .feel
    }

    private func closeFeel() {
        presentedSheet = feelOpenedFromSettings ? .settings : nil
    }

    private func openCalibration() {
        model.pause(reason: "校准后可继续演奏", notify: false)
        presentedSheet = .calibration
    }
}

private struct WristDownPlayer: View {
    @EnvironmentObject private var model: PerformanceModel
    @EnvironmentObject private var round: RhythmRound
    let isChallenge: Bool

    private var title: String {
        if isChallenge && round.phase != .ready {
            if round.source == .speaker { return "外放跟拍" }
            if round.source == .taps { return "点拍挑战" }
        }
        return model.song?.title ?? (model.externalMusic ? "跟外部音乐" : "空场练习")
    }

    private var detail: String {
        if isChallenge {
            switch round.phase {
            case .ready: return "准备挑战"
            case .analyzing: return "正在听拍"
            case .countdown: return "准备开始"
            case .playing: return "抬腕继续计分"
            case .paused: return model.isRunning ? "抬腕继续计分" : "已暂停"
            case .finished: return "本轮完成"
            }
        }
        if model.isStarting { return "正在准备" }
        if model.isRunning { return model.automaticBacking && model.song != nil ? "伴奏播放中" : "弹奏中" }
        return model.status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(isChallenge ? "节奏挑战" : "自由弹奏", systemImage: "guitars")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .lineLimit(2)
            HStack {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if model.isRunning {
                    Spacer(minLength: 2)
                    Button { model.pause() } label: {
                        Image(systemName: "pause")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("暂停演奏")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .background { Color.black.ignoresSafeArea() }
    }
}

private struct PerformancePage: View {
    @EnvironmentObject private var model: PerformanceModel
    let isFrontmost: Bool
    let showsCrownVolume: Bool
    let chooseSong: () -> Void
    let settings: () -> Void
    let feel: () -> Void
    let challenge: () -> Void
    let liveGame: () -> Void

    @AppStorage("WristGuitar.didShowWristGuide") private var didShowWristGuide = false
    @State private var showsGuide = false
    @State private var showingOptions = false

    private var active: Bool { isFrontmost && model.isRunning && !showingOptions }
    private var showsChord: Bool { !model.usesSongPick && !model.usesRecordingControls }

    var body: some View {
        RecordWatchFace(title: model.song?.title ?? (model.externalMusic ? "跟外部音乐" : "空场练习"),
                        status: model.status, chord: showsChord ? model.instrumentLabel : nil,
                        elapsed: model.elapsed, duration: model.automaticBacking ? model.song?.duration : nil,
                        showsHint: showsGuide, running: model.isRunning, starting: model.isStarting,
                        frontmost: isFrontmost && !showingOptions, strokeCount: model.strumCount,
                        options: { showingOptions = true }, chooseSong: chooseSong,
                        skip: { showsGuide = false }, audition: model.audition,
                        toggle: { Task { await model.toggle() } }) {
            if showsCrownVolume && !showingOptions {
                CrownVolumeControl(volume: $model.masterVolume)
                    .foregroundStyle(RecordWatchInk.secondary)
            }
        } strings: {
            ZStack(alignment: .trailing) {
                LiveRecordWatchString(playedCount: model.strumCount, active: active,
                                      strength: model.lastPickStrength ?? 0.60)
                if showsChord {
                    WristMotionIndicator(rotation: model.wristTurn, strength: model.strength,
                                         ink: RecordWatchInk.secondary)
                        .frame(width: 32).padding(.trailing, 13)
                }
            }
        }
        .onChange(of: active, initial: true) { _, active in
            if active && !didShowWristGuide {
                didShowWristGuide = true
                showsGuide = true
            } else if !active {
                showsGuide = false
            }
        }
        .onChange(of: model.strumCount) { old, new in
            if new > old { showsGuide = false }
        }
        .confirmationDialog("演奏选项", isPresented: $showingOptions) {
            Button("双端音游", action: liveGame)
            Button("打开曲库", action: chooseSong)
            Button("节奏挑战", action: challenge)
            Button("演奏手感", action: feel).disabled(model.isStarting)
            Button("回到歌曲开头", action: model.rewind).disabled(model.isStarting)
            Button("更多设置", action: settings)
            Button("取消", role: .cancel) {}
        }
    }
}

struct CrownVolumeControl: View {
    @Binding var volume: Double
    @FocusState private var hasCrownFocus: Bool

    var body: some View {
        VStack(spacing: 1) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(volume, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
        }
        .frame(minWidth: 32, minHeight: 36)
        .contentShape(Rectangle())
        .focusable()
        .focused($hasCrownFocus)
        .digitalCrownRotation(detent: $volume, from: 0, through: 1, by: 0.05,
                              sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: false)
        .onTapGesture { hasCrownFocus = true }
        .task {
            await Task.yield()
            if !Task.isCancelled { hasCrownFocus = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("总音量")
        .accessibilityValue(Text(volume, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume = min(1, volume + 0.05)
            case .decrement: volume = max(0, volume - 0.05)
            @unknown default: break
            }
        }
    }
}

/// A restrained, explicitly labelled sensor indicator. Fixed brightness and a
/// neutral dead zone keep it distinct from the strings' sound confirmation.
struct WristMotionIndicator: View {
    let rotation: Double
    var strength: Double = 0
    var showsStrength = true
    var ink = watchSilver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var turn: Double {
        guard rotation.isFinite, abs(rotation) >= 0.08 else { return 0 }
        return min(1, max(-1, rotation))
    }

    private var intensity: Double {
        guard showsStrength, strength.isFinite, strength >= 0.08 else { return 0 }
        return min(1, max(0, strength))
    }

    private var strengthLabel: String {
        if intensity == 0 && turn == 0 { return "静" }
        return intensity >= 0.65 ? "强" : "轻"
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(showsStrength ? "动作" : "转腕").font(.system(size: 8, weight: .medium))
            if reduceMotion {
                Text(strengthLabel).font(.system(size: 8)).frame(width: 28, height: 4)
            } else {
                ZStack {
                    Capsule().fill(ink.opacity(0.22)).frame(height: 2)
                    if showsStrength {
                        Capsule().fill(ink.opacity(0.45))
                            .frame(width: 28 * intensity, height: 2)
                    }
                    Circle().fill(ink.opacity(0.65))
                        .frame(width: 3 + intensity * 2, height: 3 + intensity * 2)
                        .offset(x: turn * 11)
                }
                .frame(width: 28, height: 4)
            }
        }
        .foregroundStyle(ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsStrength ? "手腕动作，不表示已经拨弦" : "转腕动作，不表示已经拨弦")
        .accessibilityValue(intensity == 0 && turn == 0 ? "静止" : (showsStrength ? "检测到动作，\(Int(intensity * 100))%" : "检测到转腕"))
    }
}

private struct SongPage: View {
    @EnvironmentObject private var library: WatchSongLibrary
    @EnvironmentObject private var model: PerformanceModel
    let choosingForChallenge: Bool
    let onSelect: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let practice = WatchSong.practice {
                    Button {
                        model.select(practice)
                        onSelect()
                    } label: {
                        VStack(alignment: .leading) {
                            Text("随手练习").font(.headline)
                            Text("内置伴奏 · 20 秒").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if library.songs.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "iphone.and.arrow.forward").foregroundStyle(watchPearl)
                        Text("把你的歌带过来").font(.headline)
                        Text("在 iPhone 导入一首歌，它会自动送到这里。也可以在手机曲库点“用手表弹”。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
                ForEach(library.songs) { song in
                    Button {
                        model.select(song)
                        onSelect()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.title).font(.headline).lineLimit(2)
                                let queued = library.preparation?.state == .waiting && library.preparation?.request.id == song.id
                                Text(queued ? "下一首 · " + Self.duration(song.duration) : Self.duration(song.duration))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 2)
                            if model.song?.id == song.id { Image(systemName: "checkmark").foregroundStyle(watchPearl) }
                        }
                    }
                }.onDelete { indices in
                    let songs = indices.map { library.songs[$0] }
                    for song in songs {
                        if model.song?.id == song.id { model.select(nil) }
                        library.remove(song)
                    }
                }
                if !choosingForChallenge {
                    Button("空场练习") { model.select(nil); onSelect() }.font(.caption)
                    Button("跟外部音乐") { model.select(nil, external: true); onSelect() }.font(.caption)
                }
                if let message = library.message {
                    Text(message).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("曲库")
            .scrollContentBackground(.hidden)
            .listStyle(.carousel)
            .background { SessionBackdrop(subdued: true) }
        }
    }

    private static func duration(_ seconds: Double) -> String {
        "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))"
    }
}

private struct SettingsPage: View {
    let calibrate: () -> Void
    let editFeel: () -> Void
    @Binding var crownVolumeEnabled: Bool
    @EnvironmentObject private var model: PerformanceModel
    @EnvironmentObject private var round: RhythmRound
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("挑战提示音", isOn: $round.sounds)
                        .accessibilityHint("跟自己的歌曲挑战时，只在开始前的倒数发声。")
                    Toggle("演奏振动", isOn: $round.haptics)
                        .accessibilityHint("轻拨和重拨用两种触感回应。")
                    Toggle("鼓点轻震", isOn: $round.beatHaptics)
                        .disabled(!round.haptics)
                        .accessibilityHint("跟随伴奏的拍点轻震。节奏挑战中跟随目标拍。")
                    if round.haptics { Button("试一下振动") { round.touch(.click) } }
                } header: {
                    Text("声音与触感")
                } footer: {
                    Text("鼓点轻震会在手腕静止时提示节拍。想保留震感，可在手表控制中心开启静音模式。")
                }
                Section("演奏手感") {
                    Button(action: editFeel) {
                        HStack {
                            Text("演奏手感")
                            Spacer(minLength: 2)
                            Text(model.feelTitle)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                    }
                    .disabled(model.isStarting)
                    Button(model.calibration == nil ? "校准轻重手感" : "重新校准手感", action: calibrate)
                    Toggle("随演奏微调", isOn: $model.adaptiveDynamics)
                        .accessibilityHint("根据这一轮已弹出的轻拨和重拨，逐渐微调琴声和触感。")
                    if model.adaptiveDynamics {
                        Text("轻重交替弹过一段后，手表会跟着你微调力度。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if model.assisted && !model.usesSongPick && !model.usesRecordingControls && round.phase == .ready {
                        Toggle("一挥一小句", isOn: $model.addsAssistedReply)
                            .accessibilityHint("自由弹奏时，轻挥弹分解和弦，利落挥动弹扫弦。关闭后每挥只扫一次。")
                    }
                    if model.calibration == nil {
                        Picker("灵敏度", selection: $model.sensitivity) {
                            Text("低").tag(Sensitivity.low)
                            Text("中").tag(Sensitivity.medium)
                            Text("高").tag(Sensitivity.high)
                        }
                    }
                    if !model.assisted { Button("以当前手腕姿势校准", action: model.calibrate) }
                }
                Section("伴奏播放") {
                    Toggle("自由弹自动伴奏", isOn: Binding(get: { model.automaticBacking }, set: model.setAutomaticBacking))
                        .disabled(model.isStarting)
                    Button("回到歌曲开头", action: model.rewind)
                    Text("已拨弦 \(model.strumCount) 次").font(.caption).foregroundStyle(.secondary)
                }
                Section("声音平衡") {
                    Toggle("表冠调音量", isOn: $crownVolumeEnabled)
                        .accessibilityHint("演奏和挑战倒数时，转动数码表冠调整总音量。")
                    HStack {
                        Text("总音量")
                        Spacer()
                        Text(model.masterVolume, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    Slider(value: $model.masterVolume, in: 0...1, step: 0.05)
                        .accessibilityLabel("总音量")
                    Text(model.usesRecordingControls ? "拨动强度" : "演奏音量").font(.caption)
                    Slider(value: $model.guitarVolume, in: 0...1)
                        .accessibilityLabel(model.usesRecordingControls ? "拨动强度" : "演奏音量")
                    Text(model.usesRecordingControls ? "歌曲音量" : "伴奏音量").font(.caption)
                    Slider(value: $model.backingVolume, in: 0...1)
                        .accessibilityLabel(model.usesRecordingControls ? "歌曲音量" : "伴奏音量")
                    if !model.route.isEmpty { Text(model.route).font(.caption2).foregroundStyle(watchPearl) }
                }
                Section("弹奏小贴士") {
                    Text("跟自己的歌试试：在句尾轻挥两下，下一拍加重，再停手听原曲。")
                    Text("跟外部音乐时可以用闷音打节奏，空场练习每四挥换和弦。")
                    Text("双指互点两下：开始或暂停。请在系统设置开启此手势。")
                    Text("想在放下手腕时看到歌名，可在手表「设置 › 显示与亮度 › 全天候显示 › 显示 App」中开启 Wrist Guitar。")
                    Text("想让演奏页停留更久，可在「设置 › 通用 › 返回表盘 › Wrist Guitar」选择「自定义」，再选「1 小时后」。")
                    Text("手指连续动作暂不支持。S10 充电时请使用耳机播放。")
                }.font(.caption2)
            }
            .navigationTitle("更多")
            .scrollContentBackground(.hidden)
            .background { SessionBackdrop(subdued: true) }
        }
    }
}
