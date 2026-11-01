import { z } from "zod";
import { json } from "@/lib/api";
import { getScope } from "@/lib/session";
import { isStaffFor } from "@/lib/authz";
import { audit } from "@/lib/audit";
import { readJson, sameOrigin } from "@/lib/agentauth";
import { env } from "@/lib/env";
import { createRequest, customerExists, customerSlug, hostName, volumeLetter } from "@/lib/bitlocker";

export const dynamic = "force-dynamic";

const Body = z.object({ customer: customerSlug, host: hostName, volume: volumeLetter, action: z.enum(["enable", "escrow"]) }).strict();

// Ask for BitLocker to be turned on (and its recovery key saved), or just for the key to be saved. A host-side worker
// carries it out through MeshCentral; the PC runs a fixed script and the only things from the browser that reach its
// command line are a validated computer name (to pick the device) and a drive letter.
export async function POST(req: Request) {
  if (!sameOrigin(req, env.publicUrl)) return json({ error: "bad origin" }, 403);
  const scope = await getScope();
  if (!scope) return json({ error: "not signed in" }, 401);
  let b: z.infer<typeof Body>;
  try { b = Body.parse(await readJson(req, 500)); } catch { return json({ error: "bad request" }, 400); }
  if (!isStaffFor(scope, b.customer) || !(await customerExists(b.customer))) return json({ error: "not found" }, 404);
  const id = await createRequest(b.customer, b.host, b.volume, b.action, scope.username);
  if (!id) return json({ error: "a request for this drive is already waiting or running" }, 409);
  await audit(scope, `bitlocker.${b.action}.request`, { customer: b.customer, detail: { id, host: b.host, volume: b.volume } });
  return json({ ok: true, id });
}
