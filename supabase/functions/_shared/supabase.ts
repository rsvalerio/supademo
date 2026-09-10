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

// API-key authentication lives in ./api-auth.ts. It is not here because it is
// not a client factory: it is an authorization decision the database makes,
// and putting it beside createClient invited callers to treat "I have an
// admin client" and "I know who is asking" as the same thing.
