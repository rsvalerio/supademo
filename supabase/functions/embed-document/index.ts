/**
 * Chunks a document and embeds each chunk.
 *
 * Inference runs inside the Edge Runtime via `Supabase.ai` — the `gte-small`
 * model ships with the runtime, so there is no external API, no key to rotate
 * and no per-token bill. It produces 384-dimensional vectors, which is why
 * public.document_sections.embedding is vector(384).
 *
 * POST { document_id }            — as a signed-in user (RLS applies)
 * POST { document_id, internal }  — as service_role, from the queue worker
 */

import { HttpError, json, readJson, serveJson } from "../_shared/http.ts";
import { adminClient, userClient } from "../_shared/supabase.ts";

// Roughly one paragraph per chunk, with overlap so a sentence spanning a
// boundary is still retrievable from both sides.
const MAX_CHUNK_CHARS = 1200;
const CHUNK_OVERLAP_CHARS = 150;

declare const Supabase: {
  ai: {
    Session: new (
      model: string,
    ) => { run(input: string, opts: Record<string, unknown>): Promise<number[]> };
  };
};

interface Body {
  document_id?: string;
  internal?: boolean;
}

/** Splits on paragraph boundaries first, falling back to hard slicing. */
export function chunk(text: string): string[] {
  const paragraphs = text.split(/\n{2,}/).map((p) => p.trim()).filter(Boolean);
  const chunks: string[] = [];
  let current = "";

  for (const paragraph of paragraphs) {
    if (current.length + paragraph.length + 2 <= MAX_CHUNK_CHARS) {
      current = current ? `${current}\n\n${paragraph}` : paragraph;
      continue;
    }

    if (current) chunks.push(current);

    if (paragraph.length <= MAX_CHUNK_CHARS) {
      current = paragraph;
      continue;
    }

    // A single oversized paragraph: slice it with overlap.
    for (let i = 0; i < paragraph.length; i += MAX_CHUNK_CHARS - CHUNK_OVERLAP_CHARS) {
      chunks.push(paragraph.slice(i, i + MAX_CHUNK_CHARS));
    }
    current = "";
  }

  if (current) chunks.push(current);
  return chunks;
}

serveJson(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "Method not allowed");

  const body = await readJson<Body>(req);
  if (!body.document_id) throw new HttpError(400, "document_id is required");

  // Internal calls come from the queue worker and are already authorized;
  // everything else goes through the caller's own permissions.
  const supabase = body.internal ? adminClient() : userClient(req);

  const { data: document, error: docError } = await supabase
    .from("documents")
    .select("id, organization_id, title, content")
    .eq("id", body.document_id)
    .maybeSingle();

  if (docError) {
    console.error("document lookup failed", docError);
    throw new HttpError(500, "Could not load document");
  }
  if (!document) throw new HttpError(404, "Document not found");

  const chunks = chunk(document.content ?? "");
  if (chunks.length === 0) {
    return json(req, { document_id: document.id, sections: 0, note: "document is empty" });
  }

  // Replace the chunk set first, so a failure part-way through embedding leaves
  // rows in 'pending' rather than leaving stale vectors behind.
  const { error: replaceError } = await supabase.rpc("replace_document_sections", {
    p_document_id: document.id,
    p_sections: chunks,
  });
  if (replaceError) {
    console.error("replace_document_sections failed", replaceError);
    throw new HttpError(500, "Could not store document sections");
  }

  const { data: sections, error: sectionError } = await supabase
    .from("document_sections")
    .select("id, content")
    .eq("document_id", document.id)
    .order("position");

  if (sectionError || !sections) {
    console.error("section lookup failed", sectionError);
    throw new HttpError(500, "Could not load document sections");
  }

  const model = new Supabase.ai.Session("gte-small");
  let embedded = 0;
  let failed = 0;

  for (const section of sections) {
    try {
      const embedding = await model.run(section.content, {
        mean_pool: true,
        // Normalized vectors make cosine distance and inner product agree.
        normalize: true,
      });

      const { error } = await supabase
        .from("document_sections")
        .update({ embedding: JSON.stringify(embedding), status: "ready", error: null })
        .eq("id", section.id);

      if (error) throw error;
      embedded += 1;
    } catch (err) {
      failed += 1;
      console.error(`embedding failed for section ${section.id}`, err);
      await supabase
        .from("document_sections")
        .update({ status: "failed", error: String(err).slice(0, 500) })
        .eq("id", section.id);
    }
  }

  // Metering is the server's business, so it always goes through the admin
  // client regardless of who asked for the embedding.
  if (embedded > 0) {
    await adminClient().from("usage_events").insert({
      organization_id: document.organization_id,
      metric: "ai_embedding",
      quantity: embedded,
      subject_type: "document",
      subject_id: document.id,
    });
  }

  return json(req, { document_id: document.id, sections: sections.length, embedded, failed });
});
