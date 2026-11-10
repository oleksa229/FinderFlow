import SwiftUI
import UniformTypeIdentifiers
import AppKit

// Approximate height of the Table's column header row. Below this strip the pointer
// is over the rows, where the cursor must always be the plain arrow. Erring slightly
// tall keeps us from ever clobbering the header divider's resize cursor.
private let kTableHeaderStripHeight: CGFloat = 30

struct ListView: View {
    let files:         [FileItem]
    @Binding var selectedIDs:      Set<String>
    @Binding var pendingRenameURL: URL?
    let currentPath:   URL
    @Binding var sortField:     SortField
    @Binding var sortAscending: Bool
    let groupBy:       GroupBy
    /// Tree mode (ungrouped list only): rows carry an indent and a disclosure chevron.
    let showTree:       Bool
    let treeDepths:     [String: Int]
    let expandedIDs:    Set<String>
    let emptyFolderIDs: Set<String>
    let onToggleExpand: (FileItem) -> Void
    let onNavigate:    (FileItem) -> Void
    let onBrowseInto:  (URL) -> Void
    let onReload:      () -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService

    @State private var sortOrder:       [KeyPathComparator<FileItem>] = [.init(\.name, order: .forward)]
    /// Which columns are shown and in what order (header right-click menu + drag). Saved between launches.
    @State private var columnCustomization: TableColumnCustomization<FileItem> = Self.loadColumnCustomization()
    @State private var renamingID:      String?
    @State private var renameText:      String = ""
    @State private var renameCancelled: Bool   = false
    @FocusState private var renameActive: Bool

    var body: some View {
        if groupBy != .none {
            GroupedListView(
                files:            files,
                selectedIDs:      $selectedIDs,
                pendingRenameURL: $pendingRenameURL,
                currentPath:      currentPath,
                groupBy:          groupBy,
                onNavigate:       onNavigate,
                onBrowseInto:     onBrowseInto,
                onReload:         onReload,
                fileOps:          fileOps,
                favorites:        favorites
            )
        } else {
            tableView
                .onChange(of: pendingRenameURL) { _, url in
                    guard let url, let item = files.first(where: { $0.url == url }) else { return }
                    startRename(item: item)
                    pendingRenameURL = nil
                }
        }
    }

    // MARK: - Table (non-grouped)

