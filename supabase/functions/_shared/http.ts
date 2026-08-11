/**
 * Request/response plumbing shared by every function.
 *
 * The rules encoded here — allow-list CORS, JSON-only errors, never echo an
 * internal message to a caller — are the ones that are tedious to remember per
 * endpoint and expensive to get wrong once.
 */

const ALLOWED_ORIGINS = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
  .split(",")
  .map((o) => o.trim())
  .filter(Boolean);

/**
 * Reflects the caller's origin only when it is allow-listed. With
 * ALLOWED_ORIGINS unset (local development) it falls back to `*`, which is
 * fine precisely because no cookies are involved — auth travels in the
 * Authorization header.
 */
export function corsHeaders(req: Request): Record<string, string> {
  const origin = req.headers.get("Origin") ?? "";
  const allowed = ALLOWED_ORIGINS.length === 0
    ? "*"
    : ALLOWED_ORIGINS.includes(origin)
    ? origin
    : ALLOWED_ORIGINS[0];

  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-supademo-api-key",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    ...(ALLOWED_ORIGINS.length > 0 ? { Vary: "Origin" } : {}),
  };
}

export function json(req: Request, body: unknown, status = 200, extra: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      ...corsHeaders(req),
      ...Object.fromEntries(new Headers(extra)),
    },
  });
}

/** A failure the caller is allowed to see. Anything else becomes a generic 500. */
export class HttpError extends Error {
  constructor(readonly status: number, message: string, readonly code?: string) {
    super(message);
    this.name = "HttpError";
  }
}

export function preflight(req: Request): Response | null {
  return req.method === "OPTIONS" ? new Response("ok", { headers: corsHeaders(req) }) : null;
}

/**
 * Wraps a handler so every function has the same error surface: CORS preflight
 * handled, expected failures returned as JSON, unexpected ones logged in full
 * and reported as an opaque 500.
 */
export function serveJson(handler: (req: Request) => Promise<Response>): void {
  Deno.serve(async (req) => {
    const pre = preflight(req);
    if (pre) return pre;

    try {
      return await handler(req);
    } catch (err) {
      if (err instanceof HttpError) {
        return json(req, { error: err.message, code: err.code }, err.status);
      }
      console.error("unhandled error", err);
      return json(req, { error: "Internal server error" }, 500);
    }
  });
}

export async function readJson<T>(req: Request): Promise<T> {
  try {
    return (await req.json()) as T;
  } catch {
    throw new HttpError(400, "Request body must be valid JSON");
  }
}
