import CryptoKit
import Foundation

/// The private half of the agent's key (`Server/README.md`, 「エージェントの側」): a P-256
/// key-agreement key that opens the writing keys wrapped for the agent, and that the pairing file
/// keeps in the form `kept` gives.
public protocol AgentPrivateKey: HPKEDiffieHellmanPrivateKey, Sendable
where PublicKey == P256.KeyAgreement.PublicKey {
  static func generate() throws -> Self
  init(kept: Data) throws
  var kept: Data { get }
}

/// The key `mai-mcp` makes: it never leaves the Secure Enclave, and what the pairing file keeps of
/// it opens nothing on another Mac.
extension SecureEnclave.P256.KeyAgreement.PrivateKey: AgentPrivateKey {
  public static func generate() throws -> Self {
    try Self()
  }

  public init(kept: Data) throws {
    try self.init(dataRepresentation: kept)
  }

  public var kept: Data { dataRepresentation }
}
