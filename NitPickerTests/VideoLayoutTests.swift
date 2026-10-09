import Foundation
import Testing
@testable import NitPicker

private func expectClose(_ actual: CGRect, _ expected: CGRect, sourceLocation: SourceLocation = #_sourceLocation) {
    let close = abs(actual.minX - expected.minX) < 0.01 && abs(actual.minY - expected.minY) < 0.01
        && abs(actual.width - expected.width) < 0.01 && abs(actual.height - expected.height) < 0.01
    #expect(close, "\(actual) is not \(expected)", sourceLocation: sourceLocation)
}

@Suite struct VideoGeometryTests {
    private let container = CGSize(width: 1000, height: 600)
    private let hd = CGSize(width: 1920, height: 1080)

    private func place(_ layout: VideoLayout = VideoLayout(), video: CGSize? = nil) -> VideoPlacement {
        VideoGeometry.placement(container: container, videoSize: video ?? hd, layout: layout)
    }

    @Test func defaultFitsTheVideoAndClipsToIt() {
        let placement = place()
        expectClose(placement.videoRect, CGRect(x: 0, y: 18.75, width: 1000, height: 562.5))
        expectClose(placement.clipRect, placement.videoRect)
        #expect(!placement.stretches)
    }

    @Test func aWideCropRemovesBakedInBars() {
        // 2.39:1 inside a 16:9 frame: the bars above and below are cut away.
        let placement = place(VideoLayout(crop: .r239))
        expectClose(placement.videoRect, CGRect(x: 0, y: 18.75, width: 1000, height: 562.5))
        let visibleHeight = 1000 / 2.39
        expectClose(placement.clipRect, CGRect(x: 0, y: (600 - visibleHeight) / 2, width: 1000, height: visibleHeight))
    }

    @Test func aNarrowCropRemovesPillarbars() {
        let placement = place(VideoLayout(crop: .r4x3))
        expectClose(placement.clipRect, CGRect(x: 100, y: 0, width: 800, height: 600))
        expectClose(placement.videoRect, CGRect(x: -1000.0 / 30, y: 0, width: 3200.0 / 3, height: 600))
    }

    @Test func cropsAlwaysKeepTheirRatio() {
        for crop in VideoLayout.Crop.allCases.dropFirst() {
            let clip = place(VideoLayout(crop: crop)).clipRect
            #expect(abs(clip.width / clip.height - crop.ratio!) < 0.001, "\(crop)")
        }
    }

    @Test func aCropOfTheSameRatioChangesNothing() {
        let plain = place()
        let same = place(VideoLayout(crop: .r16x9))
        expectClose(same.clipRect, plain.clipRect)
        expectClose(same.videoRect, plain.videoRect)
    }

    @Test func fillCoversTheWholeContainer() {
        let placement = place(VideoLayout(zoom: .fill))
        expectClose(placement.clipRect, CGRect(x: 0, y: 0, width: 1000, height: 600))
        expectClose(placement.videoRect, CGRect(x: -1000.0 / 30, y: 0, width: 3200.0 / 3, height: 600))
    }

    @Test func fillWithACropFillsTheRegion() {
        let placement = place(VideoLayout(crop: .r239, zoom: .fill))
        expectClose(placement.clipRect, CGRect(x: 0, y: 0, width: 1000, height: 600))
        // The visible 2.39:1 region now spans the full height, so the picture is far wider than the window.
        #expect(placement.videoRect.height > 600 && placement.videoRect.width > 1000)
        #expect(abs(placement.videoRect.midX - 500) < 0.01 && abs(placement.videoRect.midY - 300) < 0.01)
    }

    @Test func anAspectOverrideStretchesThePicture() {
        let placement = place(VideoLayout(aspect: .r4x3))
        expectClose(placement.videoRect, CGRect(x: 100, y: 0, width: 800, height: 600))
        expectClose(placement.clipRect, placement.videoRect)
        #expect(placement.stretches)
    }

    @Test func anAspectOverrideAndACropCombine() {
        let placement = place(VideoLayout(aspect: .r239, crop: .r16x9))
        #expect(placement.stretches)
        #expect(abs(placement.clipRect.width / placement.clipRect.height - 16.0 / 9) < 0.001)
        // The override is applied first: the stretched picture is 2.39:1 and the crop trims its sides.
        #expect(abs(placement.videoRect.width / placement.videoRect.height - 2.39) < 0.001)
    }

