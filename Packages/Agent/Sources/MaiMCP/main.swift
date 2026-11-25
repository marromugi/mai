import Agent
import CoreImage
import CryptoKit
import Foundation
import MCP
import Sync

typealias Key = SecureEnclave.P256.KeyAgreement.PrivateKey

let version = "0.1.0"
let file = PairingFile.standard(environment: ProcessInfo.processInfo.environment)
let usage = """
  mai-mcp: Cotoma の文書を、iPhone で読み取りモードがオンの間だけ読む MCP サーバー（読むだけ）

    mai-mcp          MCP サーバーとして標準入出力で動く（MCP のクライアントが起動する）
    mai-mcp pair     この Mac の Secure Enclave に鍵を作り、iPhone の Cotoma と組む
    mai-mcp forget   ペアリングを消す（鍵ごと。iPhone の側でも取り消す）

  ペアリングは \(file.url.path) に置く（MAI_MCP_HOME で場所を変えられる）。
  """

func standardError(_ text: String) {
  FileHandle.standardError.write(Data((text + "\n").utf8))
}

switch CommandLine.arguments.dropFirst().first {
case nil, "serve":
  let server = Server(
    name: "mai-mcp", version: version, title: "Cotoma",
    instructions:
      "Cotoma（執筆アプリ）の文書を読むだけのツール。iPhone で読み取りモードがオンの間だけ、「AI に読ませない」にしていない文書が読める。まず list_writings か search_writings で ID を見つけ、read_writing で本文を読む。",
    capabilities: .init(tools: .init(listChanged: false)))
  await ReadingTools<Key>(file: file, transport: URLSession.shared).register(on: server)
  try await server.start(transport: StdioTransport())
  await server.waitUntilCompleted()
case "pair":
  exit(await pair())
case "forget":
  do {
    print(
      try file.remove()
        ? "ペアリングを消しました。iPhone の Cotoma の「AI に読ませる」で、このエージェントを取り消してください。"
        : "ペアリングはありません。")
  } catch {
    standardError(error.localizedDescription)
    exit(1)
  }
case "help", "-h", "--help":
  print(usage)
default:
  standardError(usage)
  exit(64)
}

/// Makes a key in the Secure Enclave, shows its pairing code, and keeps the pairing once the line
/// the iPhone hands back reads from the server.
func pair() async -> Int32 {
  let key: Key
  do {
    key = try Key.generate()
  } catch {
    standardError("Secure Enclave に鍵を作れませんでした（\(error.localizedDescription)）。")
    return 1
  }
  let code = AgentKey(key.publicKey).pairingCode
  print(
    """
    この Mac の Secure Enclave に、新しいエージェントの鍵を作りました。
    iPhone の Cotoma で「設定」→「AI に読ませる」→「エージェントを承認…」を開き、
    次の QR コードを読み取るか、コードを打ってください。

    """)
  if let qr = QRCode.lines(of: code) {
    print(qr.joined(separator: "\n") + "\n")
  }
  print(
    """
    \(code)

    承認すると、iPhone に 1 行（サーバーの URL と # とトークン）が出ます。
    「コピー」して、ここに貼り付けて Return を押してください。
    """)
  while true {
    print("> ", terminator: "")
    fflush(stdout)
    guard let line = readLine() else {
      standardError(
        "\nペアリングをやめました。作った鍵は残していません。iPhone で承認したなら、そのエージェントを取り消してください。")
      return 1
    }
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    do {
      let pairing = try await file.pair(key, line: line, transport: URLSession.shared)
      print(
        """

        ペアリングしました（サーバー: \(pairing.handoff.server.absoluteString)）。
        MCP のクライアントにこのコマンドを登録すると、iPhone で読み取りモードがオンの間、文書を読めます。
          Claude Code: claude mcp add cotoma -- \(executablePath())
        """)
      return 0
    } catch {
      standardError(error.localizedDescription)
    }
  }
}

func executablePath() -> String {
  URL(filePath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().path
}

/// A QR code drawn in the terminal, two modules a character, black on white whatever the
/// terminal's colours.
enum QRCode {
  static func lines(of text: String) -> [String]? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(Data(text.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let image = filter.outputImage else { return nil }
    let width = Int(image.extent.width)
    let height = Int(image.extent.height)
    var pixels = [UInt8](repeating: 255, count: width * height)
    CIContext().render(
      image, toBitmap: &pixels, rowBytes: width, bounds: image.extent, format: .L8,
      colorSpace: nil)
    let quiet = 2
    func dark(_ x: Int, _ y: Int) -> Bool {
      let (column, row) = (x - quiet, y - quiet)
      guard (0..<width).contains(column), (0..<height).contains(row) else { return false }
      return pixels[row * width + column] < 128
    }
    let side = (width + 2 * quiet, height + 2 * quiet)
    return stride(from: 0, to: side.1, by: 2).map { y in
      let row = (0..<side.0).map { x -> String in
        switch (dark(x, y), dark(x, y + 1)) {
        case (true, true): "█"
        case (true, false): "▀"
        case (false, true): "▄"
        case (false, false): " "
        }
      }.joined()
      return "\u{1B}[30;47m" + row + "\u{1B}[0m"
    }
  }
}
