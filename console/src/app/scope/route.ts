import { NextResponse } from "next/server";
import { getScope } from "@/lib/session";
import { listCustomers } from "@/lib/data";
import { VIEW_COOKIE } from "@/lib/view";

export const dynamic = "force-dynamic";

// POST only (the top-bar picker). Anything that is not one of this person's own customers/sites is stored as "all".
export async function POST(req: Request) {
  const scope = await getScope();
  if (!scope) return new NextResponse(null, { status: 401 });
  const form = await req.formData();
  const c = String(form.get("customer") ?? ""), s = String(form.get("site") ?? "");
  const cust = (await listCustomers(scope)).find((x) => x.slug === c);
  const value = cust ? `${cust.slug}|${cust.sites.includes(s) ? s : ""}` : "";
  let next = String(form.get("next") ?? "/");
  if (!/^\/[A-Za-z0-9/_-]*$/.test(next) || next.startsWith("//")) next = "/";   // same-site paths only
  const res = new NextResponse(null, { status: 303, headers: { Location: next } });
  res.cookies.set(VIEW_COOKIE, value, { httpOnly: true, secure: true, sameSite: "lax", path: "/", maxAge: 30 * 86400 });
  return res;
}
