/**
 * The embeddable player's endpoint: everything needed to render a shared demo,
 * for a viewer with no account.
 *
 * GET  /public-demo?id=<public_id>   → demo + steps + signed asset URLs
 * POST /public-demo                  → { public_id, session_id, ... } view ping
 *
 * Runs with verify_jwt = false because its callers are anonymous. It uses the
 * service key, so authorization is explicit: the RPCs it calls already refuse
 * anything that is not published and shareable, and this function never accepts
 * an organization id from the caller.
 */

import { HttpError, json, readJson, serveJson } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

const SIGNED_URL_TTL_SECONDS = 60 * 60;

interface Step {
  asset_path: string | null;
  [key: string]: unknown;
}

interface ViewPing {
  public_id?: string;
  session_id?: string;
  steps_viewed?: number;
  completed?: boolean;
  duration_ms?: number;
  referrer?: string;
  country?: string;
  device_type?: string;
}

serveJson(async (req) => {
  const supabase = adminClient();

  if (req.method === "GET") {
    const publicId = new URL(req.url).searchParams.get("id");
    if (!publicId) throw new HttpError(400, "Missing ?id=<public_id>");

    const { data, error } = await supabase.rpc("get_public_demo", { p_public_id: publicId });
    if (error) {
      console.error("get_public_demo failed", error);
      throw new HttpError(500, "Could not load demo");
    }
    // The RPC returns NULL for both "no such demo" and "not shared", which is
    // what stops this endpoint from confirming that a share id exists.
    if (!data) throw new HttpError(404, "Demo not found");

    const demo = data as { steps?: Step[]; [key: string]: unknown };
    const steps = demo.steps ?? [];

    // demo-assets is a private bucket. Viewers get short-lived signed URLs
    // rather than access to the bucket.
    const paths = steps.map((s) => s.asset_path).filter((p): p is string => Boolean(p));
    const signed = new Map<string, string>();

    if (paths.length > 0) {
      const { data: urls, error: signError } = await supabase.storage
        .from("demo-assets")
        .createSignedUrls(paths, SIGNED_URL_TTL_SECONDS);

      if (signError) console.error("could not sign asset urls", signError);
      for (const entry of urls ?? []) {
        if (entry.signedUrl && entry.path) signed.set(entry.path, entry.signedUrl);
      }
    }

    return json(
      req,
      {
        ...demo,
        steps: steps.map((step) => ({
          ...step,
          asset_url: step.asset_path ? signed.get(step.asset_path) ?? null : null,
        })),
      },
      200,
      // Safe to cache at the edge: the payload is identical for every viewer,
      // and the signed URLs outlive the cache window.
      { "Cache-Control": "public, max-age=60, s-maxage=300" },
    );
  }

  if (req.method === "POST") {
    const body = await readJson<ViewPing>(req);
    if (!body.public_id || !body.session_id) {
      throw new HttpError(400, "public_id and session_id are required");
    }

    const { error } = await supabase.rpc("track_demo_view", {
      p_public_id: body.public_id,
      p_session_id: body.session_id,
      p_steps_viewed: body.steps_viewed ?? 0,
      p_completed: body.completed ?? false,
      p_duration_ms: body.duration_ms ?? 0,
      p_referrer: body.referrer ?? req.headers.get("Referer"),
      // Supplied by the CDN in front of the function; never trusted from the body.
      p_country: req.headers.get("x-country") ?? body.country ?? null,
      p_device_type: body.device_type ?? null,
    });

    if (error) {
      console.error("track_demo_view failed", error);
      throw new HttpError(500, "Could not record view");
    }

    // 202: the ping is fire-and-forget from the player's point of view.
    return json(req, { recorded: true }, 202);
  }

  throw new HttpError(405, "Method not allowed");
});
