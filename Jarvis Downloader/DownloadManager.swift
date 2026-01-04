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
            if item.status == .completed || item.status == .skipped { continue }
            
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
            }
            
            if success && !isDuplicate, let idx = items.firstIndex(where: { $0.id == item.id }) {
                let completedItem = items[idx]
                addToHistory(completedItem)
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
            "--print", "after_move:filepath"
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
        let process = Process()
        process.launchPath = "/opt/homebrew/bin/yt-dlp"
        process.arguments = ytDlpArguments(for: item, in: folder)
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
        } catch {
            print("❌ Failed to launch yt-dlp: \(error.localizedDescription)")
            updateItem(item.id) { $0.errorMessage = error.localizedDescription }
            return (false, nil, false)
        }
        
        process.waitUntilExit()
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        
        let outputString = String(data: outputData, encoding: .utf8) ?? ""
        let errorString = String(data: errorData, encoding: .utf8) ?? ""
        
        let isDuplicate = false
        let isSuccess = process.terminationStatus == 0
        
        if !isSuccess {
            print("❌ yt-dlp error: \(errorString)")
            updateItem(item.id) { $0.errorMessage = errorString }
            return (false, nil, false)
        }
        
        let filePath = outputString.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").last
        
        // Extract filename from path
        if let path = filePath, !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            let filename = url.deletingPathExtension().lastPathComponent
            updateItem(item.id) { $0.fileName = filename }
        }
        
        return (true, filePath, isDuplicate)
    }
    
    private func updateItem(_ id: UUID, _ update: @escaping (inout DownloadItem) -> Void) {
        DispatchQueue.main.async {
            if let idx = self.items.firstIndex(where: { $0.id == id }) {
                update(&self.items[idx])
            }
        }
    }
    
    private func addToHistory(_ item: DownloadItem) {
        DispatchQueue.main.async {
            var updatedItem = item
            updatedItem.completedDate = Date()
            self.history.append(updatedItem)
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
}
