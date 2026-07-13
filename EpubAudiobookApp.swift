import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ZIPFoundation

// MARK: - App Main Entry Point
@main
struct EpubAudiobookApp: App {
    init() {
        // Configure standard background execution audio pipeline routing
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to initialize background AVAudioSession: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            MainContentView()
        }
    }
}

// MARK: - Models
struct VoiceProfile: Identifiable, Hashable {
    let id: String
    let name: String
    let languageCode: String
    let gender: String
    let region: String
}

struct BookChapter: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let contentText: String
    var audioURL: URL?
    
    static func == (lhs: BookChapter, rhs: BookChapter) -> Bool {
        return lhs.id == rhs.id && lhs.audioURL == rhs.audioURL
    }
}

// MARK: - Main Application Controller
class AudiobookManager: NSObject, ObservableObject {
    @Published var isExtracting = false
    @Published var currentBookTitle = "No Book Loaded"
    @Published var chapters: [BookChapter] = []
    @Published var currentChapterIndex: Int = 0
    
    // Voice configurations
    @Published var selectedVoiceId: String = ""
    @Published var availableVoices: [VoiceProfile] = []
    
    // Processing Trackers
    @Published var processingProgress: Double = 0.0
    @Published var isRenderingAudio = false
    
    // Media Playback State
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0.0
    @Published var duration: TimeInterval = 0.0
    
    private var audioPlayer: AVAudioPlayer?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var displayTimer: Timer?
    
    override init() {
        super.init()
        loadVoiceProfiles()
        startTimer()
    }
    
    private func loadVoiceProfiles() {
        let targets = [
            ("en-US", "American"),
            ("en-GB", "British"),
            ("en-AU", "Australian")
        ]
        
        var localizedProfiles: [VoiceProfile] = []
        let systemVoices = AVSpeechSynthesisVoice.speechVoices()
        
        for (lang, regionLabel) in targets {
            let matches = systemVoices.filter { $0.language.lowercased().hasPrefix(lang.lowercased()) }
            
            // Find distinct genders
            let femaleVoice = matches.first { $0.gender == .female } ?? matches.first
            let maleVoice = matches.first { $0.gender == .male } ?? matches.last
            
            if let female = femaleVoice {
                localizedProfiles.append(VoiceProfile(id: female.identifier, name: "\(regionLabel) - Female", languageCode: female.language, gender: "Female", region: regionLabel))
            }
            if let male = maleVoice, male.identifier != femaleVoice?.identifier {
                localizedProfiles.append(VoiceProfile(id: male.identifier, name: "\(regionLabel) - Male", languageCode: male.language, gender: "Male", region: regionLabel))
            }
        }
        
        self.availableVoices = localizedProfiles
        if let first = localizedProfiles.first {
            self.selectedVoiceId = first.id
        }
    }
    
    // MARK: - EPUB Parsing Process
    func importEpubFile(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        
        isExtracting = true
        chapters.removeAll()
        currentBookTitle = url.deletingPathExtension().lastPathComponent
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            
            do {
                try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
                try fm.unzipItem(at: url, to: tempDir)
                
                // Track down the container configuration entry file mapping
                let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
                guard fm.fileExists(atPath: containerURL.path) else {
                    self.failOnMainThread("Invalid EPUB format (Missing layout container)")
                    return
                }
                
                let containerContent = try String(contentsOf: containerURL, encoding: .utf8)
                guard let opfPath = self.extractAttribute(from: containerContent, tag: "rootfile", attribute: "full-path") else {
                    self.failOnMainThread("Could not determine package structure configuration file.")
                    return
                }
                
                let opfURL = tempDir.appendingPathComponent(opfPath)
                let opfContent = try String(contentsOf: opfURL, encoding: .utf8)
                let baseFolderURL = opfURL.deletingLastPathComponent()
                
                // Parse out filemanifest layout links
                var manifestMap: [String: String] = [:]
                let manifestRegex = try NSRegularExpression(pattern: "<item[^>]+id=\"([^\"]+)\"[^>]+href=\"([^\"]+)\"", options: [])
                let nsContent = opfContent as NSString
                let matches = manifestRegex.matches(in: opfContent, options: [], range: NSRange(location: 0, length: nsContent.length))
                
                for match in matches {
                    let idStr = nsContent.substring(with: match.range(at: 1))
                    let hrefStr = nsContent.substring(with: match.range(at: 2))
                    manifestMap[idStr] = hrefStr
                }
                
                // Reconstruct chapter linear sequence order matching structural spines
                var orderedChapterFiles: [String] = []
                let spineRegex = try NSRegularExpression(pattern: "<itemref[^>]+idref=\"([^\"]+)\"", options: [])
                let spineMatches = spineRegex.matches(in: opfContent, options: [], range: NSRange(location: 0, length: nsContent.length))
                
                for match in spineMatches {
                    let idref = nsContent.substring(with: match.range(at: 1))
                    if let fileRelativePath = manifestMap[idref] {
                        orderedChapterFiles.append(fileRelativePath)
                    }
                }
                
                var parsedChapters: [BookChapter] = []
                for (idx, relativePath) in orderedChapterFiles.enumerated() {
                    // Resolve URL decoding for filenames inside manifest files
                    let cleanPath = relativePath.removingPercentEncoding ?? relativePath
                    let chapterURL = baseFolderURL.appendingPathComponent(cleanPath)
                    
                    if fm.fileExists(atPath: chapterURL.path) {
                        let htmlRaw = try String(contentsOf: chapterURL, encoding: .utf8)
                        let textData = self.stripHTMLTags(htmlRaw)
                        
                        if !textData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let title = "Chapter \(idx + 1)"
                            parsedChapters.append(BookChapter(id: UUID(), title: title, contentText: textData, audioURL: nil))
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.chapters = parsedChapters
                    self.isExtracting = false
                    self.currentChapterIndex = 0
                    if !parsedChapters.isEmpty {
                        self.renderAudioForCurrentBook()
                    }
                }
                
            } catch {
                self.failOnMainThread("Parsing aborted: \(error.localizedDescription)")
            }
        }
    }
    
