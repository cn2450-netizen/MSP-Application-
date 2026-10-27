import { NextRequest, NextResponse } from "next/server";
import { client, oidcConfig } from "@/lib/oidc";
import { env } from "@/lib/env";
import { createSession } from "@/lib/session";
import { audit } from "@/lib/audit";

export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const raw = req.cookies.get("__Host-msp_oidc")?.value;
  const fail = (why: string) => {
    const res = new NextResponse(`Sign-in failed (${why}). Go back and try again.`, { status: 400 });
    res.cookies.delete("__Host-msp_oidc");
    return res;
  };
  if (!raw) return fail("no sign-in in progress");
  let saved: { verifier: string; state: string; nonce: string };
  try { saved = JSON.parse(raw); } catch { return fail("bad state"); }

  try {
    const config = await oidcConfig();
    // The public URL, not the container's internal one: it must match what authentik redirected to.
    const current = new URL(`${env.publicUrl}/auth/callback${req.nextUrl.search}`);
    const tokens = await client.authorizationCodeGrant(config, current, {
      pkceCodeVerifier: saved.verifier, expectedState: saved.state, expectedNonce: saved.nonce, idTokenExpected: true,
    });
    const claims = tokens.claims()!;
    let groups = Array.isArray(claims.groups) ? (claims.groups as string[]) : null;
    if (!groups) {
      const info = await client.fetchUserInfo(config, tokens.access_token, claims.sub);
      groups = Array.isArray(info.groups) ? (info.groups as string[]) : [];
    }
    const username = String(claims.preferred_username || claims.email || claims.sub);
    await createSession({ sub: claims.sub, username, name: String(claims.name || username), groups });
    await audit(username, "login");
    const res = NextResponse.redirect(`${env.publicUrl}/`);
    res.cookies.delete("__Host-msp_oidc");
    return res;
  } catch (e) {
    console.error("oidc callback failed:", (e as Error).message);
    return fail("authentication error");
  }
}
