#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_depictions.py —— 按 tools/pkgmeta.py 生成 Sileo 原生 depiction JSON

产出：
    depictions/<包名>.json    每个包一份 SileoDepiction（DepictionTabView 根节点）

Sileo 渲染规则（coolstar RawDocs）：
    根节点必须是 DepictionTabView；tab 内用 DepictionStackView 堆叠各视图。
    文本一律走 DepictionMarkdownView（支持 **粗体** / `code` / 列表），
    键值走 DepictionTableTextView（自动分列、右侧灰字），
    分组靠 DepictionHeaderView + DepictionSeparatorView + DepictionSpacerView。

用法：
    python3 tools/gen_depictions.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from pkgmeta import PKGS, CATEGORIES, depiction_url

OUT_DIR = os.path.join(ROOT, "depictions")

TINT = "#0071e3"


def md(text, spacing=True):
    return {"class": "DepictionMarkdownView", "markdown": text, "useSpacing": spacing}


def hdr(title, sub=False, bold=True):
    cls = "DepictionSubheaderView" if sub else "DepictionHeaderView"
    v = {"class": cls, "title": title, "useBottomMargin": True}
    if not sub:
        v["useBoldText"] = bold
    return v


def sep():
    return {"class": "DepictionSeparatorView"}


def spacer(n):
    return {"class": "DepictionSpacerView", "spacing": n}


def table_text(title, text):
    return {"class": "DepictionTableTextView", "title": title, "text": text}


def build(pkg):
    m = PKGS[pkg]
    views = []

    # ---- 概览 ----
    views.append(md("**%s**" % m["tagline"]))
    views.append(sep())

    # ---- 信息表 ----
    views.append(hdr("基本信息"))
    views.append(table_text("分类", m["category"]))
    if m.get("type"):
        views.append(table_text("类型", m["type"]))
    if m.get("host"):
        views.append(table_text("宿主", m["host"]))
    if m.get("scope"):
        views.append(table_text("范围", m["scope"]))
    for label, val in m.get("extra", []):
        views.append(table_text(label, val))
    views.append(table_text("兼容", m["compat"]))
    views.append(table_text("包名", pkg))

    # ---- 功能 ----
    views.append(spacer(12))
    views.append(hdr("功能"))
    views.append(md("\n".join("- " + f for f in m["features"])))

    # ---- 备注 ----
    if m.get("notes"):
        views.append(spacer(12))
        views.append(hdr("备注", sub=True))
        views.append(md(m["notes"]))

    # ---- 底部 ----
    views.append(spacer(16))
    views.append(sep())
    views.append(md("源码与版本记录：<https://github.com/g459416925/ios-tweaks>"))

    return {
        "minVersion": "0.4",
        "tintColor": TINT,
        "class": "DepictionTabView",
        "tabs": [
            {
                "tabname": "详情",
                "class": "DepictionStackView",
                "views": views,
            }
        ],
    }


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    # 清理旧文件（只清本脚本产物）
    for fn in os.listdir(OUT_DIR):
        if fn.endswith(".json"):
            os.remove(os.path.join(OUT_DIR, fn))

    n = 0
    for pkg in PKGS:
        doc = build(pkg)
        p = os.path.join(OUT_DIR, pkg + ".json")
        with open(p, "w", encoding="utf-8") as f:
            json.dump(doc, f, ensure_ascii=False, indent=2)
            f.write("\n")
        views = doc["tabs"][0]["views"]
        print("  + %-28s %2d views  %s" % (pkg, len(views), depiction_url(pkg)))
        n += 1
    print("\n完成：%d 份 depiction → depictions/" % n)


if __name__ == "__main__":
    main()
