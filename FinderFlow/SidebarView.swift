import SwiftUI

enum SidebarItem: Hashable {
    case location(URL)
    case pinned(URL)
    case recent(URL)

    var folderURL: URL {
        switch self {
        case .location(let url), .pinned(let url), .recent(let url):
            return url
        }
    }
}

// MARK: - Favorites service (pinned folders)

class FavoritesService: ObservableObject {
    @Published var pinnedURLs: [URL] = []

    init() { load() }

    func load() {
        pinnedURLs = (UserDefaults.standard.stringArray(forKey: "pinnedFolders") ?? [])
            .compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func pin(_ url: URL) {
        guard url.hasDirectoryPath, !pinnedURLs.contains(url) else { return }
        pinnedURLs.insert(url, at: 0)
        save()
    }

    func unpin(_ url: URL) {
        pinnedURLs.removeAll { $0 == url }
        save()
    }

    func isPinned(_ url: URL) -> Bool { pinnedURLs.contains(url) }

    private func save() {
        UserDefaults.standard.set(pinnedURLs.map(\.path), forKey: "pinnedFolders")
    }
}

// MARK: - Sidebar view

struct SidebarView: View {
    @Binding var currentPath:     URL
    @Binding var selection:       SidebarItem?
    @Binding var activeTagFilter: String?
    let usedTagNames: [String]
    @EnvironmentObject var favorites: FavoritesService
    @State private var recentFolders: [URL] = []
    @State private var iCloudDriveURL: URL?   // checked once on appear, not on every redraw
    @State private var volumes: [MountedVolume] = []

    var body: some View {
        List(selection: $selection) {

            // ── System locations ──────────────────────────────────────────
            Section("Favorites") {
                ForEach(systemLocations, id: \.self) { url in
                    SidebarRow(url: url)
                        .tag(SidebarItem.location(url))
                }
            }

            // ── Mounted volumes (internal disk, USB drives, disk images, network shares) ──
            if !volumes.isEmpty {
                Section("Locations") {
                    ForEach(volumes) { volume in
                        SidebarRow(url: volume.url, name: volume.name)
                            .tag(SidebarItem.location(volume.url))
                    }
                }
            }

            // ── User-pinned folders ───────────────────────────────────────
            if !favorites.pinnedURLs.isEmpty {
                Section("Pinned") {
                    ForEach(favorites.pinnedURLs, id: \.self) { url in
                        SidebarRow(url: url)
                            .tag(SidebarItem.pinned(url))
                            .contextMenu {
                                Button("Remove from Pinned") { favorites.unpin(url) }
                            }
                    }
                    .onDelete { idx in
                        idx.forEach { favorites.unpin(favorites.pinnedURLs[$0]) }
                    }
                }
            }

            // ── Recent ────────────────────────────────────────────────────
            if !recentFolders.isEmpty {
                Section("Recent") {
                    ForEach(recentFolders.prefix(8), id: \.self) { url in
                        SidebarRow(url: url)
                            .tag(SidebarItem.recent(url))
                    }
                }
            }

            // ── Tags (only when files in current folder are tagged) ────────
            if !usedTagNames.isEmpty {
                Section("Tags") {
                    ForEach(usedTagNames, id: \.self) { tag in
                        tagRow(tag: tag)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear {
            loadRecent()
            volumes = MountedVolume.current()
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
            iCloudDriveURL = FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        // Keep the list in step when a drive is plugged in, ejected or renamed.
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumes = MountedVolume.current()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumes = MountedVolume.current()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didRenameVolumeNotification)) { _ in
            volumes = MountedVolume.current()
        }
        .onChange(of: selection) { _, item in
            guard let url = item?.folderURL, url != currentPath else { return }
            // Defer so the sidebar list is not rebuilt inside its own selection update.
            DispatchQueue.main.async {
                if currentPath != url { currentPath = url }
            }
        }
        .onChange(of: currentPath) { _, path in
            guard path.hasDirectoryPath else { return }
            DispatchQueue.main.async { addToRecent(path) }
        }
    }

    private var systemLocations: [URL] {
        let fm = FileManager.default
        return [
            fm.homeDirectoryForCurrentUser,
            fm.urls(for: .desktopDirectory,  in: .userDomainMask).first,
            fm.urls(for: .documentDirectory, in: .userDomainMask).first,
            fm.urls(for: .downloadsDirectory, in: .userDomainMask).first,
            iCloudDriveURL,
        ].compactMap { $0 }
    }

    private func loadRecent() {
        recentFolders = (UserDefaults.standard.stringArray(forKey: "recentFolders") ?? [])
            .compactMap { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func addToRecent(_ url: URL) {
        var paths = UserDefaults.standard.stringArray(forKey: "recentFolders") ?? []
        paths.removeAll { $0 == url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(20)), forKey: "recentFolders")
        recentFolders = Array(paths.prefix(8)).compactMap { URL(fileURLWithPath: $0) }
    }

    @ViewBuilder
    private func tagRow(tag: String) -> some View {
        let isActive = activeTagFilter == tag
        let dotColor = FileItem.colorForTagName(tag) ?? Color(nsColor: .systemGray)
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 11, height: 11)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5))
            Text(tag)
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
            Spacer()
            if isActive {
                Image(systemName: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .listRowBackground(isActive ? Color.accentColor.opacity(0.1) : Color.clear)
        .onTapGesture {
            activeTagFilter = isActive ? nil : tag
        }
    }
}

struct MountedVolume: Identifiable, Equatable {
    let url: URL
    let name: String
    var id: URL { url }

    /// Volumes Finder shows: hidden system volumes (Data, Preboot, VM...) are skipped.
    static func current() -> [MountedVolume] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeNameKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeLocalizedName ?? values?.volumeName
                ?? FileManager.default.displayName(atPath: url.path)
            return MountedVolume(url: url, name: name)
        }
    }
}

struct SidebarRow: View {
    let url: URL
    var name: String? = nil
    private var displayName: String {
        if let name { return name }
        if url.lastPathComponent == "com~apple~CloudDocs" { return "iCloud Drive" }
        return url.lastPathComponent.isEmpty ? "Macintosh HD" : url.lastPathComponent
    }
    var body: some View {
        Label {
            Text(displayName).lineLimit(1)
        } icon: {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 16, height: 16)
        }
    }
}
