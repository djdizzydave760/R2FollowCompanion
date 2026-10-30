import SwiftUI
import MediaPlayer

struct SystemAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsVolumeSlider = false
        view.showsRouteButton = true
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.showsVolumeSlider = false
        uiView.showsRouteButton = true
    }
}
