import { X509Certificate } from "node:crypto";
import { compactVerify, decodeProtectedHeader } from "jose";

/**
 * SHA-256 fingerprint of "Apple Root CA - G3", the root of every App Store signed transaction.
 * Override with APPLE_ROOT_CA_SHA256 (tests pin their own root).
 */
export const APPLE_ROOT_CA_G3_SHA256 = "63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79";

/** Apple marks the signing certificates with these extensions (App Store Server Library does the same check). */
const LEAF_OID = "1.2.840.113635.100.6.11.1";
const INTERMEDIATE_OID = "1.2.840.113635.100.6.2.1";

export interface AppStoreConfig {
  bundleId: string;
  /** Subscription product ids that unlock premium. */
  productIds: string[];
  /** Trusted root fingerprints ("AB:CD:…", case-insensitive). */
  rootFingerprints: string[];
}

/** The fields we use from a StoreKit 2 `JWSTransactionDecodedPayload`. */
export interface VerifiedTransaction {
  transactionId: string;
  originalTransactionId: string;
  productId: string;
  bundleId: string;
  environment: string;
  expiresAt: Date;
  revokedAt: Date | null;
  /** The `appAccountToken` the app set at purchase (we use the household id), lowercased. */
  appAccountToken: string | null;
}

export class TransactionError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

export interface TransactionVerifier {
  verify(signedTransaction: string, now: Date): Promise<VerifiedTransaction>;
}

/** Verifies StoreKit 2 signed transactions offline: the x5c chain to Apple's root, then the JWS signature. */
export function createAppStoreVerifier(config: AppStoreConfig): TransactionVerifier {
  const roots = new Set(config.rootFingerprints.map(normalizeFingerprint));

  return {
    async verify(signedTransaction, now) {
      let chain: X509Certificate[];
      try {
        const header = decodeProtectedHeader(signedTransaction);
        if (header.alg !== "ES256" || !Array.isArray(header.x5c) || header.x5c.length !== 3) {
          throw new TransactionError("invalid_transaction");
        }
        chain = header.x5c.map((der) => new X509Certificate(Buffer.from(der, "base64")));
      } catch {
        throw new TransactionError("invalid_transaction");
      }
      const [leaf, intermediate, root] = chain as [X509Certificate, X509Certificate, X509Certificate];
      if (!roots.has(normalizeFingerprint(root.fingerprint256))) throw new TransactionError("untrusted_certificate");
      const chainOk =
        root.verify(root.publicKey) &&
        intermediate.verify(root.publicKey) &&
        leaf.verify(intermediate.publicKey) &&
        intermediate.checkIssued(root) &&
        leaf.checkIssued(intermediate) &&
        hasExtension(leaf, LEAF_OID) &&
        hasExtension(intermediate, INTERMEDIATE_OID) &&
        chain.every((cert) => isValidAt(cert, now));
      if (!chainOk) throw new TransactionError("untrusted_certificate");

      let payload: Record<string, unknown>;
      try {
        const { payload: bytes } = await compactVerify(signedTransaction, leaf.publicKey, { algorithms: ["ES256"] });
        payload = JSON.parse(new TextDecoder().decode(bytes)) as Record<string, unknown>;
      } catch {
        throw new TransactionError("invalid_signature");
      }

      const transaction = parsePayload(payload);
      if (transaction.bundleId !== config.bundleId) throw new TransactionError("wrong_bundle");
      if (!config.productIds.includes(transaction.productId)) throw new TransactionError("unknown_product");
      return transaction;
    },
  };
}

function parsePayload(payload: Record<string, unknown>): VerifiedTransaction {
  const str = (key: string) => (typeof payload[key] === "string" ? (payload[key] as string) : null);
  const ms = (key: string) => (typeof payload[key] === "number" ? new Date(payload[key] as number) : null);
  const transactionId = str("transactionId");
  const originalTransactionId = str("originalTransactionId");
  const productId = str("productId");
  const bundleId = str("bundleId");
  const expiresAt = ms("expiresDate");
  if (!transactionId || !originalTransactionId || !productId || !bundleId || !expiresAt) {
    throw new TransactionError("invalid_transaction");
  }
  return {
    transactionId,
    originalTransactionId,
    productId,
    bundleId,
    environment: str("environment") ?? "Production",
    expiresAt,
    revokedAt: ms("revocationDate"),
    appAccountToken: str("appAccountToken")?.toLowerCase() ?? null,
  };
}

function normalizeFingerprint(value: string): string {
  return value.replace(/[^0-9a-f]/gi, "").toUpperCase();
}

function isValidAt(cert: X509Certificate, now: Date): boolean {
  return new Date(cert.validFrom).getTime() <= now.getTime() && now.getTime() <= new Date(cert.validTo).getTime();
}

/** True when the certificate's DER contains the extension OID (node exposes no generic extension list). */
function hasExtension(cert: X509Certificate, oid: string): boolean {
  return cert.raw.includes(encodeOid(oid));
}

function encodeOid(oid: string): Buffer {
  const parts = oid.split(".").map(Number);
  const bytes = [40 * parts[0]! + parts[1]!];
  for (const part of parts.slice(2)) {
    const chunk = [part & 0x7f];
    let rest = part >> 7;
    while (rest > 0) {
      chunk.unshift((rest & 0x7f) | 0x80);
      rest >>= 7;
    }
    bytes.push(...chunk);
  }
  return Buffer.from([0x06, bytes.length, ...bytes]);
}
