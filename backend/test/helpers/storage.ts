import type { MediaStorage, PresignedUpload } from "../../src/storage/storage.js";

/** Records calls and returns predictable URLs instead of talking to S3. */
export class FakeStorage implements MediaStorage {
  deleted: string[] = [];

  async presignUpload(key: string, contentType: string, expiresInSeconds: number): Promise<PresignedUpload> {
    return {
      key,
      url: `https://bucket.test/${key}?put&ttl=${expiresInSeconds}`,
      headers: { "Content-Type": contentType },
      expiresAt: new Date(Date.now() + expiresInSeconds * 1000).toISOString(),
    };
  }

  async presignDownload(key: string, expiresInSeconds: number): Promise<string> {
    return `https://bucket.test/${key}?get&ttl=${expiresInSeconds}`;
  }

  async deleteObjects(keys: string[]): Promise<void> {
    this.deleted.push(...keys);
  }
}
