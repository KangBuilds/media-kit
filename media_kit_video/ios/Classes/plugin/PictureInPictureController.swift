import AVKit
import CoreMedia
import UIKit

private final class PictureInPictureHostView: UIView {
  let displayLayer: AVSampleBufferDisplayLayer

  init(frame: CGRect, displayLayer: AVSampleBufferDisplayLayer) {
    self.displayLayer = displayLayer
    super.init(frame: frame)
    layer.addSublayer(displayLayer)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    displayLayer.frame = bounds
  }
}

final class PictureInPictureController: NSObject {
  typealias StateCallback = (
    Int64,
    Int64,
    String,
    String,
    Bool,
    Bool
  ) -> Void

  var onSetPlaying: ((Int64, Int64, Bool) -> Void)?
  var onSeek: ((Int64, Int64, Double) -> Void)?
  var onStateChanged: StateCallback?

  private enum State {
    case inline
    case preparing
    case requesting
    case active
    case restoring

    var eventValue: String {
      switch self {
      case .inline:
        "inline"
      case .preparing, .requesting:
        "requestingPiP"
      case .active:
        "pipActive"
      case .restoring:
        "restoringInline"
      }
    }
  }

  private struct PlaybackConfiguration {
    let handle: Int64
    let session: Int64
    var loaded: Bool
    var playing: Bool
    var completed: Bool
    var audioOnly: Bool
    var position: Double
    var duration: Double
    var inlineFrame: CGRect

    var eligible: Bool {
      loaded && playing && !completed && !audioOnly
    }
  }

  private static let readinessTimeout: TimeInterval = 1.5
  private let displayLayer = AVSampleBufferDisplayLayer()
  private let hostClock = CMClockGetHostTimeClock()
  private var controller: AVPictureInPictureController?
  private var possibleObservation: NSKeyValueObservation?
  private var readinessTimer: Timer?
  private var hostView: PictureInPictureHostView?
  private var formatDescription: CMVideoFormatDescription?
  private var formatSize = CGSize.zero
  private var configuration: PlaybackConfiguration?
  private var transitionHandle: Int64?
  private var transitionSession: Int64?
  private var state = State.inline
  private var isInBackground =
    UIApplication.shared.applicationState == .background
  private var stopReason: String?
  private var restoreRequested = false
  private var loggedFirstFrame = false

