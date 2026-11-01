// A half-circle gauge drawn as plain SVG (no chart library, no script). `percent` is 0-100, or null when there is no data.
// `goodHigh`: true = green at 100 and red at 0 (encryption); false = green at 0 and red at 100 (processor, memory, disk use).
export default function Gauge({ percent, label, caption, goodHigh = false }: { percent: number | null; label: string; caption?: string; goodHigh?: boolean }) {
  const f = percent === null ? 0 : Math.max(0, Math.min(1, percent / 100));
  const L = Math.PI * 80;                       // length of the half circle, radius 80
  const color = `hsl(${Math.round((goodHigh ? f : 1 - f) * 120)}, 62%, 46%)`;
  const arc = "M 20 100 A 80 80 0 0 1 180 100";
  return (
    <svg viewBox="0 0 200 120" width="100%" style={{ maxWidth: 230 }} role="img" aria-label={percent === null ? `${label}: no data` : `${label}: ${Math.round(percent)}%`}>
      <path d={arc} fill="none" stroke="var(--none-bg)" strokeWidth="16" strokeLinecap="round" />
      {f > 0 && <path d={arc} fill="none" stroke={color} strokeWidth="16" strokeLinecap="round" strokeDasharray={`${f * L} ${L}`} />}
      <text x="100" y="92" textAnchor="middle" fontSize="34" fontWeight="600" fill="var(--text)">{percent === null ? "–" : `${Math.round(percent)}%`}</text>
      {caption && <text x="100" y="112" textAnchor="middle" fontSize="12" fill="var(--muted)">{caption}</text>}
    </svg>
  );
}
