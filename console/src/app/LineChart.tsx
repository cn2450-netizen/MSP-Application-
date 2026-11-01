import type { Series } from "@/lib/metrics";

const COLORS = ["var(--brand)", "var(--ok)", "var(--warn)", "#b877d9", "var(--bad)"];
const W = 640, H = 190, L = 38, R = 10, T = 8, B = 24;

const clock = (t: number, spanMs: number) => {
  const d = new Date(t);
  return spanMs > 36 * 3_600_000
    ? d.toLocaleDateString([], { month: "short", day: "numeric" })
    : d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
};

// A line chart drawn as plain SVG on the server: no chart library, no script. The vertical scale is 0-100 % for every
// chart so they can be compared at a glance. A gap in the data (computer off) breaks the line instead of joining across it.
export default function LineChart({ series, from, to, gapMs, title }: { series: Series[]; from: number; to: number; gapMs: number; title: string }) {
  const x = (t: number) => L + ((t - from) / (to - from)) * (W - L - R);
  const y = (v: number) => T + (1 - Math.max(0, Math.min(100, v)) / 100) * (H - T - B);
  const paths = series.map((s) => {
    let d = "", prev: number | null = null;
    for (const p of s.points) {
      d += `${prev === null || p.t - prev > gapMs ? "M" : "L"}${x(p.t).toFixed(1)} ${y(p.v).toFixed(1)} `;
      prev = p.t;
    }
    return d.trim();
  });
  const all = series.flatMap((s) => s.points);
  const stat = (s: Series) => {
    const v = s.points.map((p) => p.v);
    return v.length ? { now: v[v.length - 1], avg: v.reduce((a, b) => a + b, 0) / v.length, max: Math.max(...v) } : null;
  };

  return (
    <div className="chart">
      <svg viewBox={`0 0 ${W} ${H}`} width="100%" role="img" aria-label={title}>
        {[0, 25, 50, 75, 100].map((g) => (
          <g key={g}>
            <line x1={L} x2={W - R} y1={y(g)} y2={y(g)} stroke="var(--line)" strokeWidth="1" />
            <text x={L - 6} y={y(g) + 4} textAnchor="end" fontSize="11" fill="var(--muted)">{g}%</text>
          </g>
        ))}
        {[0, 0.5, 1].map((f) => (
          <text key={f} x={L + f * (W - L - R)} y={H - 6} textAnchor={f === 0 ? "start" : f === 1 ? "end" : "middle"} fontSize="11" fill="var(--muted)">
            {clock(from + f * (to - from), to - from)}
          </text>
        ))}
        {paths.map((d, i) => d && <path key={i} d={d} fill="none" stroke={COLORS[i % COLORS.length]} strokeWidth="1.8" strokeLinejoin="round" />)}
        {all.length === 0 && <text x={W / 2} y={H / 2} textAnchor="middle" fontSize="13" fill="var(--muted)">No data in this period</text>}
      </svg>
      <ul className="legend chart-legend">
        {series.map((s, i) => {
          const st = stat(s);
          return (
            <li key={s.label || title}>
              <i style={{ background: COLORS[i % COLORS.length] }} />
              {s.label && <span>{s.label}</span>}
              {st && <span className="muted small">now <strong>{Math.round(st.now)}%</strong> · average {Math.round(st.avg)}% · highest {Math.round(st.max)}%</span>}
            </li>
          );
        })}
      </ul>
    </div>
  );
}
