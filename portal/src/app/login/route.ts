import { NextResponse } from "next/server";
import { client, oidcConfig, redirectUri } from "@/lib/oidc";

export const dynamic = "force-dynamic";

export async function GET() {
  const config = await oidcConfig();
  const verifier = client.randomPKCECodeVerifier();
  const state = client.randomState();
  const nonce = client.randomNonce();
  const url = client.buildAuthorizationUrl(config, {
    redirect_uri: redirectUri(),
    scope: "openid profile email",
    code_challenge: await client.calculatePKCECodeChallenge(verifier),
    code_challenge_method: "S256",
    state,
    nonce,
  });
  const res = NextResponse.redirect(url.href);
  res.cookies.set("__Host-msp_oidc", JSON.stringify({ verifier, state, nonce }), { httpOnly: true, secure: true, sameSite: "lax", path: "/", maxAge: 600 });
  return res;
}
