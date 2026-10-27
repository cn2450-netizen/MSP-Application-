"use client";
import { useEffect, useState } from "react";

// Dark is the default. The choice is a per-browser convenience, so a blocked or empty localStorage just means dark.
export default function ThemeToggle() {
  const [light, setLight] = useState(false);
  useEffect(() => {
    try { if (localStorage.getItem("theme") === "light") { document.documentElement.dataset.theme = "light"; setLight(true); } } catch { /* storage blocked */ }
  }, []);
  function flip() {
    const next = !light;
    setLight(next);
    document.documentElement.dataset.theme = next ? "light" : "dark";
    try { localStorage.setItem("theme", next ? "light" : "dark"); } catch { /* storage blocked */ }
  }
  return <button type="button" className="theme-toggle" onClick={flip} aria-label="Switch between dark and light">{light ? "Dark" : "Light"} mode</button>;
}
