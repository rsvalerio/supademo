/**
 * Send Email auth hook.
 *
 * When enabled ([auth.hook.send_email] in config.toml) GoTrue stops sending
 * mail itself and POSTs here instead, letting all transactional email go
 * through one provider with one set of templates.
 *
 * The payload is signed with a Standard Webhooks HMAC. Verification is
 * non-negotiable: this endpoint runs with verify_jwt = false, and its payload
 * contains one-time login tokens.
 *
 * Enabling this without deploying the function stops auth email entirely, which
 * is why it ships disabled.
 */

import { HttpError, json, serveJson } from "../_shared/http.ts";

interface HookPayload {
  user: { email: string; user_metadata?: Record<string, unknown> };
  email_data: {
    token: string;
    token_hash: string;
    redirect_to: string;
    email_action_type: string;
    site_url: string;
  };
}

const SUBJECTS: Record<string, string> = {
  signup: "Confirm your Supademo account",
  invite: "You've been invited to a Supademo workspace",
  magiclink: "Your Supademo sign-in link",
  recovery: "Reset your Supademo password",
  email_change: "Confirm your new email address",
  reauthentication: "Confirm it's you",
};

/** Standard Webhooks: `v1,<base64>` signature over `<id>.<timestamp>.<body>`. */
async function verifySignature(req: Request, body: string): Promise<void> {
  const secret = Deno.env.get("AUTH_HOOK_SECRET");
  if (!secret) throw new HttpError(500, "AUTH_HOOK_SECRET is not configured");

  const id = req.headers.get("webhook-id");
  const timestamp = req.headers.get("webhook-timestamp");
  const signatureHeader = req.headers.get("webhook-signature");
  if (!id || !timestamp || !signatureHeader) throw new HttpError(401, "Missing webhook signature");

  // Reject anything older than five minutes, so a captured request cannot be
  // replayed later.
  const age = Math.abs(Date.now() / 1000 - Number(timestamp));
  if (!Number.isFinite(age) || age > 300) {
    throw new HttpError(401, "Signature timestamp out of range");
  }

  const rawSecret = secret.replace(/^v1,\s*/, "").replace(/^whsec_/, "");
  const key = await crypto.subtle.importKey(
    "raw",
    Uint8Array.from(atob(rawSecret), (c) => c.charCodeAt(0)),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const mac = await crypto.subtle.sign(
    "HMAC",
    key,
    new TextEncoder().encode(`${id}.${timestamp}.${body}`),
  );
  const expected = btoa(String.fromCharCode(...new Uint8Array(mac)));

  // The header may carry several space-separated versioned signatures.
  const presented = signatureHeader.split(" ").map((part) => part.split(",")[1]);
  if (!presented.some((candidate) => timingSafeEqual(candidate ?? "", expected))) {
    throw new HttpError(401, "Invalid webhook signature");
  }
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

serveJson(async (req) => {
  if (req.method !== "POST") throw new HttpError(405, "Method not allowed");

  const raw = await req.text();
  await verifySignature(req, raw);

  const payload = JSON.parse(raw) as HookPayload;
  const { user, email_data: data } = payload;

  const confirmationUrl = `${data.site_url}/auth/v1/verify` +
    `?token=${encodeURIComponent(data.token_hash)}` +
    `&type=${encodeURIComponent(data.email_action_type)}` +
    `&redirect_to=${encodeURIComponent(data.redirect_to)}`;

  const subject = SUBJECTS[data.email_action_type] ?? "A message from Supademo";
  const html = render(subject, confirmationUrl, data.token);

  const apiKey = Deno.env.get("RESEND_API_KEY");
  if (!apiKey) {
    // Without a provider configured, log instead of silently dropping mail.
    console.info(`[auth-email] ${data.email_action_type} for ${user.email}: ${confirmationUrl}`);
    return json(req, {});
  }

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
    body: JSON.stringify({
      from: Deno.env.get("EMAIL_FROM") ?? "Supademo <onboarding@resend.dev>",
      to: [user.email],
      subject,
      html,
    }),
  });

  if (!response.ok) {
    const detail = await response.text();
    console.error("email provider rejected the message", detail);
    // A non-2xx tells GoTrue the send failed, so the user sees an error rather
    // than waiting for an email that will never arrive.
    return json(req, { error: { http_code: 502, message: "Email provider error" } }, 502);
  }

  return json(req, {});
});

function render(title: string, url: string, token: string): string {
  return `
    <div style="font-family: ui-sans-serif, system-ui, sans-serif; max-width: 480px; margin: 0 auto; padding: 32px 24px; color: #18181b;">
      <h1 style="font-size: 20px; margin: 0 0 16px;">${title}</h1>
      <p style="margin: 0 0 24px;">
        <a href="${url}" style="display: inline-block; background: #18181b; color: #fff; text-decoration: none; padding: 10px 18px; border-radius: 8px;">
          Continue
        </a>
      </p>
      <p style="font-size: 15px; color: #3f3f46; margin: 0 0 24px;">
        Or enter this code: <strong style="letter-spacing: 2px;">${token}</strong>
      </p>
      <p style="font-size: 13px; color: #a1a1aa; margin: 0;">
        If you didn't request this, you can ignore this email.
      </p>
    </div>
  `;
}
