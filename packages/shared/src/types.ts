/**
 * Domain types that are richer than the generated row types: the shapes the
 * database's jsonb-returning RPCs produce, and the claim structure the custom
 * access token hook writes into every JWT.
 */

import type { OrgRole } from "./permissions.ts";

export type UnitOfMeasure = "g" | "ml" | "unit";
export type ProductStatus = "draft" | "active" | "discontinued";
export type OrderStatus = "pending" | "confirmed" | "fulfilled" | "cancelled";
export type StockMovementKind =
  | "receipt"
  | "consumption"
  | "waste"
  | "adjustment"
  | "release";
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
    products: number;
    ingredients: number;
    customers: number;
    orders_this_month: number;
    members: number;
    pending_invites: number;
  };
  usage_this_month: Record<string, number>;
}

/**
 * Shape returned by `public.get_order(uuid, uuid)`, and therefore by
 * `place_order` and `cancel_order`, which both return it.
 *
 * Note what the lines carry: the sku, name, price and allergen list as they
 * were when the order was placed, not as they are now. Rendering a past order
 * must use these and never re-read the product, or the receipt will quietly
 * change the next time something is repriced or relabelled.
 */
export interface Order {
  id: string;
  order_number: string;
  status: OrderStatus;
  currency: string;
  total_cents: number;
  placed_at: string;
  customer: { id: string; email: string; name: string | null };
  items: OrderLine[];
}

export interface OrderLine {
  sku: string;
  name: string;
  quantity: number;
  unit_price_cents: number;
  line_total_cents: number;
  /** What the buyer was told, frozen at the moment of sale. */
  allergens: string[];
}

/**
 * One row of `public.orders_missing_allergen(uuid, text, timestamptz)`: an
 * order whose label omitted an allergen the product is now known to contain.
 * This is a recall list — every entry is someone to contact.
 */
export interface AllergenRecallHit {
  order_number: string;
  placed_at: string;
  status: OrderStatus;
  customer_email: string;
  sku: string;
  product_name: string;
  quantity: number;
  /** What was disclosed at the time, which is why this row is a hit. */
  disclosed: string[];
}

/** Events an organization can subscribe a webhook endpoint to. */
export const WEBHOOK_EVENTS = [
  "order.confirmed",
  "order.fulfilled",
  "order.cancelled",
  "*",
] as const;
export type WebhookEvent = (typeof WEBHOOK_EVENTS)[number];

export function isUnlimited(limit: number | undefined): boolean {
  return limit === -1;
}

export function quotaRemaining(limit: number | undefined, used: number): number | null {
  if (limit === undefined || isUnlimited(limit)) return null;
  return Math.max(0, limit - used);
}
