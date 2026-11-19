import SwiftUI

struct WatchGameScreen: View {
    @ObservedObject var game: WatchGameController
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var titleSize = 24.0

    var body: some View {
        if dimmed {
            VStack(alignment: .leading, spacing: 5) {
                Text("双端音游").font(.caption).foregroundStyle(.secondary)
                Text(game.title.isEmpty ? "等待选歌" : game.title)
                    .font(.headline).lineLimit(2)
                Text(game.phase == .playing ? "已挥 \(game.strokes) 次" : game.message)
                    .font(.caption2).lineLimit(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .background(Color.black.ignoresSafeArea())
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("双端音游", systemImage: "applewatch.radiowaves.left.and.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(RecordWatchInk.blue)
                        Spacer(minLength: 0)
                        Button(action: game.leave) {
                            Image(systemName: "xmark").font(.footnote.bold())
                                .frame(width: 38, height: 36)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(game.phase == .playing ? "结束本局并返回" : "返回")
                    }
                    Text(heading)
                        .font(.system(size: titleSize, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    if game.phase == .countdown, let start = game.startTime {
                        TimelineView(.periodic(from: .now, by: 0.12)) { _ in
                            Text("\(max(1, Int(ceil(start-WristGameLink.now))))")
                                .font(.largeTitle.bold().monospacedDigit())
                                .foregroundStyle(RecordWatchInk.blue)
                        }
                        .accessibilityLabel("准备开始")
                    } else if game.phase == .playing {
                        Label(game.matched ? "合拍" : (game.strokes > 0 ? "已挥 \(game.strokes) 次" : "跟着光点挥腕"),
                              systemImage: game.matched ? "checkmark.circle.fill" : "waveform")
                            .font(.headline).foregroundStyle(RecordWatchInk.blue)
                            .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : game.strokes)
                        Text(game.output == .phone ? "iPhone 出声 · 手表感应" : "手表出声 · iPhone 显示判定")
                            .font(.caption2).foregroundStyle(RecordWatchInk.secondary)
                    } else {
                        Text(helper).font(.caption).foregroundStyle(RecordWatchInk.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 2)
            }
            .foregroundStyle(RecordWatchInk.foreground)
            .background { RecordWatchBackdrop().ignoresSafeArea() }
        }
    }

    private var heading: String {
        switch game.phase {
        case .waiting: return game.connected ? "手表已连接" : "等待 iPhone"
        case .preparing: return "正在准备"
        case .ready: return "手表就绪"
        case .countdown: return "准备挥腕"
        case .playing: return game.title
        case .finished: return game.message
        }
    }

    private var helper: String {
        switch game.phase {
        case .waiting:
            return game.connected ? "在 iPhone 打开「双端音游」，选一首歌开始。" : "打开配对 iPhone 上的 Wrist Guitar，保持两端 App 在前台。"
        case .preparing, .ready: return game.output == .watch ? "声音将从手表播放" : "声音将从 iPhone 播放"
        case .finished: return "可在 iPhone 再开一局。"
        case .countdown, .playing: return ""
        }
    }
}
