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

详情页布局约定（用户视角，不写实现机制/宿主/依赖）：
    ① 一句话定位（加粗）
    ② 功能列表（主要功能点，全量）
    ③ 基本信息表：分类 / 类型（独立应用时）/ 兼容 / 包名

用法：
    python3 tools/gen_depictions.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from pkgmeta import PKGS, depiction_url

OUT_DIR = os.path.join(ROOT, "depictions")

TINT = "#0071e3"


def md(text, spacing=True):
    return {"class": "DepictionMarkdownView", "markdown": text, "useSpacing": spacing}


def hdr(title):
    return {"class": "DepictionHeaderView", "title": title,
            "useBottomMargin": True, "useBoldText": True}


def sep():
    return {"class": "DepictionSeparatorView"}


def spacer(n):
    return {"class": "DepictionSpacerView", "spacing": n}


def table_text(title, text):
    return {"class": "DepictionTableTextView", "title": title, "text": text}


def build(pkg):
    m = PKGS[pkg]
    views = []

    # ---- ① 一句话定位 ----
    views.append(md("**%s**" % m["tagline"]))
    views.append(sep())

    # ---- ② 功能（主体，全量）----
    views.append(hdr("功能"))
    views.append(md("\n".join("- " + f for f in m["features"])))

    # ---- ③ 基本信息 ----
    views.append(spacer(12))
    views.append(hdr("基本信息"))
    views.append(table_text("分类", m["category"]))
    if m.get("type"):
        views.append(table_text("类型", m["type"]))
    views.append(table_text("兼容", m["compat"]))
    views.append(table_text("包名", pkg))

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
