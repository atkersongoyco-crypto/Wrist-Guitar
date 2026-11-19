import AVFoundation
import SwiftUI

struct PhoneRhythmGame: View {
    @ObservedObject private var library: PhoneLibrary
    @ObservedObject private var link: WristGameLink
    @StateObject private var game: PhoneGameController
    @State private var selected: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @Environment(\.colorScheme) private var scheme
    private var song: PhoneSong? { library.songs.first { $0.id == selected } }
    private var active: Bool { game.phase != .lobby && game.phase != .finished }

    init(library: PhoneLibrary, song: PhoneSong) {
        self.library = library
        self.link = library.gameLink
        _game = StateObject(wrappedValue: PhoneGameController(library: library))
        _selected = State(initialValue: song.id)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let song {
                        switch game.phase {
                        case .lobby:
                            setup(song)
                        case .preparing:
                            ProgressView(game.message).frame(maxWidth: .infinity).padding(.vertical, 75)
                            Button("取消准备") { game.cancel() }.frame(maxWidth: .infinity)
                        case .countdown, .playing:
                            live(song)
                        case .finished:
                            results(song)
                        }
                    } else {
                        ContentUnavailableView("歌曲已移除", systemImage: "music.note")
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background {
                LinearGradient(colors: scheme == .dark ? [Color(white: 0.07), Color(white: 0.11)]
                               : [.white, SessionPalette.sage.opacity(0.20), Color.white],
                               startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            }
            .navigationTitle("体感音游").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { game.cancel(); dismiss() } label: {
                        Image(systemName: "xmark").frame(minWidth: 38, minHeight: 38)
                    }.accessibilityLabel(active ? "退出本局" : "关闭音游")
                }
            }
        }
        .tint(SessionPalette.action(in: scheme))
        .onAppear { game.appear() }
        .onDisappear { game.leave() }
        .onChange(of: scene) { _, next in
            if next == .background && active { game.cancel(reason: "已退出本局，回到前台可重新开始。") }
        }
        .onChange(of: link.isReachable) { _, reachable in
            if !reachable && active && game.input == .watch { game.cancel(reason: "手表已断开，重新连接后可以再开一局。") }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { note in
            guard let code = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  code == AVAudioSession.InterruptionType.began.rawValue, active, game.output == .phone else { return }
            game.cancel(reason: "声音被其他应用中断，回到这里可以再开一局。")
        }
    }

