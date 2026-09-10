/**
 * API-key authentication for machine callers.
 *
 * The three identities Supabase deals in, and where this one fits:
 *
 *   anon key       identifies the project, not a caller. Public by design; RLS
 *                  is what makes that safe.
 *   user JWT       minted by GoTrue at sign-in. RLS reads it via auth.uid().
 *   service key    bypasses RLS. Never leaves the server.
 *
 * A customer's backend has no user to sign in as, and must not hold a service
 * key. So it presents an API key, which the database resolves to exactly one
 * organization plus a scope list.
 *
 * Everything that matters happens in `public.authenticate_api_key`: hash
 * lookup, revocation, expiry, scope, per-minute budget, metering and the audit
 * event, in one round trip. This file is transport — parsing a header and
 * shaping a response.
 */

import { HttpError, json } from "./http.ts";
import { adminClient } from "./supabase.ts";

/** Mirrors public.api_scopes. Kept narrow so a typo is a compile error. */
export type ApiScope =
  | "demos:read"
  | "demos:write"
  | "analytics:read"
  | "leads:read"
  | "projects:read"
  | "documents:read"
  | "documents:write";

export interface ApiIdentity {
  organizationId: string;
  keyId: string;
  scopes: ApiScope[];
  rateLimit: { limit: number; remaining: number; resets_at: string };
}

/** Exactly what public.authenticate_api_key returns on success. */
interface AuthSuccess {
  ok: true;
  organization_id: string;
  key_id: string;
  scopes: ApiScope[];
  rate_limit: { limit: number; remaining: number; resets_at: string };
}

interface AuthFailure {
  ok: false;
  error: string;
  required_scope?: string;
  scopes?: string[];
  limit?: number;
  resets_at?: string;
  retry_after_seconds?: number;
}

type AuthResult = AuthSuccess | AuthFailure;

/**
 * Accepts either `Authorization: Bearer sk_…` or `x-supademo-api-key: sk_…`.
 *
 * Bearer is what most HTTP clients reach for, but Supabase's own gateway also
 * reads Authorization — so on a function with verify_jwt enabled the header is
 * already spoken for. The dedicated header is the one that always works, and
 * the reason both exist.
 */
function presentedKey(req: Request): string | null {
  const dedicated = req.headers.get("x-supademo-api-key");
  if (dedicated) return dedicated.trim();

  const authorization = req.headers.get("Authorization") ?? "";
  const bearer = authorization.match(/^Bearer\s+(sk_\S+)$/i);
  return bearer ? bearer[1] : null;
}

/** Failure codes map to status codes deliberately, not incidentally. */
function statusFor(error: string): number {
  switch (error) {
    case "unknown_key":
    case "revoked":
    case "expired":
      return 401;
    case "missing_scope":
      return 403;
    case "rate_limited":
      return 429;
    default:
      return 401;
  }
}

/** Human-readable, without telling an attacker which guess was closer. */
function messageFor(failure: AuthFailure): string {
  switch (failure.error) {
    case "missing_scope":
      return `This key does not have the "${failure.required_scope}" scope.`;
    case "rate_limited":
      return `Rate limit of ${failure.limit} requests/minute exceeded.`;
    default:
      // One message for unknown/revoked/expired: which of the three it is would
      // tell someone probing whether a key was ever valid.
      return "Invalid or expired API key.";
  }
}

/**
 * Authenticates the request or throws an HttpError carrying the right status.
 * Rate-limit headers are attached by `apiJson` on the way out.
 */
export async function requireApiIdentity(
  req: Request,
  scope: ApiScope,
): Promise<ApiIdentity> {
  const key = presentedKey(req);
  if (!key) {
    throw new HttpError(
      401,
      "Missing API key. Send it as `Authorization: Bearer sk_…` or `x-supademo-api-key`.",
      "missing_key",
    );
  }

  const { data, error } = await adminClient().rpc("authenticate_api_key", {
    p_key: key,
    p_required_scope: scope,
  });

  if (error) {
    console.error("authenticate_api_key failed", error);
    throw new HttpError(500, "Could not verify API key");
  }

  const result = data as AuthResult;

  if (!result?.ok) {
    const failure = (result ?? { ok: false, error: "unknown_key" }) as AuthFailure;
    const err = new HttpError(statusFor(failure.error), messageFor(failure), failure.error);
    // serveJson turns this into a Retry-After header.
    err.retryAfter = failure.retry_after_seconds;
    throw err;
  }

  // snake_case on the wire, camelCase in TypeScript. Mapped in one place so no
  // caller has to know the database's naming.
  return {
    organizationId: result.organization_id,
    keyId: result.key_id,
    scopes: result.scopes ?? [],
    rateLimit: result.rate_limit,
  };
}

/** Standard rate-limit headers, so a client can back off before being told to. */
export function rateLimitHeaders(identity: ApiIdentity): Record<string, string> {
  if (!identity.rateLimit || identity.rateLimit.limit < 0) return {};
  return {
    "X-RateLimit-Limit": String(identity.rateLimit.limit),
    "X-RateLimit-Remaining": String(identity.rateLimit.remaining),
    "X-RateLimit-Reset": identity.rateLimit.resets_at,
  };
}

export function apiJson(
  req: Request,
  identity: ApiIdentity,
  body: unknown,
  status = 200,
): Response {
  return json(req, body, status, rateLimitHeaders(identity));
}
