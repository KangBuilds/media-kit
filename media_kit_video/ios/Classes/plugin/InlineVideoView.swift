import AVFoundation
import CoreMedia
import Flutter
import UIKit

final class InlineVideoViewManager {
  private final class WeakView {
    weak var value: InlineVideoRenderView?

    init(_ value: InlineVideoRenderView) {
      self.value = value
    }
  }

  private var views = [Int64: WeakView]()

  func attach(handle: Int64, view: InlineVideoRenderView) {
    views[handle] = WeakView(view)
  }

  func detach(handle: Int64, view: InlineVideoRenderView) {
    if views[handle]?.value === view {
      views[handle] = nil
    }
  }

  func enqueue(handle: Int64, pixelBuffer: () -> CVPixelBuffer?) -> Bool {
    guard let view = views[handle]?.value else {
      views[handle] = nil
      return false
    }
    guard view.window != nil else { return false }
    view.enqueue(pixelBuffer: pixelBuffer)
    return true
  }

  func displayLayer(handle: Int64) -> AVSampleBufferDisplayLayer? {
    views[handle]?.value?.displayLayer
  }
}

final class InlineVideoViewFactory: NSObject, FlutterPlatformViewFactory {
  private let manager: InlineVideoViewManager

  init(manager: InlineVideoViewManager) {
    self.manager = manager
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let arguments = args as? [String: Any]
    let handle = Int64(arguments?["handle"] as? String ?? "") ?? 0
    return InlineVideoPlatformView(frame: frame, handle: handle, manager: manager)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

private final class InlineVideoPlatformView: NSObject, FlutterPlatformView {
  private let handle: Int64
  private let manager: InlineVideoViewManager
  private let renderView: InlineVideoRenderView

  init(frame: CGRect, handle: Int64, manager: InlineVideoViewManager) {
    self.handle = handle
    self.manager = manager
    renderView = InlineVideoRenderView(frame: frame)
    super.init()
    manager.attach(handle: handle, view: renderView)
  }

  deinit {
    manager.detach(handle: handle, view: renderView)
  }

  func view() -> UIView {
    renderView
  }
}

final class InlineVideoRenderView: UIView {
  override class var layerClass: AnyClass {
    AVSampleBufferDisplayLayer.self
  }

  var displayLayer: AVSampleBufferDisplayLayer {
    layer as! AVSampleBufferDisplayLayer
  }

  private let hostClock = CMClockGetHostTimeClock()
  private var formatDescription: CMVideoFormatDescription?
  private var formatSize = CGSize.zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .black
    displayLayer.videoGravity = .resize
    var timebase: CMTimebase?
    if CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: hostClock,
      timebaseOut: &timebase
    ) == noErr, let timebase {
      displayLayer.controlTimebase = timebase
      CMTimebaseSetTime(timebase, time: CMClockGetTime(hostClock))
      CMTimebaseSetRate(timebase, rate: 1)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func enqueue(pixelBuffer provider: () -> CVPixelBuffer?) {
    if displayLayer.status == .failed {
      displayLayer.flush()
    }
    guard displayLayer.isReadyForMoreMediaData,
      let pixelBuffer = provider()
    else { return }

    let size = CGSize(
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer)
    )
    if formatDescription == nil || formatSize != size {
      formatSize = size
      CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &formatDescription
      )
    }
    guard let formatDescription else { return }

    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMClockGetTime(hostClock),
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    ) == noErr, let sampleBuffer else { return }

    CMSetAttachment(
      sampleBuffer,
      key: kCMSampleAttachmentKey_DisplayImmediately,
      value: kCFBooleanTrue,
      attachmentMode: kCMAttachmentMode_ShouldPropagate
    )
    displayLayer.enqueue(sampleBuffer)
  }
}
