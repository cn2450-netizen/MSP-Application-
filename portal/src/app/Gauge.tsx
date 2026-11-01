// A half-circle gauge drawn as plain SVG (no chart library, no script). Red at 0, green at 100, like the Grafana gauges.
export default function Gauge({ value, total, label, caption }: { value: number; total: number; label: string; caption: string }) {
  const f = total > 0 ? Math.max(0, Math.min(1, value / total)) : 0;
  const L = Math.PI * 80;                       // length of the half circle, radius 80
  const color = `hsl(${Math.round(f * 120)}, 62%, 46%)`;
  const arc = "M 20 100 A 80 80 0 0 1 180 100";
  return (
    <div className="gauge">
      <svg viewBox="0 0 200 120" width="220" role="img" aria-label={`${label}: ${value} of ${total}`}>
        <path d={arc} fill="none" stroke="var(--none-bg)" strokeWidth="16" strokeLinecap="round" />
        {f > 0 && <path d={arc} fill="none" stroke={color} strokeWidth="16" strokeLinecap="round" strokeDasharray={`${f * L} ${L}`} />}
        <text x="100" y="92" textAnchor="middle" fontSize="34" fontWeight="600" fill="var(--text)">{total > 0 ? `${Math.round(f * 100)}%` : "–"}</text>
        <text x="100" y="112" textAnchor="middle" fontSize="12" fill="var(--muted)">{caption}</text>
      </svg>
    </div>
  );
}
