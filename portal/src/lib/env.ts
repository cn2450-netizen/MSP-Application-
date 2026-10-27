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
  // Off unless the operator turns it on: a lab with a single technician cannot have a second person approve.
  get allowSelfApprove() { return process.env.PORTAL_ALLOW_SELF_APPROVE === "1"; },
  get publicUrl() { return `https://${plain("PORTAL_HOST")}`; },
};
