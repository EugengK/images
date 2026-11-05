import SwiftUI

struct ContentView: View {
    @EnvironmentObject var lib: Library

    var body: some View {
        ZStack {
            if lib.folder == nil { WelcomeView() }
            else if lib.viewing { ViewerView() }
            else { GridView() }
        }
        .navigationTitle(lib.folder?.lastPathComponent ?? "PixView")
        .toolbar(lib.folder == nil || lib.viewing ? .hidden : .visible, for: .windowToolbar)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { lib.chooseFolder() } label: { Label("폴더 열기", systemImage: "folder") }
                Button { lib.goUp() } label: { Label("상위 폴더", systemImage: "arrow.up") }
                Menu {
                    ForEach(lib.subfolders, id: \.self) { f in
                        Button(f.lastPathComponent) { lib.load(folder: f) }
                    }
                } label: { Label("하위 폴더", systemImage: "folder.badge.gearshape") }
                .disabled(lib.subfolders.isEmpty)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("정렬", selection: $lib.sortKey) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle(isOn: $lib.ascending) {
                    Label("오름차순", systemImage: lib.ascending ? "arrow.up" : "arrow.down")
                }
                Toggle(isOn: $lib.favoritesOnly) {
                    Label("즐겨찾기만", systemImage: lib.favoritesOnly ? "star.fill" : "star")
                }
                Slider(value: $lib.thumbSize, in: 90...300).frame(width: 110)
                Button { lib.moveToFolder(lib.targets) } label: { Label("이동", systemImage: "folder.badge.plus") }
                    .disabled(lib.targets.isEmpty)
                Button { lib.trash(lib.targets) } label: { Label("삭제", systemImage: "trash") }
                    .disabled(lib.targets.isEmpty)
            }
        }
        .overlay(alignment: .bottom) {
            if let m = lib.message {
                HStack(spacing: 8) {
                    if lib.busy { ProgressView().controlSize(.small) }
                    Text(m)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 18)
                .transition(.opacity)
            }
        }
        .animation(.default, value: lib.message)
        .alert("이름 바꾸기 (확장자 제외)", isPresented: $lib.showRename) {
            TextField("파일 이름", text: $lib.renameText)
            Button("변경") { lib.commitRename() }
            Button("취소", role: .cancel) {}
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            lib.open(url: u)
            return true
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject var lib: Library
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("PixView").font(.largeTitle.bold())
            Text("폴더를 열거나 이 창에 폴더/이미지를 끌어다 놓으세요").foregroundStyle(.secondary)
            Button("폴더 열기…") { lib.chooseFolder() }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}
