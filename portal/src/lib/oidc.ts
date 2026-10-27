import * as client from "openid-client";
import { env } from "./env";

let cached: Promise<client.Configuration> | null = null;

export function oidcConfig(): Promise<client.Configuration> {
  if (!cached) {
    cached = client
      .discovery(new URL(`https://${env.authHost}/application/o/portal/`), "portal", env.oidcSecret)
      .catch((e) => { cached = null; throw e; });
  }
  return cached;
}

export const redirectUri = () => `${env.publicUrl}/auth/callback`;
export { client };
