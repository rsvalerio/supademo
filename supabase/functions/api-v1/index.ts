/**
 * The machine-facing API. Authenticated by API key, never by user session.
 *
 *   GET   /api-v1/whoami                          products:read
 *
 *   GET   /api-v1/products                        products:read
 *   GET   /api-v1/products/:sku                   products:read
 *   PUT   /api-v1/products/:sku                   products:write
 *   PUT   /api-v1/products/:sku/recipe            products:write
 *   PUT   /api-v1/ingredients/:sku                products:write
 *
 *   GET   /api-v1/stock                           inventory:read
 *   POST  /api-v1/stock/:sku/movements            inventory:write
 *
 *   PUT   /api-v1/customers                       customers:write
 *
 *   GET   /api-v1/orders                          orders:read
 *   GET   /api-v1/orders/:order_number            orders:read
 *   POST  /api-v1/orders                          orders:write
 *   POST  /api-v1/orders/:order_number/cancel     orders:write
 *   GET   /api-v1/recalls/:allergen               orders:read
 *
 *   PUT   /api-v1/documents/:source_id            documents:write
 *
 * Nothing is addressed by uuid. A sku, an order number and an email are handles
 * the caller already has, and a handle that is only unique within one
 * organization cannot be used to probe across one.
 *
 * Writes accept an `Idempotency-Key` header; a retry replays the first
 * response rather than doing the work twice.
 *
 * `verify_jwt = false`, because the caller has no Supabase JWT — the API key
 * *is* the credential, and it is checked on every route below.
 *
 * This function runs as service_role, which bypasses RLS. That is why it never
 * queries a table directly: every read goes through a `public.api_*` function
 * that takes the organization id the key resolved to and filters by it. The
 * tenant boundary is inside the database, not in this file.
 */

import { HttpError, json, serveJson } from "../_shared/http.ts";
import { adminClient } from "../_shared/supabase.ts";
import {
  type ApiIdentity,
  apiJson,
  type ApiScope,
  requireApiIdentity,
} from "../_shared/api-auth.ts";
import { remember, replay } from "../_shared/idempotency.ts";

/** Strips the function prefix so routing works locally and when deployed. */
function pathSegments(url: URL): string[] {
  return url.pathname
    .replace(/^\/functions\/v1/, "")
    .replace(/^\/api-v1/, "")
    .split("/")
    .filter(Boolean);
}

/**
 * Postgres error codes carry the intent already; translating them once here
 * beats a try/catch around every call. `check_violation` covers both quota
 * exhaustion and validation, so its message is what distinguishes them — which
 * is why those RAISEs are worded for a caller to read.
 */
function statusForPgError(code: string | undefined, message: string): number {
  switch (code) {
    case "no_data_found":
    case "P0002":
      return 404;
    case "23514":
      return /plan limit reached/.test(message) ? 402 : 422;
    case "23505":
      return 409;
    case "53000":
      // insufficient_resources: raised when an order asks for more stock than
      // the ledger holds. A conflict with the world's state, not a bad request.
      return 409;
    case "42501":
      return 403;
    default:
      return 500;
  }
}

async function callRpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await adminClient().rpc(fn, args);
  if (error) {
    const status = statusForPgError(error.code, error.message ?? "");
    if (status === 500) {
      console.error(`${fn} failed`, error);
      throw new HttpError(500, "Query failed");
    }
    throw new HttpError(status, error.message ?? "Request rejected", error.code);
  }
  return data as T;
}

/** Parses a JSON body, tolerating an empty one. */
function parseBody(raw: string): Record<string, unknown> {
  if (!raw.trim()) return {};
  try {
    return JSON.parse(raw) as Record<string, unknown>;
  } catch {
    throw new HttpError(400, "Request body must be valid JSON");
  }
}

/**
 * Runs a write with replay protection: if this exact request has been seen
 * before under the same Idempotency-Key, the stored response comes back and the
 * work is not repeated.
 */
