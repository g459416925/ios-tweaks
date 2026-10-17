#!/usr/bin/env python3
from pathlib import Path

source = Path(__file__).with_name("StatusBarScale.m").read_text(encoding="utf-8")
checks = {
    "version": '#define SBS_VERSION @"2.6.0"' in source,
    "dynamic_render": "sbs_currentRenderScale" in source,
    "dynamic_main": "sbs_statusBarScale()" in source,
    "dynamic_lead": "sbs_statusBarLeadScale()" in source,
    "dynamic_threshold": "sbs_statusBarThreshold()" in source,
    "string_excluded": 'containsString:@"StringView"' in source,
}
for name, passed in checks.items():
    print(f"{name}={'PASS' if passed else 'FAIL'}")
if not all(checks.values()):
    raise SystemExit(1)
print("dynamic-scale source verification: PASS")