    // MARK: - Text to Audio Rendering Engine
    func renderAudioForCurrentBook() {
        guard !chapters.isEmpty else { return }
        isRenderingAudio = true
        processingProgress = 0.0
        
        renderNextChapterAudio(index: 0)
    }
    
    private func renderNextChapterAudio(index: Int) {
        guard index < chapters.count else {
            DispatchQueue.main.async {
                self.isRenderingAudio = false
                self.processingProgress = 1.0
                self.loadChapterAudio(index: self.currentChapterIndex)
            }
            return
        }
        
        DispatchQueue.main.async {
            self.processingProgress = Double(index) / Double(self.chapters.count)
        }
        
        let chapter = chapters[index]
        let utterance = AVSpeechUtterance(string: chapter.contentText)
        utterance.voice = AVSpeechSynthesisVoice(identifier: selectedVoiceId) ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        
        let fm = FileManager.default
        let fileName = "chapter_\(chapter.id.uuidString).caf"
        let outputURL = fm.temporaryDirectory.appendingPathComponent(fileName)
        
        try? fm.removeItem(at: outputURL)
        
        var audioFile: AVAudioFile? = nil
        
        speechSynthesizer.write(utterance) { [weak self] buffer in
            guard let self = self else { return }
            guard let pcmBuffer = buffer as? AVAudioPCMBuffer else { return }
            
            // iOS 17 uses 1 frame size padding to declare synthesis execution termination
            let terminationFrameThreshold = (pcmBuffer.format.commonFormat == .pcmFormatInt16 || pcmBuffer.format.commonFormat == .pcmFormatInt32) ? 0 : 1
            
            if pcmBuffer.frameLength <= terminationFrameThreshold {
                // Done writing file reference asset
                audioFile = nil
                DispatchQueue.main.async {
                    self.chapters[index].audioURL = outputURL
                    self.renderNextChapterAudio(index: index + 1)
                }
            } else {
                do {
                    if audioFile == nil {
                        audioFile = try AVAudioFile(forWriting: outputURL, settings: pcmBuffer.format.settings, commonFormat: pcmBuffer.format.commonFormat, interleaved: pcmBuffer.format.isInterleaved)
                    }
                    try audioFile?.write(from: pcmBuffer)
                } catch {
                    print("Error outputting audio buffer chunk stream sequence: \(error)")
                }
            }
        }
    }
    
    // MARK: - Audio Playback Engine
    func loadChapterAudio(index: Int) {
        guard index >= 0 && index < chapters.count else { return }
        currentChapterIndex = index
        stop()
        
        guard let url = chapters[index].audioURL else { return }
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.prepareToPlay()
            duration = audioPlayer?.duration ?? 0.0
            currentTime = 0.0
        } catch {
            print("Audio setup failed: \(error)")
        }
    }
    
    func playPause() {
        guard let player = audioPlayer else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }
    
    func stop() {
        audioPlayer?.stop()
        isPlaying = false
        currentTime = 0.0
    }
    
    func skipForward() {
        guard let player = audioPlayer else { return }
        player.currentTime = min(player.currentTime + 15, player.duration)
        currentTime = player.currentTime
    }
    
    func skipBackward() {
        guard let player = audioPlayer else { return }
        player.currentTime = max(player.currentTime - 15, 0)
        currentTime = player.currentTime
    }
    
    func seek(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        player.currentTime = time
        currentTime = time
    }
    
    private func startTimer() {
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.audioPlayer, self.isPlaying else { return }
            self.currentTime = player.currentTime
            
            // Continuous auto-advance track transition
            if player.currentTime >= player.duration - 0.2 {
                self.advanceTrackAutomatically()
            }
        }
    }
    
    private func advanceTrackAutomatically() {
        if currentChapterIndex + 1 < chapters.count {
            loadChapterAudio(index: currentChapterIndex + 1)
            playPause()
        } else {
            stop()
        }
    }
    
    // MARK: - Utilities
    private func stripHTMLTags(_ html: String) -> String {
        guard let data = html.data(using: .utf8) else { return html }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributedString.string
        }
        
        // Dynamic structural fallback scanner stripping engine loop
        return html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
    
    private func extractAttribute(from content: String, tag: String, attribute: String) -> String? {
        let pattern = "<\(tag)[^>]*\(attribute)=\"([^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: content, options: [], range: NSRange(content.startIndex..., in: content)) {
            return (content as NSString).substring(with: match.range(at: 1))
        }
        return nil
    }
    
    private func failOnMainThread(_ message: String) {
        DispatchQueue.main.async {
            self.isExtracting = false
            self.isRenderingAudio = false
            self.currentBookTitle = "Import Failure: \(message)"
        }
    }
}

