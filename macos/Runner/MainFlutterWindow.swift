import Cocoa
import FlutterMacOS
import PDFKit

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    CmbokPlatformChannel.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// 与 Dart 侧 lib/services/platform_service.dart 的 `cmbok/platform` 方法通道对接。
///
/// 方法对齐 Android MainActivity.kt：
/// - openDir / openFile：NSWorkspace 调起 Finder 或外部应用
/// - pdfOpen / pdfRenderPage：PDFKit 度量与光栅化（对齐 Android PdfRenderer 语义）
/// - getApkPath / setVolumeKeyNav：Android 专有，桌面端静默返回空实现
enum CmbokPlatformChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "cmbok/platform", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      handle(call: call, result: result)
    }
  }

  private static func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]

    switch call.method {
    case "openDir":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "缺少 path", details: nil))
        return
      }
      result(openPath(path))

    case "openFile":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "缺少 path", details: nil))
        return
      }
      // mimeType 在 macOS 由系统按扩展名推断，忽略入参
      result(openPath(path))

    case "getApkPath":
      // Android 专有
      result(nil)

    case "setVolumeKeyNav":
      // 桌面端没有音量键，静默接受避免 Dart 侧告警
      result(true)

    case "pdfOpen":
      guard let path = args["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "缺少 path", details: nil))
        return
      }
      do {
        result(try pdfOpen(path))
      } catch {
        result(
          FlutterError(
            code: "pdf_open_failed", message: error.localizedDescription, details: path))
      }

    case "pdfRenderPage":
      guard let path = args["path"] as? String,
        let index = args["index"] as? Int,
        let targetWidth = args["targetWidth"] as? Int
      else {
        result(FlutterError(code: "bad_args", message: "参数不完整", details: nil))
        return
      }
      do {
        let data = try pdfRenderPage(path, index, targetWidth)
        result(FlutterStandardTypedData(bytes: data))
      } catch {
        result(
          FlutterError(
            code: "pdf_render_failed", message: error.localizedDescription, details: path))
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 用系统默认方式打开路径：目录 → Finder，文件 → 关联应用。
  private static func openPath(_ path: String) -> Bool {
    guard FileManager.default.fileExists(atPath: path) else { return false }
    return NSWorkspace.shared.open(URL(fileURLWithPath: path))
  }

  /// 打开 PDF 取页数与每页尺寸（单位：PDF point，与 Android PdfRenderer 一致）。
  private static func pdfOpen(_ path: String) throws -> [String: Any] {
    guard FileManager.default.fileExists(atPath: path) else {
      throw NSError(
        domain: "cmbok", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "文件不存在: \(path)"])
    }
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
      throw NSError(
        domain: "cmbok", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "无法解析 PDF: \(path)"])
    }

    let pageCount = doc.pageCount
    var sizes: [[String: Int]] = []
    sizes.reserveCapacity(pageCount)
    for i in 0..<pageCount {
      guard let page = doc.page(at: i) else {
        sizes.append(["w": 1, "h": 1])
        continue
      }
      let bounds = page.bounds(for: .mediaBox)
      sizes.append([
        "w": max(1, Int(bounds.width.rounded())),
        "h": max(1, Int(bounds.height.rounded())),
      ])
    }
    return ["pageCount": pageCount, "sizes": sizes]
  }

  /// 光栅化单页为 JPEG（白底、质量 85），宽度按 targetWidth 缩放。
  private static func pdfRenderPage(_ path: String, _ index: Int, _ targetWidth: Int) throws -> Data {
    guard FileManager.default.fileExists(atPath: path) else {
      throw NSError(
        domain: "cmbok", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "文件不存在: \(path)"])
    }
    guard let doc = PDFDocument(url: URL(fileURLWithPath: path)) else {
      throw NSError(
        domain: "cmbok", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "无法解析 PDF: \(path)"])
    }
    guard index >= 0 && index < doc.pageCount else {
      throw NSError(
        domain: "cmbok", code: 3,
        userInfo: [NSLocalizedDescriptionKey: "页码越界: \(index) / \(doc.pageCount)"])
    }
    guard let page = doc.page(at: index) else {
      throw NSError(
        domain: "cmbok", code: 4,
        userInfo: [NSLocalizedDescriptionKey: "取不到第 \(index) 页"])
    }

    let box = page.bounds(for: .mediaBox)
    let pageW = max(box.width, 1)
    let pageH = max(box.height, 1)
    let pxW = max(targetWidth, 1)
    let scale = CGFloat(pxW) / pageW
    let pxH = max(1, Int((pageH * scale).rounded()))

    guard
      let ctx = CGContext(
        data: nil,
        width: pxW,
        height: pxH,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else {
      throw NSError(
        domain: "cmbok", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "创建位图上下文失败"])
    }

    // PDF 页可能透明，铺白底避免深色主题下渲染成黑块
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pxW, height: pxH))

    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
    page.draw(with: .mediaBox, to: ctx)
    ctx.restoreGState()

    guard let cgImage = ctx.makeImage() else {
      throw NSError(
        domain: "cmbok", code: 6,
        userInfo: [NSLocalizedDescriptionKey: "生成 CGImage 失败"])
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
      throw NSError(
        domain: "cmbok", code: 7,
        userInfo: [NSLocalizedDescriptionKey: "JPEG 编码失败"])
    }
    return data
  }
}
