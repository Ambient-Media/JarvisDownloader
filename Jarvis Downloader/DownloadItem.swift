import Foundation

enum SourceType: String, Codable {
    case soundCloud = "SoundCloud"
    case bandcamp   = "Bandcamp"
    case youtube    = "YouTube"
    case unknown    = "Unknown"
}

enum DownloadStatus: String, Codable {
    case pending    = "Pending"
    case running    = "Downloading"
    case completed  = "Completed"
    case skipped    = "Already in Library"
    case failed     = "Failed"
}

struct DownloadItem: Identifiable, Codable {
    let id: UUID
    let url: URL
    let source: SourceType
    var status: DownloadStatus
    var progress: Double
    var fileName: String?
    var errorMessage: String?
    var completedDate: Date?
    var filePath: String?
    var isPlaylist: Bool = false
    var playlistTitle: String?
    var totalTracks: Int?
    var downloadedTracks: Int?
    var albumArtworkData: Data?
    
    init(url: URL, source: SourceType, isPlaylist: Bool = false) {
        self.id = UUID()
        self.url = url
        self.source = source
        self.status = .pending
        self.progress = 0.0
        self.fileName = nil
        self.errorMessage = nil
        self.completedDate = nil
        self.filePath = nil
        self.isPlaylist = isPlaylist
        self.playlistTitle = nil
        self.totalTracks = nil
        self.downloadedTracks = nil
        self.albumArtworkData = nil
    }
}

func detectSource(from url: URL) -> SourceType {
    let host = url.host ?? ""
    if host.contains("soundcloud.com") { return .soundCloud }
    if host.contains("bandcamp.com")   { return .bandcamp }
    if host.contains("youtube.com") || host.contains("youtu.be") { return .youtube }
    return .unknown
}

func isPlaylistURL(_ url: URL) -> Bool {
    let urlString = url.absoluteString
    // Check for common playlist patterns
    return urlString.contains("/sets/") || // SoundCloud playlists
           urlString.contains("?list=") || // YouTube playlists
           urlString.contains("&list=") || // YouTube playlists
           urlString.contains("/album/")   // Bandcamp albums
}
