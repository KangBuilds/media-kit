import AVKit
import CoreMedia
import Flutter
import UIKit

final class PictureInPictureController: NSObject {
  private enum State {
    case inline
    case requesting
    case active
    case restoring

    var eventValue: String {
      switch self {
      case .inline:
        "inline"
      case .requesting:
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

    var eligible: Bool {
      loaded && playing && !completed && !audioOnly
    }
  }

  private let channel: FlutterMethodChannel
  private let inlineVideoViews: InlineVideoViewManager
  private var controller: AVPictureInPictureController?
  private weak var sourceLayer: AVSampleBufferDisplayLayer?
  private var possibleObservation: NSKeyValueObservation?
  private var configuration: PlaybackConfiguration?
  private var transitionHandle: Int64?
  private var transitionSession: Int64?
  private var state = State.inline
  private var isInBackground =
    UIApplication.shared.applicationState == .background
  private var stopReason: String?
  private var restoreRequested = false

  init(
    channel: FlutterMethodChannel,
    inlineVideoViews: InlineVideoViewManager
  ) {
    self.channel = channel
    self.inlineVideoViews = inlineVideoViews
    super.init()
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
  }

  func update(
    handle: Int64,
    session: Int64,
    loaded: Bool,
    playing: Bool,
    completed: Bool,
    audioOnly: Bool,
    position: Double,
    duration: Double
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
      duration: duration
    )
    controller?.invalidatePlaybackState()

    if state == .requesting, configuration?.eligible != true {
      cancelRequest(reason: "playbackBecameIneligible")
    } else if state == .active,
      completed || audioOnly
    {
      stopReason = "playbackBecameIneligible"
      state = .restoring
      emitState(reason: stopReason!)
      controller?.stopPictureInPicture()
    }

    if loaded && !completed && !audioOnly {
      setupController(handle: handle)
    } else if state == .inline {
      cleanUpController()
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

  func dispose(handle: Int64) {
    guard configuration?.handle == handle || transitionHandle == handle else {
      return
    }

    if configuration?.handle == handle {
      configuration = nil
    }

    if state == .active || state == .restoring {
      transitionHandle = handle
      stopReason = "playerDisposed"
      state = .restoring
      controller?.stopPictureInPicture()
    } else {
      state = .inline
      transitionHandle = nil
      transitionSession = nil
      controller?.stopPictureInPicture()
      cleanUpController()
    }
  }

  @objc private func didEnterBackground() {
    isInBackground = true
    if state == .active {
      log("lifecycle background, PiP already active")
      emitState(reason: "backgrounded")
      return
    }
    if state == .requesting {
      log("lifecycle background, PiP request pending")
      emitState(reason: "backgrounded")
      return
    }
  }

  @objc private func willEnterForeground() {
    isInBackground = false
    log("lifecycle foreground")

    switch state {
    case .requesting:
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
    guard state == .requesting else { return }
    state = .inline
    emitState(
      reason: reason,
      pauseRequired: isInBackground && configuration?.playing == true
    )
    transitionHandle = nil
    transitionSession = nil
  }

  private func failRequest(reason: String) {
    log("PiP start failed, reason=\(reason)")
    cancelRequest(reason: reason)
  }

  private func setupController(handle: Int64) {
    guard state == .inline,
      AVPictureInPictureController.isPictureInPictureSupported(),
      let displayLayer = inlineVideoViews.displayLayer(handle: handle)
    else { return }
    guard controller == nil || sourceLayer !== displayLayer else { return }

    cleanUpController()
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
      self?.log("readiness possible=\(controller.isPictureInPicturePossible)")
    }
    sourceLayer = displayLayer
    self.controller = controller
  }

  private func cleanUpController() {
    possibleObservation = nil
    controller?.delegate = nil
    controller = nil
    sourceLayer = nil
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
    channel.invokeMethod(
      "PictureInPicture.StateChanged",
      arguments: [
        "handle": handle,
        "session": session,
        "state": state.eventValue,
        "reason": reason,
        "pauseRequired": pauseRequired,
        "background": isInBackground,
      ]
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
  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    guard state == .inline, let configuration, configuration.eligible else {
      pictureInPictureController.stopPictureInPicture()
      return
    }
    transitionHandle = configuration.handle
    transitionSession = configuration.session
    state = .requesting
    log("automatic PiP requested")
    emitState(reason: "automaticRequest")
  }

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
    state = .active
    log("PiP started")
    emitState(reason: "started")
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
    if configuration == nil {
      cleanUpController()
    }
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
      channel.invokeMethod(
        "PictureInPicture.SetPlaying",
        arguments: [
          "handle": handle,
          "session": session,
          "playing": playing,
        ]
      )
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
      channel.invokeMethod(
        "PictureInPicture.Seek",
        arguments: [
          "handle": configuration.handle,
          "session": configuration.session,
          "position": target,
        ]
      )
    }
    completionHandler()
  }
}
