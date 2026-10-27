import { NextResponse } from "next/server";
import { getScope } from "./session";
import { getMachine, type MachineRow } from "./data";
import { sameOrigin } from "./agentauth";
import { env } from "./env";
import type { Scope } from "./authz";

export const json = (body: unknown, status = 200) => NextResponse.json(body, { status });

/**
 * For browser-facing API routes: signed in, same-origin (for anything that changes state), and the machine must be
 * one this person may see. Unknown and forbidden look identical (404) so ids cannot be probed.
 */
export async function withMachine(req: Request, id: string, opts: { write: boolean }):
  Promise<{ scope: Scope; machine: MachineRow } | NextResponse> {
  if (opts.write && !sameOrigin(req, env.publicUrl)) return json({ error: "bad origin" }, 403);
  const scope = await getScope();
  if (!scope) return json({ error: "not signed in" }, 401);
  const machine = await getMachine(scope, id);
  if (!machine) return json({ error: "not found" }, 404);
  return { scope, machine };
}
