import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // Registrar la vista nativa Liquid Glass (iOS 26).
    if let registrar = self.registrar(forPlugin: "LiquidGlass") {
      let factory = LiquidGlassFactory(messenger: registrar.messenger())
      registrar.register(factory, withId: "liquid_glass")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// LIQUID GLASS NATIVO (iOS 26)
// Vista de cristal real de Apple (UIGlassEffect) incrustada en Flutter vía
// UiKitView. Se mantiene en este archivo (ya incluido en el proyecto Xcode)
// para no tener que registrar un .swift nuevo en project.pbxproj.
// ═══════════════════════════════════════════════════════════════════════════

/// Factory registrada con el id "liquid_glass".
class LiquidGlassFactory: NSObject, FlutterPlatformViewFactory {
  private var messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return LiquidGlassPlatformView(frame: frame, args: args)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

/// Vista nativa que aplica el efecto Liquid Glass REAL de Apple.
/// - En iOS 26+ usa `UIGlassEffect` (refracción, brillos, adaptación dinámica).
/// - En versiones anteriores cae a un material translúcido del sistema.
class LiquidGlassPlatformView: NSObject, FlutterPlatformView {
  private let container: UIView
  private let effectView: UIVisualEffectView

  init(frame: CGRect, args: Any?) {
    container = UIView(frame: frame)

    // Parámetros enviados desde Flutter.
    var interactive = true
    if let dict = args as? [String: Any] {
      if let i = dict["interactive"] as? NSNumber {
        interactive = i.boolValue
      }
    }

    if #available(iOS 26.0, *) {
      // ── Liquid Glass auténtico de Apple ──
      let glass = UIGlassEffect()
      glass.isInteractive = interactive
      effectView = UIVisualEffectView(effect: glass)
    } else {
      // ── Fallback: material translúcido claro ──
      effectView = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemThinMaterial)
      )
    }

    super.init()

    // Fondo transparente: el rectángulo lo llena el cristal y el redondeo lo
    // hace Flutter con ClipRRect (evita el borde negro del platform view).
    container.backgroundColor = .clear
    container.isOpaque = false
    effectView.frame = container.bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.addSubview(effectView)
  }

  func view() -> UIView {
    return container
  }
}
