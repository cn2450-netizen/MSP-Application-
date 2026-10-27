#!/usr/bin/env python3
"""Generates dashboards/windows-overview.json (the dashboard is JSON, but its Flux queries are easier to edit here).

    python dashboards/build_windows_overview.py

House style: anything shown as a percentage is a 0-100 gauge with green/amber/red zones.
History lines for CPU and memory live in a collapsed "Trends" row at the bottom.
"""
import json
import os

HOST = r'r.host =~ /^${host:regex}$/'
INFLUX = {"type": "influxdb", "uid": "influx"}
LOKI = {"type": "loki", "uid": "loki"}

GREEN_AMBER_RED = {"mode": "absolute", "steps": [
    {"color": "green", "value": None}, {"color": "orange", "value": 80}, {"color": "red", "value": 90}]}
CPU_STEPS = {"mode": "absolute", "steps": [
    {"color": "green", "value": None}, {"color": "orange", "value": 70}, {"color": "red", "value": 90}]}


def flux(q, ref="A"):
    return {"refId": ref, "query": q, "datasource": INFLUX}


def base(pid, title, ptype, x, y, w, h, targets, ds=INFLUX):
    return {"id": pid, "title": title, "type": ptype, "gridPos": {"x": x, "y": y, "w": w, "h": h},
            "datasource": ds, "targets": targets, "options": {},
            "fieldConfig": {"defaults": {}, "overrides": []}}


def gauge(pid, title, x, y, w, h, query, display_name, steps=GREEN_AMBER_RED):
    p = base(pid, title, "gauge", x, y, w, h, [flux(query)])
    p["fieldConfig"]["defaults"] = {"unit": "percent", "min": 0, "max": 100, "decimals": 0,
                                    "displayName": display_name, "thresholds": steps}
    p["options"] = {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "showThresholdMarkers": True, "showThresholdLabels": False, "orientation": "auto"}
    return p


def gauge_cell():
    """Table-cell gauge, 0-100 %."""
    return [{"id": "custom.cellOptions", "value": {"type": "gauge", "mode": "gradient"}},
            {"id": "min", "value": 0}, {"id": "max", "value": 100}, {"id": "unit", "value": "percent"},
            {"id": "thresholds", "value": GREEN_AMBER_RED}]


# ---- queries ---------------------------------------------------------------------------------------------

CPU = ('from(bucket: v.defaultBucket) |> range(start: -5m) '
       f'|> filter(fn: (r) => r._measurement == "cpu" and r._field == "usage_idle" and r.cpu == "cpu-total" and {HOST}) '
       '|> map(fn: (r) => ({r with _value: 100.0 - r._value})) |> mean() |> keep(columns: ["host", "_value"])')

MEM = ('from(bucket: v.defaultBucket) |> range(start: -5m) '
       f'|> filter(fn: (r) => r._measurement == "mem" and r._field == "used_percent" and {HOST}) '
       '|> last() |> keep(columns: ["host", "_value"])')

DISK_PCT = ('from(bucket: v.defaultBucket) |> range(start: -15m) '
            f'|> filter(fn: (r) => r._measurement == "volume" and r._field == "used_percent" and {HOST}) '
            '|> last() |> keep(columns: ["host", "name", "_value"])')

BITLOCKER = ('from(bucket: v.defaultBucket) |> range(start: -1h) '
             f'|> filter(fn: (r) => r._measurement == "bitlocker" and {HOST} and (r._field == "protection_status" or r._field == "encryption_percentage" or r._field == "volume_status")) '
             '|> last() |> drop(columns: ["_time", "_start", "_stop"]) '
             '|> map(fn: (r) => ({r with name: if exists r.name then r.name else r.volume + ":"})) '
             '|> pivot(rowKey: ["host", "name"], columnKey: ["_field"], valueColumn: "_value") '
             '|> group() '
             '|> keep(columns: ["host", "name", "protection_status", "encryption_percentage", "volume_status"]) '
             '|> rename(columns: {name: "volume"})')

SERVICES = ('from(bucket: v.defaultBucket) |> range(start: -15m) '
            f'|> filter(fn: (r) => r._measurement == "win_services" and {HOST} and (r._field == "state" or r._field == "startup_mode")) '
            '|> last() '
            '|> pivot(rowKey: ["host", "service_name", "display_name"], columnKey: ["_field"], valueColumn: "_value") '
            '|> filter(fn: (r) => r.startup_mode == 2 and r.state != 4) '
            '|> keep(columns: ["host", "display_name", "service_name"])')

