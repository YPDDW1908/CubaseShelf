import SwiftUI
import AppKit

private let panelColor = ShelfTheme.surface

@main struct LifelineShelfApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PreviewPlayer()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup("LIFELINE Shelf") {
            ContentView(store: library, player: player)
                .frame(minWidth: 1100, minHeight: 720)
                .tint(ShelfTheme.accent)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in library.shutdown(); player.shutdown() }
        }
        .defaultSize(width: 1280, height: 850)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加工程文件夹…") { library.chooseFolder() }.keyboardShortcut("o")
                Button("刷新资料库") { library.refresh() }.keyboardShortcut("r")
            }
        }
        .onChange(of: scenePhase) { phase in if phase != .active { library.save() } }
    }
}

struct ContentView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var player: PreviewPlayer
    var selected: Project? { store.visibleProjects.first { $0.id == store.selectedID } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView(store: store).frame(width: 202)
                Divider()
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.filter).font(.system(size: 24, weight: .bold))
                            Text("\(store.visibleProjects.count) 个工程 · 让下一次创作从这里开始")
                                .font(.caption).foregroundStyle(.secondary)
                            if let location = store.selectedLocation {
                                Label(URL(fileURLWithPath: location).lastPathComponent, systemImage: "folder")
                                    .font(.caption).foregroundStyle(ShelfTheme.accent).lineLimit(1).help(location)
                            }
                        }
                        Spacer()
                        Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(store.scanning).help("刷新资料库 ⌘R")
                    }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索工程、备注、导出音频", text: $store.query).textFieldStyle(.plain)
                    }.padding(12).background(ShelfTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius:10).stroke(ShelfTheme.border.opacity(0.6),lineWidth:1))
                    HStack {
                        if store.scanning { ProgressView().controlSize(.small); Text("正在扫描…").font(.caption) }
                        Spacer()
                        Picker("排序", selection: $store.sort) {
                            Text("最近修改").tag("最近修改"); Text("名称").tag("名称"); Text("迭代评分").tag("迭代评分")
                        }.labelsHidden().frame(width: 110)
                    }
                    if store.visibleProjects.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "folder.badge.plus").font(.system(size: 38)).foregroundStyle(ShelfTheme.accent)
                            Text(store.data.locations.isEmpty ? "把 Cubase 工程放进你的资料库" : "没有匹配的工程").font(.headline)
                            Text("支持 .cpr 工程、Auto Saves 备份与 Mixdown 试听")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if store.selectedLocation != nil || !store.query.isEmpty || store.filter != "全部工程" {
                                Button("清除筛选") { store.selectedLocation = nil; store.query = ""; store.filter = "全部工程" }
                            } else { Button("添加工程文件夹…") { store.chooseFolder() } }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(store.visibleProjects) { project in
                                    ProjectRow(project: project, annotation: store.annotation(project.id),
                                        audioCount: store.audio(for: project).count, selected: store.selectedID == project.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { store.selectedID = project.id }
                                    .contextMenu {
                                        Button("在 Cubase 中打开最新版本") { if let file = project.versions.first { store.openProject(file) } }.disabled(project.isOffline)
                                        Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.directory) }
                                    }
                                }
                            }
                        }
                    }
                    if let warning = store.warnings.first {
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(ShelfTheme.warning).lineLimit(3)
                            .help(store.warnings.joined(separator: "\n"))
                    }
                    if let date = store.lastScan {
                        Text("上次扫描 \(date.formatted(date: .omitted, time: .shortened)) · \(store.automaticRefresh ? "自动刷新已开启" : "手动刷新 ⌘R")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !store.monitorHealthy && store.automaticRefresh {
                        Text("文件监听暂不可用，已改为每 30 秒检查。")
                            .font(.caption2).foregroundStyle(ShelfTheme.warning)
                    }
                }.padding(22).frame(minWidth: 340, idealWidth: 405, maxWidth: 460)
                Divider()
                if let project = selected {
                    ProjectDetail(store: store, player: player, project: project).id(project.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.path").font(.system(size: 42)).foregroundStyle(ShelfTheme.accent.opacity(0.5))
                        Text("选择工程，找回创作的状态").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            PlayerBar(player: player)
        }
        .background(ShelfTheme.background)
        .onChange(of: store.selectedLocation) { _ in store.reconcileSelection() }
        .onChange(of: store.filter) { _ in store.reconcileSelection() }
        .onChange(of: store.query) { _ in store.reconcileSelection() }
        .alert("需要注意", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct SidebarView: View {
    @ObservedObject var store: LibraryStore
    let filters: [(String, String)] = [("全部工程", "square.stack.3d.up"), ("收藏", "heart"), ("最近 30 天", "clock"), ("模板", "square.on.square"), ("缺少试听", "waveform.slash"), ("试听较旧", "clock.badge.exclamationmark"), ("离线工程", "externaldrive.badge.xmark")]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(nsImage:ShelfTheme.logo).resizable().scaledToFit().frame(width:44,height:44)
                    .background(Color.white,in:RoundedRectangle(cornerRadius:10))
                    .clipShape(RoundedRectangle(cornerRadius:10)).accessibilityLabel("LIFELINE 标志")
                VStack(alignment: .leading, spacing: 3) {
                    Text("LIFELINE").font(.system(size: 16, weight: .bold)).tracking(1.3)
                    Text("Shelf · 音乐工程资料库").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.top, 10)
            ScrollView {
            VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("资料库").font(.caption).foregroundStyle(.secondary).padding(.bottom, 5)
                ForEach(filters, id: \.0) { title, icon in navigation(title, icon) }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("制作状态").font(.caption).foregroundStyle(.secondary).padding(.bottom, 5)
                ForEach(Stage.allCases) { stage in navigation(stage.rawValue, "circle.fill") }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("工程位置").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { store.chooseFolder() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("添加工程位置")
                }
                    VStack(alignment: .leading, spacing: 9) {
                        Button {
                            store.selectedLocation = nil
                        } label: {
                            HStack {
                                Image(systemName: "tray.2")
                                Text("所有位置")
                                Spacer()
                                if store.selectedLocation == nil { Image(systemName: "checkmark") }
                            }.font(.caption).foregroundStyle(store.selectedLocation == nil ? ShelfTheme.accent : .secondary)
                        }.buttonStyle(.plain).padding(.vertical, 4)
                        ForEach(store.data.locations) { location in
                            Button { store.selectedLocation = location.path } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: store.unavailableRoots.contains(location.path) ? "externaldrive.badge.xmark" : "folder")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(URL(fileURLWithPath: location.path).lastPathComponent).lineLimit(1)
                                        if store.unavailableRoots.contains(location.path) { Text("离线 / 不可访问").font(.system(size: 9)).foregroundStyle(ShelfTheme.warning) }
                                    }
                                    Spacer(minLength: 0)
                                    Text("\(store.count(in: location.path))").monospacedDigit()
                                }.font(.caption).padding(.vertical, 5)
                                    .foregroundStyle(store.selectedLocation == location.path ? ShelfTheme.accent : .secondary)
                            }.buttonStyle(.plain).help(location.path)
                                .contextMenu {
                                    Button("仅显示此位置") { store.selectedLocation = location.path }
                                    Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: location.path) }
                                    Button("从资料库移除（不删除文件）") { store.removeRoot(location.path) }
                                }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            }
            Spacer(minLength: 0)
            Toggle("自动刷新", isOn: Binding(get: { store.automaticRefresh }, set: { store.setAutomaticRefresh($0) }))
                .toggleStyle(.switch).controlSize(.mini).font(.caption)
            Button("添加工程文件夹…") { store.chooseFolder() }.frame(maxWidth: .infinity)
            if !(store.data.relocationHistory ?? []).isEmpty {
                Menu("找回移动工程资料") {
                    ForEach(store.data.relocationHistory ?? []) { old in
                        Button("\(old.name) · \(old.directory)") { store.relocate(old) }
                    }
                }.font(.caption)
            }
            Button("选择 Cubase 应用…") { store.chooseCubase() }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            Text("独立开发 · 本地资料库 · v0.8 Alpha").font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(16).frame(maxHeight: .infinity).background(ShelfTheme.sidebar)
    }
    func navigation(_ title: String, _ icon: String) -> some View {
        Button { store.filter = title } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: icon == "circle.fill" ? 6 : 13)).frame(width: 16)
                Text(title).font(.system(size: 12))
                Spacer()
                if title == "全部工程" { Text("\(store.data.projects.count)").font(.caption) }
            }.padding(.horizontal, 9).padding(.vertical, 7)
                .foregroundStyle(store.filter == title ? ShelfTheme.accent : Color.secondary)
                .background(store.filter == title ? ShelfTheme.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain)
    }
}

