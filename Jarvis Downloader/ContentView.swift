import SwiftUI

struct ContentView: View {
    @StateObject private var downloadManager = DownloadManager()
    @State private var urlInput = ""
    @State private var showingImportAlert = false
    @State private var importMessage = ""
    @State private var isImporting = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header with folder path
            HeaderBar(rootFolder: downloadManager.rootFolder,
                      jarvisFolder: downloadManager.jarvisDownloadsFolder,
                      onFolderChange: changeFolder,
                      onImport: importFiles)
            
            Divider()
            
            HStack(spacing: 0) {
                // Left side: URL input
                InputSection(
                    urlInput: $urlInput,
                    onAdd: addToQueue,
                    onStart: startDownload,
                    isRunning: downloadManager.isRunning,
                    hasItemsInQueue: !downloadManager.items.filter { $0.status == .pending || $0.status == .running }.isEmpty
                )
                
                Divider()
                
                // Middle: Active queue (pending/downloading)
                DownloadListSection(
                    title: "Queue",
                    items: downloadManager.items.filter {
                        $0.status == .pending || $0.status == .running
                    },
                    onRemove: removeItem,
                    onDelete: deleteItem,
                    onRedownload: nil,  // Queue items can't be re-downloaded
                    onClearAll: nil
                )
                
                Divider()
                
                // Right: Library (completed/failed/skipped)
                DownloadListSection(
                    title: "Library",
                    items: downloadManager.history,
                    onRemove: removeFromHistory,
                    onDelete: deleteFromHistory,
                    onRedownload: redownloadItem,  // Library items can be re-downloaded
                    onClearAll: clearAllHistory
                )
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert("Import Complete", isPresented: $showingImportAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importMessage)
        }
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture {
                            // Prevent closing by tapping outside
                        }
                    
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Importing existing files...")
                            .font(.system(size: 14, weight: .medium))
                        Text("This may take a while for many files")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        
                        Button("Cancel") {
                            isImporting = false
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(30)
                    .background(Color(NSColor.windowBackgroundColor))
                    .cornerRadius(12)
                }
            }
        }
    }
    
    private func addToQueue() {
        let urls = urlInput
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) }
        
        for url in urls {
            let source = detectSource(from: url)
            let playlist = isPlaylistURL(url)
            let item = DownloadItem(url: url, source: source, isPlaylist: playlist)
            downloadManager.items.append(item)
        }
        
        downloadManager.saveQueueToDefaults()
        urlInput = ""
    }
    
    private func startDownload() {
        Task {
            await downloadManager.startDownload()
        }
    }
    
    private func removeItem(id: UUID) {
        downloadManager.removeItem(id: id)
    }
    
    private func deleteItem(id: UUID) {
        downloadManager.deleteItem(id: id)
    }
    
    private func changeFolder(url: URL) {
        downloadManager.rootFolder = url
    }
    
    private func removeFromHistory(id: UUID) {
        downloadManager.removeFromHistory(id: id)
    }
    
    private func deleteFromHistory(id: UUID) {
        downloadManager.deleteFromHistory(id: id)
    }
    
    private func redownloadItem(id: UUID) {
        downloadManager.redownloadItem(id: id)
    }
    
    private func clearAllHistory() {
        downloadManager.clearAllHistory()
    }
    
    private func importFiles() {
        isImporting = true
        Task {
            let result = await downloadManager.importExistingFiles()
            await MainActor.run {
                isImporting = false
                if result.imported > 0 {
                    importMessage = "Added \(result.imported) files to your library."
                } else {
                    importMessage = "No new files found. All existing files are already in your library."
                }
                showingImportAlert = true
            }
        }
    }
}

struct HeaderBar: View {
    let rootFolder: URL
    let jarvisFolder: URL
    let onFolderChange: (URL) -> Void
    let onImport: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 16))
                .foregroundColor(.blue)
            
            Text(rootFolder.path)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            
            Spacer()
            
            Button(action: {
                onImport()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import Files")
                }
                .font(.system(size: 12, weight: .medium))
            }
            
            Button(action: chooseFolder) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.gearshape")
                    Text("Change")
                }
                .font(.system(size: 12, weight: .medium))
            }
            
            Button(action: openFolder) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.square")
                    Text("Open")
                }
                .font(.system(size: 12, weight: .medium))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"
        
        if panel.runModal() == .OK, let url = panel.url {
            onFolderChange(url)
        }
    }
    
    private func openFolder() {
        NSWorkspace.shared.open(jarvisFolder)
    }
}

