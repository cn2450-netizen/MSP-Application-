"use client";
import { useEffect } from "react";
import { startHeartbeat } from "@/lib/useJob";

// While a machine's page is open its agent checks in every few seconds, so the first click is answered at once
// instead of waiting for the next one-minute check-in.
export default function Heartbeat({ machineId }: { machineId: string }) {
  useEffect(() => startHeartbeat(machineId), [machineId]);
  return null;
}
