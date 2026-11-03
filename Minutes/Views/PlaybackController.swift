import AVFoundation
import Observation

/// Plays a meeting back from any point, so a doubtful word can be checked against the audio.
@MainActor
@Observable
final class PlaybackController {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var url: URL?
    private var timer: Timer?

    func load(_ url: URL?) {
        guard url != self.url else { return }
        stop()
        self.url = url
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else {
            self.player = nil
            duration = 0
            return
        }
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        currentTime = 0
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play(from time: TimeInterval? = nil) {
        guard let player else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        if let time { player.currentTime = max(0, min(time, player.duration)) }
        player.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func stop() {
        pause()
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            timer?.invalidate()
        }
    }
}
