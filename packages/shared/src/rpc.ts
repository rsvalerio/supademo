/**
 * Thin, typed wrappers over the database's RPC surface.
 *
 * Every function here corresponds to one `public.*` function in a migration.
 * They exist so a frontend never has to remember an argument name (`p_` prefix
 * and all), and so the return shapes are declared in one place rather than cast
 * at each call site.
 */

import type { SupademoClient } from "./client.ts";
import type {
  DemoAnalytics,
  Entitlements,
  OrganizationOverview,
  PublicDemo,
} from "./types.ts";
import type { OrgRole } from "./permissions.ts";

async function unwrap<T>(promise: PromiseLike<{ data: T | null; error: unknown }>): Promise<T> {
  const { data, error } = await promise;
  if (error) throw error;
  return data as T;
}

// --- Organizations ----------------------------------------------------------

export function createOrganization(client: SupademoClient, name: string, slug?: string) {
  return unwrap(client.rpc("create_organization", { p_name: name, p_slug: slug ?? null }));
}

/**
 * The returned token is shown once and never stored in recoverable form — the
 * database keeps only its SHA-256. Put it in front of the user immediately;
 * there is no way to retrieve it later.
 */
export function createInvite(
  client: SupademoClient,
  organizationId: string,
  email: string,
  role: Exclude<OrgRole, "owner"> = "member",
): Promise<Array<{ invite_id: string; token: string }>> {
  return unwrap(
    client.rpc("create_organization_invite", {
      p_organization_id: organizationId,
      p_email: email,
      p_role: role,
    }),
  );
}

export function acceptInvite(client: SupademoClient, token: string) {
  return unwrap(client.rpc("accept_organization_invite", { p_token: token }));
}

/** Requires a verified second factor; expect a 403 at aal1. */
export function transferOwnership(
  client: SupademoClient,
  organizationId: string,
  toUserId: string,
) {
  return unwrap(
    client.rpc("transfer_organization_ownership", {
      p_organization_id: organizationId,
      p_to_user_id: toUserId,
    }),
  );
}

export function organizationOverview(
  client: SupademoClient,
  organizationId: string,
): Promise<OrganizationOverview> {
  return unwrap(client.rpc("organization_overview", { p_organization_id: organizationId }));
}

export function entitlements(
  client: SupademoClient,
  organizationId: string,
): Promise<Entitlements> {
  return unwrap(client.rpc("entitlements", { p_organization_id: organizationId }));
}

// --- Demos ------------------------------------------------------------------

export function searchDemos(
  client: SupademoClient,
  query: string,
  organizationId?: string,
  limit = 20,
) {
  return unwrap(
    client.rpc("search_demos", {
      p_query: query,
      p_organization_id: organizationId ?? null,
      p_limit: limit,
    }),
  );
}

/** Works unauthenticated. Resolves to `null` when the demo is not shareable. */
export function getPublicDemo(
  client: SupademoClient,
  publicId: string,
): Promise<PublicDemo | null> {
  return unwrap(client.rpc("get_public_demo", { p_public_id: publicId }));
}

export function demoAnalytics(
  client: SupademoClient,
  demoId: string,
  since?: Date,
): Promise<DemoAnalytics> {
  return unwrap(
    client.rpc("demo_analytics", {
      p_demo_id: demoId,
      p_since: since?.toISOString() ?? null,
    }),
  );
}

export interface ViewPing {
  publicId: string;
  sessionId: string;
  stepsViewed?: number;
  completed?: boolean;
  durationMs?: number;
  referrer?: string;
}

/**
 * Idempotent per (demo, session): call it as often as the player likes. Only
 * the first call for a session is metered.
 */
export function trackDemoView(client: SupademoClient, ping: ViewPing) {
  return unwrap(
    client.rpc("track_demo_view", {
      p_public_id: ping.publicId,
      p_session_id: ping.sessionId,
      p_steps_viewed: ping.stepsViewed ?? 0,
      p_completed: ping.completed ?? false,
      p_duration_ms: ping.durationMs ?? 0,
      p_referrer: ping.referrer ?? null,
    }),
  );
}

export function captureLead(
  client: SupademoClient,
  publicId: string,
  email: string,
  name?: string,
  fields: Record<string, unknown> = {},
) {
  return unwrap(
    client.rpc("capture_demo_lead", {
      p_public_id: publicId,
      p_email: email,
      p_name: name ?? null,
      p_fields: fields,
    }),
  );
}

// --- Search over documents --------------------------------------------------

export function hybridSearch(
  client: SupademoClient,
  organizationId: string,
  query: string,
  embedding: number[],
  limit = 10,
) {
  return unwrap(
    client.rpc("hybrid_search_documents", {
      p_organization_id: organizationId,
      p_query: query,
      // pgvector accepts its text representation over the wire.
      p_embedding: JSON.stringify(embedding),
      p_match_count: limit,
    }),
  );
}

// --- Notifications and account ---------------------------------------------

export function markNotificationsRead(client: SupademoClient, ids?: string[]) {
  return unwrap(client.rpc("mark_notifications_read", { p_ids: ids ?? null }));
}

export function myAuthEvents(client: SupademoClient, limit = 50) {
  return unwrap(client.rpc("my_auth_events", { p_limit: limit }));
}

export function auditTrail(client: SupademoClient, organizationId: string, limit = 100) {
  return unwrap(
    client.rpc("audit_trail", { p_organization_id: organizationId, p_limit: limit }),
  );
}

// --- API keys ---------------------------------------------------------------

/** The plaintext key is in the response and nowhere else, ever. */
export function createApiKey(
  client: SupademoClient,
  organizationId: string,
  name: string,
  scopes: string[] = ["demos:read"],
): Promise<Array<{ key_id: string; key_prefix: string; api_key: string }>> {
  return unwrap(
    client.rpc("create_api_key", {
      p_organization_id: organizationId,
      p_name: name,
      p_scopes: scopes,
    }),
  );
}
