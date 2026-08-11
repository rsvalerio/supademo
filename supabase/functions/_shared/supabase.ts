/**
 * Supabase client factories.
 *
 * Two kinds of client, and the distinction matters more than any other line in
 * these functions:
 *
 *   userClient(req)  — carries the caller's JWT, so every query is subject to
 *                      RLS exactly as it would be from a browser. Default.
 *   adminClient()    — service_role, bypasses RLS entirely. Only for work that
 *                      is genuinely the server's: queue draining, billing
 *                      reconciliation, cross-tenant maintenance.
 *
 * Reach for adminClient() and you have taken responsibility for authorization
 * yourself, in code, with no safety net underneath.
 */

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { HttpError } from "./http.ts";

export function requireEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing required environment variable: ${name}`);
  return value;
}

const SUPABASE_URL = () => requireEnv("SUPABASE_URL");

/** Acts as the caller. RLS applies. */
export function userClient(req: Request): SupabaseClient {
  const authorization = req.headers.get("Authorization");
  if (!authorization) throw new HttpError(401, "Missing Authorization header");

  return createClient(SUPABASE_URL(), requireEnv("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Bypasses RLS. Authorize by hand before every query. */
export function adminClient(): SupabaseClient {
  return createClient(SUPABASE_URL(), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

/** Resolves the calling user, or 401s. */
export async function requireUser(req: Request) {
  const client = userClient(req);
  const { data, error } = await client.auth.getUser();
  if (error || !data.user) throw new HttpError(401, "Not authenticated");
  return { client, user: data.user };
}

/**
 * Resolves the caller's organization from an `x-supademo-api-key` header.
 * Used by the machine-facing endpoints, where there is no user session.
 */
export async function requireApiKey(req: Request) {
  const presented = req.headers.get("x-supademo-api-key");
  if (!presented) throw new HttpError(401, "Missing x-supademo-api-key header");

  const admin = adminClient();
  const { data, error } = await admin.rpc("verify_api_key", { p_key: presented });
  if (error) {
    console.error("verify_api_key failed", error);
    throw new HttpError(500, "Could not verify API key");
  }

  const match = Array.isArray(data) ? data[0] : data;
  if (!match) throw new HttpError(401, "Invalid or expired API key");

  return {
    admin,
    organizationId: match.organization_id as string,
    scopes: (match.scopes ?? []) as string[],
  };
}

export function requireScope(scopes: string[], needed: string): void {
  if (!scopes.includes(needed) && !scopes.includes("*")) {
    throw new HttpError(403, `API key is missing the "${needed}" scope`);
  }
}
