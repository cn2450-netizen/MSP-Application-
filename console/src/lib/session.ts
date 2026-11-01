import { cookies, headers } from "next/headers";
import { createHash, randomBytes } from "node:crypto";
import { q, q1 } from "./db";
import { scopeFromGroups, type Scope } from "./authz";

export const SESSION_COOKIE = "__Host-msp_session";
const ABSOLUTE_HOURS = 12;
const IDLE_MINUTES = 60;

const hash = (v: string) => createHash("sha256").update(v).digest("hex");

export async function clientIp(): Promise<string> {
  const h = await headers();
  return (h.get("x-forwarded-for") || "").split(",")[0].trim() || h.get("x-real-ip") || "";
}

export async function createSession(user: { sub: string; username: string; name: string; groups: string[] }) {
  const id = randomBytes(32).toString("base64url");
  await q(
    `INSERT INTO session(id_hash, sub, username, name, groups, expires_at) VALUES ($1,$2,$3,$4,$5, now() + make_interval(hours => $6))`,
    [hash(id), user.sub, user.username, user.name, JSON.stringify(user.groups), ABSOLUTE_HOURS],
  );
  (await cookies()).set(SESSION_COOKIE, id, { httpOnly: true, secure: true, sameSite: "lax", path: "/", maxAge: ABSOLUTE_HOURS * 3600 });
  await q("DELETE FROM session WHERE expires_at < now() OR last_seen < now() - make_interval(mins => $1)", [IDLE_MINUTES]);
}

export async function getScope(): Promise<Scope | null> {
  const id = (await cookies()).get(SESSION_COOKIE)?.value;
  if (!id) return null;
  const row = await q1<{ username: string; name: string; groups: string[] }>(
    `UPDATE session SET last_seen = now()
      WHERE id_hash = $1 AND expires_at > now() AND last_seen > now() - make_interval(mins => $2)
      RETURNING username, name, groups`,
    [hash(id), IDLE_MINUTES],
  );
  return row ? scopeFromGroups(row.username, row.name, row.groups) : null;
}

export async function destroySession() {
  const jar = await cookies();
  const id = jar.get(SESSION_COOKIE)?.value;
  if (id) await q("DELETE FROM session WHERE id_hash = $1", [hash(id)]);
  jar.delete(SESSION_COOKIE);
}