PATCHES = ('from(bucket: v.defaultBucket) |> range(start: -90d) '
           f'|> filter(fn: (r) => r._measurement == "patch_history" and r._field == "title" and {HOST}) '
           '|> group(columns: ["host", "kb", "result", "operation", "date", "source"]) |> last() |> group() '
           '|> sort(columns: ["date"], desc: true) '
           '|> keep(columns: ["host", "date", "kb", "result", "operation", "source", "_value"]) '
           '|> rename(columns: {_value: "title"}) |> limit(n: 100)')

CPU_TREND = ('from(bucket: v.defaultBucket) |> range(start: v.timeRangeStart, stop: v.timeRangeStop) '
             f'|> filter(fn: (r) => r._measurement == "cpu" and r._field == "usage_idle" and r.cpu == "cpu-total" and {HOST}) '
             '|> map(fn: (r) => ({r with _value: 100.0 - r._value})) '
             '|> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)')

MEM_TREND = ('from(bucket: v.defaultBucket) |> range(start: v.timeRangeStart, stop: v.timeRangeStop) '
             f'|> filter(fn: (r) => r._measurement == "mem" and r._field == "used_percent" and {HOST}) '
             '|> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false)')

DISK_PCT_TREND = ('from(bucket: v.defaultBucket) |> range(start: v.timeRangeStart, stop: v.timeRangeStop) '
                  f'|> filter(fn: (r) => r._measurement == "volume" and r._field == "used_percent" and {HOST}) '
                  '|> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false) '
                  '|> keep(columns: ["_time", "_value", "host", "name"])')

DISK_FREE_TREND = ('from(bucket: v.defaultBucket) |> range(start: v.timeRangeStart, stop: v.timeRangeStop) '
                   f'|> filter(fn: (r) => r._measurement == "volume" and r._field == "free_bytes" and {HOST}) '
                   '|> aggregateWindow(every: v.windowPeriod, fn: mean, createEmpty: false) '
                   '|> keep(columns: ["_time", "_value", "host", "name"])')

BACKUPS = ('from(bucket: v.defaultBucket) |> range(start: -30d) '
           f'|> filter(fn: (r) => r._measurement == "backup_run" and {HOST} and (r._field == "result_code" or r._field == "last_success" or r._field == "duration_s" or r._field == "data_added" or r._field == "bytes_processed" or r._field == "message")) '
           '|> last() |> drop(columns: ["_time", "_start", "_stop"]) '
           '|> pivot(rowKey: ["host"], columnKey: ["_field"], valueColumn: "_value") |> group() '
           '|> map(fn: (r) => ({r with age_h: float(v: int(v: now()) / 1000000000 - r.last_success) / 3600.0, last_success: r.last_success * 1000})) '
           '|> keep(columns: ["host", "result_code", "last_success", "age_h", "duration_s", "bytes_processed", "data_added", "message"]) '
           '|> rename(columns: {result_code: "last_run", last_success: "last_good_backup", age_h: "hours_since_good", duration_s: "seconds", bytes_processed: "protected", data_added: "new_data"})')

# ---- panels ----------------------------------------------------------------------------------------------

panels = []

panels.append(gauge(1, "CPU used (5 min average)", 0, 0, 6, 7, CPU, "${__field.labels.host}", CPU_STEPS))
panels.append(gauge(2, "Memory used", 6, 0, 6, 7, MEM, "${__field.labels.host}"))
panels.append(gauge(3, "Disk used", 12, 0, 12, 7, DISK_PCT, "${__field.labels.host}  ${__field.labels.name}"))

# Backup status: newest backup_run per machine (written by agent/backup/windows/msp-backup.ps1). A machine that
# stops reporting is caught by "hours_since_good" climbing, not by the row disappearing.
backups = base(4, "Backups", "table", 0, 7, 12, 8, [flux(BACKUPS)])
backups["fieldConfig"]["overrides"] = [
    {"matcher": {"id": "byName", "options": "last_run"}, "properties": [
        {"id": "mappings", "value": [{"type": "value", "options": {
            "0": {"text": "OK", "color": "green", "index": 0},
            "2": {"text": "Partial", "color": "orange", "index": 1},
            "1": {"text": "FAILED", "color": "red", "index": 2}}}]},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}}]},
    {"matcher": {"id": "byName", "options": "hours_since_good"}, "properties": [
        {"id": "unit", "value": "h"}, {"id": "decimals", "value": 0},
        {"id": "thresholds", "value": {"mode": "absolute", "steps": [
            {"color": "green", "value": None}, {"color": "orange", "value": 30}, {"color": "red", "value": 54}]}},
        {"id": "custom.cellOptions", "value": {"type": "color-background", "mode": "basic"}}]},
    {"matcher": {"id": "byName", "options": "last_good_backup"}, "properties": [
        {"id": "unit", "value": "dateTimeAsLocal"}]},
    {"matcher": {"id": "byName", "options": "protected"}, "properties": [{"id": "unit", "value": "bytes"}]},
    {"matcher": {"id": "byName", "options": "new_data"}, "properties": [{"id": "unit", "value": "bytes"}]},
    {"matcher": {"id": "byName", "options": "seconds"}, "properties": [{"id": "unit", "value": "s"}]},
]
panels.append(backups)

