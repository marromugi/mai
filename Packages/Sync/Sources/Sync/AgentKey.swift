import CryptoKit
import Foundation

/// An agent's public key (`Server/README.md`, 「エージェントの側」): a P-256 key-agreement key,
/// which the agent keeps the private half of. Written as its 33-byte compressed form (SEC 1).
public struct AgentKey: Sendable, Hashable {
  public let rawRepresentation: Data

  public init(_ publicKey: P256.KeyAgreement.PublicKey) {
    rawRepresentation = publicKey.compressedRepresentation
  }

  public init(rawRepresentation: Data) throws(AgentKeyError) {
    do {
      self.init(try P256.KeyAgreement.PublicKey(compressedRepresentation: rawRepresentation))
    } catch {
      throw .notAPublicKey
    }
  }

  /// Reads the pairing code the agent shows, as a QR code or as text a person types: the key and a
  /// 2-byte check, in Crockford's Base32 as 14 groups of 4, read as `RecoveryKey` reads.
  public init(pairingCode: String) throws(AgentKeyError) {
    let bytes: Data
    do {
      bytes = try Base32.bytes(of: pairingCode, count: Self.codeLength)
    } catch {
      switch error {
      case .unknownCharacter(let character): throw .unknownCharacter(character)
      case .wrongLength(let count): throw .wrongLength(count)
      }
    }
    let key = bytes.prefix(Self.keyLength)
    guard Data(bytes.suffix(2)) == Self.check(of: key) else {
      throw .mistyped
    }
    try self.init(rawRepresentation: Data(key))
  }

  /// The code the agent shows for its key.
  public var pairingCode: String {
    Base32.text(of: rawRepresentation + Self.check(of: rawRepresentation))
  }

  /// `key`, the key of `writing` at `revision`, wrapped for this agent alone: HPKE (RFC 9180) in
  /// base mode with DHKEM(P-256), HKDF-SHA256 and AES-256-GCM, the info `mai read-mode copy 1`,
  /// and the writing's ID and revision as authenticated data. The encapsulated key (65 bytes)
  /// followed by the sealed key (48 bytes).
  func wrap(_ key: WritingKey, of writing: UUID, at revision: Revision) -> Data {
    do {
      let recipient = try P256.KeyAgreement.PublicKey(compressedRepresentation: rawRepresentation)
      var sender = try HPKE.Sender(
        recipientKey: recipient, ciphersuite: Wrapping.suite, info: Wrapping.info)
      let sealed = try sender.seal(
        key.rawRepresentation, authenticating: Wrapping.data(writing, revision.bytes))
      return sender.encapsulatedKey + sealed
    } catch {
      preconditionFailure("HPKE seals for any P-256 public key read from its bytes: \(error)")
    }
  }

  private static let keyLength = 33
  /// The key and its check are 35 bytes: 280 bits, exactly 56 digits of 5 bits.
  private static let codeLength = keyLength + 2

  private static func check(of key: some DataProtocol) -> Data {
    Data(SHA256.hash(data: key).prefix(2))
  }
}

extension OwnKey {
  /// The signature `POST /agents` keeps beside `agent`, saying a device holding this own key
  /// approved it: an HMAC-SHA256 of the agent's key, keyed by a key derived one way from this
  /// one. Every device of the account can check it, and the server can't make one.
  public func signature(approving agent: AgentKey) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: agent.rawRepresentation, using: approvalKey))
  }

  /// Whether `signature` is this own key's approval of `agent`.
  public func approved(_ agent: AgentKey, signature: Data) -> Bool {
    HMAC<SHA256>.isValidAuthenticationCode(
      signature, authenticating: agent.rawRepresentation, using: approvalKey)
  }

  private var approvalKey: SymmetricKey {
    HKDF<SHA256>.deriveKey(
      inputKeyMaterial: key, info: Data("mai agent approval".utf8), outputByteCount: 32)
  }
}

/// A copy as an agent reads it (`GET /agent/writings/<ID>`): the sealed writing and its key
/// wrapped for the agent (`Mai-Wrapped-Key`).
public struct AgentCopy: Sendable {
  public let id: UUID
  let envelope: Envelope
  let wrapped: Data

  /// `bytes` is the sealed writing with `id`, as the server gives it.
  public init(id: UUID, bytes: Data, wrapped: Data) throws(EnvelopeError) {
    envelope = try Envelope(bytes: bytes)
    guard envelope.id == id else { throw .notASealedWriting }
    self.id = id
    self.wrapped = wrapped
  }

  /// Opens the copy with the agent's private key: unwraps the writing key, then the contents.
  /// Fails when the key was wrapped for another agent, another writing or another save of it.
  public func open<PrivateKey: HPKEDiffieHellmanPrivateKey>(with privateKey: PrivateKey)
    throws(OpeningError) -> PlainWriting
  {
    let bytes = envelope.bytes
    let header = bytes.prefix(Layout.header)
    do {
      var recipient = try HPKE.Recipient(
        privateKey: privateKey, ciphersuite: Wrapping.suite, info: Wrapping.info,
        encapsulatedKey: wrapped.prefix(Wrapping.encapsulatedKey))
      let revision = Data(SHA256.hash(data: bytes))
      let writingKey = try recipient.open(
        wrapped.dropFirst(Wrapping.encapsulatedKey),
        authenticating: Wrapping.data(id, revision))
      let sealedContents = try AES.GCM.SealedBox(
        combined: bytes[(Layout.header + Layout.sealedKey)...])
      let contents = try AES.GCM.open(
        sealedContents, using: SymmetricKey(data: writingKey), authenticating: header)
      let updated = bytes[20..<28].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
      return PlainWriting(
        id: id, updated: Date(timeIntervalSince1970: Double(updated) / 1000), contents: contents)
    } catch {
      throw OpeningError(id: id)
    }
  }
}

/// How a writing key is wrapped for an agent; `AgentKey.wrap` says it in full.
private enum Wrapping {
  static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
  static let info = Data("mai read-mode copy 1".utf8)
  /// DHKEM(P-256)'s encapsulated key, an uncompressed point.
  static let encapsulatedKey = 65

  /// The writing's ID (16 bytes) and the SHA-256 of the sealed writing (its revision, 32 bytes).
  static func data(_ writing: UUID, _ revision: Data) -> Data {
    withUnsafeBytes(of: writing.uuid) { Data($0) } + revision
  }
}

public enum AgentKeyError: LocalizedError, Equatable {
  case unknownCharacter(Character)
  case wrongLength(Int)
  case mistyped
  case notAPublicKey

  public var errorDescription: String? {
    switch self {
    case .unknownCharacter(let character):
      "エージェントのコードに使わない文字「\(character)」が入っています。"
    case .wrongLength(let count):
      "エージェントのコードは 56 文字ですが、\(count) 文字でした。"
    case .mistyped:
      "エージェントのコードが合いません。打ち間違いがないか確かめてください。"
    case .notAPublicKey:
      "エージェントのコードが、エージェントの鍵を表していません。エージェントが出したコードか確かめてください。"
    }
  }
}
