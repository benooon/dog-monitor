import { DeleteObjectsCommand, GetObjectCommand, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

/** S3-compatible bucket (Cloudflare R2, Railway bucket, AWS). Env: S3_*. */
export interface S3Config {
  /** e.g. https://<account>.r2.cloudflarestorage.com; omit for AWS. */
  endpoint?: string;
  /** "auto" for R2. */
  region: string;
  bucket: string;
  accessKeyId: string;
  secretAccessKey: string;
}

export interface PresignedUpload {
  key: string;
  url: string;
  /** Headers the client must send with the PUT. */
  headers: Record<string, string>;
  expiresAt: string;
}

/** Clip and snapshot storage behind an interface, so tests and other providers can swap it. */
export interface MediaStorage {
  presignUpload(key: string, contentType: string, expiresInSeconds: number): Promise<PresignedUpload>;
  presignDownload(key: string, expiresInSeconds: number): Promise<string>;
  deleteObjects(keys: string[]): Promise<void>;
}

export class S3MediaStorage implements MediaStorage {
  private readonly client: S3Client;

  constructor(
    private readonly config: S3Config,
    private readonly now: () => number = Date.now,
  ) {
    this.client = new S3Client({
      region: config.region,
      endpoint: config.endpoint,
      // R2 and most S3-compatible services want path-style URLs when a custom endpoint is used.
      forcePathStyle: Boolean(config.endpoint),
      credentials: { accessKeyId: config.accessKeyId, secretAccessKey: config.secretAccessKey },
    });
  }

  async presignUpload(key: string, contentType: string, expiresInSeconds: number): Promise<PresignedUpload> {
    const command = new PutObjectCommand({ Bucket: this.config.bucket, Key: key, ContentType: contentType });
    const url = await getSignedUrl(this.client, command, { expiresIn: expiresInSeconds });
    return {
      key,
      url,
      headers: { "Content-Type": contentType },
      expiresAt: new Date(this.now() + expiresInSeconds * 1000).toISOString(),
    };
  }

  presignDownload(key: string, expiresInSeconds: number): Promise<string> {
    return getSignedUrl(this.client, new GetObjectCommand({ Bucket: this.config.bucket, Key: key }), {
      expiresIn: expiresInSeconds,
    });
  }

  async deleteObjects(keys: string[]): Promise<void> {
    // S3 accepts at most 1000 keys per DeleteObjects call.
    for (let i = 0; i < keys.length; i += 1000) {
      const batch = keys.slice(i, i + 1000);
      await this.client.send(
        new DeleteObjectsCommand({
          Bucket: this.config.bucket,
          Delete: { Objects: batch.map((Key) => ({ Key })), Quiet: true },
        }),
      );
    }
  }
}

export type MediaKind = "clip" | "snapshot";

export const MEDIA_CONTENT_TYPES: Record<MediaKind, string> = {
  clip: "video/mp4",
  snapshot: "image/jpeg",
};

/** Every object for an event lives under this prefix, so ownership can be checked from the key. */
export function eventMediaPrefix(householdId: string, cameraId: string, eventId: string): string {
  return `households/${householdId}/cameras/${cameraId}/events/${eventId}/`;
}

export function eventMediaKey(householdId: string, cameraId: string, eventId: string, kind: MediaKind): string {
  return `${eventMediaPrefix(householdId, cameraId, eventId)}${kind === "clip" ? "clip.mp4" : "snapshot.jpg"}`;
}
