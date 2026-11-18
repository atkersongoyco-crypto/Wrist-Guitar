import AirGuitarCore
import SwiftUI

/// An optional rhythm challenge. Free performance remains a separate mode.
struct RhythmChallengePage: View {
    @EnvironmentObject private var model: PerformanceModel
    @EnvironmentObject private var round: RhythmRound
    let isFrontmost: Bool
    let chooseSong: () -> Void
    let returnToPlayer: () -> Void
    let settings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSources = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 9) {
                    header
                    switch round.phase {
                    case .ready:
                        readyContent
                    case .analyzing:
                        analyzingContent
                    case .countdown:
                        performanceContent(countingDown: true)
                    case .playing:
                        performanceContent(countingDown: false)
                    case .paused:
                        pausedContent
                    case .finished:
                        finishedContent
                    }
                }
                .padding(.horizontal, 9).padding(.bottom, 10)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
        .tint(watchPearl)
        .foregroundStyle(watchPearl)
        .background { SessionBackdrop(fileURL: model.song?.url) }
    }

    private var header: some View {
        HStack(spacing: 1) {
            Button(action: returnToPlayer) {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.plain).accessibilityLabel("回到自由弹奏")
            Text("节奏挑战").font(.system(size: 13, weight: .semibold))
                .frame(maxWidth: .infinity)
            Button(action: settings) {
                Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold))
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.plain).accessibilityLabel("更多演奏选项")
        }
    }

    private var readyContent: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text("接住每一拍")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(model.assisted ? "轻挥就好，空过也能接着来。" : "转腕选和弦，把握你的节奏。")
                    .font(.system(size: 11)).foregroundStyle(watchPearl.opacity(0.72))
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 7)

            Button(action: chooseSong) {
                HStack(spacing: 8) {
                    LocalTrackArtwork(fileURL: model.song?.url) {
                        Image("SessionCover").resizable().scaledToFill()
                    }
                        .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.song?.title ?? "选一首本地伴奏")
                            .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        Text("本地伴奏").font(.system(size: 10)).foregroundStyle(watchSilver)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain).accessibilityLabel("更换挑战歌曲，\(model.song?.title ?? "未选择")")

            Button {
                if model.song == nil { chooseSong() }
                else { model.startChallenge(.song) }
            } label: {
                Label("开始挑战", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(SessionPrimaryButtonStyle())
            .handGestureShortcut(.primaryAction, isEnabled: isFrontmost)

            SessionDisclosure("其他跟拍方式", isExpanded: $showingSources) {
                VStack(spacing: 9) {
                    sourceButton(title: "听手机外放", subtitle: "让手表听一小段音乐", symbol: "waveform") {
                        model.startChallenge(.speaker)
                    }
                    Button(action: model.tapTempo) {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap")
                            Text("跟音乐点四下")
                            Spacer(minLength: 0)
                            Text("\(min(4, max(0, round.tapsTaken))) / 4").monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(SessionSecondaryButtonStyle())
                    .accessibilityLabel("跟音乐点拍，已点 \(min(4, max(0, round.tapsTaken))) 次，共需四次")
                    if round.manualBeat != nil {
                        Button("按这个节奏开始") { model.startChallenge(.taps) }
                            .font(.system(size: 12, weight: .semibold))
                            .buttonStyle(SessionPrimaryButtonStyle())
                    }
                    feedbackText
                    Text("手表上用 Apple Music 听歌，可点四拍。外放或点拍只评你挥出的拍；换歌或变速后请重新定拍。")
                        .font(.system(size: 11)).foregroundStyle(watchSilver)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.top, 2)
        }
    }

    private var analyzingContent: some View {
        VStack(spacing: 12) {
            ProgressView().tint(watchPearl)
            Text(sourceTitle)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
            feedbackText
            if case .song? = round.source {
                Text(model.song?.title ?? "本地伴奏")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("取消", action: model.resetChallenge)
                .buttonStyle(SessionSecondaryButtonStyle())
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 12)
    }

    private func performanceContent(countingDown: Bool) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                if countingDown {
                    Text(round.countdown > 0 ? "\(round.countdown)" : "开始")
                        .font(.system(size: 48, weight: .semibold, design: .rounded))
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .accessibilityLabel(round.countdown > 0 ? "准备，\(round.countdown)" : "开始")
                } else {
                    Button(action: model.audition) {
                        Text(model.instrumentLabel)
                            .font(.system(size: model.muted ? 35 : 49, weight: .semibold, design: .rounded))
                            .minimumScaleFactor(0.7).lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 58)
                    }
                    .buttonStyle(.plain).accessibilityLabel("\(model.instrumentLabel)，轻点拨弦")
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(round.combo)")
                            .font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(round.assisted ? "已接住" : "连击")
                            .font(.system(size: 10)).foregroundStyle(watchSilver)
                        Text("\(round.score) 分")
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(watchSilver)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            beatLane(isPlaying: !countingDown).frame(height: 36)
            feedbackText
            HStack(spacing: 18) {
                Button { model.pause() } label: {
                    Image(systemName: "pause.fill").font(.system(size: 20, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.black).background(watchPearl, in: Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("暂停挑战")
                .handGestureShortcut(.primaryAction, isEnabled: isFrontmost)
                Button("结束", action: model.finishChallenge)
                    .font(.system(size: 12, weight: .medium))
                    .frame(minWidth: 44, minHeight: 44).buttonStyle(.plain)
            }
            if !countingDown {
                Text(round.assisted ? "\(tempoLabel)每\(round.targetBeatStride)拍轻挥" : (round.everyOtherBeat ? "隔拍挥弦，光点到线时拨弦" : "光点到线时挥腕"))
                    .font(.system(size: 11)).foregroundStyle(watchSilver)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pausedContent: some View {
        VStack(spacing: 11) {
            Image(systemName: "pause.circle").font(.system(size: 28)).foregroundStyle(watchPearl)
            Text("挑战已暂停").font(.system(size: 16, weight: .semibold))
            Text(round.source == .song ? "继续前会再次倒数三拍。" : "原曲一直在播时可接原拍。切歌、暂停过音乐或拖动进度后，请重新定拍。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            feedbackText
            Button(round.source == .song ? "继续挑战" : "接原拍继续", action: model.resumeChallenge)
                .buttonStyle(SessionPrimaryButtonStyle())
                .handGestureShortcut(.primaryAction, isEnabled: isFrontmost)
                .frame(maxWidth: .infinity)
            if round.source == .speaker {
                Button("重新听拍开新局") { model.startChallenge(.speaker) }.buttonStyle(SessionSecondaryButtonStyle())
            } else if round.source == .taps {
                Button("重新点拍开新局", action: model.resetChallenge).buttonStyle(SessionSecondaryButtonStyle())
            }
            Button("结束本轮", action: model.finishChallenge)
                .buttonStyle(SessionSecondaryButtonStyle())
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 6)
    }

    private var finishedContent: some View {
        VStack(spacing: 10) {
            Text("本轮成绩").font(.system(size: 14, weight: .semibold))
            Text("\(round.score)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(watchPearl)
                .accessibilityLabel("得分 \(round.score) 分")
            HStack(alignment: .top, spacing: 8) {
                if round.assisted {
                    resultValue("合拍次数", value: round.hits)
                } else {
                    resultValue("最佳连击", value: round.bestCombo)
                    resultValue("命中", value: round.hits)
                    if round.source == .song { resultValue("漏拍", value: round.misses) }
                }
            }
            feedbackText
            Button("重新选来源", action: model.resetChallenge)
                .buttonStyle(SessionPrimaryButtonStyle())
                .frame(maxWidth: .infinity)
        }
    }

    private var feedbackText: some View {
        Text(round.feedback)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var tempoLabel: String {
        guard round.bpm.isFinite, round.bpm > 0, round.bpm < 1_000 else { return "" }
        return "\(Int(round.bpm.rounded())) BPM · "
    }

    private var sourceTitle: String {
        switch round.source {
        case .song?: return "正在分析伴奏"
        case .speaker?: return "正在听外放节奏"
        case .taps?: return "准备点拍节奏"
        case nil: return "正在准备"
        }
    }

    private func sourceButton(title: String, subtitle: String, symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(watchPearl)
                    .frame(width: 19)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(watchSilver)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        }
        .buttonStyle(SessionSecondaryButtonStyle())
    }

    private func resultValue(_ label: String, value: Int) -> some View {
        VStack(spacing: 3) {
            Text("\(value)").font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(watchSilver)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func beatLane(isPlaying: Bool) -> some View {
        Canvas { context, size in
            let targetX = size.width * 0.24
            let middle = size.height / 2
            let zone = CGRect(x: targetX - 12, y: 4, width: 24, height: size.height - 8)
            context.fill(Path(roundedRect: zone, cornerRadius: 7), with: .color(watchPearl.opacity(0.10)))
            context.fill(Path(CGRect(x: 0, y: middle - 1, width: size.width, height: 2)),
                         with: .color(Color.white.opacity(0.12)))
            context.fill(Path(roundedRect: CGRect(x: targetX - 1, y: 3,
                                                  width: 2, height: size.height - 6),
                              cornerRadius: 1), with: .color(watchPearl))
            let fraction = round.fraction.isFinite ? min(1, max(0, round.fraction)) : 0
            let x = reduceMotion ? targetX : targetX + size.width * 0.72 * CGFloat(isPlaying ? 1 - fraction : 1)
            context.fill(Path(ellipseIn: CGRect(x: x - 7, y: middle - 7, width: 14, height: 14)),
                         with: .color(watchSilver.opacity(reduceMotion && isPlaying ? 0.25 + 0.75 * fraction : 1)))
        }
        .accessibilityLabel(reduceMotion ? "节拍提示亮起时拨弦" : "拍点从右向左移动，到达银白判定线时拨弦")
    }
}
