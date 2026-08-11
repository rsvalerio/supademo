/**
 * Billing webhook receiver.
 *
 * Three properties this endpoint must have, all of which are easy to omit:
 *
 *  1. The signature is verified before the body is parsed. `verify_jwt = false`
 *     means anyone can POST here; the HMAC is the only thing separating Stripe
 *     from an attacker who knows the URL.
 *  2. Handling is idempotent. Stripe retries, and retries arrive out of order.
 *  3. The reply is fast. Work that could be slow is acknowledged first and
 *     finished in a background task.
 *
 * The subscription row is written with the service key: it is server state and
 * has no client write path (see migration 0400).
 */

import Stripe from "stripe";
import { HttpError, json, serveJson } from "../_shared/http.ts";
import { adminClient, requireEnv } from "../_shared/supabase.ts";

// EdgeRuntime.waitUntil keeps the isolate alive for work that outlives the
// response. Declared here because it is a runtime global, not an import.
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

const RELEVANT_EVENTS = new Set([
  "checkout.session.completed",
  "customer.subscription.created",
  "customer.subscription.updated",
  "customer.subscription.deleted",
  "invoice.payment_failed",
  "invoice.payment_succeeded",
]);

const STATUS_MAP: Record<string, string> = {
  trialing: "trialing",
  active: "active",
  past_due: "past_due",
  canceled: "canceled",
  unpaid: "past_due",
  incomplete: "incomplete",
  incomplete_expired: "canceled",
  paused: "paused",
};

serveJson(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "Method not allowed");

  const signature = req.headers.get("stripe-signature");
  if (!signature) throw new HttpError(400, "Missing stripe-signature header");

  const stripe = new Stripe(requireEnv("STRIPE_SECRET_KEY"), { apiVersion: "2025-08-27.basil" });
  const payload = await req.text();

  let event: Stripe.Event;
  try {
    // Async variant: the sync one needs a Node crypto shim that Deno lacks.
    event = await stripe.webhooks.constructEventAsync(
      payload,
      signature,
      requireEnv("STRIPE_WEBHOOK_SECRET"),
    );
  } catch (err) {
    console.error("signature verification failed", err);
    throw new HttpError(400, "Invalid signature");
  }

  if (!RELEVANT_EVENTS.has(event.type)) {
    return json(req, { received: true, ignored: event.type });
  }

  const work = handleEvent(stripe, event).catch((err) => {
    // Swallowed on purpose: Stripe has already been told we received it, and
    // an unhandled rejection would take down the isolate.
    console.error(`failed to handle ${event.type} (${event.id})`, err);
  });

  if (typeof EdgeRuntime !== "undefined") {
    EdgeRuntime.waitUntil(work);
  } else {
    await work;
  }

  return json(req, { received: true, type: event.type });
});

async function handleEvent(stripe: Stripe, event: Stripe.Event): Promise<void> {
  const supabase = adminClient();

  switch (event.type) {
    case "checkout.session.completed": {
      const session = event.data.object as Stripe.Checkout.Session;
      // The organization is carried in metadata set when the session was
      // created — never inferred from anything the caller controls.
      const organizationId = session.metadata?.organization_id;
      if (!organizationId || !session.subscription) return;

      const subscription = await stripe.subscriptions.retrieve(String(session.subscription));
      await syncSubscription(supabase, organizationId, subscription);
      return;
    }

    case "customer.subscription.created":
    case "customer.subscription.updated":
    case "customer.subscription.deleted": {
      const subscription = event.data.object as Stripe.Subscription;
      const organizationId = subscription.metadata?.organization_id ??
        (await organizationForCustomer(supabase, String(subscription.customer)));
      if (!organizationId) {
        console.warn(`no organization for subscription ${subscription.id}`);
        return;
      }
      await syncSubscription(supabase, organizationId, subscription);
      return;
    }

    case "invoice.payment_failed":
    case "invoice.payment_succeeded": {
      const invoice = event.data.object as Stripe.Invoice;
      const organizationId = await organizationForCustomer(supabase, String(invoice.customer));
      if (!organizationId) return;

      const failed = event.type === "invoice.payment_failed";
      await supabase
        .from("subscriptions")
        .update({ status: failed ? "past_due" : "active" })
        .eq("organization_id", organizationId);
      return;
    }
  }
}

async function organizationForCustomer(
  supabase: ReturnType<typeof adminClient>,
  customerId: string,
): Promise<string | null> {
  const { data } = await supabase
    .from("subscriptions")
    .select("organization_id")
    .eq("stripe_customer_id", customerId)
    .maybeSingle();

  return data?.organization_id ?? null;
}

async function syncSubscription(
  supabase: ReturnType<typeof adminClient>,
  organizationId: string,
  subscription: Stripe.Subscription,
): Promise<void> {
  const priceId = subscription.items.data[0]?.price.id ?? null;

  // Map Stripe's price back to a local plan. Falls back to `free` so a price
  // that has not been wired up degrades to the safe tier instead of granting
  // whatever was there before.
  const { data: plan } = await supabase
    .from("plans")
    .select("id")
    .eq("stripe_price_id", priceId)
    .maybeSingle();

  const item = subscription.items.data[0];

  const { error } = await supabase
    .from("subscriptions")
    .update({
      plan_id: subscription.status === "canceled" ? "free" : plan?.id ?? "free",
      status: STATUS_MAP[subscription.status] ?? "incomplete",
      seats: item?.quantity ?? 1,
      stripe_customer_id: String(subscription.customer),
      stripe_subscription_id: subscription.id,
      cancel_at_period_end: subscription.cancel_at_period_end,
      canceled_at: subscription.canceled_at
        ? new Date(subscription.canceled_at * 1000).toISOString()
        : null,
      current_period_start: item?.current_period_start
        ? new Date(item.current_period_start * 1000).toISOString()
        : null,
      current_period_end: item?.current_period_end
        ? new Date(item.current_period_end * 1000).toISOString()
        : null,
      trial_ends_at: subscription.trial_end
        ? new Date(subscription.trial_end * 1000).toISOString()
        : null,
    })
    .eq("organization_id", organizationId);

  if (error) throw new Error(`could not sync subscription: ${error.message}`);
}
