/**
 * The typed Supabase client every frontend should use, plus the handful of
 * URL helpers that would otherwise be reimplemented (differently) in each app.
 */

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@supademo/db-types";

export type SupademoClient = SupabaseClient<Database>;

export interface SupademoClientOptions {
  url: string;
  anonKey: string;
  /**
   * Browsers persist the session and refresh it in the background; a CLI or a
   * server-side render usually should not.
   */
  persistSession?: boolean;
  /** Extra headers, e.g. a request id for tracing. */
  headers?: Record<string, string>;
}

export function createSupademoClient(options: SupademoClientOptions): SupademoClient {
  return createClient<Database>(options.url, options.anonKey, {
    auth: {
      persistSession: options.persistSession ?? true,
      autoRefreshToken: options.persistSession ?? true,
      detectSessionInUrl: options.persistSession ?? true,
    },
    global: { headers: options.headers ?? {} },
    db: { schema: "public" },
  });
}

/**
 * Reads the curated views instead of the raw tables. `api` is exposed to
 * PostgREST alongside `public`, but a client can only talk to one schema at a
 * time, hence the second client rather than an option.
 */
export function createApiClient(options: SupademoClientOptions): SupabaseClient<Database> {
  return createClient<Database>(options.url, options.anonKey, {
    auth: { persistSession: options.persistSession ?? true },
    // deno-lint-ignore no-explicit-any -- the `api` schema is not in the generated Database type yet
    db: { schema: "api" as any },
  });
}

// --- Storage ---------------------------------------------------------------
//
// Paths must match the conventions the storage policies parse (migration 0700).
// Building them here keeps a typo from turning into a mysterious 403.

export const buckets = {
  avatars: "avatars",
  orgBranding: "org-branding",
  demoAssets: "demo-assets",
  exports: "exports",
} as const;

export function avatarPath(userId: string, filename: string): string {
  return `users/${userId}/${filename}`;
}

export function orgBrandingPath(organizationId: string, filename: string): string {
  return `orgs/${organizationId}/${filename}`;
}

export function demoAssetPath(organizationId: string, demoId: string, filename: string): string {
  return `orgs/${organizationId}/demos/${demoId}/${filename}`;
}

export interface TransformOptions {
  width?: number;
  height?: number;
  quality?: number;
  resize?: "cover" | "contain" | "fill";
}

/**
 * Public URL for an object in a public bucket, optionally transformed on the
 * fly by the Storage image pipeline — cheaper than generating thumbnails and
 * storing them.
 */
export function publicAssetUrl(
  client: SupademoClient,
  bucket: (typeof buckets)[keyof typeof buckets],
  path: string,
  transform?: TransformOptions,
): string {
  const { data } = client.storage.from(bucket).getPublicUrl(path, {
    transform: transform
      ? {
        width: transform.width,
        height: transform.height,
        quality: transform.quality ?? 80,
        resize: transform.resize ?? "cover",
      }
      : undefined,
  });
  return data.publicUrl;
}

/** Time-boxed URL for an object in a private bucket. */
export async function signedAssetUrl(
  client: SupademoClient,
  bucket: (typeof buckets)[keyof typeof buckets],
  path: string,
  expiresInSeconds = 3600,
): Promise<string | null> {
  const { data, error } = await client.storage.from(bucket).createSignedUrl(path, expiresInSeconds);
  if (error) return null;
  return data.signedUrl;
}

// --- Realtime --------------------------------------------------------------

/**
 * Channel naming has to agree with the RLS policy on `realtime.messages`
 * (migration 0800), which authorizes topics shaped `org:<uuid>`.
 */
export function organizationChannel(organizationId: string): string {
  return `org:${organizationId}`;
}
