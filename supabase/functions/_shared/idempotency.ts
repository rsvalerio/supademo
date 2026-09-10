/**
 * Idempotent replay for write endpoints.
 *
 * A machine client that times out will retry, and "create a demo" is not safe
 * to run twice. When the caller sends `Idempotency-Key`, the first response is
 * stored against (api key, idempotency key) and replayed on any repeat.
 *
 * The stored fingerprint covers method, path and body: reusing a key with a
 * different request is a client bug, and returning the old response for a
 * different question would hide it. That case is a 409.
 *
 * Scoped to the API key rather than the organization, so one integration's
 * choice of key names cannot collide with another's.
 */

import { HttpError } from "./http.ts";
import { adminClient } from "./supabase.ts";
import type { ApiIdentity } from "./api-auth.ts";

export interface ReplayedResponse {
  statusCode: number;
  body: unknown;
}

async function fingerprint(req: Request, rawBody: string): Promise<string> {
  const material = `${req.method} ${new URL(req.url).pathname} ${rawBody}`;
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(material));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export function idempotencyKey(req: Request): string | null {
  const key = req.headers.get("Idempotency-Key");
  return key && key.trim().length >= 8 ? key.trim() : null;
}

/** Returns the stored response when this exact request has been seen before. */
export async function replay(
  req: Request,
  identity: ApiIdentity,
  rawBody: string,
): Promise<ReplayedResponse | null> {
  const key = idempotencyKey(req);
  if (!key) return null;

  const { data, error } = await adminClient().rpc("api_replay_idempotent", {
    p_key_id: identity.keyId,
    p_idempotency_key: key,
    p_fingerprint: await fingerprint(req, rawBody),
  });

  if (error) {
    // 23505 is the reused-key-different-body case the function raises.
    if (error.code === "23505") {
      throw new HttpError(
        409,
        "This Idempotency-Key was already used with a different request body.",
        "idempotency_conflict",
      );
    }
    console.error("api_replay_idempotent failed", error);
    throw new HttpError(500, "Could not check idempotency");
  }

  if (!data) return null;
  const stored = data as { status_code: number; response: unknown };
  return { statusCode: stored.status_code, body: stored.response };
}

/** Stores a response so a retry replays it. Best effort: never fails the write. */
export async function remember(
  req: Request,
  identity: ApiIdentity,
  rawBody: string,
  body: unknown,
  statusCode: number,
): Promise<void> {
  const key = idempotencyKey(req);
  if (!key) return;

  const { error } = await adminClient().rpc("api_remember_idempotent", {
    p_key_id: identity.keyId,
    p_idempotency_key: key,
    p_fingerprint: await fingerprint(req, rawBody),
    p_response: body,
    p_status_code: statusCode,
  });

  // The write already happened. Failing the response now would tell the client
  // it failed and invite exactly the duplicate retry this is meant to prevent.
  if (error) console.error("could not store idempotent response", error);
}
