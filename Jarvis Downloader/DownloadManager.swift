import Foundation
import Combine
import AppKit
import AVFoundation

final class DownloadManager: ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published var history: [DownloadItem] = []
    @Published var isRunning = false
    @Published var rootFolder: URL {
        didSet {
            UserDefaults.standard.set(rootFolder.path, forKey: "jarvisRootFolder")
        }
    }
    
    var jarvisDownloadsFolder: URL {
        rootFolder.appendingPathComponent("Jarvis Downloads", isDirectory: true)
    }
    
    var downloadArchivePath: URL {
        jarvisDownloadsFolder.appendingPathComponent(".download-archive.txt")
    }
    
    private let historyKey = "jarvisDownloadHistory"
    private let queueKey = "jarvisDownloadQueue"
    
    init() {
        if let savedPath = UserDefaults.standard.string(forKey: "jarvisRootFolder"),
           let savedURL = URL(string: "file://" + savedPath) {
            self.rootFolder = savedURL
        } else {
            self.rootFolder = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop")
        }
        
        try? FileManager.default.createDirectory(
            at: jarvisDownloadsFolder,
            withIntermediateDirectories: true
        )
        
        loadHistory()
        loadQueue()
        migrateCompletedItems()
    }
    
    // Move any completed items from queue to history
    private func migrateCompletedItems() {
        let completedInQueue = items.filter {
            $0.status == .completed || $0.status == .failed || $0.status == .skipped
        }
        
        for item in completedInQueue {
            if !history.contains(where: { $0.id == item.id }) {
                history.append(item)
            }
        }
        
        // Remove completed items from queue
        items.removeAll {
            $0.status == .completed || $0.status == .failed || $0.status == .skipped
        }
        
        if !completedInQueue.isEmpty {
            saveHistory()
            saveQueue()
        }
    }
    
    func startDownload() async {
        guard !isRunning else { return }
        
        DispatchQueue.main.async {
            self.isRunning = true
        }
        
        await processQueue()
    }
    
    private func processQueue() async {
        for item in items {
            // Skip items that are already done
            if item.status == .completed || item.status == .skipped || item.status == .failed {
                continue
            }
            
            updateItem(item.id) { $0.status = .running }
            
            let (success, filePath, isDuplicate) = await runYtDlp(for: item, in: jarvisDownloadsFolder)
            
            // Update status first
            let finalStatus: DownloadStatus
            if isDuplicate {
                finalStatus = .skipped
            } else if success {
                finalStatus = .completed
            } else {
                finalStatus = .failed
            }
            
            // Update the item completely
            await MainActor.run {
                if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[idx].status = finalStatus
                    self.items[idx].filePath = filePath
                    self.items[idx].completedDate = Date()
                }
            }
            
            // Small delay to let UI update
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            
            // NOW copy the fully-updated item to history
            await MainActor.run {
                if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                    let completedItem = self.items[idx]
                    self.history.append(completedItem)
                    self.saveHistory()
                    self.items.remove(at: idx)
                    self.saveQueue()
                }
            }
        }
        
        DispatchQueue.main.async { self.isRunning = false }
    }
    
    private func ytDlpArguments(for item: DownloadItem, in folder: URL) -> [String] {
        var args: [String] = []
        
        args += [
            "--ffmpeg-location", "/opt/homebrew/bin",
            "-x", "--audio-format", "mp3",
            "--embed-thumbnail",
            "-o", "\(folder.path)/%(artist,uploader)s - %(title)s.%(ext)s",
            "--print", "after_move:filepath",
            "--newline",
            "--progress",
            "--download-archive", downloadArchivePath.path,
            "--no-overwrites"
        ]
        
        // If it's a playlist, add playlist-specific options
        if item.isPlaylist {
            args += [
                "--yes-playlist",
                "--print", "playlist:%(playlist)s",
                "--print", "playlist_count:%(playlist_count)s"
            ]
        } else {
            args += ["--no-playlist"]
        }
        
        switch item.source {
        case .soundCloud:
            args += [
                "--user-agent", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                "--add-header", "Accept-Language:en-US,en;q=0.9"
            ]
        case .bandcamp, .youtube, .unknown:
            break
        }
        
        args.append(item.url.absoluteString)
        return args
    }
    
    private func runYtDlp(for item: DownloadItem, in folder: URL) async -> (Bool, String?, Bool) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.launchPath = "/opt/homebrew/bin/yt-dlp"
                process.arguments = self.ytDlpArguments(for: item, in: folder)
                
                let outputPipe = Pipe()
                let errorPipe = Pipe()
                process.standardOutput = outputPipe
                process.standardError = errorPipe
                
                var outputData = Data()
                var playlistTitle: String?
                var totalTracks = 0
                var downloadedTracks = 0
                var skippedTracks = 0
                
                // Read output in real-time for progress updates
                let outputHandle = outputPipe.fileHandleForReading
                
                outputHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.count > 0 {
                        outputData.append(data)
                        
                        if let line = String(data: data, encoding: .utf8) {
                            // Parse playlist info
                            if line.hasPrefix("playlist:") {
                                playlistTitle = line.replacingOccurrences(of: "playlist:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                            if line.hasPrefix("playlist_count:") {
                                if let count = Int(line.replacingOccurrences(of: "playlist_count:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)) {
                                    totalTracks = count
                                }
                            }
                            
                            // Track downloads and skips
                            if line.contains("[download] Downloading item") {
                                downloadedTracks += 1
                                if item.isPlaylist {
                                    DispatchQueue.main.async {
                                        if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                                            self.items[idx].downloadedTracks = downloadedTracks
                                            self.items[idx].totalTracks = totalTracks
                                            if let title = playlistTitle {
                                                self.items[idx].playlistTitle = title
                                            }
                                        }
                                    }
                                }
                            }
                            
                            if line.contains("has already been downloaded") || line.contains("has already been recorded in the archive") {
                                skippedTracks += 1
                                if item.isPlaylist {
                                    DispatchQueue.main.async {
                                        if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                                            self.items[idx].totalTracks = totalTracks
                                        }
                                    }
                                }
                            }
                            
                            // Parse progress from yt-dlp output
                            // Format: [download]  45.2% of 5.23MiB at 1.23MiB/s ETA 00:03
                            if line.contains("[download]") && line.contains("%") {
                                let components = line.components(separatedBy: " ")
                                for component in components {
                                    if component.hasSuffix("%") {
                                        if let percentStr = component.dropLast().split(separator: ".").first,
                                           let percent = Double(percentStr) {
                                            DispatchQueue.main.async {
                                                if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                                                    // For playlists, calculate overall progress
                                                    if item.isPlaylist && totalTracks > 0 {
                                                        let trackProgress = Double(downloadedTracks) / Double(totalTracks)
                                                        let currentTrackProgress = (percent / 100.0) / Double(totalTracks)
                                                        self.items[idx].progress = trackProgress + currentTrackProgress
                                                    } else {
                                                        self.items[idx].progress = percent / 100.0
                                                    }
                                                }
                                            }
                                        }
                                        break
                                    }
                                }
                            }
                        }
                    }
                }
                
                do {
                    try process.run()
                } catch {
                    print("❌ Failed to launch yt-dlp: \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                            self.items[idx].errorMessage = error.localizedDescription
                        }
                    }
                    outputHandle.readabilityHandler = nil
                    continuation.resume(returning: (false, nil, false))
                    return
                }
                
                process.waitUntilExit()
                outputHandle.readabilityHandler = nil
                
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let outputString = String(data: outputData, encoding: .utf8) ?? ""
                let errorString = String(data: errorData, encoding: .utf8) ?? ""
                
                // Check if everything was already downloaded
                let allSkipped = (downloadedTracks == 0 && skippedTracks > 0) ||
                                (item.isPlaylist && totalTracks > 0 && skippedTracks == totalTracks)
                let isSuccess = process.terminationStatus == 0
                
                if !isSuccess && !allSkipped {
                    print("❌ yt-dlp error: \(errorString)")
                    DispatchQueue.main.async {
                        if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                            self.items[idx].errorMessage = errorString
                        }
                    }
                    continuation.resume(returning: (false, nil, false))
                    return
                }
                
                let filePath = outputString.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last
                
                // Extract filename from path or use playlist title
                if item.isPlaylist {
                    DispatchQueue.main.async {
                        if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                            if let title = playlistTitle {
                                self.items[idx].fileName = "\(title) (\(downloadedTracks) new / \(totalTracks) total)"
                            } else {
                                self.items[idx].fileName = "Playlist (\(downloadedTracks) new / \(totalTracks) total)"
                            }
                            self.items[idx].progress = 1.0
                        }
                    }
                } else if let path = filePath, !path.isEmpty {
                    let url = URL(fileURLWithPath: path)
                    let filename = url.deletingPathExtension().lastPathComponent
                    DispatchQueue.main.async {
                        if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                            self.items[idx].fileName = filename
                            self.items[idx].progress = 1.0
                        }
                    }
                }
                
                continuation.resume(returning: (isSuccess, filePath, allSkipped))
            }
        }
    }
    
    private func updateItem(_ id: UUID, _ update: @escaping (inout DownloadItem) -> Void) {
        DispatchQueue.main.async {
            if let idx = self.items.firstIndex(where: { $0.id == id }) {
                update(&self.items[idx])
                self.saveQueue()
            }
        }
    }
    
    private func addToHistory(_ item: DownloadItem) {
        DispatchQueue.main.async {
            self.history.append(item)
            self.saveHistory()
        }
    }
    
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            self.history = decoded
        }
    }
    
    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(encoded, forKey: historyKey)
        }
    }
    
    private func loadQueue() {
        if let data = UserDefaults.standard.data(forKey: queueKey),
           let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            self.items = decoded
        }
    }
    
    private func saveQueue() {
        if let encoded = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(encoded, forKey: queueKey)
        }
    }
    
    // Public method to save queue from outside
    func saveQueueToDefaults() {
        saveQueue()
    }
    
    // Remove item from list only
    func removeItem(id: UUID) {
        DispatchQueue.main.async {
            self.items.removeAll { $0.id == id }
            self.saveQueue()
        }
    }
    
    // Delete file from disk and remove from list
    func deleteItem(id: UUID) {
        if let item = items.first(where: { $0.id == id }),
           let filePath = item.filePath {
            let fileURL = URL(fileURLWithPath: filePath)
            
            do {
                try FileManager.default.removeItem(at: fileURL)
                print("✅ Deleted file: \(filePath)")
            } catch {
                print("❌ Failed to delete file: \(error.localizedDescription)")
            }
        }
        
        // Remove from list regardless of whether file deletion succeeded
        removeItem(id: id)
    }
    
    // Remove item from history only
    func removeFromHistory(id: UUID) {
        DispatchQueue.main.async {
            self.history.removeAll { $0.id == id }
            self.saveHistory()
        }
    }
    
    // Delete file from disk and remove from history
    func deleteFromHistory(id: UUID) {
        if let item = history.first(where: { $0.id == id }),
           let filePath = item.filePath {
            let fileURL = URL(fileURLWithPath: filePath)
            
            do {
                try FileManager.default.removeItem(at: fileURL)
                print("✅ Deleted file: \(filePath)")
            } catch {
                print("❌ Failed to delete file: \(error.localizedDescription)")
            }
        }
        
        removeFromHistory(id: id)
    }
    
    // Clear all items from history
    func clearAllHistory() {
        DispatchQueue.main.async {
            self.history.removeAll()
            self.saveHistory()
        }
    }
    
    // Import existing files into the library
    func importExistingFiles() async -> (imported: Int, failed: Int) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fileManager = FileManager.default
                var importedCount = 0
                
                // Get all MP3 files in the downloads folder
                guard let files = try? fileManager.contentsOfDirectory(at: self.jarvisDownloadsFolder, includingPropertiesForKeys: [.creationDateKey])
                    .filter({ $0.pathExtension.lowercased() == "mp3" }) else {
                    continuation.resume(returning: (0, 0))
                    return
                }
                
                print("📂 Found \(files.count) MP3 files to import")
                
                // Create DownloadItems for each file
                var importedItems: [DownloadItem] = []
                
                for file in files {
                    let filename = file.deletingPathExtension().lastPathComponent
                    
                    // Get file creation date
                    var creationDate = Date()
                    if let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                       let fileCreationDate = attributes[.creationDate] as? Date {
                        creationDate = fileCreationDate
                    }
                    
                    // Extract album artwork from MP3
                    // Note: Using deprecated API but it still works
                    var artworkData: Data?
                    let asset = AVAsset(url: file)
                    let metadata = asset.commonMetadata
                    for item in metadata {
                        if item.commonKey == .commonKeyArtwork,
                           let data = item.dataValue {
                            artworkData = data
                            break
                        }
                    }
                    
                    // Create a DownloadItem for this file
                    let dummyURL = URL(string: "file://imported")!
                    var item = DownloadItem(url: dummyURL, source: .soundCloud)
                    item.fileName = filename
                    item.status = .completed
                    item.completedDate = creationDate
                    item.filePath = file.path
                    item.albumArtworkData = artworkData
                    
                    importedItems.append(item)
                    importedCount += 1
                }
                
                // Add all imported items to history on main thread
                DispatchQueue.main.async {
                    // Only add items that aren't already in history (check by filename)
                    let existingFilenames = Set(self.history.compactMap { $0.fileName })
                    let newItems = importedItems.filter { item in
                        guard let filename = item.fileName else { return false }
                        return !existingFilenames.contains(filename)
                    }
                    
                    self.history.append(contentsOf: newItems)
                    self.saveHistory()
                    
                    print("✅ Import complete: \(newItems.count) new files added to library")
                    continuation.resume(returning: (newItems.count, 0))
                }
            }
        }
    }
}
