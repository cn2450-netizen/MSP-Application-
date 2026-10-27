import { NextResponse } from "next/server";
import { destroySession } from "@/lib/session";
import { env } from "@/lib/env";

export const dynamic = "force-dynamic";

// POST only: a GET link must not be able to sign someone out (or be triggered by another site).
export async function POST() {
  await destroySession();
  return NextResponse.redirect(`https://${env.authHost}/application/o/portal/end-session/`, 303);
}
