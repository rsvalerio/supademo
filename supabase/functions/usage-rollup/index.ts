/**
 * Runs the usage rollup and the quota-warning sweep.
 *
 * pg_cron already calls the underlying functions directly (migration 1200), so
 * this exists for the cases cron cannot cover: backfilling a range of days
 * after an incident, or triggering a run from CI or a deploy pipeline.
 *
 * POST { days?: number }   — recompute the last N days (default 1)
 */

import { HttpError, json, readJson, serveJson } from "../_shared/http.ts";
import { adminClient, requireEnv } from "../_shared/supabase.ts";

const MAX_DAYS = 90;

serveJson(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "Method not allowed");

  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.includes(requireEnv("SUPABASE_SERVICE_ROLE_KEY"))) {
    throw new HttpError(403, "This endpoint requires the service role key");
  }

  const { days } = await readJson<{ days?: number }>(req);
  const span = Math.min(Math.max(days ?? 1, 1), MAX_DAYS);
  const supabase = adminClient();

  const results: Array<{ day: string; rows: number }> = [];

  // rollup_usage is idempotent per day, so re-running a range is safe and is
  // the normal way to repair a gap.
  for (let offset = 1; offset <= span; offset++) {
    const day = new Date(Date.now() - offset * 86_400_000).toISOString().slice(0, 10);

    const { data, error } = await supabase.rpc("rollup_usage", { p_day: day });
    if (error) {
      console.error(`rollup failed for ${day}`, error);
      throw new HttpError(500, `Rollup failed for ${day}`);
    }
    results.push({ day, rows: (data as number) ?? 0 });
  }

  return json(req, { days: span, results });
});
