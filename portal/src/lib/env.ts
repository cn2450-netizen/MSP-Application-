import fs from "node:fs";

function secret(name: string): string {
  const file = process.env[`${name}_FILE`];
  const v = file ? fs.readFileSync(file, "utf8").trim() : process.env[name];
  if (!v) throw new Error(`missing ${name}`);
  return v;
}
function plain(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing ${name}`);
  return v;
}

// Read lazily so `next build` (which has no secrets) can import modules.
export const env = {
  get portalHost() { return plain("PORTAL_HOST"); },
  get authHost() { return plain("AUTH_HOST"); },
  get dbHost() { return process.env.PORTAL_DB_HOST || "postgres"; },
  get dbPassword() { return secret("PORTAL_DB_PASSWORD"); },
  get oidcSecret() { return secret("PORTAL_OIDC_SECRET"); },
  get publicUrl() { return `https://${plain("PORTAL_HOST")}`; },
};
