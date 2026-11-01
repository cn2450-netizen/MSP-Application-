// A donut chart drawn as plain SVG on the server (no chart library, no script).
export default function Donut({ slices, label }: { slices: { label: string; value: number; color: string }[]; label: string }) {
  const total = slices.reduce((a, s) => a + s.value, 0);
  const R = 52, C = 2 * Math.PI * R;
  let offset = 0;
  return (
    <div className="donut-wrap">
      <svg width="150" height="150" viewBox="0 0 150 150" role="img" aria-label={label}>
        <circle cx="75" cy="75" r={R} fill="none" stroke="var(--none-bg)" strokeWidth="18" />
        {total > 0 && slices.filter((s) => s.value > 0).map((s) => {
          const len = (s.value / total) * C;
          const el = <circle key={s.label} cx="75" cy="75" r={R} fill="none" stroke={s.color} strokeWidth="18"
                             strokeDasharray={`${len} ${C - len}`} strokeDashoffset={-offset} transform="rotate(-90 75 75)" />;
          offset += len;
          return el;
        })}
        <text x="75" y="81" textAnchor="middle" fontSize="24" fontWeight="600" fill="var(--text)">{total}</text>
      </svg>
      <ul className="legend">
        {slices.map((s) => <li key={s.label}><i style={{ background: s.color }} />{s.label}: <strong>{s.value}</strong></li>)}
      </ul>
    </div>
  );
}
