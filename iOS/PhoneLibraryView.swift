import SwiftUI
import UniformTypeIdentifiers

struct PhoneLibraryView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject var library: PhoneLibrary
    let showsPracticeGuide: Bool
    let onReplayGuide: () -> Void
    let onDismissGuide: () -> Void
    let onPracticeStroke: () -> Void
    @State private var showingImporter = false
    @State private var selectedSong: PhoneSong?
    @State private var gameSong: PhoneSong?
    @State private var canRestoreAfterStroke = false

    private var practice: PhoneSong? { library.songs.first { $0.isPracticeTrack == true } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header.padding(.horizontal, 18).padding(.vertical, 4)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            if practice != nil || showsPracticeGuide || canRestoreAfterStroke {
                                practiceSection
                            }
                            Button {
                                if let song = library.songs.first ?? resolvePractice() { gameSong = song }
                            } label: {
                                Label("体感音游", systemImage: "waveform.path").font(.headline)
                                    .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 46)
                                    .background(SessionPalette.kleinBlue, in: Capsule())
                            }.buttonStyle(.plain)
                            songList
                            if let notice = library.notice {
                                Text(notice).font(.footnote).foregroundStyle(.secondary)
                            }
                            footer
                        }
                        .padding(.horizontal, 18).padding(.bottom, 28)
                        .id("libraryTop")
                    }
                    .onChange(of: showsPracticeGuide) { _, show in
                        if show { proxy.scrollTo("libraryTop", anchor: .top) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            .background { LivelyLibraryCanvas().ignoresSafeArea() }
            .toolbar(.hidden, for: .navigationBar)
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.audio],
                          allowsMultipleSelection: true, onCompletion: library.importFiles)
            .fullScreenCover(item: $gameSong) { song in PhoneRhythmGame(library: library, song: song) }
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
        .tint(SessionPalette.action(in: scheme))
    }

    @ViewBuilder private var header: some View {
        if typeSize.isAccessibilitySize {
            stackedHeader
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    headerTitle
                    connection.fixedSize()
                    Spacer(minLength: 4)
                    headerButtons
                }
                stackedHeader
            }
        }
    }

    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack { headerTitle; Spacer(minLength: 8); headerButtons }
                VStack(alignment: .leading, spacing: 4) { headerTitle; headerButtons }
            }
            connection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerTitle: some View {
        Text("资料库").font(.title.bold()).tracking(-1)
            .accessibilityAddTraits(.isHeader).fixedSize()
    }

    private var connection: some View {
        HStack(spacing: 5) {
            Circle().fill(library.canTransfer ? SessionPalette.sage : Color.secondary)
                .frame(width: 6, height: 6).accessibilityHidden(true)
            Text(library.canTransfer ? "手表已配对" : library.connectionText)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var headerButtons: some View {
        HStack(spacing: 2) {
            Button(action: onReplayGuide) {
                Image(systemName: "questionmark.circle").frame(minWidth: 44, minHeight: 44)
            }
            .foregroundStyle(.secondary).accessibilityLabel("重看使用演示")
            Button { showingImporter = true } label: {
                Label("导入", systemImage: "plus").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 13).frame(minHeight: 35)
                    .background { TransferStatusGlass(cornerRadius: 22) }
                    .frame(minHeight: 44)
            }
        }
        .buttonStyle(.plain).foregroundStyle(SessionPalette.action(in: scheme))
    }

    private var practiceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            RecordPracticeCard(showsGuide: showsPracticeGuide, onDismissGuide: onDismissGuide, onStroke: {
                if showsPracticeGuide && practice == nil { canRestoreAfterStroke = true }
                onPracticeStroke()
            }, onPrepare: {
                if let song = resolvePractice() { library.prepareForWatch(song) }
            }, onOpenDetails: {
                if let song = resolvePractice() { selectedSong = song }
            })
            if let practice {
                transferNotes(practice)
            }
        }
    }

    private func resolvePractice() -> PhoneSong? {
        let song = practice ?? library.restorePracticeTrack()
        if song != nil { canRestoreAfterStroke = false }
        return song
    }

    private var songList: some View {
        let practiceID = practice?.id
        let personalSongs = library.songs.filter { $0.id != practiceID }
        return VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.bottom, 15)
            HStack(alignment: .firstTextBaseline) {
                Text("我的歌曲").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                if !personalSongs.isEmpty {
                    Text("\(personalSongs.count) 首").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 8)
            if personalSongs.isEmpty {
                Button { showingImporter = true } label: {
                    Text("导入第一首歌").font(.subheadline.weight(.medium)).frame(minHeight: 44)
                }
                .buttonStyle(.plain).foregroundStyle(SessionPalette.action(in: scheme))
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(personalSongs) { song in
                        recordRow(song)
                        if song.id != personalSongs.last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
    }

    private func recordRow(_ song: PhoneSong) -> some View {
        let url = library.originalURL(for: song)
        return VStack(alignment: .leading, spacing: 0) {
            Button { selectedSong = song } label: {
                HStack(spacing: 12) {
                    PhoneTrackArtwork(song: song, fileURL: url)
                        .frame(width: 43, height: 43)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(song.displayTitle).font(.body.weight(.semibold)).lineLimit(2)
                        Text(PhoneTrackPresentation.subtitle(song))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary).accessibilityHidden(true)
                }
                .padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开歌曲详情")
            .task(id: song.id) { await library.loadTrackInfo(for: song) }
            .contextMenu {
                Button("用手表弹", systemImage: "applewatch") { library.prepareForWatch(song) }
                Button(library.previewID == library.audioItem(for: song).id ? "停止手机试听" : "在手机试听",
                       systemImage: "speaker.wave.2") { library.togglePreview(song) }
                Button("歌曲详情", systemImage: "info.circle") { selectedSong = song }
                Button(song.backing == nil ? "制作伴奏" : "重新制作伴奏", systemImage: "waveform") {
                    selectedSong = song
                    library.makeBacking(song)
                }.disabled(library.processingID != nil)
                Button("仅传输所选版本文件", systemImage: "arrow.up.doc") { library.sendToWatch(song) }
                    .disabled(!library.canTransfer || library.transferProgress[library.audioItem(for: song).id] != nil)
                Button("删除手机中的原曲与伴奏", systemImage: "trash", role: .destructive) { library.remove(song) }
                    .disabled(library.processingID == song.id)
            }
            transferNotes(song).padding(.leading, typeSize.isAccessibilitySize ? 0 : 55)
        }
    }

    @ViewBuilder private func transferNotes(_ song: PhoneSong) -> some View {
        if let status = library.watchFileStatus(for: song) {
            Button { selectedSong = song } label: {
                WatchFileStatusLabel(status: status).padding(.vertical, 3)
            }.buttonStyle(.plain)
        }
        if library.processingID == song.id {
            Button { selectedSong = song } label: {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(library.processingCancelling ? "正在取消伴奏合成" : "伴奏合成中 · \(Int(library.processingProgress * 100))%")
                }.font(.caption).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
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

private struct WatchFileStatusLabel: View {
    let status: PhoneLibrary.WatchFileStatus
    var detailed = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: detailed ? 9 : 6) {
                Group {
                    if status.isSynthesizing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: status.transferFraction == nil ? "applewatch" : "arrow.up")
                    }
                }
                .foregroundStyle(SessionPalette.action(in: scheme))
                .tint(SessionPalette.action(in: scheme))
                .frame(width: detailed ? 27 : 20, height: detailed ? 27 : 20)
                .background(scheme == .dark ? SessionPalette.kleinBlue.opacity(0.68) : SessionPalette.sage.opacity(0.4),
                            in: Circle())
                .accessibilityHidden(true)
                Text(status.title)
                    .font(detailed ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                    .monospacedDigit()
            }
            if detailed {
                Text(status.detail)
                    .font(.footnote)
                    .foregroundStyle(contrast == .increased ? Color.primary : Color.secondary)
                if let fraction = status.transferFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(TransferGlassProgress())
                        .accessibilityLabel("文件传输进度")
                        .accessibilityValue(Text(fraction, format: .percent))
                }
            }
        }
        .multilineTextAlignment(.leading)
        .foregroundStyle(.primary)
        .padding(.horizontal, detailed ? 16 : 10)
        .padding(.vertical, detailed ? 14 : 7)
        .frame(maxWidth: detailed ? .infinity : nil, alignment: .leading)
        .background { TransferStatusGlass(cornerRadius: detailed ? 18 : 12) }
    }
}

