/**
 * The machine-facing API. Authenticated by API key, never by user session.
 *
 *   GET   /api-v1/whoami                      products:read
 *   PUT   /api-v1/documents/:source_id        documents:write
 *
 * The commerce routes — products, inventory, orders — are not here yet. The
 * domain and its RPCs landed first, deliberately: the transport layer is the
 * thin part, and routing to a function that does not exist yet would be worse
 * than not routing at all. The demo routes that used to be here were removed
 * with the domain they served.
 *
 * Writes accept an `Idempotency-Key` header; a retry replays the first
 * response rather than doing the work twice.
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
import {
  type ApiIdentity,
  apiJson,
  type ApiScope,
  requireApiIdentity,
} from "../_shared/api-auth.ts";
import { remember, replay } from "../_shared/idempotency.ts";

/** Strips the function prefix so routing works locally and when deployed. */
function pathSegments(url: URL): string[] {
  return url.pathname
    .replace(/^\/functions\/v1/, "")
    .replace(/^\/api-v1/, "")
    .split("/")
    .filter(Boolean);
}

/**
 * Postgres error codes carry the intent already; translating them once here
 * beats a try/catch around every call. `check_violation` covers both quota
 * exhaustion and validation, so its message is what distinguishes them — which
 * is why those RAISEs are worded for a caller to read.
 */
function statusForPgError(code: string | undefined, message: string): number {
  switch (code) {
    case "no_data_found":
    case "P0002":
      return 404;
    case "23514":
      return /plan limit reached/.test(message) ? 402 : 422;
    case "23505":
      return 409;
    case "53000":
      // insufficient_resources: raised when an order asks for more stock than
      // the ledger holds. A conflict with the world's state, not a bad request.
      return 409;
    case "42501":
      return 403;
    default:
      return 500;
  }
}

async function callRpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await adminClient().rpc(fn, args);
  if (error) {
    const status = statusForPgError(error.code, error.message ?? "");
    if (status === 500) {
      console.error(`${fn} failed`, error);
      throw new HttpError(500, "Query failed");
    }
    throw new HttpError(status, error.message ?? "Request rejected", error.code);
  }
  return data as T;
}

/** Parses a JSON body, tolerating an empty one. */
function parseBody(raw: string): Record<string, unknown> {
  if (!raw.trim()) return {};
  try {
    return JSON.parse(raw) as Record<string, unknown>;
  } catch {
    throw new HttpError(400, "Request body must be valid JSON");
  }
}

/**
 * Runs a write with replay protection: if this exact request has been seen
 * before under the same Idempotency-Key, the stored response comes back and the
 * work is not repeated.
 */
async function writeOnce(
  req: Request,
  identity: ApiIdentity,
  rawBody: string,
  status: number,
  work: () => Promise<unknown>,
): Promise<Response> {
  const replayed = await replay(req, identity, rawBody);
  if (replayed) {
    return apiJson(req, identity, replayed.body, replayed.statusCode);
  }

  const body = await work();
  await remember(req, identity, rawBody, body, status);
  return apiJson(req, identity, body, status);
}

serveJson(async (req) => {
  const url = new URL(req.url);
  const segments = pathSegments(url);
  const rawBody = req.method === "GET" ? "" : await req.text();

  // Authenticate once, with the scope the route requires. Doing it per-route
  // rather than up front means the scope is stated next to the thing it
  // protects, and a new route cannot inherit someone else's permission.
  const authenticate = (scope: ApiScope): Promise<ApiIdentity> => requireApiIdentity(req, scope);

  // GET /whoami — what this key is, useful for verifying a deploy's config.
  if (segments[0] === "whoami") {
    if (req.method !== "GET") throw new HttpError(405, "Method not allowed");
    const identity = await authenticate("products:read");
    return apiJson(req, identity, {
      organization_id: identity.organizationId,
      key_id: identity.keyId,
      scopes: identity.scopes,
      rate_limit: identity.rateLimit,
    });
  }

  // PUT /documents/:source_id — upsert, so a customer's sync job can re-run.
  if (segments[0] === "documents" && segments.length === 2 && req.method === "PUT") {
    const identity = await authenticate("documents:write");
    const body = parseBody(rawBody);
    if (!body.title) throw new HttpError(400, "`title` is required");

    return await writeOnce(req, identity, rawBody, 200, () =>
      callRpc("api_upsert_document", {
        p_organization_id: identity.organizationId,
        p_source_id: segments[1],
        p_title: String(body.title),
        p_content: body.content ?? "",
      }));
  }

  return json(req, {
    error: "Not found",
    routes: [
      "GET   /api-v1/whoami",
      "PUT   /api-v1/documents/:source_id",
    ],
  }, 404);
});