struct ProjectRow: View {
    let project: Project
    let annotation: Annotation
    let audioCount: Int
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: "waveform").font(.title3).foregroundStyle(ShelfTheme.accent)
                    .frame(width: 38, height: 38).background(ShelfTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(project.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let availability = project.availability {
                        Label(availability == .offline ? "离线 · 已保留资料" : "部分文件不可访问", systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(ShelfTheme.warning)
                    }
                    Text(project.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if annotation.favorite { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
            }
            HStack {
                Text(annotation.stage.rawValue).foregroundStyle(ShelfTheme.accent)
                if annotation.template { Text("模板").foregroundStyle(ShelfTheme.warning) }
                Spacer()
                Label("\(audioCount) 试听", systemImage: "headphones").foregroundStyle(.secondary)
            }.font(.caption)
            HStack {
                Text("\(project.versions.count) 个版本 · \(project.backups.count) 个备份")
                Spacer()
                Text(project.iterationRating == 0 ? "暂无迭代备份" : String(repeating: "★", count: project.iterationRating))
                    .font(.caption).foregroundStyle(ShelfTheme.rating).help(Project.ratingExplanation)
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(15).background(selected ? ShelfTheme.selection : panelColor, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? ShelfTheme.accent : ShelfTheme.border.opacity(0.6), lineWidth: 1))
    }
}

struct ProjectDetail: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var player: PreviewPlayer
    let project: Project
    @State private var versionPath = ""
    @State private var selectedMetadata: ProjectMetadata?
    var metadataEntry: FileEntry? { project.versions.first { $0.path == versionPath } ?? project.versions.first }
    var annotation: Annotation { store.annotation(project.id) }
    func binding<T>(_ keyPath: WritableKeyPath<Annotation, T>) -> Binding<T> {
        Binding(get: { store.annotation(project.id)[keyPath: keyPath] }, set: { value in store.update(project.id) { $0[keyPath: keyPath] = value } })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider()
                metadata
                Divider()
                projectInformation
                Divider()
                audioList
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("下次继续做什么").font(.headline)
                    TextEditor(text: binding(\.notes)).font(.system(size: 13)).scrollContentBackground(.hidden)
                        .frame(minHeight: 90).padding(8).background(panelColor, in: RoundedRectangle(cornerRadius: 8))
                    Text("备注自动保存在资料库中，不写入 Cubase 工程。").font(.caption2).foregroundStyle(.secondary)
                }
                DisclosureGroup("自动备份 · \(project.backups.count) 个") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(project.backups) { backup in
                            HStack {
                                Text(backup.name).lineLimit(1).help(backup.name)
                                Spacer()
                                Button { NSWorkspace.shared.activateFileViewerSelecting([backup.url]) } label: { Image(systemName: "folder") }.help("在 Finder 中显示备份")
                            }.font(.caption)
                        }
                        if project.backups.isEmpty { Text("尚未发现 .bak 备份").foregroundStyle(.secondary).font(.caption) }
                    }.padding(.top, 8)
                }.font(.caption)
            }.padding(26)
        }.onAppear { versionPath = project.versions.first?.path ?? "" }
        .task(id: metadataEntry) {
            guard let entry = metadataEntry else { selectedMetadata = nil; return }
            if entry == project.versions.first, let cached = project.metadata { selectedMetadata = cached; return }
            selectedMetadata = nil
            let result = await Task.detached(priority: .utility) { CPRMetadataReader.read(entry.url) }.value
            guard !Task.isCancelled else { return }; selectedMetadata = result
        }
        .onChange(of: project.versions) { versions in
            if !versions.contains(where: { $0.path == versionPath }) { versionPath = versions.first?.path ?? "" }
        }
    }
    var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("工程详情  /  CUBASE").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(ShelfTheme.accent)
            HStack {
                Text(project.name).font(.system(size: 27, weight: .bold)).textSelection(.enabled)
                Spacer()
                Button { store.update(project.id) { $0.favorite.toggle() } } label: {
                    Image(systemName: annotation.favorite ? "heart.fill" : "heart").foregroundStyle(annotation.favorite ? .pink : .secondary)
                }.buttonStyle(.plain).help("收藏工程")
            }
            Text(project.directory).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            if let availability = project.availability {
                Label(availability == .offline ? "位置离线或不可访问，已保留工程资料。连接磁盘并刷新后恢复；收藏和备注仍可编辑。" : "部分文件暂不可访问，显示上次扫描的记录。恢复访问并刷新后更新。", systemImage: "externaldrive.badge.xmark")
                    .font(.caption).foregroundStyle(ShelfTheme.warning)
            }
            HStack {
                Button { if let version = project.versions.first(where: { $0.path == versionPath }) ?? project.versions.first { store.openProject(version) } } label: {
                    Label("在 Cubase 中打开", systemImage: "arrow.up.forward.app")
                }.buttonStyle(.borderedProminent).tint(ShelfTheme.accent).foregroundStyle(ShelfTheme.onAccent).disabled(project.isOffline)
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.directory) } label: { Image(systemName: "folder") }.help("显示工程文件夹")
                Button("重新定位…") { store.relocate(project) }.font(.caption)
                Spacer()
            }
            Picker("工程版本", selection: $versionPath) {
                ForEach(project.versions) { file in Text(file.name).tag(file.path) }
            }.font(.caption)
        }
    }
    var projectInformation: some View {
        DisclosureGroup("工程信息 · 自动读取") {
            VStack(alignment: .leading, spacing: 9) {
                if let info = selectedMetadata {
                    Group {
                    Text("来源：\(metadataEntry?.name ?? "CPR")\(project.isOffline ? "（离线缓存）" : "")").font(.caption2)
                    Text("保存版本：\(info.applicationVersion.map { "Cubase " + $0 } ?? "未识别")")
                    Text("工程音频属性：" + info.audioFormatText)
                    Text("起始拍号：" + info.initialSignatureText)
                    if !(info.signatures ?? []).isEmpty { Text("拍号事件：" + info.signatureEventsText).font(.caption2) }
                    Text("起始 BPM：\(info.bpmText)")
                    }
                    if let source = info.tempoSource { Text("\(source) · \(info.tempos.count) 个速度事件").font(.caption2) }
                    if info.tempos.count > 1 {
                        Text("速度值：" + info.tempos.map { String(format: "%.2f", $0) }.joined(separator: " → ")).font(.caption2)
                    }
                    Text("已识别通道名（去重）：\(info.channelNames.count)")
                    Text(info.channelNames.isEmpty ? "未识别" : info.channelNames.joined(separator: " · ")).textSelection(.enabled)
                    Text("插件引用名（去重）：\(info.pluginNames.count)")
                    Text(info.pluginNames.isEmpty ? "未识别" : info.pluginNames.joined(separator: " · ")).textSelection(.enabled)
                    if let message = info.message { Text(message).font(.caption2).foregroundStyle(.secondary) }
                } else { Text("正在读取工程信息…") }
            }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top,8)
        }.font(.headline)
    }
    var metadata: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("状态", selection: binding(\.stage)) { ForEach(Stage.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 210)
                Spacer()
                Toggle("可复用模板", isOn: binding(\.template)).toggleStyle(.checkbox).font(.caption)
            }
            HStack(spacing: 7) {
                Text("迭代评分").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    ForEach(1...5, id: \.self) { number in
                        Image(systemName: number <= project.iterationRating ? "star.fill" : "star").foregroundStyle(ShelfTheme.rating)
                    }
                }.accessibilityElement(children: .ignore)
                    .accessibilityLabel("自动迭代评分 \(project.iterationRating) 星，\(project.iterationBackupCount) 个备份")
                    .help(Project.ratingExplanation)
                Spacer()
                Text("BPM").font(.caption).foregroundStyle(.secondary)
                TextField("手动", text: binding(\.bpm)).textFieldStyle(.roundedBorder).frame(width: 60)
            }
            Text("根据 \(project.iterationBackupCount) 个 .bak 备份自动评分，反映迭代活跃度。BPM 为手动备注。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    var audioList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("导出试听").font(.headline)
                Spacer()
                Button("关联音频…") { store.associateAudio(project) }.font(.caption)
            }
            Text("自动读取此工程的 Mixdown 及其他导出目录，无需逐个关联；按修改时间排列。")
                .font(.caption2).foregroundStyle(.secondary)
            let audio = store.audio(for: project)
            if audio.isEmpty {
                Text("尚未发现导出音频。将完整混音放入此工程的 Mixdown 文件夹；自动刷新开启时会自动识别，也可按 ⌘R 刷新。其他位置的音频可手动关联。").font(.caption).foregroundStyle(.secondary).padding(.vertical, 15)
            }
            ForEach(Array(audio.enumerated()), id: \.element.id) { index, file in
                let unavailable = store.audioIsUnavailable(file, project: project)
                HStack(spacing: 10) {
                    Button { player.load(file, project: project, autoplay: true) } label: {
                        Image(systemName: player.selected?.id == file.id && player.playbackActive ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2).foregroundStyle(ShelfTheme.accent)
                    }.buttonStyle(.plain).disabled(unavailable).help(unavailable ? "文件离线或不可访问" : "播放 / 暂停")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(project.bounces.contains(where: { $0.path == file.path }) ? "自动识别 · \(file.url.deletingLastPathComponent().lastPathComponent)" : "手动关联")
                            .font(.caption2).foregroundStyle(.secondary)
                        Text("\(file.url.pathExtension.uppercased()) · \(unavailable ? "文件离线" : file.modified < project.modified ? "早于工程修改" : "已更新")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.contentShape(Rectangle()).onTapGesture { if !unavailable { player.load(file, project: project) } }
                    Spacer(minLength: 0)
                    Text(index < 26 ? String(UnicodeScalar(65 + index)!) : "\(index + 1)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Menu {
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        if annotation.externalAudio.contains(where: { $0.path == file.path }) {
                            Button("取消外部关联") { store.update(project.id) { $0.externalAudio.removeAll { $0.path == file.path } } }
                        }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
                }.padding(11).background(player.selected?.id == file.id ? ShelfTheme.selection : panelColor, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("同一工程切换音频时保持播放时间；底部可开启响度对齐，仅影响试听。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct PlayerBar: View {
    @ObservedObject var player: PreviewPlayer
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(player.selected?.name ?? "尚未选择试听音频").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(player.selected == nil ? "选择工程中的导出音频开始试听" : player.projectName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }.frame(width: 190, alignment: .leading)
                Button { player.stop() } label: { Image(systemName: "stop.fill") }.buttonStyle(.plain).disabled(player.selected == nil)
                Button { player.toggle() } label: {
                    Image(systemName: player.playbackActive ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34)).foregroundStyle(ShelfTheme.accent)
                }.buttonStyle(.plain).disabled(player.selected == nil)
                Text(formatTime(player.time)).font(.system(.caption, design: .monospaced)).frame(width: 40)
                WaveformView(player: player).frame(height: 48)
                Text(formatTime(player.duration)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 40)
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1).frame(width: 95).help("试听音量")
            }
            HStack(spacing: 12) {
                Toggle("试听响度对齐", isOn: $player.normalizationEnabled).toggleStyle(.switch).controlSize(.mini)
                Picker("目标", selection: $player.targetLUFS) {
                    Text("−23 LUFS").tag(-23.0); Text("−18 LUFS").tag(-18.0); Text("−14 LUFS").tag(-14.0)
                }.frame(width: 160).disabled(!player.normalizationEnabled)
                Text(player.alignmentStatus).foregroundStyle(.secondary).lineLimit(2).help(player.alignmentStatus)
                Spacer()
            }.font(.caption).help("静态增益，不压缩动态、不改原文件。上限 −1 dBTP，另留 0.3 dB 余量，最多提升 12 dB。系统音量和试听音量仍影响实际听到的音量。")
            if let error = player.error { Text(error).font(.caption).foregroundStyle(ShelfTheme.warning).textSelection(.enabled) }
            else if let summary = player.summary {
                VStack(alignment:.leading,spacing:8) {
                    HStack(spacing:16) {
                        if let analysis = summary.loudness {
                            meter("综合响度",analysis.integrated,"LUFS")
                            meter("响度范围",analysis.range,"LU")
                            meter("真实峰值",analysis.truePeak,"dBTP")
                            meter("采样峰值",analysis.samplePeak,"dBFS")
                            meter("最大瞬时",analysis.momentaryMax,"LUFS")
                            meter("最大短时",analysis.shortTermMax,"LUFS")
                        }
                        Spacer(minLength:0)
                        VStack(alignment:.trailing,spacing:4) {
                            Text("\(summary.sampleRate/1000,specifier:"%.1f") kHz · \(summary.channels) 声道")
                            if let bits = summary.sourceBitDepth { Text("原文件 PCM · \(bits) bit") }
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                    if summary.duration < 60 { Text("短于 60 秒：LRA 稳定性有限").font(.caption2).foregroundStyle(ShelfTheme.warning) }
                    if let analysis = summary.loudness {
                        if analysis.invalidSamples > 0 { Text("发现 \(analysis.invalidSamples) 个无效采样，响度结果不可用，对齐已禁用。").font(.caption2).foregroundStyle(ShelfTheme.warning) }
                        if !analysis.layoutSupported { Text("声道布局未支持，不计算 LUFS/LRA。").font(.caption2).foregroundStyle(ShelfTheme.warning) }
                        if analysis.fullScaleSamples > 0 { Text("\(analysis.fullScaleSamples) 个采样达到或超过 0 dBFS；不等同于已确认削波失真。").font(.caption2).foregroundStyle(ShelfTheme.warning) }
                    }
                }.padding(.top,6)
            }
        }.padding(.horizontal,22).padding(.vertical,16).background(panelColor)
    }
    private func meter(_ title: String, _ value: Double?, _ unit: String) -> some View {
        VStack(alignment:.leading,spacing:4) {
            Text(title).font(.system(size:10)).foregroundStyle(.secondary)
            HStack(alignment:.firstTextBaseline,spacing:4) {
                Text(LoudnessResult.text(value)).font(.system(size:17,weight:.medium,design:.monospaced))
                Text(unit).font(.system(size:9)).foregroundStyle(.secondary)
            }
        }.frame(minWidth:88,alignment:.leading).textSelection(.enabled)
        .help("原始音频读数。LUFS/LRA 支持单声道、立体声和明确布局的 5.1；True Peak 支持 44.1 kHz 及以上。— 表示无法测量。")
    }
}
