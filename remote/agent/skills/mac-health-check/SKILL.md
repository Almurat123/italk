---
name: mac-health-check
description: A quick, read-only health check of this Mac — uptime, battery, disk, memory pressure, what is using the CPU.
version: 1.0.0
platforms: [macos]
tags: [system, diagnostics]
---

# Mac health check

## When to use
"Is my Mac OK", "why is it slow/hot", "battery health", "how long has it been on".

## Procedure
Run these (several will ask the person for approval on the phone; that is expected):
1. `uptime` and `sw_vers`.
2. Battery: `pmset -g batt` and `system_profiler SPPowerDataType | grep -E 'Cycle Count|Condition|Maximum Capacity'`.
3. Disk: `df -h /`.
4. Memory: `vm_stat | head -12` and `memory_pressure | tail -3`.
5. Busiest processes: `ps -Aro %cpu,%mem,comm | sort -rn | head -8`.
6. Thermal/power state if the person says it is hot: `pmset -g therm`.
Report one line per area with a verdict (fine / watch / problem) and the reason, then at most three concrete suggestions.

## Pitfalls
- Do not kill processes or change settings in this skill. Suggest, and wait to be asked.
- A single high CPU reading is normal right after launching apps; look at the pattern across the list.

## Verification
Each verdict points to a number from a command output above.
