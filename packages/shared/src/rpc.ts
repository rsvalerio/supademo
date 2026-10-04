/**
 * Thin, typed wrappers over the database's RPC surface.
 *
 * Every function here corresponds to one `public.*` function in a migration.
 * They exist so a frontend never has to remember an argument name (`p_` prefix
 * and all), and so the return shapes are declared in one place rather than cast
 * at each call site.
 */

import type { Json } from "@supademo/db-types";

import type { SupademoClient } from "./client.ts";
import type {
  AllergenRecallHit,
  Order,
  OrganizationOverview,
} from "./types.ts";
import type { OrgRole } from "./permissions.ts";

/**
 * Throws on error, returns the payload otherwise.
 *
 * `T` is supplied by the caller's declared return type rather than inferred
 * from the response, and that is deliberate: several of these RPCs return
 * `jsonb`, which Postgres cannot describe more precisely than `Json`. The
 * domain shape lives in types.ts and is asserted here — which is the entire
 * reason these wrappers exist rather than callers using `.rpc()` directly.
 */
async function unwrap<T>(promise: PromiseLike<{ data: unknown; error: unknown }>): Promise<T> {
  const { data, error } = await promise;
  if (error) throw error;
  return data as T;
}

// --- Organizations ----------------------------------------------------------

export function createOrganization(client: SupademoClient, name: string, slug?: string) {
  // An argument with a DEFAULT comes through as optional, not nullable
  // (`p_slug?: string`), so leaving it unset means omitting the key. Passing
  // null would send a null and override the default.
  return unwrap(
    client.rpc("create_organization", {
      p_name: name,
      ...(slug === undefined ? {} : { p_slug: slug }),
    }),
  );
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

// There is deliberately no `entitlements()` wrapper. `app.entitlements()` lives
// in the `app` schema, which PostgREST does not expose and `gen types` does not
// cover, so there is nothing for a client to call. Read them from
// `organizationOverview(...).entitlements`, which is one round trip anyway.

// --- Commerce ---------------------------------------------------------------

export interface OrderLineInput {
  sku: string;
  quantity: number;
}

/**
 * Places an order and returns it.
 *
 * One call does the whole thing: it resolves each sku against the active
 * catalogue, snapshots the price and allergen list onto the line, locks the
 * ingredients the order consumes, refuses the order if the ledger does not
 * cover it, and writes the consumption. There is no way to do half of that
 * from here, which is the point — the sequence is in the database, not in
 * whichever client happens to be calling.
 *
 * Errors worth handling by code rather than by message:
 *   `P0002` an unknown sku, or a customer that is not in this organization
 *   `23514` a bad quantity, an empty order, mixed currencies, or a lapsed plan
 *   `53000` not enough stock on hand
 */
export function placeOrder(
  client: SupademoClient,
  organizationId: string,
  customerId: string,
  lines: OrderLineInput[],
): Promise<Order> {
  return unwrap(
    client.rpc("place_order", {
      p_organization_id: organizationId,
      p_customer_id: customerId,
      // A jsonb argument is typed `Json`, which an interface does not satisfy
      // structurally (it has no index signature). The shape is checked by
      // OrderLineInput on the way in, which is the part worth checking.
      p_lines: lines as unknown as Json,
    }),
  );
}

/**
 * Cancels an order and returns stock as a `release` movement. The consumption
 * rows are not deleted, so what happened stays on the record.
 *
 * Refused with `23514` on an order that is already cancelled, or fulfilled —
 * a fulfilled order is refunded, not cancelled.
 */
export function cancelOrder(
  client: SupademoClient,
  organizationId: string,
  orderId: string,
  reason?: string,
): Promise<Order> {
  return unwrap(
    client.rpc("cancel_order", {
      p_organization_id: organizationId,
      p_order_id: orderId,
      ...(reason === undefined ? {} : { p_reason: reason }),
    }),
  );
}

/** Resolves to `null` when the id does not belong to this organization. */
export function getOrder(
  client: SupademoClient,
  organizationId: string,
  orderId: string,
): Promise<Order | null> {
  return unwrap(
    client.rpc("get_order", {
      p_organization_id: organizationId,
      p_order_id: orderId,
    }),
  );
}

/**
 * The recall query: orders whose label omitted an allergen the product is now
 * known to contain. Cancelled orders are excluded.
 *
 * This is the one query that justifies modelling ingredients separately from
 * products at all. Correcting an ingredient relabels every product that uses
 * it, but it cannot and must not change what a past buyer was told — so the
 * two records disagree, and this is how that disagreement is read back.
 */
export function ordersMissingAllergen(
  client: SupademoClient,
  organizationId: string,
  allergen: string,
  since?: Date,
): Promise<AllergenRecallHit[]> {
  return unwrap(
    client.rpc("orders_missing_allergen", {
      p_organization_id: organizationId,
      p_allergen: allergen,
      ...(since === undefined ? {} : { p_since: since.toISOString() }),
    }),
  );
}

/**
 * Stock on hand, summed from the ledger. There is no column to read instead;
 * that is deliberate, and it means this value is always consistent with the
 * movements that produced it.
 */
export function ingredientAvailable(
  client: SupademoClient,
  ingredientId: string,
): Promise<number> {
  return unwrap(client.rpc("ingredient_available", { p_ingredient_id: ingredientId }));
}

/** How many of a product the current stock could make, from its recipe. */
export function productSellable(client: SupademoClient, productId: string): Promise<number> {
  return unwrap(client.rpc("product_sellable", { p_product_id: productId }));
}

/**
 * Scrubs a customer's personal details in place, keeping the row so their
 * orders stay referentially intact. Irreversible; admin or service_role only.
 */
export function anonymizeCustomer(client: SupademoClient, customerId: string) {
  return unwrap(client.rpc("anonymize_customer", { p_customer_id: customerId }));
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
  return unwrap(
    client.rpc("mark_notifications_read", ids === undefined ? {} : { p_ids: ids }),
  );
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
  scopes: string[] = ["products:read"],
): Promise<Array<{ key_id: string; key_prefix: string; api_key: string }>> {
  return unwrap(
    client.rpc("create_api_key", {
      p_organization_id: organizationId,
      p_name: name,
      p_scopes: scopes,
    }),
  );
}
