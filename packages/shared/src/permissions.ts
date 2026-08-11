/**
 * The role hierarchy, mirrored from the `public.org_role` enum.
 *
 * This is a copy of a rule the database already enforces, and that is fine — as
 * long as it is understood as a *hint for the UI*, never as the enforcement
 * point. It decides whether a button renders disabled; RLS decides whether the
 * write happens. If the two ever disagree, the database wins and the user sees
 * an error, which is the correct failure mode.
 */

export const ORG_ROLES = ["viewer", "member", "admin", "owner"] as const;
export type OrgRole = (typeof ORG_ROLES)[number];

/** Declaration order is the hierarchy, exactly as in the enum. */
const RANK: Record<OrgRole, number> = {
  viewer: 0,
  member: 1,
  admin: 2,
  owner: 3,
};

export function hasRole(actual: OrgRole | null | undefined, minimum: OrgRole): boolean {
  if (!actual) return false;
  return RANK[actual] >= RANK[minimum];
}

/**
 * What each role may do, as the UI understands it. Every entry here has a
 * corresponding policy in `supabase/migrations`; see `docs/rls.md` for the map.
 */
export const CAPABILITIES = {
  "demo:read": "viewer",
  "demo:comment": "viewer",
  "demo:write": "member",
  "demo:publish": "member",
  "demo:delete": "admin",
  "project:write": "member",
  "project:delete": "admin",
  "member:invite": "admin",
  "member:remove": "admin",
  "billing:manage": "admin",
  "apikey:manage": "admin",
  "webhook:manage": "admin",
  "audit:read": "admin",
  "organization:delete": "owner",
  "organization:transfer": "owner",
} as const satisfies Record<string, OrgRole>;

export type Capability = keyof typeof CAPABILITIES;

export function can(role: OrgRole | null | undefined, capability: Capability): boolean {
  return hasRole(role, CAPABILITIES[capability]);
}

/**
 * Actions the database additionally gates on a verified second factor
 * (`app.is_mfa_verified()`), so the UI can prompt for MFA before attempting
 * something that would otherwise fail with a confusing 403.
 */
export const REQUIRES_MFA: ReadonlySet<Capability> = new Set([
  "organization:delete",
  "organization:transfer",
]);
