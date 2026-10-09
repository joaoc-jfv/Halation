import SwiftUI

/// Draws the selected sidecar subtitle over the video, in step with the playhead.
struct SubtitleOverlay: View {
    @Environment(PlayerModel.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            // Subtitles belong to the visible picture, so they follow crops and zoom.
            let rect = VideoGeometry.placement(
                container: geometry.size, videoSize: player.mediaInfo?.presentationSize, layout: player.videoLayout
            ).clipRect
            let style = player.subtitles.style
            let bottom = SubtitleLayout.bottomInset(
                videoRect: rect, container: geometry.size, style: style, controlsVisible: player.controlsVisible
            )
            // Re-read the playhead ~30 times a second while playing; when paused, observation of
            // `currentTime` redraws on seeks and frame steps.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying)) { _ in
                SubtitleText(cues: player.activeSubtitleCues(), style: style, videoHeight: rect.height, maxWidth: rect.width * 0.86)
                    .padding(.bottom, bottom)
                    .frame(width: rect.width, height: rect.height, alignment: .bottom)
            }
            .offset(x: rect.minX, y: rect.minY)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: bottom)
        }
        .allowsHitTesting(false)
    }
}

/// The cue text block, styled. Also used by the settings preview.
struct SubtitleText: View {
    let cues: [SubtitleCue]
    let style: SubtitleStyle
    let videoHeight: CGFloat
    let maxWidth: CGFloat

    var body: some View {
        let fontSize = style.fontSize(forVideoHeight: videoHeight)
        VStack(spacing: fontSize * 0.2) {
            ForEach(Array(cues.enumerated()), id: \.offset) { _, cue in
                Text(SubtitleMarkup.attributedString(from: cue.text))
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(style.background == .shadow ? 0.95 : 0), radius: fontSize * 0.1, y: fontSize * 0.04)
                    .shadow(color: .black.opacity(style.background == .shadow ? 0.6 : 0), radius: fontSize * 0.25)
                    .padding(.horizontal, style.background == .box ? fontSize * 0.5 : 0)
                    .padding(.vertical, style.background == .box ? fontSize * 0.2 : 0)
                    .background {
                        if style.background == .box {
                            RoundedRectangle(cornerRadius: fontSize * 0.3).fill(.black.opacity(0.72))
                        }
                    }
            }
        }
        .frame(maxWidth: maxWidth)
    }
}
