import { randomBytes } from "node:crypto";
import { AccessToken, TrackSource, type VideoGrant } from "livekit-server-sdk";

/** Credentials for a LiveKit Cloud project (env: LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET). */
export interface LiveKitConfig {
  url: string;
  apiKey: string;
  apiSecret: string;
}

/** What a client needs to join a camera's room. */
export interface LiveTokenResponse {
  url: string;
  token: string;
  room: string;
  identity: string;
  expiresAt: string;
}

/** Tokens only need to stay valid long enough to connect; the SDK refreshes them in-room. */
export const LIVE_TOKEN_TTL_SECONDS = 10 * 60;

/** One LiveKit room per camera device. */
export function roomForCamera(deviceId: string): string {
  return `camera-${deviceId}`;
}

export interface LiveTokenIssuer {
  /** Token for a household member to watch a camera, and talk back (push-to-talk). */
  viewerToken(opts: { deviceId: string; userId: string; name?: string | null }): Promise<LiveTokenResponse>;
  /** Token for a camera device to publish its own room. */
  cameraToken(opts: { deviceId: string; name?: string | null }): Promise<LiveTokenResponse>;
}

export function createLiveKitIssuer(config: LiveKitConfig, now: () => Date = () => new Date()): LiveTokenIssuer {
  async function mint(identity: string, room: string, grant: VideoGrant, name?: string | null): Promise<LiveTokenResponse> {
    const token = new AccessToken(config.apiKey, config.apiSecret, {
      identity,
      name: name ?? undefined,
      ttl: LIVE_TOKEN_TTL_SECONDS,
    });
    token.addGrant({ room, roomJoin: true, ...grant });
    const expiresAt = new Date(now().getTime() + LIVE_TOKEN_TTL_SECONDS * 1000).toISOString();
    return { url: config.url, token: await token.toJwt(), room, identity, expiresAt };
  }

  return {
    viewerToken({ deviceId, userId, name }) {
      // A random suffix lets one user watch from two phones: LiveKit kicks duplicate identities.
      const identity = `viewer:${userId}:${randomBytes(4).toString("hex")}`;
      return mint(
        identity,
        roomForCamera(deviceId),
        { canSubscribe: true, canPublish: true, canPublishSources: [TrackSource.MICROPHONE], canPublishData: false },
        name,
      );
    },
    cameraToken({ deviceId, name }) {
      return mint(
        `camera:${deviceId}`,
        roomForCamera(deviceId),
        { canSubscribe: true, canPublish: true, canPublishSources: [TrackSource.CAMERA, TrackSource.MICROPHONE], canPublishData: true },
        name,
      );
    },
  };
}