async function writeOnce(
  req: Request,
  identity: ApiIdentity,
  rawBody: string,
  status: number,
  work: () => Promise<unknown>,
): Promise<Response> {
  const replayed = await replay(req, identity, rawBody);
  if (replayed) {
    return apiJson(req, identity, replayed.body, replayed.statusCode);
  }

  const body = await work();
  await remember(req, identity, rawBody, body, status);
  return apiJson(req, identity, body, status);
}

serveJson(async (req) => {
  const url = new URL(req.url);
  const segments = pathSegments(url);
  const rawBody = req.method === "GET" ? "" : await req.text();

  // Authenticate once, with the scope the route requires. Doing it per-route
  // rather than up front means the scope is stated next to the thing it
  // protects, and a new route cannot inherit someone else's permission.
  const authenticate = (scope: ApiScope): Promise<ApiIdentity> => requireApiIdentity(req, scope);

  // GET /whoami — what this key is, useful for verifying a deploy's config.
  if (segments[0] === "whoami") {
    if (req.method !== "GET") throw new HttpError(405, "Method not allowed");
    const identity = await authenticate("products:read");
    return apiJson(req, identity, {
      organization_id: identity.organizationId,
      key_id: identity.keyId,
      scopes: identity.scopes,
      rate_limit: identity.rateLimit,
    });
  }

  // --- Products -------------------------------------------------------------

  if (segments[0] === "products") {
    // GET /products?status=active&limit=25&before=<iso>
    if (segments.length === 1 && req.method === "GET") {
      const identity = await authenticate("products:read");
      const limit = Number(url.searchParams.get("limit") ?? 25);

      const products = await callRpc("api_list_products", {
        p_organization_id: identity.organizationId,
        p_status: url.searchParams.get("status"),
        p_limit: Number.isFinite(limit) ? limit : 25,
        p_before: url.searchParams.get("before"),
      });
      return apiJson(req, identity, { products });
    }

    const sku = segments[1];

    // GET /products/:sku
    if (segments.length === 2 && req.method === "GET") {
      const identity = await authenticate("products:read");
      const product = await callRpc<unknown>("api_get_product", {
        p_organization_id: identity.organizationId,
        p_sku: sku,
      });
      // A sku that belongs to another organization is indistinguishable from
      // one that does not exist, which is the whole point.
      if (!product) throw new HttpError(404, "Product not found");
      return apiJson(req, identity, product);
    }

    // PUT /products/:sku — upsert, so a sync job converges instead of
    // accumulating duplicates or failing on its second run.
    if (segments.length === 2 && req.method === "PUT") {
      const identity = await authenticate("products:write");
      const body = parseBody(rawBody);
      if (!body.name) throw new HttpError(400, "`name` is required");
      if (body.price_cents === undefined) {
        throw new HttpError(400, "`price_cents` is required");
      }
      if (body.allergens !== undefined) {
        throw new HttpError(
          422,
          "`allergens` is derived from the recipe and cannot be set; " +
            "change the ingredients instead",
        );
      }

      return await writeOnce(req, identity, rawBody, 200, () =>
        callRpc("api_upsert_product", {
          p_organization_id: identity.organizationId,
          p_sku: sku,
          p_name: String(body.name),
          p_price_cents: Number(body.price_cents),
          p_description: body.description ?? null,
          p_currency: body.currency ?? "eur",
          p_status: body.status ?? "draft",
        }));
    }

    // PUT /products/:sku/recipe — the whole recipe, not a patch. A partial
    // recipe would mean a product briefly declaring fewer allergens than it
    // contains, so there is no route that can produce one.
    if (segments.length === 3 && segments[2] === "recipe" && req.method === "PUT") {
      const identity = await authenticate("products:write");
      const body = parseBody(rawBody);
      if (!Array.isArray(body.lines)) {
        throw new HttpError(400, "`lines` must be an array of {ingredient_sku, quantity}");
      }

      return await writeOnce(req, identity, rawBody, 200, () =>
        callRpc("api_set_recipe", {
          p_organization_id: identity.organizationId,
          p_sku: sku,
          p_lines: body.lines,
        }));
    }
  }

  // --- Ingredients ----------------------------------------------------------

  // PUT /ingredients/:sku
  if (segments[0] === "ingredients" && segments.length === 2 && req.method === "PUT") {
    const identity = await authenticate("products:write");
    const body = parseBody(rawBody);
    if (!body.name) throw new HttpError(400, "`name` is required");
    if (!body.unit) throw new HttpError(400, "`unit` is required: g, ml or unit");

    return await writeOnce(req, identity, rawBody, 200, () =>
      callRpc("api_upsert_ingredient", {
        p_organization_id: identity.organizationId,
        p_sku: segments[1],
        p_name: String(body.name),
        p_unit: String(body.unit),
        p_allergens: body.allergens ?? [],
        p_reorder_level: body.reorder_level ?? 0,
      }));
  }

  // --- Stock ----------------------------------------------------------------

  if (segments[0] === "stock") {
    // GET /stock?below_reorder_level=true
    if (segments.length === 1 && req.method === "GET") {
      const identity = await authenticate("inventory:read");
      const levels = await callRpc("api_stock_levels", {
        p_organization_id: identity.organizationId,
        p_below_reorder_level: url.searchParams.get("below_reorder_level") === "true",
      });
      return apiJson(req, identity, { stock: levels });
    }

    // POST /stock/:sku/movements — receipts, waste and adjustments only.
    // Consumption and release belong to the order functions, and an endpoint
    // that could forge one would decouple the ledger from the orders it
    // explains.
    if (segments.length === 3 && segments[2] === "movements" && req.method === "POST") {
      const identity = await authenticate("inventory:write");
      const body = parseBody(rawBody);
      if (!body.kind) throw new HttpError(400, "`kind` is required: receipt, waste or adjustment");
      if (body.quantity === undefined) throw new HttpError(400, "`quantity` is required");

      return await writeOnce(req, identity, rawBody, 201, () =>
        callRpc("api_record_movement", {
          p_organization_id: identity.organizationId,
          p_sku: segments[1],
          p_kind: String(body.kind),
          p_quantity: Number(body.quantity),
          p_unit_cost_cents: body.unit_cost_cents ?? null,
          p_note: body.note ?? null,
        }));
    }
  }

  // --- Customers ------------------------------------------------------------

  // PUT /customers — the email is in the body rather than the path, because a
  // path segment carrying an address is a trail of percent-encoding bugs.
  if (segments[0] === "customers" && segments.length === 1 && req.method === "PUT") {
    const identity = await authenticate("customers:write");
    const body = parseBody(rawBody);
    if (!body.email) throw new HttpError(400, "`email` is required");

    return await writeOnce(req, identity, rawBody, 200, () =>
      callRpc("api_upsert_customer", {
        p_organization_id: identity.organizationId,
        p_email: String(body.email),
        p_full_name: body.full_name ?? null,
        p_phone: body.phone ?? null,
        p_marketing_opt_in: body.marketing_opt_in ?? false,
      }));
  }

  // --- Orders ---------------------------------------------------------------

  if (segments[0] === "orders") {
    // GET /orders?status=confirmed
    if (segments.length === 1 && req.method === "GET") {
      const identity = await authenticate("orders:read");
      const limit = Number(url.searchParams.get("limit") ?? 25);

      const orders = await callRpc("api_list_orders", {
        p_organization_id: identity.organizationId,
        p_status: url.searchParams.get("status"),
        p_limit: Number.isFinite(limit) ? limit : 25,
        p_before: url.searchParams.get("before"),
      });
      return apiJson(req, identity, { orders });
    }

    // POST /orders — one call places the whole order. The lock ordering, the
    // stock check and the price snapshot are inside place_order(), so there is
    // no sequence here for a caller to get wrong or an endpoint to skip.
    // Retrying with the same Idempotency-Key replays rather than selling twice.
    if (segments.length === 1 && req.method === "POST") {
      const identity = await authenticate("orders:write");
      const body = parseBody(rawBody);
      if (!body.customer_email) throw new HttpError(400, "`customer_email` is required");
      if (!Array.isArray(body.lines) || body.lines.length === 0) {
        throw new HttpError(400, "`lines` must be a non-empty array of {sku, quantity}");
      }

      return await writeOnce(req, identity, rawBody, 201, () =>
        callRpc("api_place_order", {
          p_organization_id: identity.organizationId,
          p_customer_email: String(body.customer_email),
          p_lines: body.lines,
        }));
    }

    const orderNumber = segments[1];

    // GET /orders/:order_number
    if (segments.length === 2 && req.method === "GET") {
      const identity = await authenticate("orders:read");
      const order = await callRpc<unknown>("api_get_order", {
        p_organization_id: identity.organizationId,
        p_order_number: orderNumber,
      });
      if (!order) throw new HttpError(404, "Order not found");
      return apiJson(req, identity, order);
    }

    // POST /orders/:order_number/cancel — returns stock as a `release`
    // movement. A fulfilled order is refunded, not cancelled, and the database
    // says so with a 422.
    if (segments.length === 3 && segments[2] === "cancel" && req.method === "POST") {
      const identity = await authenticate("orders:write");
      const body = parseBody(rawBody);

      return await writeOnce(req, identity, rawBody, 200, () =>
        callRpc("api_cancel_order", {
          p_organization_id: identity.organizationId,
          p_order_number: orderNumber,
          p_reason: body.reason ?? null,
        }));
    }
  }

  // --- Recalls --------------------------------------------------------------

  // GET /recalls/:allergen — orders placed under a label that omitted an
  // allergen the product is now known to contain. The answer is a list of
  // people to contact, which is why it is on the machine surface.
  if (segments[0] === "recalls" && segments.length === 2 && req.method === "GET") {
    const identity = await authenticate("orders:read");
    const report = await callRpc("api_recall_report", {
      p_organization_id: identity.organizationId,
      p_allergen: segments[1],
      p_since: url.searchParams.get("since"),
    });
    return apiJson(req, identity, report);
  }

  // --- Knowledge base -------------------------------------------------------

  // PUT /documents/:source_id — upsert, so a customer's sync job can re-run.
  if (segments[0] === "documents" && segments.length === 2 && req.method === "PUT") {
    const identity = await authenticate("documents:write");
    const body = parseBody(rawBody);
    if (!body.title) throw new HttpError(400, "`title` is required");

    return await writeOnce(req, identity, rawBody, 200, () =>
      callRpc("api_upsert_document", {
        p_organization_id: identity.organizationId,
        p_source_id: segments[1],
        p_title: String(body.title),
        p_content: body.content ?? "",
      }));
  }

  return json(req, {
    error: "Not found",
    routes: [
      "GET   /api-v1/whoami",
      "GET   /api-v1/products",
      "GET   /api-v1/products/:sku",
      "PUT   /api-v1/products/:sku",
      "PUT   /api-v1/products/:sku/recipe",
      "PUT   /api-v1/ingredients/:sku",
      "GET   /api-v1/stock",
      "POST  /api-v1/stock/:sku/movements",
      "PUT   /api-v1/customers",
      "GET   /api-v1/orders",
      "POST  /api-v1/orders",
      "GET   /api-v1/orders/:order_number",
      "POST  /api-v1/orders/:order_number/cancel",
      "GET   /api-v1/recalls/:allergen",
      "PUT   /api-v1/documents/:source_id",
    ],
  }, 404);
});
