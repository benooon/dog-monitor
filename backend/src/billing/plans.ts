import { LIMITS } from "../households/limits.js";

export type Plan = "free" | "premium";

export interface PlanFeatures {
  /** Active cameras the household may pair. */
  cameras: number;
  /** People in the household, owner included. Premium is "unlimited" up to the household cap. */
  members: number;
  /** Days a clip or snapshot is kept before the retention job deletes it. */
  clipRetentionDays: number;
  /** Week-over-week trends and the vet PDF. */
  insights: boolean;
  /** The daily highlight reel. */
  highlightReel: boolean;
}

/**
 * What each plan includes, in one place (mirrored by `PlanFeatures` in DogMonitorCore).
 * Dog alerts (sofa, door, barking, whining) are not here on purpose: they are free on every plan.
 */
export const PLAN_FEATURES: Record<Plan, PlanFeatures> = {
  free: { cameras: 1, members: 2, clipRetentionDays: 1, insights: false, highlightReel: false },
  premium: {
    cameras: LIMITS.camerasPerHousehold,
    members: LIMITS.usersPerHousehold,
    clipRetentionDays: 30,
    insights: true,
    highlightReel: true,
  },
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
  return enforce ? PLAN_FEATURES[effectivePlan(household, now)].cameras : LIMITS.camerasPerHousehold;
}

/** People a household may have (owner included); the MVP cap while limits aren't enforced. */
export function memberLimit(household: HouseholdPlanFields, now: Date, enforce: boolean): number {
  return enforce ? PLAN_FEATURES[effectivePlan(household, now)].members : LIMITS.usersPerHousehold;
}

/** Feature flags a household's apps show. Until limits are enforced every household gets them all. */
export function featureFlags(
  household: HouseholdPlanFields,
  now: Date,
  enforce: boolean,
): { insights: boolean; highlightReel: boolean } {
  const features = enforce ? PLAN_FEATURES[effectivePlan(household, now)] : PLAN_FEATURES.premium;
  return { insights: features.insights, highlightReel: features.highlightReel };
}