// MARK: - Views
struct MainContentView: View {
    @StateObject private var manager = AudiobookManager()
    @State private var showFilePicker = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                
                // Document Info Panel
                VStack(spacing: 6) {
                    Text(manager.currentBookTitle)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    if manager.isExtracting {
                        ProgressView("Unzipping & Parsing Layout Structures...")
                    } else if manager.isRenderingAudio {
                        VStack(spacing: 4) {
                            ProgressView(value: manager.processingProgress)
                                .progressViewStyle(.linear)
                            Text("Baking voice frames: \(Int(manager.processingProgress * 100))%")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 40)
                    }
                }
                .padding()
                .background(Color(.secondarySystemBackground))
                .cornerRadius(12)
                .padding(.horizontal)
                
                // Voice Profile Selector Engine Interface
                HStack {
                    Text("Narrator Profile:")
                        .font(.subheadline)
                        .bold()
                    Spacer()
                    Picker("Voice", selection: $manager.selectedVoiceId) {
                        ForEach(manager.availableVoices) { voice in
                            Text(voice.name).tag(voice.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: manager.selectedVoiceId) { _ in
                        manager.renderAudioForCurrentBook()
                    }
                }
                .padding(.horizontal, 24)
                
                // Dynamic Multi-Channel Linear Interactive Chapter Matrix
                List {
                    Section(header: Text("Book Chapters")) {
                        if manager.chapters.isEmpty {
                            Text("No content imported. Open an EPUB file to begin.")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(0..<manager.chapters.count, id: \.self) { idx in
                                HStack {
                                    Button(action: {
                                        manager.loadChapterAudio(index: idx)
                                        manager.playPause()
                                    }) {
                                        HStack {
                                            Image(systemName: manager.currentChapterIndex == idx && manager.isPlaying ? "speaker.wave.3.fill" : "play.circle")
                                                .foregroundColor(manager.currentChapterIndex == idx ? .accentColor : .primary)
                                            Text(manager.chapters[idx].title)
                                                .font(.body)
                                                .foregroundColor(manager.currentChapterIndex == idx ? .accentColor : .primary)
                                        }
                                    }
                                    Spacer()
                                    
                                    if let audioURL = manager.chapters[idx].audioURL {
                                        ShareLink(item: audioURL) {
                                            Image(systemName: "square.and.arrow.up")
                                                .font(.subheadline)
                                        }
                                    } else {
                                        Image(systemName: "hourglass")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                
                // Master Audio Playback Controls Scrub Panel
                VStack(spacing: 12) {
                    // Time Markers Control Layout Matrix
                    HStack {
                        Text(formatTime(manager.currentTime))
                            .font(.caption2)
                            .monospacedDigit()
                        Slider(value: Binding(get: { manager.currentTime }, set: { manager.seek(to: $0) }), in: 0...max(manager.duration, 1))
                        Text(formatTime(manager.duration))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 24)
                    
                    // Hardware Execution Button Deck
                    HStack(spacing: 40) {
                        Button(action: manager.skipBackward) {
                            Image(systemName: "gobackward.15")
                                .font(.title)
                        }
                        
                        Button(action: manager.playPause) {
                            Image(systemName: manager.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 56))
                        }
                        .disabled(manager.chapters.isEmpty || manager.isRenderingAudio)
                        
                        Button(action: manager.skipForward) {
                            Image(systemName: "goforward.15")
                                .font(.title)
                        }
                    }
                }
                .padding(.bottom, 20)
            }
            .navigationTitle("EPUB Audiobook Builder")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showFilePicker = true }) {
                        Image(systemName: "doc.badge.plus")
                            .font(.title3)
                    }
                }
            }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [UTType(filenameExtension: "epub")!], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let fileURL = urls.first {
                        manager.importEpubFile(from: fileURL)
                    }
                case .failure(let error):
                    print("File reference mapping initialization rejected: \(error)")
                }
            }
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}