    @ViewBuilder private func setup(_ song: PhoneSong) -> some View {
        Menu {
            ForEach(library.songs) { item in
                Button { selected = item.id; game.cancel() } label: {
                    if selected == item.id { Label(item.displayTitle, systemImage: "checkmark") }
                    else { Text(item.displayTitle) }
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("本局歌曲").font(.caption).foregroundStyle(.secondary)
                    Text(song.displayTitle).font(.title.bold()).foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.up.chevron.down")
            }
            .padding(17).contentShape(Rectangle())
            .sessionGlass(in: RoundedRectangle(cornerRadius: 20))
        }
        Text("音符落到蓝线时挥动手腕。每一挥都有回应，合拍得分。")
            .font(.body).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 10) {
            Text("怎么玩").font(.headline)
            Picker("怎么玩", selection: $game.input) {
                Text("手表挥腕").tag(PhoneGameInput.watch)
                Text("点屏练习").tag(PhoneGameInput.screen)
            }.pickerStyle(.segmented)
            if game.input == .watch {
                Label(link.isReachable ? "手表已连接" : "请在手表打开 Wrist Guitar",
                      systemImage: link.isReachable ? "checkmark.circle" : "applewatch")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("在 iPhone 上轻点判定线，体验相同的拍点。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        if game.input == .watch {
            VStack(alignment: .leading, spacing: 9) {
                Text("声音从哪里播放").font(.headline)
                Picker("声音输出", selection: $game.output) {
                    Text("iPhone").tag(WristGameOutput.phone)
                    Text("Apple Watch").tag(WristGameOutput.watch)
                }.pickerStyle(.segmented)
            }
        }
        if !game.message.isEmpty {
            Text(game.message).font(.callout).foregroundStyle(.secondary)
        }
        if game.needsTransfer {
            Button { library.prepareForWatch(song) } label: { Label("把这首歌送到手表", systemImage: "applewatch") }
            if let status = library.watchFileStatus(for: song) { Text(status.title).font(.caption).foregroundStyle(.secondary) }
        }
        action("开始挑战", icon: "play.fill") { game.begin(song) }
    }

    private func live(_ song: PhoneSong) -> some View {
        VStack(spacing: 14) {
            Text(song.displayTitle).font(.title2.bold()).lineLimit(2)
            HStack {
                metric("得分", value: game.score)
                Spacer()
                metric("连击", value: game.combo)
                Spacer()
                metric("合拍", value: game.hits)
            }
            PhoneGameLane(targets: game.chart?.targets ?? [], firstTarget: game.resolvedTarget,
                          seconds: game.phase == .countdown ? game.position-Double(game.countdown) : game.position,
                          feedbackTime: game.feedbackAt, grade: game.grade, strength: game.strength,
                          countdown: game.phase == .countdown ? game.countdown : nil)
                .frame(height: 295)
                .accessibilityLabel(game.input == .screen ? "判定线，轻点打拍" : "拍点轨道")
                .accessibilityValue("得分 \(game.score)，连击 \(game.combo)")
                .overlay {
                    if game.input == .screen {
                        Button(action: game.tap) { Color.clear.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("点屏打拍")
                    }
                }
            if let chart = game.chart {
                ProgressView(value: min(chart.duration, game.position), total: max(0.001, chart.duration))
                    .tint(SessionPalette.action(in: scheme))
                    .accessibilityLabel("歌曲进度")
            }
            HStack {
                Text(game.input == .screen ? "轻点轨道打拍" : "挥腕打拍")
                Spacer()
                Text(Duration.seconds(game.position).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
            }
            .font(.footnote).foregroundStyle(.secondary)
            Button("结束本局") { game.endEarly() }
                .frame(minHeight: 40)
        }
    }

    private func results(_ song: PhoneSong) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note").font(.largeTitle).foregroundStyle(SessionPalette.action(in: scheme))
            Text(song.displayTitle).font(.title2.bold()).multilineTextAlignment(.center)
            Text("\(game.score)").font(.system(size: 66, weight: .bold, design: .rounded)).monospacedDigit()
                .accessibilityLabel("得分 \(game.score)")
            HStack { Spacer(); metric("合拍", value: game.hits); Spacer(); metric("最高连击", value: game.bestCombo); Spacer() }
            recordComparison
            action("再来一局", icon: "arrow.clockwise") { game.begin(song) }
            Button("换首歌") { game.cancel() }.frame(minHeight: 44)
        }.frame(maxWidth: .infinity).padding(.vertical, 20)
    }

    private var recordComparison: some View {
        VStack(alignment: .leading, spacing: 9) {
            let title = game.input == .watch ? "挥腕纪录" : "点屏纪录"
            if let previous = game.previousBest {
                Text(title).font(.headline)
                Text("开局前最高分 \(previous.score) · 最高连击 \(previous.combo)")
                    .font(.subheadline).foregroundStyle(.secondary)
                if game.completedSong && (game.score > previous.score || game.bestCombo > previous.combo) {
                    Label("刷新个人纪录", systemImage: "star.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(SessionPalette.action(in: scheme))
                } else if !game.completedSong {
                    Text("本局提前结束").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(game.completedSong ? "已记下你的首场\(title)" : "完整演奏这首歌，可留下首场\(title)")
                    .font(.subheadline.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(15)
        .sessionGlass(in: RoundedRectangle(cornerRadius: 16))
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }

    private func action(_ title: String, icon: String, _ tapped: @escaping () -> Void) -> some View {
        Button(action: tapped) {
            Label(title, systemImage: icon).font(.headline)
                .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 49)
                .background(SessionPalette.kleinBlue, in: Capsule())
        }.buttonStyle(.plain)
    }
}

