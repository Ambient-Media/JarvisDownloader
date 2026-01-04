import Foundation
import Combine
import AppKit

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
            
            updateItem(item.id) {
                if isDuplicate {
                    $0.status = .skipped
                } else if success {
                    $0.status = .completed
                } else {
                    $0.status = .failed
                }
                $0.filePath = filePath
                $0.completedDate = Date()
            }
            
            // Add to history for record keeping
            if success || isDuplicate {
                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    let completedItem = items[idx]
                    addToHistory(completedItem)
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
            "--progress"
        ]
        
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
                
                // Read output in real-time for progress updates
                let outputHandle = outputPipe.fileHandleForReading
                
                outputHandle.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.count > 0 {
                        outputData.append(data)
                        
                        if let line = String(data: data, encoding: .utf8) {
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
                                                    self.items[idx].progress = percent / 100.0
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
                
                let isDuplicate = false
                let isSuccess = process.terminationStatus == 0
                
                if !isSuccess {
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
                
                // Extract filename from path
                if let path = filePath, !path.isEmpty {
                    let url = URL(fileURLWithPath: path)
                    let filename = url.deletingPathExtension().lastPathComponent
                    DispatchQueue.main.async {
                        if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                            self.items[idx].fileName = filename
                            self.items[idx].progress = 1.0
                        }
                    }
                }
                
                continuation.resume(returning: (true, filePath, isDuplicate))
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
}
