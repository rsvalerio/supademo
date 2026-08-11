/**
 * Creates a Stripe Checkout session (to upgrade) or a Billing Portal session
 * (to manage an existing subscription).
 *
 * The caller supplies an organization id; this function verifies with the
 * caller's own credentials that they are an admin of it, and only then switches
 * to the service key to write billing identifiers. The pattern matters: the
 * authorization decision is made by RLS against the user's token, not by a
 * conditional in application code.
 *
 * POST { organization_id, mode: "checkout" | "portal", plan_id? }
 */

import Stripe from "stripe";
import { HttpError, json, readJson, serveJson } from "../_shared/http.ts";
import { adminClient, requireEnv, requireUser } from "../_shared/supabase.ts";

interface Body {
  organization_id?: string;
  mode?: "checkout" | "portal";
  plan_id?: string;
}

serveJson(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "Method not allowed");

  const body = await readJson<Body>(req);
  if (!body.organization_id) throw new HttpError(400, "organization_id is required");

  const { client, user } = await requireUser(req);

  // RLS decides. `has_org_role` is the same helper the policies use, so this
  // cannot drift from the rules enforced everywhere else.
  const { data: isAdmin, error: roleError } = await client.rpc("has_org_role", {
    p_organization_id: body.organization_id,
    p_min_role: "admin",
  });

  if (roleError) {
    console.error("role check failed", roleError);
    throw new HttpError(500, "Could not verify permissions");
  }
  if (!isAdmin) throw new HttpError(403, "Only admins and owners can manage billing");

  const admin = adminClient();
  const stripe = new Stripe(requireEnv("STRIPE_SECRET_KEY"), { apiVersion: "2025-08-27.basil" });
  const appUrl = Deno.env.get("APP_BASE_URL") ?? "http://localhost:3000";

  const { data: subscription } = await admin
    .from("subscriptions")
    .select("stripe_customer_id, plan_id")
    .eq("organization_id", body.organization_id)
    .maybeSingle();

  let customerId = subscription?.stripe_customer_id ?? null;

  if (!customerId) {
    const { data: organization } = await admin
      .from("organizations")
      .select("name, billing_email")
      .eq("id", body.organization_id)
      .maybeSingle();

    const customer = await stripe.customers.create({
      name: organization?.name ?? undefined,
      email: organization?.billing_email ?? user.email ?? undefined,
      // The link back to our tenant, so webhook events can be attributed even
      // if they arrive before anything else has been written.
      metadata: { organization_id: body.organization_id },
    });

    customerId = customer.id;
    await admin
      .from("subscriptions")
      .update({ stripe_customer_id: customerId })
      .eq("organization_id", body.organization_id);
  }

  if (body.mode === "portal") {
    const portal = await stripe.billingPortal.sessions.create({
      customer: customerId,
      return_url: `${appUrl}/settings/billing`,
    });
    return json(req, { url: portal.url });
  }

  if (!body.plan_id) throw new HttpError(400, "plan_id is required for checkout");

  const { data: plan } = await admin
    .from("plans")
    .select("id, stripe_price_id")
    .eq("id", body.plan_id)
    .maybeSingle();

  if (!plan?.stripe_price_id) {
    throw new HttpError(400, `Plan "${body.plan_id}" has no Stripe price configured`);
  }

  const session = await stripe.checkout.sessions.create({
    mode: "subscription",
    customer: customerId,
    line_items: [{ price: plan.stripe_price_id, quantity: 1 }],
    success_url: `${appUrl}/settings/billing?checkout=success`,
    cancel_url: `${appUrl}/settings/billing?checkout=cancelled`,
    // Read back by the webhook. Metadata is the only channel that survives the
    // round trip through Stripe.
    metadata: { organization_id: body.organization_id },
    subscription_data: { metadata: { organization_id: body.organization_id } },
  });

  return json(req, { url: session.url });
});
