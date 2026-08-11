/**
 * Domain types that are richer than the generated row types: the shapes the
 * database's jsonb-returning RPCs produce, and the claim structure the custom
 * access token hook writes into every JWT.
 */

import type { OrgRole } from "./permissions.ts";

export type DemoStatus = "draft" | "published" | "archived";
export type DemoVisibility = "private" | "link" | "public";
export type SubscriptionStatus =
  | "trialing"
  | "active"
  | "past_due"
  | "canceled"
  | "incomplete"
  | "paused";

/**
 * Written into `app_metadata` by `auth_hooks.custom_access_token` (migration
 * 1300). It is a snapshot taken when the token was minted, so it can be up to
 * an hour stale — good enough to decide what to render, never good enough to
 * decide what to allow.
 */
export interface OrganizationClaim {
  id: string;
  slug: string;
  name: string;
  role: OrgRole;
  plan: string | null;
}

export interface SupademoAppMetadata {
  organizations: OrganizationClaim[];
  is_staff: boolean;
}

/** Shape returned by `app.entitlements(uuid)`. */
export interface Entitlements {
  plan_id: string;
  status: SubscriptionStatus;
  seats: number;
  trial_ends_at: string | null;
  current_period_end: string | null;
  /** Quota map. `-1` means unlimited. */
  limits: Record<string, number>;
  features: string[];
}

/** Shape returned by `public.organization_overview(uuid)`. */
export interface OrganizationOverview {
  organization: {
    id: string;
    slug: string;
    name: string;
    logo_path: string | null;
    created_at: string;
  };
  role: OrgRole;
  entitlements: Entitlements;
  counts: {
    projects: number;
    demos: number;
    members: number;
    pending_invites: number;
  };
  usage_this_month: Record<string, number>;
}

/** Shape returned by `public.get_public_demo(text)`. */
export interface PublicDemo {
  id: string;
  public_id: string;
  title: string;
  description: string | null;
  cover_path: string | null;
  theme: Record<string, unknown>;
  tags: string[];
  published_at: string | null;
  organization: { name: string; logo_path: string | null };
  steps: PublicDemoStep[];
}

export interface PublicDemoStep {
  id: string;
  position: number;
  title: string | null;
  body: string | null;
  asset_path: string | null;
  /** Added by the `public-demo` edge function; absent when read via the RPC directly. */
  asset_url?: string | null;
  hotspot: { x?: number; y?: number; shape?: "circle" | "rect" };
  duration_ms: number | null;
}

/** Shape returned by `public.demo_analytics(uuid, timestamptz)`. */
export interface DemoAnalytics {
  views: number;
  unique_sessions: number;
  completions: number;
  completion_rate: number;
  avg_duration_ms: number;
  by_day: Array<{ day: string; views: number }>;
}

/** Events an organization can subscribe a webhook endpoint to. */
export const WEBHOOK_EVENTS = ["demo.published", "*"] as const;
export type WebhookEvent = (typeof WEBHOOK_EVENTS)[number];

export function isUnlimited(limit: number | undefined): boolean {
  return limit === -1;
}

export function quotaRemaining(limit: number | undefined, used: number): number | null {
  if (limit === undefined || isUnlimited(limit)) return null;
  return Math.max(0, limit - used);
}