    private var tableView: some View {
        Table(of: FileItem.self, selection: $selectedIDs, sortOrder: $sortOrder,
              columnCustomization: $columnCustomization) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 6) {
                    if showTree {
                        Color.clear.frame(width: CGFloat(treeDepths[item.id, default: 0]) * 16, height: 1)
                        if item.isBrowsableFolder && !emptyFolderIDs.contains(item.id) {
                            Button { onToggleExpand(item) } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .rotationEffect(.degrees(expandedIDs.contains(item.id) ? 90 : 0))
                                    .frame(width: 12, height: 16)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else {
                            Color.clear.frame(width: 12, height: 1)
                        }
                    }
                    Image(nsImage: item.icon).resizable().frame(width: 16, height: 16)
                        .allowsHitTesting(false)
                    if renamingID == item.id {
                        TextField("", text: $renameText)
                            .textFieldStyle(.plain)
                            .resetsCursorOnExit()
                            .focused($renameActive)
                            .onSubmit {
                                if let it = files.first(where: { $0.id == renamingID }) {
                                    commitRename(for: it)
                                }
                            }
                            .onExitCommand { cancelRename() }
                    } else {
                        Text(item.name).lineLimit(1)
                            .foregroundStyle(fileOps.isCut && fileOps.clipboardURLs.contains(item.url)
                                             ? Color.secondary : Color.primary)
                            .allowsHitTesting(false)
                    }
                    TagDotsView(colors: item.tagColors, size: 10)
                        .allowsHitTesting(false)
                }
            }
            .width(min: 140, ideal: 280, max: 600)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)   // Name stays: it holds the icon, tree chevron and rename

            TableColumn("Date Modified", value: \.dateModified) { item in
                Text(item.formattedDateModified).foregroundStyle(.secondary)
            }.width(min: 100, ideal: 148, max: 240).customizationID("dateModified")

            TableColumn("Date Created", value: \.dateCreated) { item in
                Text(item.formattedDateCreated).foregroundStyle(.secondary)
            }.width(min: 100, ideal: 148, max: 240).customizationID("dateCreated")

            TableColumn("Size", value: \.size) { item in
                Text(item.formattedSize).foregroundStyle(.secondary).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }.width(min: 50, ideal: 80, max: 140).customizationID("size")

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary)
            }.width(min: 60, ideal: 110, max: 200).customizationID("kind")

            TableColumn("Extension", value: \.fileExtension) { item in
                Text(item.fileExtension.isEmpty ? "—" : item.fileExtension.uppercased())
                    .foregroundStyle(.secondary)
            }.width(min: 40, ideal: 68, max: 120).customizationID("extension")
        } rows: {
            // Drag lives on the row, not on the Name cell: a cell-level onDrag swallowed
            // the click whenever the pointer was over the icon or the name text.
            ForEach(files) { item in
                if item.isBrowsableFolder {
                    TableRow(item)
                        .itemProvider { dragProvider(for: item) }
                        .dropDestination(for: URL.self) { urls in dropOnFolder(urls, item) }
                } else {
                    TableRow(item)
                        .itemProvider { dragProvider(for: item) }
                        .dropDestination(for: URL.self) { _ in dropNextTo(item) }
                }
            }
        }
        .onChange(of: sortOrder) { _, order in
            guard let first = order.first else { return }
            sortAscending = (first.order == .forward)
            switch first.keyPath {
            case \FileItem.name:          sortField = .name
            case \FileItem.dateModified:  sortField = .dateModified
            case \FileItem.dateCreated:   sortField = .dateCreated
            case \FileItem.size:          sortField = .size
            case \FileItem.kind:          sortField = .kind
            case \FileItem.fileExtension: sortField = .ext
            default: break
            }
        }
        .onChange(of: sortField)     { _, _ in syncSortOrder() }
        .onChange(of: sortAscending) { _, _ in syncSortOrder() }
        .onChange(of: files) { _, newFiles in
            if let id = renamingID, !newFiles.contains(where: { $0.id == id }) {
                renamingID = nil
            }
        }
        .onChange(of: renameActive)  { _, active in
            guard !active, let id = renamingID,
                  let item = files.first(where: { $0.id == id }) else { return }
            commitRename(for: item)
        }
        .onAppear { sortByNameIfSortColumnHidden(); syncSortOrder() }
        .onChange(of: columnCustomization) { _, value in
            if let data = try? JSONEncoder().encode(value) {
                UserDefaults.standard.set(data, forKey: UserPreferences.listColumnsKey)
            }
            sortByNameIfSortColumnHidden()
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.isEmpty {
                FolderBackgroundMenu()
            } else {
                contextMenu(for: ids)
            }
        }
        primaryAction: { ids in
            guard renamingID == nil else { return }
            if let id = ids.first, let item = files.first(where: { $0.id == id }) {
                onNavigate(item)
            }
        }
        .background(
            Button("") { quickLook(ids: selectedIDs) }
                .keyboardShortcut(.space, modifiers: []).hidden()
        )
        // Release the column-resize cursor once the pointer moves into the rows.
        // The Table's NSTableView header sets a resize cursor on its column dividers
        // and (like every AppKit drag) leaves it stuck after a resize. The header and
        // rows are the same view, so there's no enter/exit boundary to hook — instead
        // we watch the live pointer position: anywhere below the header strip the
        // cursor must be the plain arrow, so force it there. We never touch the header
        // region (resize cursor still shows while hovering/dragging a divider) and skip
        // it during an inline rename so the text I-beam isn't disturbed.
        .onContinuousHover { phase in
            guard renamingID == nil else { return }
            if case .active(let point) = phase, point.y > kTableHeaderStripHeight {
                NSCursor.arrow.set()
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { _ in
            dropIntoCurrentFolder()
            return true
        }
    }

    private func dragProvider(for item: FileItem) -> NSItemProvider {
        // Table makes one drag item per selected row, so each row carries only its own
        // file. (A provider with the whole selection exposed just its first file as a
        // file URL, so two selected files arrived as the same file twice.)
        FileDragSupport.provider(for: [item.url])
    }

    /// File URLs of the drag in progress. SwiftUI hands over 0 URLs for our drags: the
    /// item also carries a file promise (added by NSItemProvider(contentsOf:)) and the
    /// URL decoding gives up on it. The file URLs are still on the drag pasteboard.
    private func draggedURLs(fallback urls: [URL]) -> [URL] {
        let fromPasteboard = NSPasteboard(name: .drag)
            .readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return fromPasteboard.isEmpty ? urls : fromPasteboard
    }

    private func dropOnFolder(_ urls: [URL], _ item: FileItem) {
        fileOps.drop(draggedURLs(fallback: urls), onto: item.url,
                     forceCopy: NSEvent.modifierFlags.contains(.option),
                     reload: onReload)
    }

    /// Drop on a file row: the items go into the folder that holds that file. In tree
    /// mode this is the expanded subfolder the row belongs to, otherwise the open folder.
    private func dropNextTo(_ item: FileItem) {
        let folder = showTree ? item.url.deletingLastPathComponent() : currentPath
        fileOps.drop(draggedURLs(fallback: []), onto: folder,
                     forceCopy: NSEvent.modifierFlags.contains(.option),
                     reload: onReload)
    }

    /// Drop on the list itself (empty area): the items go into the open folder.
    private func dropIntoCurrentFolder() {
        fileOps.drop(draggedURLs(fallback: []), onto: currentPath,
                     forceCopy: NSEvent.modifierFlags.contains(.option),
                     reload: onReload)
    }

    private static func loadColumnCustomization() -> TableColumnCustomization<FileItem> {
        guard let data = UserDefaults.standard.data(forKey: UserPreferences.listColumnsKey),
              let value = try? JSONDecoder().decode(TableColumnCustomization<FileItem>.self, from: data)
        else { return TableColumnCustomization<FileItem>() }
        return value
    }

    /// A hidden column gives no sort indicator, so the order would look random.
    /// If the active sort column is hidden, fall back to Name (which cannot be hidden).
    private func sortByNameIfSortColumnHidden() {
        let id: String
        switch sortField {
        case .name:         return
        case .dateModified: id = "dateModified"
        case .dateCreated:  id = "dateCreated"
        case .size:         id = "size"
        case .kind:         id = "kind"
        case .ext:          id = "extension"
        }
        if columnCustomization[visibility: id] == .hidden { sortField = .name }
    }

    private func syncSortOrder() {
        let order: SortOrder = sortAscending ? .forward : .reverse
        switch sortField {
        case .name:         sortOrder = [KeyPathComparator(\.name,          order: order)]
        case .dateModified: sortOrder = [KeyPathComparator(\.dateModified,  order: order)]
        case .dateCreated:  sortOrder = [KeyPathComparator(\.dateCreated,   order: order)]
        case .size:         sortOrder = [KeyPathComparator(\.size,          order: order)]
        case .kind:         sortOrder = [KeyPathComparator(\.kind,          order: order)]
        case .ext:          sortOrder = [KeyPathComparator(\.fileExtension, order: order)]
        }
    }

    // MARK: - Inline rename helpers

    func startRename(item: FileItem) {
        renameCancelled = false
        renamingID      = item.id
        renameText      = item.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { renameActive = true }
    }

    private func commitRename(for item: FileItem) {
        renamingID   = nil
        renameActive = false
        guard !renameCancelled else { renameCancelled = false; return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return }
        fileOps.rename(item.url, to: name, reload: onReload)
    }

    private func cancelRename() {
        renameCancelled = true
        renamingID      = nil
    }

    // MARK: - Full macOS context menu

    @ViewBuilder
    func contextMenu(for ids: Set<String>) -> some View {
        let sel  = files.filter { ids.contains($0.id) }
        if let item = sel.first {
            let urls = sel.map(\.url)

            Button("Open")               { onNavigate(item) }
            OpenWithMenu(urls: urls)
            if item.isBrowsableFolder {
                Button("Open in New Window") { NSWorkspace.shared.open(item.url) }
            } else if item.isPackage {
                Button("Show Package Contents") { onBrowseInto(item.url) }
            }
            Divider()
            Button("Quick Look")         { quickLook(ids: ids) }
            Button("Get Info")           { showGetInfo(for: sel) }
            Divider()
            Button("Rename…")            { pendingRenameURL = item.url }
            Button(sel.count > 1 ? "Duplicate \(sel.count) Items" : "Duplicate") {
                fileOps.duplicate(urls, reload: onReload)
            }
            Button(sel.count > 1 ? "Make \(sel.count) Aliases" : "Make Alias") {
                urls.forEach { fileOps.makeAlias(for: $0, reload: onReload) }
            }
            Button(sel.count > 1 ? "Compress \(sel.count) Items" : "Compress \"\(item.name)\"") {
                fileOps.compress(urls, reload: onReload)
            }
            if sel.count == 1 && item.isArchive {
                Button("Extract Here") { fileOps.extract(item.url, reload: onReload) }
            }
            Divider()
            Button("Cut")                { fileOps.cut(urls) }
            Button("Copy")               { fileOps.copy(urls) }
            Button("Paste") {
                let dest = (sel.count == 1 && item.isDirectory) ? item.url : currentPath
                fileOps.paste(to: dest, reload: onReload)
            }
            .disabled(fileOps.pasteboardURLs.isEmpty)
            Divider()
            Menu("Share") {
                Button("AirDrop")        { fileOps.shareViaAirDrop(urls) }
                Divider()
                Button("Share…")         { fileOps.showShareSheet(for: urls) }
            }
            Divider()
            Menu("Tags") {
                TagMenuContent(targets: sel, fileOps: fileOps, onReload: onReload)
            }
            Divider()
            if item.isDirectory {
                if favorites.isPinned(item.url) {
                    Button("Remove from Sidebar") { favorites.unpin(item.url) }
                } else {
                    Button("Add to Sidebar") { favorites.pin(item.url) }
                }
            }
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
            }
            Button(sel.count > 1 ? "Copy \(sel.count) Paths" : "Copy Path") {
                fileOps.copyPath(urls.map(\.path).joined(separator: "\n"))
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                fileOps.trash(urls, reload: onReload)
            }
            Button("Delete Permanently…", role: .destructive) {
                confirmPermanentDelete(names: sel.map(\.name)) {
                    fileOps.permanentlyDelete(urls, reload: onReload)
                }
            }
        } else {
            Button("Paste") { fileOps.paste(to: currentPath, reload: onReload) }
                .disabled(fileOps.pasteboardURLs.isEmpty)
            if fileOps.canUndo { Button("Undo") { fileOps.undo() } }
            if fileOps.canRedo { Button("Redo") { fileOps.redo() } }
            Divider()
            Button("Refresh") { onReload() }
        }
    }

    // MARK: - Helpers

    private func quickLook(ids: Set<String>) {
        let urls = files.filter { ids.contains($0.id) }.map(\.url)
        guard !urls.isEmpty else { return }
        QuickLookController.shared.show(urls)
    }

    private func showGetInfo(for items: [FileItem]) {
        showGetInfoInFinder(items.map(\.url))
    }
}

