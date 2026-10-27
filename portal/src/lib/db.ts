import pg from "pg";
import { env } from "./env";

const g = globalThis as unknown as { __pool?: pg.Pool };

export function pool(): pg.Pool {
  if (!g.__pool) {
    g.__pool = new pg.Pool({ host: env.dbHost, user: "portal", database: "portal", password: env.dbPassword, max: 10, idleTimeoutMillis: 30000 });
  }
  return g.__pool;
}

export async function q<T extends pg.QueryResultRow = any>(text: string, params: unknown[] = []): Promise<T[]> {
  return (await pool().query<T>(text, params as any[])).rows;
}
export async function q1<T extends pg.QueryResultRow = any>(text: string, params: unknown[] = []): Promise<T | null> {
  return (await q<T>(text, params))[0] ?? null;
}
