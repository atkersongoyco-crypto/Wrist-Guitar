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
                    LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.42), .black.opacity(0.92)],
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
            .background(watchPearl.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
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
    @EnvironmentObject private var model: PerformanceModel
    @EnvironmentObject private var round: RhythmRound
    @EnvironmentObject private var library: WatchSongLibrary
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = 0
    @State private var choosingForChallenge = false
    @State private var presentedSheet: PlayerSheet?
    @State private var restoredSelection = false
    @State private var requestDuringSong: SongPreparation?

    private enum PlayerSheet: String, Identifiable {
        case library, settings, calibration
        var id: String { rawValue }
    }

    private var playingRequest: SongPreparation? {
        guard model.isRunning || model.isStarting, library.preparation?.state == .waiting else { return nil }
        return library.preparation?.request
    }

    private var pendingSelection: SongPreparation? {
        guard scenePhase == .active, presentedSheet == nil, !model.isRunning, !model.isStarting,
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
        TabView(selection: $page) {
            PerformancePage(isFrontmost: page == 0 && presentedSheet == nil,
                            chooseSong: { openLibrary(forChallenge: false) },
                            settings: { presentedSheet = .settings }, challenge: { page = 1 }).tag(0)
            RhythmChallengePage(isFrontmost: page == 1 && presentedSheet == nil,
                                chooseSong: { openLibrary(forChallenge: true) },
                                returnToPlayer: { page = 0 }, settings: { presentedSheet = .settings }).tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .tint(watchPearl)
        .background(Color.black)
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
                SettingsPage(calibrate: openCalibration)
            case .calibration:
                WristCalibrationView(hapticsEnabled: round.haptics, onSaved: model.applyCalibration)
            }
        }
        .alert("空气吉他", isPresented: Binding(get: { model.error != nil }, set: {
            if !$0 { model.error = nil }
        })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func openLibrary(forChallenge: Bool) {
        choosingForChallenge = forChallenge
        presentedSheet = .library
    }

    private func openCalibration() {
        model.pause(reason: "校准后可继续演奏", notify: false)
        presentedSheet = .calibration
    }
}

private struct PerformancePage: View {
    @EnvironmentObject private var model: PerformanceModel
    let isFrontmost: Bool
    let chooseSong: () -> Void
    let settings: () -> Void
    let challenge: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 225
            ScrollView {
                VStack(spacing: compact ? 3 : 6) {
                    HStack(spacing: 4) {
                        Button(action: chooseSong) {
                            HStack(spacing: 4) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.song?.title ?? (model.externalMusic ? "跟外部音乐" : "空场练习"))
                                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(model.status).font(.system(size: 11)).foregroundStyle(watchSilver).lineLimit(1)
                                }
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("选歌，\(model.song?.title ?? (model.externalMusic ? "跟外部音乐" : "空场练习"))")
                        .accessibilityValue(model.status)
                        Button(action: settings) {
                            Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .sessionGlass(in: Circle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("更多演奏选项")
                    }

                    Button(action: model.audition) {
                        VStack(spacing: compact ? 0 : 3) {
                            Text(model.instrumentLabel)
                                .font(.system(size: model.muted ? 43 : (compact ? 55 : 63), weight: .semibold, design: .rounded))
                                .minimumScaleFactor(0.65).lineLimit(1)
                                .frame(maxWidth: .infinity)
                            WristStrings(energy: model.strength, rotation: model.wristTurn)
                                .frame(height: compact ? 18 : 24)
                                .padding(.horizontal, 15)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(model.instrumentLabel)，轻点演奏")
                    .accessibilityValue("已拨弦 \(model.strumCount) 次")

                    if let song = model.song, model.automaticBacking {
                        ProgressView(value: min(model.elapsed, song.duration), total: max(1, song.duration))
                            .tint(watchPearl).accessibilityLabel("伴奏进度")
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 14) {
                        transportButton("music.note.list", label: "打开曲库", action: chooseSong)
                        Button {
                            Task { await model.toggle() }
                        } label: {
                            Group {
                                if model.isStarting { ProgressView().tint(.black) }
                                else { Image(systemName: model.isRunning ? "pause.fill" : "play.fill")
                                    .font(.system(size: 22, weight: .semibold)).offset(x: model.isRunning ? 0 : 2) }
                            }
                            .frame(width: compact ? 49 : 54, height: compact ? 49 : 54)
                            .foregroundStyle(.black).background(watchPearl, in: Circle())
                        }
                        .buttonStyle(.plain).disabled(model.isStarting)
                        .accessibilityLabel(model.isStarting ? "正在准备" : (model.isRunning ? "暂停演奏" : "开始演奏"))
                        .handGestureShortcut(.primaryAction, isEnabled: isFrontmost && !model.isStarting)
                        transportButton("backward.end.fill", label: "回到歌曲开头", action: model.rewind)
                            .disabled(model.isStarting)
                    }
                    Button(action: challenge) {
                        HStack(spacing: 5) {
                            Image(systemName: "waveform.path")
                            Text("节奏挑战")
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: compact ? 24 : 29)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 9).padding(.top, 1).padding(.bottom, 3)
                .frame(minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .background { SessionBackdrop(fileURL: model.song?.url) }
        .foregroundStyle(watchPearl)
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium))
                .frame(width: 40, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }
}

struct PlayingFeelButton: View {
    @EnvironmentObject private var model: PerformanceModel
    @State private var choosing = false
    var compact = false

    var body: some View {
        Button { choosing = true } label: {
            HStack(spacing: 4) {
                if !compact { Text("演奏手感"); Spacer(minLength: 2) }
                Text(model.feelTitle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .medium))
            }
            .font(compact ? .system(size: 11, weight: .medium) : .caption)
            .padding(.horizontal, compact ? 7 : 0).padding(.vertical, compact ? 4 : 0)
            .background { if compact { Capsule().fill(watchSilver.opacity(0.15)) } }
        }
        .buttonStyle(.plain)
        .disabled(model.isStarting)
        .accessibilityLabel("演奏手感").accessibilityValue(model.feelTitle)
        .sheet(isPresented: $choosing) {
            NavigationStack {
                List {
                    option("轻松跟弹", detail: "轻挥就能跟上，和弦和尾音自动接好。", assisted: true)
                    option("精准控弦", detail: "转腕选和弦，每次拨弦的时机与轻重由你掌控。", assisted: false)
                }
                .navigationTitle("演奏手感")
            }
        }
    }

    private func option(_ title: String, detail: String, assisted: Bool) -> some View {
        Button {
            model.setAssisted(assisted)
            choosing = false
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 2)
                if model.assisted == assisted { Image(systemName: "checkmark") }
            }
        }
        .accessibilityAddTraits(model.assisted == assisted ? .isSelected : [])
    }
}

/// The three strings bow with measured rotation speed; plucks add a brief ripple.
struct WristStrings: View {
    let energy: Double
    let rotation: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            let turn = min(1, max(-1, rotation))
            for index in 0..<3 {
                let baseline = size.height * (Double(index) + 1) / 4
                var path = Path()
                for step in 0...32 {
                    let t = Double(step) / 32
                    let bow = reduceMotion ? 0 : sin(t * .pi) * (turn * 5 + energy * sin(t * .pi * 3) * 2.2)
                    let point = CGPoint(x: size.width * t, y: baseline - bow)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
                context.stroke(path, with: .color(watchPearl.opacity(0.40 + 0.55 * abs(turn))), lineWidth: index == 1 ? 1.4 : 1)
            }
        }.accessibilityHidden(true)
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
    @EnvironmentObject private var model: PerformanceModel
    @EnvironmentObject private var round: RhythmRound
    var body: some View {
        NavigationStack {
            Form {
                Section("声音与触感") {
                    Toggle("挑战提示音", isOn: $round.sounds)
                    Toggle("演奏振动", isOn: $round.haptics)
                    Toggle("鼓点轻震", isOn: $round.beatHaptics)
                        .disabled(!round.haptics)
                        .accessibilityHint("跟随伴奏的拍点轻震。节奏挑战中跟随目标拍。")
                    if round.haptics { Button("试一下振动") { round.touch(.click) } }
                }
                Section("演奏手感") {
                    PlayingFeelButton()
                    Button(model.calibration == nil ? "校准我的挥幅" : "重新校准挥幅", action: calibrate)
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
                    Text("吉他音量").font(.caption)
                    Slider(value: $model.guitarVolume, in: 0...1)
                        .accessibilityLabel("吉他音量")
                    Text("伴奏音量").font(.caption)
                    Slider(value: $model.backingVolume, in: 0...1)
                        .accessibilityLabel("伴奏音量")
                    if !model.route.isEmpty { Text(model.route).font(.caption2).foregroundStyle(watchPearl) }
                }
                Section("弹奏小贴士") {
                    Text("内置练习随伴奏换和弦。其他本地歌用能辨认的和弦，听不清时弹闷音。跟外部音乐时用闷音扫弦，空场练习每四挥换和弦。")
                    Text("双指互点两下：开始或暂停。请在系统设置开启此手势。")
                    Text("保持应用在前台；后台暂停。手指连续动作暂不支持。S10 充电时请使用耳机播放。")
                }.font(.caption2)
            }
            .navigationTitle("更多")
            .scrollContentBackground(.hidden)
            .background { SessionBackdrop(subdued: true) }
        }
    }
}
