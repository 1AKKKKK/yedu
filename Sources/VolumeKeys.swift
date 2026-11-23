import SwiftUI
import MediaPlayer
import AVFoundation

/// 用 MPVolumeView + 音量 KVO 劫持音量键做翻页：音量变化后立刻还原，避免真的改音量
final class VolumeKeyWatcher: NSObject {
    private let volumeView = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
    private var observation: NSKeyValueObservation?
    private var lastVolume: Float = 0
    private var restoring = false

    var onStep: ((Int) -> Void)?

    func attach(to host: UIView) {
        volumeView.showsRouteButton = false
        volumeView.showsVolumeSlider = true
        volumeView.alpha = 0.01
        host.addSubview(volumeView)

        lastVolume = AVAudioSession.sharedInstance().outputVolume
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume,
                                                              options: [.new]) { [weak self] _, change in
            guard let self = self, let v = change.newValue, !self.restoring else { return }
            guard abs(v - self.lastVolume) > 0.0001 else { return }
            let dir = v > self.lastVolume ? 1 : -1
            self.lastVolume = v
            self.restoreVolume(self.lastVolume - Float(dir) * 1.0 / 16.0)
            self.onStep?(dir)
        }
    }

    private func restoreVolume(_ target: Float) {
        restoring = true
        let clamped = min(1, max(0, target))
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let slider = self.volumeView.subviews.compactMap({ $0 as? UISlider }).first {
                slider.value = clamped
            }
            self.lastVolume = AVAudioSession.sharedInstance().outputVolume
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                self.restoring = false
            }
        }
    }

    func detach() {
        observation?.invalidate()
        observation = nil
        volumeView.removeFromSuperview()
    }

    deinit { observation?.invalidate() }
}

/// 把 watcher 挂进视图树
struct VolumeKeyHost: UIViewRepresentable {
    let watcher: VolumeKeyWatcher
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        watcher.attach(to: v)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
