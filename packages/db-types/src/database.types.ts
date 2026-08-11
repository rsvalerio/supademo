/**
 * PLACEHOLDER — replaced wholesale by `npm run gen:types`.
 *
 * It is committed so the workspace type-checks on a fresh clone, before anyone
 * has booted the database. The real file is several thousand lines of tables,
 * views, functions and enums derived from the live schema.
 */

export type Json = string | number | boolean | null | { [key: string]: Json | undefined } | Json[];

export interface Database {
  public: {
    Tables: Record<string, never>;
    Views: Record<string, never>;
    Functions: Record<string, never>;
    Enums: {
      org_role: "viewer" | "member" | "admin" | "owner";
      demo_status: "draft" | "published" | "archived";
      demo_visibility: "private" | "link" | "public";
      subscription_status:
        | "trialing"
        | "active"
        | "past_due"
        | "canceled"
        | "incomplete"
        | "paused";
      usage_metric:
        | "demo_view"
        | "demo_created"
        | "ai_embedding"
        | "storage_bytes"
        | "api_call"
        | "email_sent";
      notification_kind:
        | "comment"
        | "mention"
        | "invite"
        | "demo_published"
        | "quota_warning"
        | "billing"
        | "system";
      document_source: "demo" | "help_article" | "upload" | "note";
      embedding_status: "pending" | "processing" | "ready" | "failed";
    };
    CompositeTypes: Record<string, never>;
  };
}
