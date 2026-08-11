/**
 * Drains a pgmq queue.
 *
 * Invoked every minute by pg_cron (see migration 1200) or by hand. Messages are
 * read with a visibility timeout rather than deleted up front: a crash mid-job
 * makes the message reappear instead of vanishing. That makes the queue
 * at-least-once, so handlers must be idempotent.
 *
 * Queue access goes through the public.queue_* RPCs rather than Supabase's
 * `pgmq_public` schema, so the only queue operations reachable over the API are
 * the three this worker needs — and they are service_role-only.
 *
 * Outbound webhooks are deliberately NOT here: they have their own durable
 * table and are sent from Postgres with pg_net (migrations 1100/1200).
 *
 * POST { queue: "embeddings" | "emails", batch_size?: number }
 */

import { HttpError, json, readJson, serveJson } from "../_shared/http.ts";
import { adminClient, requireEnv } from "../_shared/supabase.ts";

const VISIBILITY_TIMEOUT_SECONDS = 120;
const MAX_BATCH = 50;
/** A message that keeps failing must stop consuming every batch. */
const MAX_ATTEMPTS = 5;

const QUEUES = ["embeddings", "emails"] as const;
type QueueName = (typeof QUEUES)[number];

interface Body {
  queue?: string;
  batch_size?: number;
}

interface QueueMessage {
  msg_id: number;
  read_ct: number;
  enqueued_at: string;
  message: Record<string, unknown>;
}

serveJson(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "Method not allowed");

  // verify_jwt is on for this function, so only a valid Supabase token reaches
  // here — but "any signed-in user" is not "the platform". The RPCs below are
  // service_role-only and would refuse anyone else; this check just turns that
  // into a clear 403 instead of a confusing 500.
  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.includes(requireEnv("SUPABASE_SERVICE_ROLE_KEY"))) {
    throw new HttpError(403, "This endpoint requires the service role key");
  }

  const body = await readJson<Body>(req);
  const queue = body.queue as QueueName;
  if (!QUEUES.includes(queue)) {
    throw new HttpError(400, `queue must be one of: ${QUEUES.join(", ")}`);
  }

  const batchSize = Math.min(Math.max(body.batch_size ?? 10, 1), MAX_BATCH);
  const supabase = adminClient();

  const { data, error } = await supabase.rpc("queue_read", {
    p_queue: queue,
    p_count: batchSize,
    p_visibility_seconds: VISIBILITY_TIMEOUT_SECONDS,
  });

  if (error) {
    console.error("could not read from queue", error);
    throw new HttpError(500, `Could not read queue "${queue}"`);
  }

  const messages = (data ?? []) as QueueMessage[];
  let processed = 0;
  let failed = 0;
  let abandoned = 0;

  for (const msg of messages) {
    try {
      if (msg.read_ct > MAX_ATTEMPTS) {
        // Archive rather than delete: a poison message is evidence of a bug,
        // and destroying it destroys the only record of what went wrong.
        await supabase.rpc("queue_archive", { p_queue: queue, p_msg_id: msg.msg_id });
        abandoned += 1;
        console.warn(`archived poison message ${msg.msg_id} after ${msg.read_ct} attempts`);
        continue;
      }

      if (queue === "embeddings") {
        await handleEmbedding(msg.message);
      } else {
        await handleEmail(msg.message);
      }

      await supabase.rpc("queue_delete", { p_queue: queue, p_msg_id: msg.msg_id });
      processed += 1;
    } catch (err) {
      // Leave the message where it is: its visibility timeout lapses and it
      // comes back for another attempt.
      failed += 1;
      console.error(`message ${msg.msg_id} failed`, err);
    }
  }

  return json(req, { queue, read: messages.length, processed, failed, abandoned });
});

/** Re-invokes the embedding function for one document. */
async function handleEmbedding(message: Record<string, unknown>): Promise<void> {
  const documentId = message.document_id;
  if (typeof documentId !== "string") throw new Error("message has no document_id");

  const response = await fetch(`${requireEnv("SUPABASE_URL")}/functions/v1/embed-document`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${requireEnv("SUPABASE_SERVICE_ROLE_KEY")}`,
    },
    body: JSON.stringify({ document_id: documentId, internal: true }),
  });

  if (!response.ok) {
    throw new Error(`embed-document returned ${response.status}: ${await response.text()}`);
  }
}

/** Sends one transactional email through the configured provider. */
async function handleEmail(message: Record<string, unknown>): Promise<void> {
  const { to, subject, html } = message as { to?: string; subject?: string; html?: string };
  if (!to || !subject) throw new Error("message is missing `to` or `subject`");

  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) {
    // Local development: log it rather than pretending it was sent.
    console.info(`[email] would send "${subject}" to ${to}`);
    return;
  }

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
    body: JSON.stringify({
      from: Deno.env.get("EMAIL_FROM") ?? "Supademo <onboarding@resend.dev>",
      to: [to],
      subject,
      html: html ?? "",
    }),
  });

  if (!response.ok) {
    throw new Error(`email provider returned ${response.status}: ${await response.text()}`);
  }
}
