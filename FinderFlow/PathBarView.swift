import SwiftUI
import AppKit

struct PathBarView: View {
    @Binding var currentPath: URL
    @Binding var isEditing: Bool
    @State private var editText = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.caption)

            if isEditing {
                TextField("Path", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .resetsCursorOnExit()
                    .focused($fieldFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { isEditing = false }
                    .onChange(of: fieldFocused) { _, focused in
                        if !focused { isEditing = false }
                    }
            } else {
                breadcrumbs
            }

            if isEditing { Spacer(minLength: 0) }

            Button { copyPathToClipboard() } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .buttonStyle(.borderless)
            .help("Copy full path")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var breadcrumbs: some View {
        // Path fits: show it plus a clickable empty area to its right.
        // Path too long: fall back to horizontal scrolling (double-click edits).
        ViewThatFits(in: .horizontal) {
            breadcrumbItems
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { beginEditing() }
                )
            ScrollView(.horizontal, showsIndicators: false) {
                breadcrumbItems
            }
            .onTapGesture(count: 2) { beginEditing() }
        }
    }

    private var breadcrumbItems: some View {
        HStack(spacing: 2) {
            ForEach(pathComponents, id: \.path) { component in
                Button {
                    currentPath = component
                } label: {
                    Text(component.lastPathComponent.isEmpty ? "/" : component.lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundStyle(component == currentPath ? .primary : .secondary)
                }
                .buttonStyle(.borderless)

                if component != pathComponents.last {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func beginEditing() {
        editText = currentPath.path
        isEditing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private var pathComponents: [URL] {
        var components: [URL] = []
        var url = currentPath
        components.append(url)
        while url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
            components.insert(url, at: 0)
        }
        return components
    }

    private func commitEdit() {
        // A pasted path often has a space or a line break at the end.
        let typed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = NSString(string: typed).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir),
           isDir.boolValue, FileItem.isBrowsableFolder(url) {
            currentPath = url
        } else {
            NSSound.beep()   // not a folder we can open
        }
        isEditing = false
    }

    private func copyPathToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentPath.path, forType: .string)
        // Fire the same feedback notification the toolbar / context-menu "Copy Path"
        // actions use, so this button shows the "Path copied" toast too.
        NotificationCenter.default.post(name: .ffCopyPathFeedback, object: nil)
    }
}