// MARK: - Date-grouped list view

struct GroupedListView: View {
    let files:       [FileItem]
    @Binding var selectedIDs:      Set<String>
    @Binding var pendingRenameURL: URL?
    let currentPath: URL
    let groupBy:     GroupBy
    let onNavigate:  (FileItem) -> Void
    let onBrowseInto:(URL) -> Void
    let onReload:    () -> Void
    @ObservedObject var fileOps:   FileOperationsService
    @ObservedObject var favorites: FavoritesService

    @State private var renamingID:      String?
    @State private var renameText:      String = ""
    @State private var renameCancelled: Bool   = false
    @FocusState private var renameActive: Bool

    private var groups: [FileGroup] { groupedItems(files, by: groupBy) }

    var body: some View {
        ScrollViewReader { proxy in
        List(selection: $selectedIDs) {
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        ZStack(alignment: .leading) {
                            GroupedRow(item: item, isSelected: selectedIDs.contains(item.id))
                                .opacity(renamingID == item.id ? 0 : 1)
                                .allowsHitTesting(false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture(count: 2) {
                                            guard renamingID == nil else { return }
                                            onNavigate(item)
                                        }
                                        .onTapGesture {
                                            guard renamingID == nil else { return }
                                            selectedIDs = [item.id]
                                        }
                                )
                            if renamingID == item.id {
                                HStack(spacing: 8) {
                                    Image(nsImage: item.icon).resizable().frame(width: 18, height: 18)
                                    TextField("", text: $renameText)
                                        .textFieldStyle(.plain)
                                        .resetsCursorOnExit()
                                        .focused($renameActive)
                                        .onSubmit {
                                            if let it = files.first(where: { $0.id == renamingID }) {
                                                commitGroupedRename(for: it)
                                            }
                                        }
                                        .onExitCommand { cancelGroupedRename() }
                                    Spacer()
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .tag(item.id)
                        .id(item.id)
                        .fileDragOut(item: item, files: files, selectedIDs: selectedIDs)
                        .contextMenu { listContextMenu(item: item) }
                    }
                } header: {
                    DateSectionHeader(title: group.title, count: group.items.count)
                }
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.isEmpty {
                FolderBackgroundMenu()
            } else {
                if let id = ids.first, let item = files.first(where: { $0.id == id }) {
                    listContextMenu(item: item)
                }
            }
        }
        .onChange(of: selectedIDs) { _, ids in
            if let id = ids.first {
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .onChange(of: files) { _, newFiles in
            if let id = renamingID, !newFiles.contains(where: { $0.id == id }) {
                renamingID = nil
            }
        }
        .onChange(of: renameActive) { _, active in
            guard !active, let id = renamingID,
                  let item = files.first(where: { $0.id == id }) else { return }
            commitGroupedRename(for: item)
        }
        .onChange(of: pendingRenameURL) { _, url in
            guard let url, let item = files.first(where: { $0.url == url }) else { return }
            startGroupedRename(item: item)
            pendingRenameURL = nil
        }
        .background(
            Button("") {
                let urls = files.filter { selectedIDs.contains($0.id) }.map(\.url)
                if !urls.isEmpty { QuickLookController.shared.show(urls) }
            }
            .keyboardShortcut(.space, modifiers: []).hidden()
        )
        } // ScrollViewReader
    }

    // MARK: - Grouped inline rename helpers

    func startGroupedRename(item: FileItem) {
        renameCancelled = false
        renamingID      = item.id
        renameText      = item.name
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { renameActive = true }
    }

    private func commitGroupedRename(for item: FileItem) {
        renamingID   = nil
        renameActive = false
        guard !renameCancelled else { renameCancelled = false; return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return }
        fileOps.rename(item.url, to: name, reload: onReload)
    }

    private func cancelGroupedRename() {
        renameCancelled = true
        renamingID      = nil
    }

    @ViewBuilder
    private func listContextMenu(item: FileItem) -> some View {
        let sel     = files.filter { selectedIDs.contains($0.id) }
        let targets = sel.isEmpty ? [item] : sel
        let urls    = targets.map(\.url)

        Button("Open")       { onNavigate(item) }
        OpenWithMenu(urls: urls)
        if item.isBrowsableFolder {
            Button("Open in New Window") { NSWorkspace.shared.open(item.url) }
        } else if item.isPackage {
            Button("Show Package Contents") { onBrowseInto(item.url) }
        }
        Button("Quick Look") { QuickLookController.shared.show(urls) }
        Button("Get Info")   { showGetInfoInFinder([item.url]) }
        Divider()
        Button("Rename…")   { pendingRenameURL = item.url }
        Button("Duplicate") { fileOps.duplicate(urls, reload: onReload) }
        Button(targets.count > 1 ? "Make \(targets.count) Aliases" : "Make Alias") {
            urls.forEach { fileOps.makeAlias(for: $0, reload: onReload) }
        }
        Button(targets.count > 1 ? "Compress \(targets.count) Items" : "Compress \"\(item.name)\"") {
            fileOps.compress(urls, reload: onReload)
        }
        if targets.count == 1, item.isArchive {
            Button("Extract Here") { fileOps.extract(item.url, reload: onReload) }
        }
        Divider()
        Button("Cut")  { fileOps.cut(urls) }
        Button("Copy") { fileOps.copy(urls) }
        Button("Paste") {
            let dest = (targets.count == 1 && item.isDirectory) ? item.url : currentPath
            fileOps.paste(to: dest, reload: onReload)
        }
        .disabled(fileOps.pasteboardURLs.isEmpty)
        Divider()
        Menu("Share") {
            Button("AirDrop") { fileOps.shareViaAirDrop(urls) }
            Divider()
            Button("Share…") { fileOps.showShareSheet(for: urls) }
        }
        Divider()
        Menu("Tags") {
            TagMenuContent(targets: targets, fileOps: fileOps, onReload: onReload)
        }
        Divider()
        if item.isBrowsableFolder {
            if favorites.isPinned(item.url) {
                Button("Remove from Sidebar") { favorites.unpin(item.url) }
            } else {
                Button("Add to Sidebar") { favorites.pin(item.url) }
            }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.selectFile(item.url.path, inFileViewerRootedAtPath: "")
        }
        Button(targets.count > 1 ? "Copy \(targets.count) Paths" : "Copy Path") {
            fileOps.copyPath(urls.map(\.path).joined(separator: "\n"))
        }
        Divider()
        Button("Move to Trash", role: .destructive) {
            fileOps.trash(urls, reload: onReload)
        }
        Button("Delete Permanently…", role: .destructive) {
            confirmPermanentDelete(names: targets.map(\.name)) {
                fileOps.permanentlyDelete(urls, reload: onReload)
            }
        }
    }
}

struct GroupedRow: View {
    let item:       FileItem
    let isSelected: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: item.icon).resizable().frame(width: 18, height: 18)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.name).font(.system(size: 13)).lineLimit(1)
                        .allowsHitTesting(false)
                    TagDotsView(colors: item.tagColors, size: 9)
                        .allowsHitTesting(false)
                }
                Text(item.kind + (item.isDirectory ? "" : " • \(item.formattedSize)"))
                    .font(.caption).foregroundStyle(.secondary)
                    .allowsHitTesting(false)
            }
            Spacer()
            Text(item.formattedDateModified)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Date section header (Finder-style)

