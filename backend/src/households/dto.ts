import type { devices, dogs } from "../db/schema.js";

type DeviceRow = typeof devices.$inferSelect;
type DogRow = typeof dogs.$inferSelect;

/** Public device shape. Never exposes the secret hash; the APNs token only as a flag. */
export function deviceDto(d: DeviceRow) {
  return {
    id: d.id,
    householdId: d.householdId,
    userId: d.userId,
    name: d.name,
    role: d.role,
    model: d.model,
    appVersion: d.appVersion,
    hasPushToken: d.apnsToken !== null,
    status: d.status,
    lastHeartbeatAt: d.lastHeartbeatAt,
    battery: d.battery,
    charging: d.charging,
    thermal: d.thermal,
    mutedUntil: d.mutedUntil,
    timeZone: d.timeZone,
    dogState: d.dogState,
    createdAt: d.createdAt,
  };
}

export function dogDto(d: DogRow) {
  return {
    id: d.id,
    householdId: d.householdId,
    name: d.name,
    photoKey: d.photoKey,
    lifeStage: d.lifeStage,
    traits: d.traits,
    alertStyle: d.alertStyle,
    photoUpdatedAt: d.photoUpdatedAt,
    createdAt: d.createdAt,
  };
}
