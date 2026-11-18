import SwiftUI
import UniformTypeIdentifiers

struct PhoneLibraryView: View {
    @ObservedObject var library: PhoneLibrary
    @State private var showingImporter = false
    @State private var selectedSong: PhoneSong?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Label(library.canTransfer ? "已配对 Apple Watch" : library.connectionText, systemImage: library.canTransfer
                          ? "applewatch.radiowaves.left.and.right" : "applewatch")
                        .font(.caption).foregroundStyle(.secondary)
                    if library.songs.isEmpty { emptyLibrary }
                    else {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("最近添加").font(.title2.bold())
                                Spacer()
                                Text("\(library.songs.count) 首").font(.subheadline).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: library.songs.count == 1
                                      ? [GridItem(.flexible())]
                                      : [GridItem(.adaptive(minimum: 136), spacing: 18)],
                                      alignment: .leading, spacing: 28) {
                                ForEach(library.songs) { song in album(song) }
                            }
                        }
                    }
                    if let notice = library.notice {
                        Text(notice).font(.footnote).foregroundStyle(.secondary)
                    }
                    footer
                }
                .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 32)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .background(PhoneLibraryStyle.canvas)
            .navigationTitle("资料库")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingImporter = true } label: {
                        Label("导入", systemImage: "plus").font(.subheadline.weight(.semibold))
                    }
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio],
                          allowsMultipleSelection: true, onCompletion: library.importFiles)
            .sheet(item: $selectedSong) { song in
                PhoneTrackDetail(library: library, songID: song.id)
                    .presentationDragIndicator(.visible)
            }
            .alert("操作未完成", isPresented: Binding(
                get: { selectedSong == nil && library.lastError != nil },
                set: { if !$0 && selectedSong == nil { library.lastError = nil } }
            )) {
                Button("知道了", role: .cancel) { library.lastError = nil }
            } message: { Text(library.lastError ?? "") }
        }
        .tint(PhoneLibraryStyle.ink)
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "music.note").font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(.tertiary).padding(.top, 36)
            Text("你的音乐，从这里开始").font(.title2.weight(.semibold))
            Text("导入一首本地音频，会自动准备到手表。选好歌后，在手表点播放。")
                .font(.subheadline).foregroundStyle(.secondary)
            Button { showingImporter = true } label: {
                Label("导入音频", systemImage: "plus")
                    .font(.subheadline.weight(.semibold)).padding(.vertical, 7).padding(.horizontal, 14)
            }
            .buttonStyle(.bordered).padding(.top, 2)
            Text("支持 MP3、M4A、WAV、AIFF · 每首最多 100 MB")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
    }

    private func album(_ song: PhoneSong) -> some View {
        let item = library.audioItem(for: song)
        let playing = library.previewID == item.id
        return VStack(alignment: .leading, spacing: 13) {
            Button { selectedSong = song } label: {
                PhoneTrackArtwork(song: song, fileURL: library.originalURL(for: song))
                    .shadow(color: .black.opacity(0.08), radius: 14, y: 7)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看\(PhoneTrackPresentation.title(song))")
            HStack(alignment: .top, spacing: 8) {
                Button { selectedSong = song } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(PhoneTrackPresentation.title(song)).font(.headline).lineLimit(2)
                        Text(PhoneTrackPresentation.subtitle(song))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Menu {
                    Button("歌曲详情", systemImage: "info.circle") { selectedSong = song }
                    Button(playing ? "停止手机试听" : "在手机试听", systemImage: playing ? "stop.fill" : "speaker.wave.2") {
                        library.togglePreview(song)
                    }
                    Button(song.backing == nil ? "制作伴奏" : "重新制作伴奏", systemImage: "waveform") {
                        selectedSong = song
                        library.makeBacking(song)
                    }.disabled(library.processingID != nil)
                    Button("仅传输\(library.selectedVersion(for: song).label)文件", systemImage: "arrow.up.doc") {
                        selectedSong = song
                        library.sendToWatch(song)
                    }.disabled(!library.canTransfer || library.transferProgress[item.id] != nil)
                    Button("删除手机中的原曲与伴奏", systemImage: "trash", role: .destructive) { library.remove(song) }
                        .disabled(library.processingID == song.id)
                } label: {
                    Image(systemName: "ellipsis").font(.headline).frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("\(PhoneTrackPresentation.title(song))的更多操作")
            }
            Button { library.prepareForWatch(song) } label: {
                Label("用手表弹", systemImage: "applewatch")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .sessionGlass(in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("用手表弹\(PhoneTrackPresentation.title(song))的\(library.selectedVersion(for: song).label)")
            Button { library.togglePreview(song) } label: {
                Label(playing ? "停止手机试听" : "在手机试听", systemImage: playing ? "stop.fill" : "speaker.wave.2")
                    .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if let message = library.watchPreparationMessage(for: song) {
                Button { selectedSong = song } label: {
                    Label(message, systemImage: "applewatch").font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            if library.processingID == song.id {
                Button { selectedSong = song } label: {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在制作伴奏 · \(Int(library.processingProgress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Menu {
                Text("支持 MP3、M4A、WAV、AIFF，每首最多 100 MB。")
                Link("打开 Apple Music", destination: URL(string: "https://music.apple.com/")!)
                Text("音乐 App 内的歌曲不能直接导入。可由手机播放，再到手表选择跟外部音乐。")
            } label: {
                Label("更多播放方式", systemImage: "arrow.up.right")
                    .font(.footnote.weight(.medium))
            }
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if let previewID = library.previewID,
           let song = library.songs.first(where: { $0.id == previewID || $0.backing?.id == previewID }) {
            HStack(spacing: 4) {
                Button { selectedSong = song } label: {
                    HStack(spacing: 12) {
                        PhoneTrackArtwork(song: song, fileURL: library.originalURL(for: song))
                            .frame(width: 42, height: 42)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(PhoneTrackPresentation.title(song)).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(song.backing?.id == previewID ? "伴奏版 · 手机试听" : "原曲 · 手机试听")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("查看正在播放的\(PhoneTrackPresentation.title(song))")
                Button { library.stopPreview() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("停止手机试听")
            }
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17))
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 8)
        }
    }
}

private struct PhoneTrackDetail: View {
    @ObservedObject var library: PhoneLibrary
    let songID: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let song = library.songs.first(where: { $0.id == songID }) { content(song) }
                else { ContentUnavailableView("歌曲已移除", systemImage: "music.note") }
            }
            .background(PhoneLibraryStyle.canvas)
            .navigationTitle("歌曲详情").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Label("返回资料库", systemImage: "chevron.left") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let song = library.songs.first(where: { $0.id == songID }) {
                        Menu {
                            Button(song.backing == nil ? "制作伴奏" : "重新制作伴奏", systemImage: "waveform") {
                                library.makeBacking(song)
                            }.disabled(library.processingID != nil)
                            Button("仅传输所选版本文件", systemImage: "arrow.up.doc") { library.sendToWatch(song) }
                                .disabled(!library.canTransfer || library.transferProgress[library.audioItem(for: song).id] != nil)
                            Button("删除手机中的原曲与伴奏", systemImage: "trash", role: .destructive) {
                                library.remove(song)
                                if !library.songs.contains(where: { $0.id == songID }) { dismiss() }
                            }.disabled(library.processingID == songID)
                        } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                        .accessibilityLabel("歌曲更多操作")
                    }
                }
            }
            .alert("操作未完成", isPresented: Binding(get: { library.lastError != nil },
                                                     set: { if !$0 { library.lastError = nil } })) {
                Button("知道了", role: .cancel) { library.lastError = nil }
            } message: { Text(library.lastError ?? "") }
        }
        .tint(PhoneLibraryStyle.ink)
    }

    private func content(_ song: PhoneSong) -> some View {
        let item = library.audioItem(for: song)
        let version = library.selectedVersion(for: song)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PhoneTrackArtwork(song: song, fileURL: library.originalURL(for: song))
                    .frame(maxWidth: 320).frame(maxWidth: .infinity)
                    .shadow(color: .black.opacity(0.08), radius: 18, y: 10)
                VStack(alignment: .leading, spacing: 6) {
                    Text(PhoneTrackPresentation.title(song)).font(.title2.bold()).textSelection(.enabled)
                    Text(PhoneTrackPresentation.subtitle(song)).font(.subheadline).foregroundStyle(.secondary)
                }
                if song.backing != nil {
                    Picker("跟弹与试听版本", selection: Binding(get: { library.selectedVersion(for: song) },
                                                               set: { library.selectVersion($0, for: song) })) {
                        Text("原曲").tag(PhoneVersion.original)
                        Text("伴奏版").tag(PhoneVersion.backing)
                    }.pickerStyle(.segmented)
                }
                Button { library.prepareForWatch(song) } label: {
                    Label("用手表弹", systemImage: "applewatch")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 12) {
                    if let message = library.watchPreparationMessage(for: song) {
                        Label(message, systemImage: "applewatch").font(.subheadline.weight(.medium))
                    }
                    Text(library.watchPreparationHint(for: song)).font(.footnote).foregroundStyle(.secondary)
                    if let progress = library.transferProgress[item.id] {
                        ProgressView(value: progress)
                        Text(progress > 0 ? "传输进度 \(Int(progress * 100))%" : "已加入系统传输队列，请保持设备靠近。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("\(PhoneTrackPresentation.duration(item.duration)) · \(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))")
                        .font(.caption).foregroundStyle(.tertiary)
                    Button { library.togglePreview(song) } label: {
                        Label(library.previewID == item.id ? "停止手机试听" : "在手机试听\(version.label)",
                              systemImage: library.previewID == item.id ? "stop.fill" : "speaker.wave.2")
                            .font(.footnote.weight(.medium)).frame(minHeight: 44)
                    }.buttonStyle(.plain)
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text("伴奏版本").font(.headline)
                    Text("原曲始终保留。削弱居中人声，单声道尝试保留重复伴奏；效果随混音而变。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if library.processingID == song.id {
                        ProgressView(value: library.processingProgress)
                        HStack {
                            Text(library.processingCancelling ? "正在取消…" : "正在制作伴奏… \(Int(library.processingProgress * 100))%")
                                .font(.subheadline)
                            Spacer()
                            Button("取消") { library.cancelBackingCreation() }.disabled(library.processingCancelling)
                        }
                        Text("请保持 App 在前台。取消后，原曲和已有伴奏版仍可使用。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let backing = song.backing {
                        Label(backing.method.label, systemImage: "waveform")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("伴奏版已就绪，可在上方切换试听。重新制作在右上角的更多操作中。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button { library.makeBacking(song) } label: {
                            Label("制作伴奏", systemImage: "waveform")
                                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 30)
                        }.buttonStyle(.bordered).disabled(library.processingID != nil)
                    }
                    Text("离线处理，不是 AI 分轨，部分乐器也可能被减弱。")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            .padding(24).padding(.bottom, 24)
        }
    }
}

private struct PhoneTrackArtwork: View {
    let song: PhoneSong
    let fileURL: URL
    var body: some View {
        GeometryReader { geometry in
            if PhoneTrackPresentation.isPractice(song) {
                Image("SessionCover").resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                LocalTrackArtwork(fileURL: fileURL) {
                    ZStack {
                        LinearGradient(colors: [Color(white: 0.95), Color(white: 0.87)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: "music.note").font(.system(size: geometry.size.width * 0.28, weight: .ultraLight))
                            .foregroundStyle(Color(white: 0.55))
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
    }
}

private enum PhoneTrackPresentation {
    static func isPractice(_ song: PhoneSong) -> Bool { song.isPracticeTrack == true }
    static func title(_ song: PhoneSong) -> String { song.displayTitle }
    static func subtitle(_ song: PhoneSong) -> String {
        "\(isPractice(song) ? "原创练习" : "本地音频") · \(duration(song.duration))"
    }
    static func duration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private enum PhoneLibraryStyle {
    static let ink = Color.primary
    static let canvas = Color(uiColor: .systemBackground)
}