  override init() {
    super.init()
    displayLayer.videoGravity = .resizeAspect
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

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(didEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(willEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    readinessTimer?.invalidate()
  }

  func update(
    handle: Int64,
    session: Int64,
    loaded: Bool,
    playing: Bool,
    completed: Bool,
    audioOnly: Bool,
    position: Double,
    duration: Double,
    inlineFrame: CGRect
  ) -> [String: Any] {
    if let current = configuration, current.handle != handle {
      dispose(handle: current.handle)
    }

    let isNewSession = configuration?.session != session
    if isNewSession, state == .active {
      transitionSession = session
    }

    configuration = PlaybackConfiguration(
      handle: handle,
      session: session,
      loaded: loaded,
      playing: playing,
      completed: completed,
      audioOnly: audioOnly,
      position: position,
      duration: duration,
      inlineFrame: inlineFrame
    )
    controller?.invalidatePlaybackState()

    if (state == .preparing || state == .requesting),
      configuration?.eligible != true
    {
      cancelRequest(reason: "playbackBecameIneligible")
    } else if state == .active,
      completed || audioOnly
    {
      stopReason = "playbackBecameIneligible"
      state = .restoring
      emitState(reason: stopReason!)
      controller?.stopPictureInPicture()
    }

    return status
  }

  var status: [String: Any] {
    [
      "supported": AVPictureInPictureController.isPictureInPictureSupported(),
      "possible": controller?.isPictureInPicturePossible == true,
      "state": state.eventValue,
    ]
  }

  func start() -> [String: Any] {
    if state == .preparing || state == .requesting || state == .active {
      return status.merging(["accepted": true]) { _, new in new }
    }
    guard state == .inline, let configuration else {
      return status.merging(["accepted": false]) { _, new in new }
    }

    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    guard supported, configuration.eligible else {
      log("manual request rejected, reason=\(ineligibleReason(configuration, supported: supported))")
      return status.merging(["accepted": false]) { _, new in new }
    }

    transitionHandle = configuration.handle
    transitionSession = configuration.session
    state = .preparing
    log("requesting PiP")
    emitState(reason: "manualRequest")
    guard prepare() else {
      failRequest(reason: "rendererUnavailable")
      return status.merging(["accepted": false]) { _, new in new }
    }

    readinessTimer?.invalidate()
    readinessTimer = Timer.scheduledTimer(
      withTimeInterval: Self.readinessTimeout,
      repeats: false
    ) { [weak self] _ in
      guard let self,
        self.state == .preparing || self.state == .requesting
      else { return }
      self.failRequest(reason: "readinessTimeout")
    }
    startWhenPossible()
    return status.merging(["accepted": true]) { _, new in new }
  }

  func dispose(handle: Int64) {
    guard configuration?.handle == handle || transitionHandle == handle else {
      return
    }

    readinessTimer?.invalidate()
    readinessTimer = nil
    if configuration?.handle == handle {
      configuration = nil
    }

    if state == .active {
      transitionHandle = handle
      stopReason = "playerDisposed"
      state = .restoring
      controller?.stopPictureInPicture()
    } else {
      state = .inline
      transitionHandle = nil
      transitionSession = nil
      controller?.stopPictureInPicture()
      cleanUpRenderer()
    }
  }

  func enqueue(handle: Int64, pixelBuffer: () -> CVPixelBuffer?) {
    guard configuration?.handle == handle,
      state == .preparing || state == .requesting || state == .active
        || state == .restoring
    else { return }
    if displayLayer.status == .failed {
      displayLayer.flush()
    }
    guard displayLayer.isReadyForMoreMediaData else { return }
    guard let pixelBuffer = pixelBuffer() else { return }

    let size = CGSize(
      width: CVPixelBufferGetWidth(pixelBuffer),
      height: CVPixelBufferGetHeight(pixelBuffer)
    )
    let isNewFormat = formatDescription == nil || formatSize != size
    let presentationTime = CMClockGetTime(hostClock)

    if isNewFormat {
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
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard
      CMSampleBufferCreateReadyWithImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescription: formatDescription,
        sampleTiming: &timing,
        sampleBufferOut: &sampleBuffer
      ) == noErr, let sampleBuffer
    else { return }

    CMSetAttachment(
      sampleBuffer,
      key: kCMSampleAttachmentKey_DisplayImmediately,
      value: kCFBooleanTrue,
      attachmentMode: kCMAttachmentMode_ShouldPropagate
    )
    displayLayer.enqueue(sampleBuffer)
    if !loggedFirstFrame {
      loggedFirstFrame = true
      log("renderer ready \(Int(size.width))x\(Int(size.height))")
    }
  }

  @objc private func didEnterBackground() {
    isInBackground = true
    if state == .active {
      log("lifecycle background, PiP already active")
      emitState(reason: "backgrounded")
      return
    }
    if state == .preparing || state == .requesting {
      log("lifecycle background, PiP request pending")
      return
    }
    if configuration?.playing == true {
      log("backgrounded without PiP; pausing playback")
      emitState(reason: "backgroundedWithoutPiP", pauseRequired: true)
    }
  }

  @objc private func willEnterForeground() {
    isInBackground = false
    readinessTimer?.invalidate()
    readinessTimer = nil
    log("lifecycle foreground")

    switch state {
    case .preparing, .requesting:
      cancelRequest(reason: "returnedToForeground")
    case .active:
      state = .restoring
      stopReason = "returnedToForeground"
      emitState(reason: stopReason!)
      controller?.stopPictureInPicture()
    case .inline:
      emitState(reason: "returnedToForeground")
    case .restoring:
      break
    }
  }

  private func cancelRequest(reason: String) {
    guard state == .preparing || state == .requesting else { return }
    readinessTimer?.invalidate()
    readinessTimer = nil
    state = .inline
    emitState(
      reason: reason,
      pauseRequired: isInBackground && configuration?.playing == true
    )
    transitionHandle = nil
    transitionSession = nil
    cleanUpRenderer()
  }

  private func failRequest(reason: String) {
    guard state == .preparing || state == .requesting else { return }
    readinessTimer?.invalidate()
    readinessTimer = nil
    state = .inline
    log("PiP start failed, reason=\(reason)")
    emitState(
      reason: reason,
      pauseRequired: isInBackground && configuration?.playing == true
    )
    transitionHandle = nil
    transitionSession = nil
    cleanUpRenderer()
  }

  private func ineligibleReason(
    _ configuration: PlaybackConfiguration,
    supported: Bool
  ) -> String {
    if !supported { return "unsupported" }
    if !configuration.loaded { return "noVideo" }
    if configuration.audioOnly { return "audioOnly" }
    if configuration.completed { return "completed" }
    if !configuration.playing { return "paused" }
    return "unavailable"
  }

  private func prepare() -> Bool {
    guard AVPictureInPictureController.isPictureInPictureSupported(),
      attachDisplayLayer()
    else { return false }
    setupController()
    return true
  }

  private func setupController() {
    guard controller == nil else { return }
    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: displayLayer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    possibleObservation = controller.observe(
      \.isPictureInPicturePossible,
      options: [.initial, .new]
    ) { [weak self] controller, _ in
      guard let self else { return }
      self.log("readiness possible=\(controller.isPictureInPicturePossible)")
      self.startWhenPossible()
    }
    self.controller = controller
  }

  private func startWhenPossible() {
    guard state == .preparing,
      controller?.isPictureInPicturePossible == true
    else { return }
    let application = UIApplication.shared
    let suspend = NSSelectorFromString("suspend")
    guard application.responds(to: suspend) else {
      failRequest(reason: "suspendUnavailable")
      return
    }
    state = .requesting
    log("PiP ready; suspending app")
    DispatchQueue.main.async { [weak self, weak application] in
      guard self?.state == .requesting else { return }
      _ = application?.perform(suspend)
    }
  }

  private func attachDisplayLayer() -> Bool {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .sorted {
        $0.activationState == .foregroundActive
          && $1.activationState != .foregroundActive
      }
    var windows = scenes.flatMap(\.windows)
    if let appDelegateWindow = UIApplication.shared.delegate?.window ?? nil,
      !windows.contains(where: { $0 === appDelegateWindow })
    {
      windows.append(appDelegateWindow)
    }
    let window =
      windows.first(where: \.isKeyWindow)
      ?? windows.first {
        !$0.isHidden && $0.alpha > 0 && $0.windowLevel == .normal
          && $0.rootViewController != nil
      }
    guard let window,
      let rootView = window.rootViewController?.view
    else { return false }
    guard let containerView = rootView.superview else { return false }
    let inlineFrame = containerView
      .convert(configuration?.inlineFrame ?? .zero, from: window)
      .intersection(containerView.bounds)
    guard !inlineFrame.isNull, !inlineFrame.isEmpty else { return false }

    if hostView?.window !== window {
      hostView?.removeFromSuperview()
      let hostView = PictureInPictureHostView(
        frame: inlineFrame,
        displayLayer: displayLayer
      )
      hostView.isUserInteractionEnabled = false
      hostView.backgroundColor = .clear
      containerView.insertSubview(hostView, belowSubview: rootView)
      self.hostView = hostView
      loggedFirstFrame = false
    }
    hostView?.frame = inlineFrame
    displayLayer.frame = hostView?.bounds ?? .zero
    return true
  }

  private func cleanUpRenderer() {
    displayLayer.flushAndRemoveImage()
    hostView?.removeFromSuperview()
    hostView = nil
    loggedFirstFrame = false
  }

  private func emitState(
    reason: String,
    pauseRequired: Bool = false,
    handle: Int64? = nil,
    session: Int64? = nil
  ) {
    guard let handle = handle ?? transitionHandle ?? configuration?.handle else {
      return
    }
    guard
      let session = session ?? transitionSession ?? configuration?.session
    else { return }
    if pauseRequired {
      pausePlayback(handle: handle)
      if var configuration, configuration.handle == handle {
        configuration.playing = false
        self.configuration = configuration
      }
    }
    onStateChanged?(
      handle,
      session,
      state.eventValue,
      reason,
      pauseRequired,
      isInBackground
    )
  }

  private func pausePlayback(handle: Int64) {
    guard let player = OpaquePointer(bitPattern: Int(handle)) else { return }
    let result = mpv_set_property_string(player, "pause", "yes")
    log("paused MPV without active PiP, result=\(result)")
  }

  private func log(_ message: String) {
    #if DEBUG
      NSLog("[PiP] \(message)")
    #endif
  }
}

extension PictureInPictureController:
  AVPictureInPictureControllerDelegate,
  AVPictureInPictureSampleBufferPlaybackDelegate
{
  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    guard state == .requesting,
      configuration?.eligible == true
    else {
      pictureInPictureController.stopPictureInPicture()
      return
    }
    transitionHandle = configuration?.handle
    transitionSession = configuration?.session
    readinessTimer?.invalidate()
    readinessTimer = nil
    state = .active
    log("PiP started")
    emitState(reason: "started")
    DispatchQueue.main.async { [weak self] in
      guard self?.state == .active else { return }
      _ = UIApplication.shared.perform(NSSelectorFromString("suspend"))
    }
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    log("PiP start failed, error=\(error.localizedDescription)")
    failRequest(reason: "startRejected")
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    let handle = transitionHandle
    let session = transitionSession
    readinessTimer?.invalidate()
    readinessTimer = nil
    let reason =
      restoreRequested
      ? "restoredInline"
      : stopReason ?? (isInBackground ? "closedWhileBackgrounded" : "stopped")
    let pauseRequired = isInBackground && !restoreRequested
    state = .inline
    log("PiP stopped, reason=\(reason)")
    emitState(
      reason: reason,
      pauseRequired: pauseRequired,
      handle: handle,
      session: session
    )
    transitionHandle = nil
    transitionSession = nil
    stopReason = nil
    restoreRequested = false
    cleanUpRenderer()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
      @escaping (Bool) -> Void
  ) {
    restoreRequested = true
    state = .restoring
    log("restoring inline player")
    emitState(reason: "restoreRequested")
    completionHandler(configuration != nil)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    configuration?.playing = playing
    if let handle = transitionHandle ?? configuration?.handle,
      let session = transitionSession ?? configuration?.session
    {
      onSetPlaying?(handle, session, playing)
    }
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    let duration = configuration?.duration ?? 0
    return CMTimeRange(
      start: .zero,
      duration: duration > 0
        ? CMTime(seconds: duration, preferredTimescale: 600)
        : .positiveInfinity
    )
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    configuration?.playing != true
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    if var configuration {
      let target = max(
        0,
        min(configuration.duration, configuration.position + skipInterval.seconds)
      )
      configuration.position = target
      self.configuration = configuration
      onSeek?(configuration.handle, configuration.session, target)
    }
    completionHandler()
  }
}
