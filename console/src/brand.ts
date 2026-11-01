// Everything that names or dresses the product lives here and in the CSS variables at the top of app/globals.css.
// To rename or re-brand: change these values (or set the CONSOLE_* variables in .env), rebuild, and run
// scripts/apply-brand.sh to carry the same name to MeshCentral and the sign-in page. No page hard-codes the name.
export const brand = {
  name: process.env.CONSOLE_NAME || "MSP Console",
  short: process.env.CONSOLE_SHORT || "MSP",
  tagline: process.env.CONSOLE_TAGLINE || "Monitoring, backup, encryption and remote support in one place",
  support: process.env.CONSOLE_SUPPORT || "",          // shown in the footer when set, e.g. support@example.com
  logo: process.env.CONSOLE_LOGO || "",                // path under /public, e.g. /logo.svg; the short name is used when empty
};
