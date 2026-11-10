import { LIMITS } from "../households/limits.js";

export type Plan = "free" | "premium";

/** What each plan allows (SPEC §11 phase 5). Premium matches the MVP household limits. */
export const PLAN_LIMITS: Record<Plan, { cameras: number }> = {
  free: { cameras: 1 },
  premium: { cameras: LIMITS.camerasPerHousehold },
};

export interface HouseholdPlanFields {
  planExpiresAt: Date | null;
}

/** Premium while an App Store subscription is paid up; everything else is free. */
export function effectivePlan(household: HouseholdPlanFields, now: Date): Plan {
  return household.planExpiresAt && household.planExpiresAt.getTime() > now.getTime() ? "premium" : "free";
}

/**
 * Cameras a household may pair. Until the app can sell premium (`enforce` off), every household
 * gets the full MVP limit so nobody loses a feature they had.
 */
export function cameraLimit(household: HouseholdPlanFields, now: Date, enforce: boolean): number {
  return enforce ? PLAN_LIMITS[effectivePlan(household, now)].cameras : LIMITS.camerasPerHousehold;
}