struct DateSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
            Spacer()
            Text("\(count) \(count == 1 ? "item" : "items")")
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.6)
        }
    }
}

struct FolderBackgroundMenu: View {
    var body: some View {
        Button("New Folder") {
            NotificationCenter.default.post(name: .createNewFolder, object: nil)
        }
        Button("New File") {
            NotificationCenter.default.post(name: .createNewFile, object: nil)
        }
    }
}


// MARK: - "Open With" context menu item
// Lists the apps macOS says can open every selected item (the default app of the
// first item comes first), plus "Other…" to pick any app. The chosen app opens all
// selected items.

struct OpenWithMenu: View {
    let urls: [URL]

    var body: some View {
        if let first = urls.first {
            Menu("Open With") {
                let apps = Self.apps(for: urls)
                ForEach(apps, id: \.path) { app in
                    Button { Self.open(urls, with: app) } label: {
                        Label {
                            Text(Self.name(of: app, isDefault: app == apps.first && Self.isDefault(app, for: first)))
                        } icon: {
                            Image(nsImage: Self.icon(of: app))
                        }
                    }
                }
                if !apps.isEmpty { Divider() }
                Button("Other…") { Self.chooseApp(for: urls) }
            }
        }
    }

    private static func isDefault(_ app: URL, for url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) == app
    }

    private static func apps(for urls: [URL]) -> [URL] {
        guard let url = urls.first else { return [] }
        let ws = NSWorkspace.shared
        var seen = Set<String>()
        var list = ws.urlsForApplications(toOpen: url).filter { seen.insert($0.path).inserted }
        // Keep only apps that can open every selected item (like Finder).
        for other in urls.dropFirst() {
            let paths = Set(ws.urlsForApplications(toOpen: other).map(\.path))
            list.removeAll { !paths.contains($0.path) }
        }
        // Look up each display name once, not on every comparison.
        let names = Dictionary(uniqueKeysWithValues: list.map { ($0.path, name(of: $0, isDefault: false)) })
        list.sort { (names[$0.path] ?? "").localizedStandardCompare(names[$1.path] ?? "") == .orderedAscending }
        if let def = ws.urlForApplication(toOpen: url), list.contains(def) {
            list.removeAll { $0 == def }
            list.insert(def, at: 0)
        }
        return list
    }

    private static func name(of app: URL, isDefault: Bool) -> String {
        let n = FileManager.default.displayName(atPath: app.path)
        let base = n.hasSuffix(".app") ? String(n.dropLast(4)) : n
        return isDefault ? "\(base) (default)" : base
    }

    private static func icon(of app: URL) -> NSImage {
        let img = NSWorkspace.shared.icon(forFile: app.path)
        img.size = NSSize(width: 16, height: 16)
        return img
    }

    private static func open(_ urls: [URL], with app: URL) {
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Could not open with \(name(of: app, isDefault: false))"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private static func chooseApp(for urls: [URL]) {
        let panel = NSOpenPanel()
        panel.title = "Choose Application"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(urls, with: app)
    }
}