struct InputSection: View {
    @Binding var urlInput: String
    let onAdd: () -> Void
    let onStart: () -> Void
    let isRunning: Bool
    let hasItemsInQueue: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
                
                Text("Paste URLs")
                    .font(.system(size: 16, weight: .semibold))
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            
            Text("One per line • SoundCloud, YouTube, Bandcamp")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.horizontal, 20)
            
            TextEditor(text: $urlInput)
                .font(.system(size: 13, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .background(Color(NSColor.textBackgroundColor))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 20)
            
            HStack(spacing: 12) {
                Button(action: onAdd) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill")
                        Text("Add to Queue")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.2) : Color.blue.opacity(0.1))
                    .foregroundColor(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .blue)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                
                Button(action: onStart) {
                    HStack(spacing: 8) {
                        Image(systemName: isRunning ? "stop.circle.fill" : "arrow.down.circle.fill")
                        Text(isRunning ? "Downloading..." : "Start Download")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(hasItemsInQueue && !isRunning ? Color.orange : Color.gray.opacity(0.2))
                    .foregroundColor(hasItemsInQueue && !isRunning ? .white : .secondary)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(isRunning || !hasItemsInQueue)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 350)
    }
}

struct DownloadListSection: View {
    let title: String
    let items: [DownloadItem]
    let onRemove: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onRedownload: ((UUID) -> Void)?  // Optional - only for Library
    let onClearAll: (() -> Void)?
    
    @State private var sortOption: SortOption = .dateAdded
    
    enum SortOption: String, CaseIterable {
        case dateAdded = "Date Added"
        case name = "Name"
        case status = "Status"
        case source = "Source"
    }
    
    var sortedItems: [DownloadItem] {
        let sorted: [DownloadItem]
        
        switch sortOption {
        case .dateAdded:
            sorted = items.reversed() // Newest first
        case .name:
            sorted = items.sorted { (item1, item2) in
                let name1 = item1.fileName ?? item1.url.absoluteString
                let name2 = item2.fileName ?? item2.url.absoluteString
                return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
            }
        case .status:
            sorted = items.sorted { $0.status.rawValue < $1.status.rawValue }
        case .source:
            sorted = items.sorted { $0.source.rawValue < $1.source.rawValue }
        }
        
        return sorted
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.blue)
                
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                
                Spacer()
                
                Text("\(items.count) items")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            
            Divider()
            
