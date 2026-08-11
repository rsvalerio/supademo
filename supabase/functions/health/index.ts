/**
 * Liveness + readiness probe. Public (verify_jwt = false) so uptime monitors
 * can reach it, but it reveals nothing beyond "can I talk to Postgres".
 */

import { json, serveJson } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";

const STARTED_AT = new Date().toISOString();

serveJson(async (req) => {
  const started = performance.now();

  let database: "ok" | "unreachable" = "ok";
  try {
    // Cheapest possible round trip that still proves the connection works.
    const { error } = await adminClient().from("plans").select("id").limit(1);
    if (error) database = "unreachable";
  } catch {
    database = "unreachable";
  }

  return json(
    req,
    {
      status: database === "ok" ? "healthy" : "degraded",
      database,
      booted_at: STARTED_AT,
      checked_in_ms: Math.round(performance.now() - started),
    },
    database === "ok" ? 200 : 503,
  );
});
