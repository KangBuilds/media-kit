#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public class MediaKitVideoPlugin: NSObject, FlutterPlugin {
  private static let CHANNEL_NAME = "com.alexmercerind/media_kit_video"

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if canImport(Flutter)
      let binaryMessenger = registrar.messenger()
      let registry = registrar.textures()
      let utils: UtilsProtocol? = nil
    #elseif canImport(FlutterMacOS)
      let binaryMessenger = registrar.messenger
      let registry = registrar.textures
      let utils: UtilsProtocol? = Utils(registrar)
    #endif

    let channel = FlutterMethodChannel(
      name: CHANNEL_NAME,
      binaryMessenger: binaryMessenger
    )
    #if os(iOS)
      let pictureInPictureChannel = FlutterMethodChannel(
        name: "\(CHANNEL_NAME)/picture_in_picture",
        binaryMessenger: binaryMessenger
      )
    #else
      let pictureInPictureChannel: FlutterMethodChannel? = nil
    #endif
    let instance = MediaKitVideoPlugin(
      registry: registry,
      channel: channel,
      pictureInPictureChannel: pictureInPictureChannel,
      utils: utils
    )
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  private let channel: FlutterMethodChannel
  private let videoOutputManager: VideoOutputManager
  private let utils: UtilsProtocol?
  #if os(iOS)
    private let pictureInPicture: PictureInPictureController
  #endif

  init(
    registry: FlutterTextureRegistry,
    channel: FlutterMethodChannel,
    pictureInPictureChannel: FlutterMethodChannel?,
    utils: UtilsProtocol?
  ) {
    self.channel = channel
    #if os(iOS)
      let pictureInPicture = PictureInPictureController()
      self.pictureInPicture = pictureInPicture
      videoOutputManager = VideoOutputManager(
        registry: registry,
        pixelBufferUpdateCallback: { [weak pictureInPicture] handle, pixelBuffer in
          pictureInPicture?.enqueue(handle: handle, pixelBuffer: pixelBuffer)
        }
      )
      pictureInPicture.onSetPlaying = { handle, session, playing in
        pictureInPictureChannel?.invokeMethod(
          "PictureInPicture.SetPlaying",
          arguments: [
            "handle": handle,
            "session": session,
            "playing": playing,
          ]
        )
      }
      pictureInPicture.onSeek = { handle, session, position in
        pictureInPictureChannel?.invokeMethod(
          "PictureInPicture.Seek",
          arguments: [
            "handle": handle,
            "session": session,
            "position": position,
          ]
        )
      }
      pictureInPicture.onStateChanged = {
        handle, session, state, reason, pauseRequired, background in
        pictureInPictureChannel?.invokeMethod(
          "PictureInPicture.StateChanged",
          arguments: [
            "handle": handle,
            "session": session,
            "state": state,
            "reason": reason,
            "pauseRequired": pauseRequired,
            "background": background,
          ]
        )
      }
    #else
      videoOutputManager = VideoOutputManager(registry: registry)
    #endif
    self.utils = utils
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "VideoOutputManager.Create":
      handleCreateMethodCall(call.arguments, result)
    case "VideoOutputManager.SetSize":
      handleSetSizeMethodCall(call.arguments, result)
    case "VideoOutputManager.Dispose":
      handleDisposeMethodCall(call.arguments, result)
    case "Utils.EnterNativeFullscreen":
      handleEnterNativeFullscreenMethodCall(call.arguments, result)
    case "Utils.ExitNativeFullscreen":
      handleExitNativeFullscreenMethodCall(call.arguments, result)
    #if os(iOS)
      case "PictureInPicture.Update":
        handlePictureInPictureUpdate(call.arguments, start: false, result)
      case "PictureInPicture.Start":
        handlePictureInPictureUpdate(call.arguments, start: true, result)
    #endif
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleCreateMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let handle: Int64? = Int64(handleStr)
    let configDict = args?["configuration"] as! [String: Any]
    let configuration = VideoOutputConfiguration.fromDict(configDict)

    assert(handle != nil, "handle must be an Int64")

    videoOutputManager.create(
      handle: handle!,
      configuration: configuration,
      textureUpdateCallback: { (_ textureId: Int64, _ size: CGSize) in
        self.channel.invokeMethod(
          "VideoOutput.Resize",
          arguments: [
            "handle": handle!,
            "id": textureId,
            "rect": [
              "top": 0,
              "left": 0,
              "width": size.width,
              "height": size.height,
            ],
          ] as [String: Any]
        )
      }
    )

    result(nil)
  }

  private func handleSetSizeMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let widthStr = args?["width"] as! String
    let heightStr = args?["height"] as! String

    let handle: Int64? = Int64(handleStr)
    let width: Int64? = Int64(widthStr)
    let height: Int64? = Int64(heightStr)

    assert(handle != nil, "handle must be an Int64")

    self.videoOutputManager.setSize(
      handle: handle!,
      width: width,
      height: height
    )

    result(nil)
  }

  private func handleDisposeMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let handle: Int64? = Int64(handleStr)

    assert(handle != nil, "handle must be an Int64")

    #if os(iOS)
      pictureInPicture.dispose(handle: handle!)
    #endif

    videoOutputManager.destroy(
      handle: handle!
    )

    result(nil)
  }

  private func handleEnterNativeFullscreenMethodCall(
    _: Any?,
    _ result: FlutterResult
  ) {
    if utils == nil {
      return result(FlutterMethodNotImplemented)
    }

    utils?.enterNativeFullscreen()
    result(nil)
  }

  private func handleExitNativeFullscreenMethodCall(
    _: Any?,
    _ result: FlutterResult
  ) {
    if utils == nil {
      return result(FlutterMethodNotImplemented)
    }

    utils?.exitNativeFullscreen()
    result(nil)
  }

  #if os(iOS)
    private func handlePictureInPictureUpdate(
      _ arguments: Any?,
      start: Bool,
      _ result: FlutterResult
    ) {
      let args = arguments as? [String: Any]
      guard let handleString = args?["handle"] as? String,
        let handle = Int64(handleString)
      else {
        return result(
          FlutterError(
            code: "invalid_handle",
            message: "Picture in Picture requires a valid player handle",
            details: nil
          ))
      }
      _ = pictureInPicture.update(
        handle: handle,
        session: (args?["session"] as? NSNumber)?.int64Value ?? 0,
        loaded: (args?["loaded"] as? Bool) ?? false,
        playing: (args?["playing"] as? Bool) ?? false,
        completed: (args?["completed"] as? Bool) ?? false,
        audioOnly: (args?["audioOnly"] as? Bool) ?? false,
        position: (args?["position"] as? NSNumber)?.doubleValue ?? 0,
        duration: (args?["duration"] as? NSNumber)?.doubleValue ?? 0,
        inlineFrame: CGRect(
          x: (args?["inlineX"] as? NSNumber)?.doubleValue ?? 0,
          y: (args?["inlineY"] as? NSNumber)?.doubleValue ?? 0,
          width: (args?["inlineWidth"] as? NSNumber)?.doubleValue ?? 0,
          height: (args?["inlineHeight"] as? NSNumber)?.doubleValue ?? 0
        )
      )
      result(start ? pictureInPicture.start() : pictureInPicture.status)
    }
  #endif
}
