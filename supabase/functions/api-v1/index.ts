/**
 * The machine-facing API. Authenticated by API key, never by user session.
 *
 *   GET /api-v1/demos                     demos:read
 *   GET /api-v1/demos/:public_id          demos:read
 *   GET /api-v1/demos/:public_id/analytics analytics:read
 *   GET /api-v1/whoami                    (any valid key)
 *
 * `verify_jwt = false`, because the caller has no Supabase JWT — the API key
 * *is* the credential, and it is checked on every route below.
 *
 * This function runs as service_role, which bypasses RLS. That is why it never
 * queries a table directly: every read goes through a `public.api_*` function
 * that takes the organization id the key resolved to and filters by it. The
 * tenant boundary is inside the database, not in this file.
 */

import { HttpError, json, serveJson } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import { type ApiIdentity, apiJson, type ApiScope, requireApiIdentity } from "../_shared/api-auth.ts";

/** Strips the function prefix so routing works locally and when deployed. */
function pathSegments(url: URL): string[] {
  return url.pathname
    .replace(/^\/functions\/v1/, "")
    .replace(/^\/api-v1/, "")
    .split("/")
    .filter(Boolean);
}

async function callRpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await adminClient().rpc(fn, args);
  if (error) {
    console.error(`${fn} failed`, error);
    throw new HttpError(500, "Query failed");
  }
  return data as T;
}

serveJson(async (req) => {
  if (req.method !== "GET") throw new HttpError(405, "Method not allowed");

  const url = new URL(req.url);
  const segments = pathSegments(url);

  // Authenticate once, with the scope the route requires. Doing it per-route
  // rather than up front means the scope is stated next to the thing it
  // protects, and a new route cannot inherit someone else's permission.
  const authenticate = (scope: ApiScope): Promise<ApiIdentity> => requireApiIdentity(req, scope);

  // GET /whoami — what this key is, useful for verifying a deploy's config.
  if (segments[0] === "whoami") {
    const identity = await authenticate("demos:read");
    return apiJson(req, identity, {
      organization_id: identity.organizationId,
      key_id: identity.keyId,
      scopes: identity.scopes,
      rate_limit: identity.rateLimit,
    });
  }

  if (segments[0] === "demos") {
    // GET /demos
    if (segments.length === 1) {
      const identity = await authenticate("demos:read");
      const limit = Number(url.searchParams.get("limit") ?? 25);
      const before = url.searchParams.get("before");

      const demos = await callRpc("api_list_demos", {
        p_organization_id: identity.organizationId,
        p_limit: Number.isFinite(limit) ? limit : 25,
        p_before: before,
      });
      return apiJson(req, identity, { demos });
    }

    const publicId = segments[1];

    // GET /demos/:public_id
    if (segments.length === 2) {
      const identity = await authenticate("demos:read");
      const demo = await callRpc<unknown>("api_get_demo", {
        p_organization_id: identity.organizationId,
        p_public_id: publicId,
      });
      if (!demo) throw new HttpError(404, "Demo not found");
      return apiJson(req, identity, demo);
    }

    // GET /demos/:public_id/analytics
    if (segments.length === 3 && segments[2] === "analytics") {
      const identity = await authenticate("analytics:read");
      const since = url.searchParams.get("since");
      const analytics = await callRpc<unknown>("api_demo_analytics", {
        p_organization_id: identity.organizationId,
        p_public_id: publicId,
        p_since: since,
      });
      if (!analytics) throw new HttpError(404, "Demo not found");
      return apiJson(req, identity, analytics);
    }
  }

  return json(req, {
    error: "Not found",
    routes: [
      "GET /api-v1/whoami",
      "GET /api-v1/demos",
      "GET /api-v1/demos/:public_id",
      "GET /api-v1/demos/:public_id/analytics",
    ],
  }, 404);
});
