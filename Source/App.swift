import SwiftUI
import AppKit

private let panelColor = Color(red: 0.105, green: 0.12, blue: 0.15)

@main struct CubaseShelfApp: App {
    @StateObject private var library = LibraryStore()
    @StateObject private var player = PreviewPlayer()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup("CubaseShelf") {
            ContentView(store: library, player: player)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(.dark)
                .tint(.mint)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in library.save() }
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
                        }
                        Spacer()
                        Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(store.scanning).help("刷新资料库 ⌘R")
                    }
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索工程、备注、导出音频", text: $store.query).textFieldStyle(.plain)
                    }.padding(10).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        if store.scanning { ProgressView().controlSize(.small); Text("正在扫描…").font(.caption) }
                        Spacer()
                        Picker("排序", selection: $store.sort) {
                            Text("最近修改").tag("最近修改"); Text("名称").tag("名称"); Text("评分").tag("评分")
                        }.labelsHidden().frame(width: 110)
                    }
                    if store.visibleProjects.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "folder.badge.plus").font(.system(size: 38)).foregroundStyle(.mint)
                            Text(store.data.locations.isEmpty ? "把 Cubase 工程放进你的资料库" : "没有匹配的工程").font(.headline)
                            Text("支持 .cpr 工程、Auto Saves 备份与 Mixdown 试听")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("添加工程文件夹…") { store.chooseFolder() }
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
                                        Button("在 Cubase 中打开最新版本") { if let file = project.versions.first { store.openProject(file) } }
                                        Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.directory) }
                                    }
                                }
                            }
                        }
                    }
                    if let warning = store.warnings.first {
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(3)
                            .help(store.warnings.joined(separator: "\n"))
                    }
                    if let date = store.lastScan {
                        Text("上次扫描 \(date.formatted(date: .omitted, time: .shortened)) · ⌘R 刷新")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(22).frame(minWidth: 340, idealWidth: 405, maxWidth: 460)
                Divider()
                if let project = selected {
                    ProjectDetail(store: store, player: player, project: project).id(project.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.path").font(.system(size: 42)).foregroundStyle(.mint.opacity(0.5))
                        Text("选择工程，找回创作的状态").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            PlayerBar(player: player)
        }
        .background(Color(red: 0.075, green: 0.087, blue: 0.11))
        .alert("需要注意", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("知道了") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct SidebarView: View {
    @ObservedObject var store: LibraryStore
    let filters: [(String, String)] = [("全部工程", "square.stack.3d.up"), ("收藏", "heart"), ("最近 30 天", "clock"), ("模板", "square.on.square"), ("缺少试听", "waveform.slash"), ("试听较旧", "clock.badge.exclamationmark")]
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("CubaseShelf").font(.system(size: 17, weight: .bold))
                    Text("你的音乐工程资料库").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.top, 10)
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(store.data.locations) { location in
                            Label(URL(fileURLWithPath: location.path).lastPathComponent, systemImage: "folder")
                                .font(.caption).lineLimit(1).help(location.path)
                                .contextMenu {
                                    Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: location.path) }
                                    Button("从资料库移除（不删除文件）") { store.removeRoot(location.path) }
                                }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 85)
            }
            Spacer(minLength: 0)
            Button("添加工程文件夹…") { store.chooseFolder() }.frame(maxWidth: .infinity)
            Button("选择 Cubase 应用…") { store.chooseCubase() }.font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
            Text("独立开发 · 本地资料库 · v0.1 Alpha").font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(16).frame(maxHeight: .infinity).background(panelColor)
    }
    func navigation(_ title: String, _ icon: String) -> some View {
        Button { store.filter = title } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: icon == "circle.fill" ? 6 : 13)).frame(width: 16)
                Text(title).font(.system(size: 12))
                Spacer()
                if title == "全部工程" { Text("\(store.data.projects.count)").font(.caption) }
            }.padding(.horizontal, 9).padding(.vertical, 7)
                .foregroundStyle(store.filter == title ? Color.mint : Color.secondary)
                .background(store.filter == title ? Color.mint.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
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
                Image(systemName: "waveform").font(.title3).foregroundStyle(.mint)
                    .frame(width: 38, height: 38).background(.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 5) {
                    Text(project.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(project.modified.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if annotation.favorite { Image(systemName: "heart.fill").foregroundStyle(.pink).font(.caption) }
            }
            HStack {
                Text(annotation.stage.rawValue).foregroundStyle(.mint)
                if annotation.template { Text("模板").foregroundStyle(.orange) }
                Spacer()
                Label("\(audioCount) 试听", systemImage: "headphones").foregroundStyle(.secondary)
            }.font(.caption)
            HStack {
                Text("\(project.versions.count) 个版本 · \(project.backups.count) 个备份")
                Spacer()
                if annotation.rating > 0 { Text(String(repeating: "★", count: annotation.rating)).foregroundStyle(.yellow) }
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(15).background(selected ? Color.mint.opacity(0.06) : panelColor, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.mint.opacity(0.65) : .white.opacity(0.07), lineWidth: 1))
    }
}

struct ProjectDetail: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var player: PreviewPlayer
    let project: Project
    @State private var versionPath = ""
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
    }
    var header: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("CUBASE PROJECT").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(.mint)
            HStack {
                Text(project.name).font(.system(size: 27, weight: .bold)).textSelection(.enabled)
                Spacer()
                Button { store.update(project.id) { $0.favorite.toggle() } } label: {
                    Image(systemName: annotation.favorite ? "heart.fill" : "heart").foregroundStyle(annotation.favorite ? .pink : .secondary)
                }.buttonStyle(.plain).help("收藏工程")
            }
            Text(project.directory).font(.caption2).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            HStack {
                Button { if let version = project.versions.first(where: { $0.path == versionPath }) ?? project.versions.first { store.openProject(version) } } label: {
                    Label("在 Cubase 中打开", systemImage: "arrow.up.forward.app")
                }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.directory) } label: { Image(systemName: "folder") }.help("显示工程文件夹")
                Spacer()
            }
            Picker("工程版本", selection: $versionPath) {
                ForEach(project.versions) { file in Text(file.name).tag(file.path) }
            }.font(.caption)
        }
    }
    var metadata: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("状态", selection: binding(\.stage)) { ForEach(Stage.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 210)
                Spacer()
                Toggle("可复用模板", isOn: binding(\.template)).toggleStyle(.checkbox).font(.caption)
            }
            HStack(spacing: 7) {
                Text("评分").font(.caption).foregroundStyle(.secondary)
                ForEach(1...5, id: \.self) { number in
                    Button { store.update(project.id) { $0.rating = $0.rating == number ? 0 : number } } label: {
                        Image(systemName: number <= annotation.rating ? "star.fill" : "star").foregroundStyle(.yellow)
                    }.buttonStyle(.plain).help("\(number) 星；再次点击取消")
                }
                Spacer()
                Text("BPM").font(.caption).foregroundStyle(.secondary)
                TextField("手动", text: binding(\.bpm)).textFieldStyle(.roundedBorder).frame(width: 60)
            }
            Text("按工程文件夹归组版本；备份数量仅供参考。BPM 为手动备注。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    var audioList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("导出试听").font(.headline)
                Spacer()
                Button("关联音频…") { store.associateAudio(project) }.font(.caption)
            }
            let audio = store.audio(for: project)
            if audio.isEmpty {
                Text("将完整混音导出到工程的 Mixdown 文件夹，或关联已有音频。").font(.caption).foregroundStyle(.secondary).padding(.vertical, 15)
            }
            ForEach(Array(audio.enumerated()), id: \.element.id) { index, file in
                HStack(spacing: 10) {
                    Button { player.load(file, project: project, autoplay: true) } label: {
                        Image(systemName: player.selected?.id == file.id && player.playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2).foregroundStyle(.mint)
                    }.buttonStyle(.plain).help("播放 / 暂停")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text("\(file.url.pathExtension.uppercased()) · \(file.modified == .distantPast ? "文件离线" : file.modified < project.modified ? "早于工程修改" : "已更新")")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.contentShape(Rectangle()).onTapGesture { player.load(file, project: project) }
                    Spacer(minLength: 0)
                    Text(index < 26 ? String(UnicodeScalar(65 + index)!) : "\(index + 1)").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    Menu {
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
                        if annotation.externalAudio.contains(where: { $0.path == file.path }) {
                            Button("取消外部关联") { store.update(project.id) { $0.externalAudio.removeAll { $0.path == file.path } } }
                        }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20)
                }.padding(11).background(player.selected?.id == file.id ? Color.mint.opacity(0.1) : panelColor, in: RoundedRectangle(cornerRadius: 8))
            }
            Text("同一工程切换音频时保持播放时间；当前版本不做响度对齐。")
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
                }.frame(width: 210, alignment: .leading)
                Button { player.stop() } label: { Image(systemName: "stop.fill") }.buttonStyle(.plain).disabled(player.selected == nil)
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34)).foregroundStyle(.mint)
                }.buttonStyle(.plain).disabled(player.selected == nil)
                Text(formatTime(player.time)).font(.system(.caption, design: .monospaced)).frame(width: 40)
                WaveformView(player: player).frame(height: 48)
                Text(formatTime(player.duration)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 40)
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: $player.volume, in: 0...1).frame(width: 95).help("试听音量")
            }
            if let error = player.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            else if let summary = player.summary {
                HStack {
                    Spacer()
                    Text("\(summary.sampleRate / 1000, specifier: "%.1f") kHz · \(summary.channels) 声道 · 原始 PCM 峰值波形")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal, 22).padding(.vertical, 14).background(panelColor)
    }
}
