import type { EventType } from "../db/schema.js";

/** Push copy. Keys are English format strings, localized on the device (Localizable.xcstrings). */
interface Copy {
  withDog: string;
  withoutDog: string;
}

const COPY: Record<EventType, Copy> = {
  prolongedBarking: { withDog: "%@ has been barking", withoutDog: "Your dog has been barking" },
  whining: { withDog: "%@ is whining or howling", withoutDog: "Your dog is whining or howling" },
  forbiddenZone: { withDog: "%@ is in a forbidden zone", withoutDog: "Your dog is in a forbidden zone" },
  atDoor: { withDog: "%@ is waiting at the door", withoutDog: "Your dog is waiting at the door" },
  notVisible: { withDog: "%@ hasn't been seen for a while", withoutDog: "Your dog hasn't been seen for a while" },
  calmedDown: { withDog: "%@ has calmed down", withoutDog: "Your dog has calmed down" },
  cameraOffline: { withDog: "The camera is offline", withoutDog: "The camera is offline" },
  lowBattery: { withDog: "The camera's battery is low", withoutDog: "The camera's battery is low" },
  overheating: { withDog: "The camera is overheating", withoutDog: "The camera is overheating" },
  dailySummary: { withDog: "%@'s daily summary is ready", withoutDog: "Your dog's daily summary is ready" },
};

const ESCALATION: Partial<Record<EventType, Copy>> = {
  prolongedBarking: { withDog: "%1$@ has been barking for %2$@ min", withoutDog: "Your dog has been barking for %@ min" },
  whining: { withDog: "%1$@ has been whining for %2$@ min", withoutDog: "Your dog has been whining for %@ min" },
  atDoor: { withDog: "%1$@ has been at the door for %2$@ min", withoutDog: "Your dog has been at the door for %@ min" },
};

/** Mirrors DogMonitorCore `EventType.interruptionLevel` (SPEC §5). */
export function interruptionLevel(type: EventType): "passive" | "active" | "time-sensitive" {
  switch (type) {
    case "prolongedBarking":
    case "whining":
    case "cameraOffline":
    case "lowBattery":
    case "overheating":
      return "time-sensitive";
    case "forbiddenZone":
    case "atDoor":
    case "notVisible":
      return "active";
    case "calmedDown":
    case "dailySummary":
      return "passive";
  }
}

/** Mirrors DogMonitorCore `EventType.isEnabledByDefault`. */
export function enabledByDefault(type: EventType): boolean {
  return !(type === "forbiddenZone" || type === "atDoor" || type === "notVisible");
}

/** Notification category registered by the app (actions: Watch live, Mute 1h). */
export const EVENT_CATEGORY = "DOG_EVENT";

export interface EventPushInput {
  eventId: string;
  type: EventType;
  cameraId: string;
  cameraName: string;
  dogName?: string | null;
  snapshotKey?: string | null;
  /** Presigned download URL of the snapshot, for the Notification Service Extension. */
  snapshotUrl?: string;
  /** Set for escalation updates ("barking for 5 minutes"). */
  escalationSeconds?: number;
}

export function buildEventPayload(input: EventPushInput): Record<string, unknown> {
  const escalation = input.escalationSeconds !== undefined ? ESCALATION[input.type] : undefined;
  const copy = escalation ?? COPY[input.type];
  const minutes = input.escalationSeconds !== undefined ? String(Math.round(input.escalationSeconds / 60)) : undefined;
  const dog = input.dogName?.trim() || null;
  const locArgs = [...(dog ? [dog] : []), ...(escalation && minutes ? [minutes] : [])];
  const level = interruptionLevel(input.type);

  return {
    aps: {
      alert: {
        title: input.cameraName,
        "loc-key": dog ? copy.withDog : copy.withoutDog,
        ...(locArgs.length > 0 && { "loc-args": locArgs }),
      },
      ...(level !== "passive" && { sound: "default" }),
      "thread-id": input.cameraId,
      category: EVENT_CATEGORY,
      "interruption-level": level,
      // Lets the Notification Service Extension attach the snapshot.
      ...(input.snapshotUrl && { "mutable-content": 1 }),
    },
    eventId: input.eventId,
    cameraId: input.cameraId,
    type: input.type,
    ...(input.snapshotKey && { snapshotKey: input.snapshotKey }),
    ...(input.snapshotUrl && { snapshotUrl: input.snapshotUrl }),
  };
}