private struct TransferGlassProgress: ProgressViewStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(SessionPalette.sage.opacity(scheme == .dark ? 0.22 : 0.38))
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(LinearGradient(colors: [SessionPalette.kleinBlue, SessionPalette.action(in: scheme)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * (configuration.fractionCompleted ?? 0))
                }
            }
            .frame(height: 5)
    }
}

private struct TransferStatusGlass: View {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let dark = scheme == .dark
        ZStack {
            if reduceTransparency || contrast == .increased {
                shape.fill(dark ? Color(white: 0.13) : Color(white: 0.97))
            } else {
                shape.fill(.regularMaterial)
                shape.fill(LinearGradient(colors: [
                    .white.opacity(dark ? 0.09 : 0.28), .clear, SessionPalette.sage.opacity(0.13)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            shape.strokeBorder(
                LinearGradient(colors: [
                    .white.opacity(dark ? 0.36 : 0.9),
                    .primary.opacity(contrast == .increased ? 0.5 : 0.13),
                    SessionPalette.sage.opacity(0.65)
                ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1
            )
        }
        .accessibilityHidden(true)
    }
}

private struct PhoneTrackDetail: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var library: PhoneLibrary
    @Environment(\.dynamicTypeSize) private var typeSize
    let songID: UUID
    @State private var showingGame = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let song = library.songs.first(where: { $0.id == songID }) { content(song) }
                else { ContentUnavailableView("歌曲已移除", systemImage: "music.note") }
            }
            .background { LivelyLibraryCanvas().ignoresSafeArea() }
            .fullScreenCover(isPresented: $showingGame) {
                if let song = library.songs.first(where: { $0.id == songID }) { PhoneRhythmGame(library: library, song: song) }
            }
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
        .tint(SessionPalette.action(in: scheme))
    }

    private func content(_ song: PhoneSong) -> some View {
        let item = library.audioItem(for: song)
        let version = library.selectedVersion(for: song)
        let status = library.watchFileStatus(for: song)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PhoneRecordSleeve(song: song, url: library.originalURL(for: song))
                    .frame(height: 238).frame(maxWidth: .infinity)
                let titleLine = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
                titleLine {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(song.displayTitle).font(.largeTitle.bold()).tracking(-1)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled).accessibilityAddTraits(.isHeader)
                        Text(PhoneTrackPresentation.byline(song))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button { library.togglePreview(song) } label: {
                        Label(library.previewID == item.id ? "停止试听" : "手机试听",
                              systemImage: library.previewID == item.id ? "stop.fill" : "play.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 13).frame(minHeight: 36)
                            .background { TransferStatusGlass(cornerRadius: 22) }
                            .frame(minHeight: 44)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                Button { showingGame = true } label: {
                    Label("开始体感音游", systemImage: "waveform.path")
                        .font(.headline).foregroundStyle(SessionPalette.action(in: scheme))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background { TransferStatusGlass(cornerRadius: 18) }
                }.buttonStyle(.plain)
                if song.backing != nil {
                    Picker("跟弹与试听版本", selection: Binding(get: { library.selectedVersion(for: song) },
                                                               set: { library.selectVersion($0, for: song) })) {
                        Text("原曲").tag(PhoneVersion.original)
                        Text("伴奏版").tag(PhoneVersion.backing)
                    }.pickerStyle(.segmented)
                }
                if let status {
                    WatchFileStatusLabel(status: status, detailed: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { fileInfo(item); Spacer(minLength: 8); prepareButton(song, version: version) }
                    VStack(alignment: .leading, spacing: 8) { fileInfo(item); prepareButton(song, version: version) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack { backingHeading; Spacer(); backingAction(song) }
                        VStack(alignment: .leading, spacing: 8) { backingHeading; backingAction(song) }
                    }
                    if library.processingID == song.id {
                        ProgressView(value: library.processingProgress)
                        Text(library.processingCancelling ? "正在取消伴奏合成" : "伴奏合成中 · \(Int(library.processingProgress * 100))%")
                            .font(.subheadline.weight(.medium))
                        Text("请保持 App 在前台。取消后，原曲和已有伴奏版仍可使用。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let backing = song.backing {
                        Label(backing.method.label, systemImage: "waveform")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text("伴奏版已就绪，可在上方切换试听。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("伴奏制作说明") {
                        Text("在本机削弱居中人声。单声道录音会尝试保留重复伴奏，部分乐器也可能变弱，效果随原曲混音而异。")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 32)
            .frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .task(id: song.id) { await library.loadTrackInfo(for: song) }
    }

    private func fileInfo(_ item: PhoneAudioItem) -> some View {
        Text("\(PhoneTrackPresentation.duration(item.duration)) · \(ByteCountFormatter.string(fromByteCount: item.byteCount, countStyle: .file))")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    private func prepareButton(_ song: PhoneSong, version: PhoneVersion) -> some View {
        Button { library.prepareForWatch(song) } label: {
            Label("用手表弹", systemImage: "applewatch")
                .font(.subheadline.weight(.semibold)).padding(.horizontal, 15)
                .frame(minHeight: 38)
                .foregroundStyle(Color.white)
                .background(SessionPalette.kleinBlue, in: Capsule())
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("用手表弹\(song.displayTitle)的\(version.label)")
    }

    private var backingHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("伴奏版本").font(.headline)
            Text("保留原曲，减弱人声").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func backingAction(_ song: PhoneSong) -> some View {
        if library.processingID == song.id {
            Button("取消合成", action: library.cancelBackingCreation)
                .font(.subheadline).disabled(library.processingCancelling)
        } else {
            Button { library.makeBacking(song) } label: {
                Text(song.backing == nil ? "制作伴奏" : "重新制作")
                    .font(.caption.weight(.semibold)).padding(.horizontal, 13).frame(minHeight: 34)
                    .background { TransferStatusGlass(cornerRadius: 22) }.frame(minHeight: 44)
            }
            .disabled(library.processingID != nil)
        }
    }
}

struct PhoneRecordSleeve: View {
    let song: PhoneSong
    let url: URL

    var body: some View {
        ZStack {
            LivelySleeveBack()
                .rotationEffect(.degrees(5)).offset(x: 12, y: 5)
            PhoneTrackArtwork(song: song, fileURL: url)
                .rotationEffect(.degrees(-8)).offset(x: -8, y: -1)
        }
        .frame(width: 198, height: 198)
        .shadow(color: .black.opacity(0.14), radius: 12, y: 9)
        .accessibilityHidden(true)
    }
}

private struct LivelySleeveBack: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(SessionPalette.sage.opacity(0.76)))
            for row in 0..<34 {
                let y = CGFloat(row) * 8 - 42
                var line = Path()
                line.move(to: CGPoint(x: -2, y: y))
                line.addQuadCurve(to: CGPoint(x: size.width + 2, y: y - 20),
                                  control: CGPoint(x: size.width * 0.6, y: y - 36))
                context.stroke(line, with: .color(SessionPalette.kleinBlue.opacity(0.24)), lineWidth: 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

private struct PhoneTrackArtwork: View {
    let song: PhoneSong
    let fileURL: URL

    var body: some View {
        GeometryReader { geometry in
            Group {
                if song.isPracticeTrack == true {
                    Image("LivelyPracticeCover").resizable().scaledToFill()
                } else {
                    LocalTrackArtwork(fileURL: fileURL) {
                        LivelyTitlePrint(title: song.displayTitle)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: geometry.size.width < 75 ? 7 : 3))
        }
        .accessibilityHidden(true)
    }
}

struct LivelyTitlePrint: View {
    let title: String

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let glyphs = title.filter { !$0.isWhitespace }.prefix(side < 75 ? 1 : 2).map(String.init)
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.89, green: 0.9, blue: 0.78),
                                        Color(red: 0.73, green: 0.81, blue: 0.63), SessionPalette.sage],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Canvas { context, size in
                    for (row, glyph) in glyphs.enumerated() {
                        let text = Text(glyph.uppercased())
                            .font(.custom("Songti SC", fixedSize: side * (side < 75 ? 1.08 : 0.72)).weight(.black))
                            .foregroundStyle(SessionPalette.kleinBlue)
                        context.draw(text, at: CGPoint(x: side * 0.08, y: side * (-0.12 + Double(row) * 0.55)), anchor: .topLeading)
                    }
                }
                LinearGradient(stops: [.init(color: .clear, location: 0.39),
                                       .init(color: .white.opacity(0.28), location: 0.45),
                                       .init(color: .clear, location: 0.455)],
                               startPoint: .leading, endPoint: UnitPoint(x: 1, y: 0.60))
            }
            .clipped()
        }.accessibilityHidden(true)
    }
}

private enum PhoneTrackPresentation {
    static func title(_ song: PhoneSong) -> String { song.displayTitle }
    static func byline(_ song: PhoneSong) -> String {
        if song.isPracticeTrack == true { return "内置练习曲 · \(duration(song.duration))" }
        let type = URL(fileURLWithPath: song.filename).pathExtension.uppercased()
        return [song.artist, type.isEmpty ? "本地音频" : "本地 \(type)"].compactMap { $0 }.joined(separator: " · ")
    }
    static func subtitle(_ song: PhoneSong) -> String {
        song.artist ?? "\(byline(song)) · \(duration(song.duration))"
    }
    static func duration(_ value: TimeInterval) -> String {
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct LivelyLibraryCanvas: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            dark ? Color(red: 0.061, green: 0.081, blue: 0.098)
                 : Color(red: 0.972, green: 0.978, blue: 0.96)
            if !reduceTransparency {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    RadialGradient(colors: [SessionPalette.sage.opacity(dark ? 0.16 : 0.30), .clear],
                                   center: UnitPoint(x: 1, y: 0.40), startRadius: 0, endRadius: width * 0.73)
                    RadialGradient(colors: [SessionPalette.kleinBlue.opacity(dark ? 0.17 : 0.075), .clear],
                                   center: UnitPoint(x: 0, y: 0.45), startRadius: 0, endRadius: width * 0.72)
                    LinearGradient(colors: [.white.opacity(dark ? 0.03 : 0.60), .clear, SessionPalette.sage.opacity(0.05)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}