            // Toolbar
            HStack(spacing: 12) {
                // Clear completed button (only show for Library)
                if title == "Library", let clearAll = onClearAll {
                    Button(action: clearAll) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text("Clear All")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(items.isEmpty)
                }
                
                Spacer()
                
                // Sort dropdown
                Menu {
                    ForEach(SortOption.allCases, id: \.self) { option in
                        Button(action: { sortOption = option }) {
                            HStack {
                                Text(option.rawValue)
                                if sortOption == option {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11))
                        Text(sortOption.rawValue)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.gray.opacity(0.1))
                    .cornerRadius(6)
                }
                .menuStyle(.borderlessButton)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            if items.isEmpty {
                EmptyStateView()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sortedItems) { item in
                            DownloadItemCard(
                                item: item,
                                onRemove: { onRemove(item.id) },
                                onDelete: { onDelete(item.id) },
                                onRedownload: onRedownload != nil ? { onRedownload!(item.id) } : nil
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}



struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No downloads yet")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
            
            Text("Paste URLs on the left and click 'Add to Queue' to get started")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DownloadItemCard: View {
    let item: DownloadItem
    let onRemove: () -> Void
    let onDelete: () -> Void
    let onRedownload: (() -> Void)?  // Optional - only for Library items
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                platformIcon
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    
                    HStack(spacing: 6) {
                        Text(item.source.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(platformColor.opacity(0.9))
                        
                        Circle()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 3, height: 3)
                        
                        Text(statusText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(statusColor)
                        
                        if item.status == .running && item.progress > 0 {
                            Circle()
                                .fill(Color.secondary.opacity(0.4))
                                .frame(width: 3, height: 3)
                            
                            Text("\(Int(item.progress * 100))%")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.blue)
                        }
                    }
                }
                
                Spacer()
                
                statusIndicator
            }
            .padding(10)
            
            if item.status == .running && item.progress > 0 {
                VStack(spacing: 0) {
                    Divider()
                        .padding(.horizontal, 10)
                    
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.blue.opacity(0.15))
                            
                            Rectangle()
                                .fill(Color.blue)
                                .frame(width: geometry.size.width * item.progress)
                        }
                    }
                    .frame(height: 3)
                }
            }
        }
        .background(cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: 1)
        )
        .contextMenu {
            // Re-download option (only for Library items)
            if let redownload = onRedownload {
                Button(action: redownload) {
                    Label("Re-download", systemImage: "arrow.clockwise")
                }
                
                Divider()
            }
            
            if let path = item.filePath, !path.isEmpty {
                Button(action: {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                }) {
                    Label("Show in Finder", systemImage: "folder")
                }
                
                Divider()
            }
            
            Button(action: onRemove) {
                Label("Remove from List", systemImage: "trash")
            }
            
            if let path = item.filePath, !path.isEmpty {
                Button(action: onDelete) {
                    Label("Delete File & Remove", systemImage: "trash.fill")
                }
            }
        }
    }
    
    private var displayTitle: String {
        if let fileName = item.fileName, !fileName.isEmpty {
            return fileName
                .replacingOccurrences(of: ".mp3", with: "")
                .replacingOccurrences(of: ".m4a", with: "")
        }
        
        if let path = item.filePath, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            return url.deletingPathExtension().lastPathComponent
        }
        
        if item.isPlaylist {
            if let title = item.playlistTitle {
                return title
            }
            return "Playlist"
        }
        
        return item.url.absoluteString
    }
    
    private var statusText: String {
        if item.isPlaylist && item.status == .running {
            if let downloaded = item.downloadedTracks, let total = item.totalTracks {
                return "Downloading (\(downloaded)/\(total))"
            }
        }
        return item.status.rawValue
    }
    
    private var platformIcon: some View {
        ZStack {
            if let artworkData = item.albumArtworkData,
               let nsImage = NSImage(data: artworkData) {
                // Show album artwork
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 32, height: 32)
                    .cornerRadius(6)
            } else {
                // Show platform icon fallback
                RoundedRectangle(cornerRadius: 6)
                    .fill(platformColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                
                Image(systemName: platformSystemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(platformColor)
            }
            
            if item.isPlaylist {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(2)
                    .background(Color.blue)
                    .clipShape(Circle())
                    .offset(x: 10, y: -10)
            }
        }
    }
    
    private var statusIndicator: some View {
        Group {
            switch item.status {
            case .running:
                ProgressView()
                    .scaleEffect(0.7)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.green)
            case .skipped:
                Image(systemName: "doc.on.doc.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.orange)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.red)
            case .pending:
                Image(systemName: "clock.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary.opacity(0.5))
            }
        }
    }
    
    private var platformSystemImage: String {
        switch item.source {
        case .soundCloud: return "waveform"
        case .youtube: return "play.rectangle.fill"
        case .bandcamp: return "music.note"
        case .unknown: return "link.circle"
        }
    }
    
    private var platformColor: Color {
        switch item.source {
        case .soundCloud: return Color(red: 1.0, green: 0.4, blue: 0.0)
        case .youtube: return Color(red: 1.0, green: 0.0, blue: 0.0)
        case .bandcamp: return Color(red: 0.38, green: 0.73, blue: 0.82)
        case .unknown: return .gray
        }
    }
    
    private var statusColor: Color {
        switch item.status {
        case .completed: return .green
        case .skipped: return .orange
        case .failed: return .red
        case .running: return .blue
        case .pending: return .secondary
        }
    }
    
    private var cardBackground: Color {
        switch item.status {
        case .running:
            return Color.blue.opacity(0.05)
        case .completed:
            return Color.green.opacity(0.05)
        case .skipped:
            return Color.orange.opacity(0.05)
        case .failed:
            return Color.red.opacity(0.05)
        default:
            return Color(NSColor.controlBackgroundColor).opacity(0.5)
        }
    }
    
    private var borderColor: Color {
        switch item.status {
        case .running:
            return Color.blue.opacity(0.3)
        case .completed:
            return Color.green.opacity(0.3)
        case .skipped:
            return Color.orange.opacity(0.3)
        case .failed:
            return Color.red.opacity(0.3)
        default:
            return Color.gray.opacity(0.15)
        }
    }
}
