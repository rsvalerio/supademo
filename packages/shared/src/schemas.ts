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

/**
 * The fourteen declarable allergens of EU FIC 1169/2011 Annex II, which is what
 * `public.allergens` is seeded with. Kept as a closed list here too so a typo
 * is caught in the form rather than by the ingredient trigger — the database
 * remains the one that is true, this one just answers faster.
 */
export const ALLERGENS = [
  "celery",
  "cereals_containing_gluten",
  "crustaceans",
  "eggs",
  "fish",
  "lupin",
  "milk",
  "molluscs",
  "mustard",
  "nuts",
  "peanuts",
  "sesame",
  "soybeans",
  "sulphur_dioxide",
] as const;

export const allergenSchema = z.enum(ALLERGENS);

export const ingredientSchema = z.object({
  // The database constrains the sku only by `unique (organization_id, sku)`.
  // The length cap is this layer's own, so a form can refuse something absurd
  // before a round trip; it is not mirroring a CHECK.
  sku: z.string().trim().min(1, "A sku is required").max(60),
  /** ingredients_name_length (1800) */
  name: z.string().trim().min(1, "Name is required").max(160),
  /** public.unit_of_measure (1800): base units only, so nothing needs converting. */
  unit: z.enum(["g", "ml", "unit"]),
  allergens: z.array(allergenSchema).optional(),
  /** ingredients_reorder_level_positive (1800) */
  reorder_level: z.number().min(0).optional(),
});

export const productSchema = z.object({
  /** Same as above: unique per organization, with a cap of this layer's own. */
  sku: z.string().trim().min(1, "A sku is required").max(60),
  /** products_name_length (1800) */
  name: z.string().trim().min(1, "Name is required").max(200),
  description: z.string().max(5000).optional().nullable(),
  /** products_price_non_negative (1800): integer minor units, never floats. */
  price_cents: z.number().int().min(0, "A price cannot be negative"),
  /** products_currency_format (1800) */
  currency: z.string().regex(/^[a-z]{3}$/, "Use a three-letter code like eur").optional(),
  status: z.enum(["draft", "active", "discontinued"]).optional(),
  // `allergens` is absent on purpose: it is derived from the recipe, and a
  // member has no privilege to write it.
});

export const recipeLineSchema = z.object({
  ingredient_id: z.string().uuid(),
  /**
   * product_ingredients_quantity_positive (1800). In the ingredient's own unit
   * — there is no unit field here, because there is no unit to disagree about.
   */
  quantity: z.number().positive("Use a quantity greater than zero"),
});

export const stockMovementSchema = z
  .object({
    ingredient_id: z.string().uuid(),
    kind: z.enum(["receipt", "consumption", "waste", "adjustment", "release"]),
    /** inventory_movements_quantity_non_zero (1800) */
    quantity: z.number(),
    /** inventory_movements_cost_only_on_receipt (1800) */
    unit_cost_cents: z.number().int().min(0).optional().nullable(),
    note: z.string().max(500).optional().nullable(),
  })
  /** inventory_movements_sign_matches_kind (1800) */
  .refine(
    (m) =>
      m.kind === "adjustment" ||
      (["receipt", "release"].includes(m.kind) ? m.quantity > 0 : m.quantity < 0),
    { message: "Receipts are positive, consumption and waste are negative", path: ["quantity"] },
  )
  .refine((m) => m.unit_cost_cents == null || m.kind === "receipt", {
    message: "A unit cost only belongs on a receipt",
    path: ["unit_cost_cents"],
  });

export const customerSchema = z.object({
  /** customers_email_shape (1800) */
  email: z.string().email("Enter a valid email address"),
  full_name: z.string().max(200).optional().nullable(),
  phone: z.string().max(40).optional().nullable(),
  marketing_opt_in: z.boolean().optional(),
  notes: z.string().max(2000).optional().nullable(),
});

export const orderSchema = z.object({
  customer_id: z.string().uuid(),
  /** place_order (1800) refuses an empty order. */
  lines: z
    .array(
      z.object({
        sku: z.string().trim().min(1),
        /** order_items_quantity_positive (1800) */
        quantity: z.number().int().positive("Order at least one"),
      }),
    )
    .min(1, "An order needs at least one line"),
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
  scopes: z.array(z.string().min(1)).min(1).default(["products:read"]),
  expires_in_days: z.number().int().min(1).max(3650).optional(),
});

export const roleSchema = z.enum(ORG_ROLES);

export type OrganizationInput = z.infer<typeof organizationSchema>;
export type IngredientInput = z.infer<typeof ingredientSchema>;
export type ProductInput = z.infer<typeof productSchema>;
export type RecipeLineInput = z.infer<typeof recipeLineSchema>;
export type StockMovementInput = z.infer<typeof stockMovementSchema>;
export type CustomerInput = z.infer<typeof customerSchema>;
export type OrderInput = z.infer<typeof orderSchema>;
export type InviteInput = z.infer<typeof inviteSchema>;
export type WebhookEndpointInput = z.infer<typeof webhookEndpointSchema>;
export type ApiKeyInput = z.infer<typeof apiKeySchema>;
