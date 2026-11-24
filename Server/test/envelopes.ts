/** A sealed writing of `contentsLength` ciphertext bytes, laid out as `Server/README.md` says. */
export function sealedWriting({
  writing = "6f1c2d3e-4a5b-4c6d-8e9f-0a1b2c3d4e5f",
  updated = 1_790_000_000_123n,
  magic = [0x6d, 0x61, 0x69, 0x01],
  contentsLength = 10,
}: {
  writing?: string;
  updated?: bigint;
  magic?: number[];
  contentsLength?: number;
} = {}): Uint8Array<ArrayBuffer> {
  const bytes = new Uint8Array(4 + 16 + 8 + 60 + 12 + contentsLength + 16);
  bytes.set(magic, 0);
  bytes.set(
    Array.from(writing.replaceAll("-", "").match(/../g) ?? [], (pair) => parseInt(pair, 16)),
    4,
  );
  new DataView(bytes.buffer).setBigUint64(20, updated);
  bytes.fill(0xab, 28);
  return bytes;
}
