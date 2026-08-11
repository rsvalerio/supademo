/**
 * Validation schemas that mirror the CHECK constraints in the database.
 *
 * Validating twice is not redundancy for its own sake: the database's copy is
 * the one that is *true*, and this one exists so a user learns their title is
 * too long before a round trip, with a message written for a human. Whenever a
 * constraint changes in a migration, change it here too — the reference is
 * noted on each field.
 */

import { z } from "zod";
import { ORG_ROLES } from "./permissions.ts";

/** organizations_slug_format (0300) */
export const slugSchema = z
  .string()
  .min(3, "Must be at least 3 characters")
  .max(40, "Must be 40 characters or fewer")
  .regex(/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])$/, "Use lowercase letters, numbers and hyphens");

export const organizationSchema = z.object({
  /** organizations_name_length (0300) */
  name: z.string().trim().min(1, "Name is required").max(120),
  slug: slugSchema.optional(),
  website: z.string().url().optional().nullable(),
  billing_email: z.string().email().optional().nullable(),
});

export const inviteSchema = z.object({
  email: z.string().email("Enter a valid email address"),
  /** organization_invites_role_not_owner (0300): ownership is transferred, not invited. */
  role: z.enum(["viewer", "member", "admin"]),
});

export const projectSchema = z.object({
  /** projects_name_length (0500) */
  name: z.string().trim().min(1, "Name is required").max(120),
  description: z.string().max(2000).optional().nullable(),
  /** projects_color_format (0500) */
  color: z.string().regex(/^#[0-9a-fA-F]{6}$/, "Use a hex colour like #3ecf8e").optional(),
});

export const demoSchema = z.object({
  /** demos_title_length (0500) */
  title: z.string().trim().min(1, "Title is required").max(200),
  description: z.string().max(5000).optional().nullable(),
  project_id: z.string().uuid(),
  status: z.enum(["draft", "published", "archived"]).optional(),
  visibility: z.enum(["private", "link", "public"]).optional(),
  tags: z.array(z.string().min(1).max(40)).max(20).optional(),
});

export const demoStepSchema = z.object({
  /** demo_steps_position_positive (0500) */
  position: z.number().int().min(0),
  title: z.string().max(200).optional().nullable(),
  body: z.string().max(5000).optional().nullable(),
  asset_path: z.string().optional().nullable(),
  hotspot: z
    .object({
      x: z.number().min(0).max(1),
      y: z.number().min(0).max(1),
      shape: z.enum(["circle", "rect"]).optional(),
    })
    .partial()
    .optional(),
  duration_ms: z.number().int().min(0).max(600_000).optional().nullable(),
});

export const commentSchema = z.object({
  /** demo_comments_body_length (0500) */
  body: z.string().trim().min(1, "Say something").max(5000),
  step_id: z.string().uuid().optional().nullable(),
});

export const leadCaptureSchema = z.object({
  email: z.string().email(),
  name: z.string().max(120).optional(),
  fields: z.record(z.unknown()).optional(),
});

export const webhookEndpointSchema = z.object({
  /** webhook_endpoints_url_https (1100): plaintext delivery of signed payloads is not offered. */
  url: z.string().url().startsWith("https://", "Endpoints must use HTTPS"),
  description: z.string().max(500).optional().nullable(),
  /** webhook_endpoints_events_not_empty (1100) */
  events: z.array(z.string().min(1)).min(1, "Subscribe to at least one event"),
});

export const apiKeySchema = z.object({
  /** api_keys_name_length (1400) */
  name: z.string().trim().min(1).max(80),
  /** api_keys_scopes_not_empty (1400) */
  scopes: z.array(z.string().min(1)).min(1).default(["demos:read"]),
  expires_in_days: z.number().int().min(1).max(3650).optional(),
});

export const roleSchema = z.enum(ORG_ROLES);

export type OrganizationInput = z.infer<typeof organizationSchema>;
export type ProjectInput = z.infer<typeof projectSchema>;
export type DemoInput = z.infer<typeof demoSchema>;
export type DemoStepInput = z.infer<typeof demoStepSchema>;
export type InviteInput = z.infer<typeof inviteSchema>;
export type WebhookEndpointInput = z.infer<typeof webhookEndpointSchema>;
export type ApiKeyInput = z.infer<typeof apiKeySchema>;