bl = base(5, "BitLocker", "table", 12, 7, 12, 8, [flux(BITLOCKER)])
bl["fieldConfig"]["overrides"] = [
    {"matcher": {"id": "byName", "options": "protection_status"}, "properties": [
        {"id": "mappings", "value": [{"type": "value", "options": {
            "0": {"text": "OFF", "color": "red", "index": 0},
            "1": {"text": "On", "color": "green", "index": 1}}}]},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}}]},
    {"matcher": {"id": "byName", "options": "encryption_percentage"}, "properties": gauge_cell()},
]
panels.append(bl)

panels.append(base(6, "Auto-start services NOT running", "table", 0, 15, 12, 9, [flux(SERVICES)]))

patch = base(7, "Windows update history (last 90 days, newest first)", "table", 12, 15, 12, 9, [flux(PATCHES)])
patch["fieldConfig"]["overrides"] = [
    {"matcher": {"id": "byName", "options": "result"}, "properties": [
        {"id": "mappings", "value": [{"type": "value", "options": {
            "Failed": {"color": "red", "index": 0},
            "Aborted": {"color": "red", "index": 1},
            "SucceededWithErrors": {"color": "orange", "index": 2},
            "Succeeded": {"color": "green", "index": 3}}}]},
        {"id": "custom.cellOptions", "value": {"type": "color-text"}}]},
]
panels.append(patch)

panels.append(base(8, "Warnings / errors (System + Application)", "logs", 0, 24, 24, 10,
                   [{"refId": "A", "expr": '{host=~"$host"}', "datasource": LOKI}], ds=LOKI))

trend_cpu = base(10, "CPU used % over time", "timeseries", 0, 35, 12, 8, [flux(CPU_TREND)])
trend_cpu["fieldConfig"]["defaults"] = {"unit": "percent", "min": 0, "max": 100}
trend_mem = base(11, "Memory used % over time", "timeseries", 12, 35, 12, 8, [flux(MEM_TREND)])
trend_mem["fieldConfig"]["defaults"] = {"unit": "percent", "min": 0, "max": 100}
DRIVE_LINE = "${__field.labels.host}  ${__field.labels.name}"
trend_disk = base(12, "Disk used % over time", "timeseries", 0, 43, 12, 8, [flux(DISK_PCT_TREND)])
trend_disk["fieldConfig"]["defaults"] = {"unit": "percent", "min": 0, "max": 100, "displayName": DRIVE_LINE}
trend_free = base(13, "Disk free space over time", "timeseries", 12, 43, 12, 8, [flux(DISK_FREE_TREND)])
trend_free["fieldConfig"]["defaults"] = {"unit": "bytes", "min": 0, "displayName": DRIVE_LINE}
panels.append({"id": 9, "type": "row", "title": "Trends", "collapsed": True,
               "gridPos": {"x": 0, "y": 34, "w": 24, "h": 1},
               "panels": [trend_cpu, trend_mem, trend_disk, trend_free]})

dashboard = {
    "uid": "windows-overview", "title": "Windows Overview", "tags": ["msp", "windows"],
    "schemaVersion": 39, "version": 3, "refresh": "1m",
    "time": {"from": "now-6h", "to": "now"},
    "templating": {"list": [{
        "name": "host", "label": "Host", "type": "query", "datasource": INFLUX,
        "query": 'import "influxdata/influxdb/schema"\nschema.tagValues(bucket: v.defaultBucket, tag: "host")',
        "refresh": 2, "includeAll": True, "multi": True, "current": {}}]},
    "panels": panels,
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "windows-overview.json")
with open(out, "w", encoding="utf-8", newline="\n") as f:
    json.dump(dashboard, f, indent=2)
    f.write("\n")
print("wrote", out)
