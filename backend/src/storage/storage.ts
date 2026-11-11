import { DeleteObjectsCommand, GetObjectCommand, ListObjectsV2Command, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
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
  /** Path-style URLs (bucket in the path). R2 wants them; Railway buckets use virtual-hosted. */
  forcePathStyle?: boolean;
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
  /** Deletes every object whose key starts with `prefix`; returns how many. */
  deletePrefix(prefix: string): Promise<number>;
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
      forcePathStyle: config.forcePathStyle ?? Boolean(config.endpoint),
      // Only add checksums S3 requires, so presigned uploads work on every S3-compatible service.
      requestChecksumCalculation: "WHEN_REQUIRED",
      responseChecksumValidation: "WHEN_REQUIRED",
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

  async deletePrefix(prefix: string): Promise<number> {
    let deleted = 0;
    let token: string | undefined;
    do {
      const page = await this.client.send(
        new ListObjectsV2Command({ Bucket: this.config.bucket, Prefix: prefix, ContinuationToken: token, MaxKeys: 1000 }),
      );
      const keys = (page.Contents ?? []).map((o) => o.Key).filter((k): k is string => k !== undefined);
      if (keys.length > 0) await this.deleteObjects(keys);
      deleted += keys.length;
      token = page.IsTruncated ? page.NextContinuationToken : undefined;
    } while (token);
    return deleted;
  }
}

export function householdMediaPrefix(householdId: string): string {
  return `households/${householdId}/`;
}

export type MediaKind = "clip" | "snapshot";

export const MEDIA_CONTENT_TYPES: Record<MediaKind, string> = {
  clip: "video/mp4",
  snapshot: "image/jpeg",
};

/** Every object for an event lives under this prefix, so ownership can be checked from the key. */
export function eventMediaPrefix(householdId: string, cameraId: string, eventId: string): string {
  return `${householdMediaPrefix(householdId)}cameras/${cameraId}/events/${eventId}/`;
}

export function eventMediaKey(householdId: string, cameraId: string, eventId: string, kind: MediaKind): string {
  return `${eventMediaPrefix(householdId, cameraId, eventId)}${kind === "clip" ? "clip.mp4" : "snapshot.jpg"}`;
}

/** The day's highlight reel of one camera (`date` is the camera's local YYYY-MM-DD). */
export function reelMediaKey(householdId: string, cameraId: string, date: string): string {
  return `${householdMediaPrefix(householdId)}cameras/${cameraId}/reels/${date}.mp4`;
}