    @Test func cropsStayCenteredOnPortraitVideo() {
        let placement = place(VideoLayout(crop: .r16x9), video: CGSize(width: 1080, height: 1920))
        #expect(abs(placement.clipRect.midX - 500) < 0.01 && abs(placement.clipRect.midY - 300) < 0.01)
        #expect(abs(placement.clipRect.width / placement.clipRect.height - 16.0 / 9) < 0.001)
    }

    @Test func fallsBackToTheWholeContainerWithoutAUsableSize() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        expectClose(VideoGeometry.placement(container: container, videoSize: nil, layout: VideoLayout(crop: .r239)).clipRect, bounds)
        expectClose(VideoGeometry.placement(container: container, videoSize: .zero, layout: VideoLayout()).videoRect, bounds)
        expectClose(VideoGeometry.placement(container: .zero, videoSize: hd, layout: VideoLayout()).videoRect, .zero)
    }
}

@Suite struct VideoLayoutTypeTests {
    @Test func cropCyclesThroughEveryPresetAndWraps() {
        var crop = VideoLayout.Crop.none
        var seen: [String] = []
        for _ in 0..<VideoLayout.Crop.allCases.count {
            crop = crop.next
            seen.append(crop.label)
        }
        #expect(seen == ["2.39:1", "2.00:1", "1.85:1", "16:9", "4:3", "None"])
    }

    @Test func defaultsAreDetected() {
        #expect(VideoLayout().isDefault)
        #expect(!VideoLayout(zoom: .fill).isDefault)
        #expect(VideoLayout.Aspect.auto.ratio == nil && VideoLayout.Crop.none.ratio == nil)
    }

    @Test func speedSliderMapsLogarithmically() {
        #expect(PlaybackSpeed.rate(forSliderPosition: 0) == 0.25)
        #expect(PlaybackSpeed.rate(forSliderPosition: 0.5) == 1)
        #expect(PlaybackSpeed.rate(forSliderPosition: 1) == 4)
        #expect(PlaybackSpeed.rate(forSliderPosition: -1) == 0.25 && PlaybackSpeed.rate(forSliderPosition: 2) == 4)
        for rate in [Float(0.25), 0.5, 1, 1.5, 2, 3, 4] {
            #expect(PlaybackSpeed.rate(forSliderPosition: PlaybackSpeed.sliderPosition(forRate: rate)) == rate)
        }
    }
}

@MainActor
@Suite struct VideoLayoutModelTests {
    private func wait(_ what: String, sourceLocation: SourceLocation = #_sourceLocation, until condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if ContinuousClock.now > deadline { Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation); return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func cropShortcutCyclesAndToasts() {
        let player = PlayerModel(services: .testing())
        player.cycleCropByShortcut()
        #expect(player.videoLayout.crop == .r239)
        #expect(player.toast?.text == "Crop: 2.39:1")
        for _ in 0..<5 { player.cycleCropByShortcut() }
        #expect(player.videoLayout.crop == .none)
        #expect(player.toast?.text == "Crop: None")
    }

    @Test func layoutResetsForTheNextFile() async throws {
        let url = try await TestVideo.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(services: .testing())
        defer { player.close() }
        player.setAspect(.r4x3)
        player.setCrop(.r185)
        player.setZoom(.fill)
        #expect(!player.videoLayout.isDefault)
        player.open(url)
        await wait("playback") { player.state == .playing }
        #expect(player.videoLayout.isDefault)
    }

    @Test func resetRestoresTheDefaults() {
        let player = PlayerModel(services: .testing())
        player.setCrop(.r200)
        player.setZoom(.fill)
        player.resetVideoLayout()
        #expect(player.videoLayout.isDefault)
    }

    @Test func nonSquarePixelsChangeTheDisplaySizeButNotTheCodedOne() async throws {
        let url = try await TestVideo.make(seconds: 1, pixelAspectRatio: (4, 3))
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(services: .testing())
        defer { player.close() }
        player.open(url)
        await wait("media info") { player.mediaInfo != nil }
        let info = try #require(player.mediaInfo)
        #expect(info.resolution == CGSize(width: 320, height: 240))
        let display = try #require(info.displaySize)
        #expect(abs(display.width - 320.0 * 4 / 3) < 1 && display.height == 240)
        #expect(info.presentationSize == display)
    }

    @Test func squarePixelsKeepTheCodedSizeAsTheDisplaySize() async throws {
        let url = try await TestVideo.make(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(services: .testing())
        defer { player.close() }
        player.open(url)
        await wait("media info") { player.mediaInfo != nil }
        #expect(player.mediaInfo?.displaySize == CGSize(width: 320, height: 240))
    }
}
