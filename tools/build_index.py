#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
build_index.py —— 由 tools/pkgmeta.py 生成 index.html（可按功能分类、格式统一的详情页）

用法：
    python3 tools/build_index.py
"""
import html
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from pkgmeta import PKGS, CATEGORIES, LATEST, REPO_BASE

REPO_URL = "https://g459416925.github.io/ios-tweaks/"
GH_URL = "https://github.com/g459416925/ios-tweaks"


def inline_md(s):
    """把 `code` / **bold** 转成 HTML（先转义）"""
    s = html.escape(s)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", s)
    return s


def pkg_cards(cat):
    out = []
    for pkg, m in PKGS.items():
        if m["category"] != cat:
            continue
        items = "\n".join("      <li>%s</li>" % inline_md(f) for f in m["features"])
        rows = [("包名", "<code>%s</code>" % pkg)]
        if m.get("type"):
            rows.append(("类型", html.escape(m["type"]) + "（非 tweak）"))
        rows.append(("兼容", html.escape(m["compat"])))
        dl = "\n".join("      <dt>%s</dt><dd>%s</dd>" % (k, v) for k, v in rows)
        out.append("""  <section class="pkg">
    <h3>%s <span class="ver">%s</span></h3>
    <p class="tagline">%s · %s</p>
    <ul>
%s
    </ul>
    <dl>
%s
    </dl>
  </section>""" % (
            html.escape(m["name"]),
            html.escape(LATEST.get(pkg, "—")),
            html.escape(m["category"]),
            html.escape(m["tagline"]),
            items, dl,
        ))
    return "\n\n".join(out)


def total_table():
    rows = []
    for cat, _desc in CATEGORIES:
        members = [(p, m) for p, m in PKGS.items() if m["category"] == cat]
        for idx, (pkg, m) in enumerate(members):
            catcell = ('<td class="cat" rowspan="%d">%s</td>' % (len(members), html.escape(cat))
                       if idx == 0 else "")
            rows.append("    <tr>%s<td>%s</td><td><code>%s</code></td><td>%s</td></tr>" % (
                catcell, html.escape(m["name"]), pkg, html.escape(LATEST.get(pkg, "—"))))
    return "\n".join(rows)


def sections():
    out = []
    cn = ["一", "二", "三", "四", "五", "六"]
    for i, (cat, desc) in enumerate(CATEGORIES):
        out.append('  <h3 class="cat-head">%s、%s<small>%s</small></h3>' % (
            cn[i] if i < len(cn) else str(i + 1), html.escape(cat), html.escape(desc)))
        out.append(pkg_cards(cat))
    return "\n\n".join(out)


TPL = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>g459416925 · iOS Tweaks</title>
<style>
  :root{
    --bg:#fff; --fg:#1d1d1f; --sub:#6e6e73; --line:#e5e5ea;
    --card:#f5f5f7; --accent:#0071e3;
  }
  @media (prefers-color-scheme: dark){
    :root{ --bg:#000; --fg:#f5f5f7; --sub:#86868b; --line:#2c2c2e;
           --card:#1c1c1e; --accent:#0a84ff; }
  }
  *{box-sizing:border-box}
  body{
    margin:0; background:var(--bg); color:var(--fg);
    font:16px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text","PingFang SC",sans-serif;
    -webkit-font-smoothing:antialiased;
  }
  .wrap{max-width:760px;margin:0 auto;padding:56px 22px 72px}
  h1{font-size:32px;letter-spacing:-.02em;margin:0 0 6px}
  .sub{color:var(--sub);font-size:15px;margin:0 0 34px}
  h2{font-size:13px;letter-spacing:.06em;text-transform:uppercase;color:var(--sub);
     margin:38px 0 12px;font-weight:600}
  .box{background:var(--card);border-radius:14px;padding:16px 18px;
       font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;
       word-break:break-all;user-select:all}
  ol{padding-left:20px;margin:0}
  ol li{margin:7px 0}
  table{width:100%;border-collapse:collapse;font-size:15px}
  th,td{text-align:left;padding:11px 6px;border-bottom:1px solid var(--line);vertical-align:top}
  th{color:var(--sub);font-weight:500;font-size:13px}
  td.cat{color:var(--sub);font-size:13px;white-space:nowrap}
  code{background:var(--card);border-radius:5px;padding:2px 6px;font-size:13px}
  a{color:var(--accent);text-decoration:none}
  a:hover{text-decoration:underline}

  .pkg{border:1px solid var(--line);border-radius:14px;padding:18px 20px;margin:14px 0}
  .pkg h3{margin:0 0 2px;font-size:18px}
  .pkg .ver{color:var(--sub);font-weight:400;font-size:13px;margin-left:8px}
  .pkg .tagline{color:var(--sub);font-size:14px;margin:0 0 10px}
  .pkg ul{margin:8px 0 12px;padding-left:20px;font-size:15px}
  .pkg ul li{margin:6px 0}
  .pkg dl{display:grid;grid-template-columns:64px 1fr;gap:4px 10px;
          margin:0;font-size:13px;color:var(--sub);
          border-top:1px solid var(--line);padding-top:10px}
  .pkg dt{font-weight:600}
  .pkg dd{margin:0}
  .pkg dd code{font-size:12px}
  .cat-head{margin:34px 0 4px;font-size:20px}
  .cat-head small{display:block;color:var(--sub);font-weight:400;font-size:13px;margin-top:2px}
  footer{margin-top:46px;color:var(--sub);font-size:13px}
</style>
</head>
<body>
<div class="wrap">
  <h1>g459416925 · iOS Tweaks</h1>
  <p class="sub">个人 iOS 越狱插件源 · RootHide 无根 · arm64e · iOS 16.x</p>

  <h2>源地址（Sileo 添加）</h2>
  <div class="box">__REPO__</div>

  <h2>安装步骤</h2>
  <ol>
    <li>Sileo → <b>软件源</b> → 右上角 <b>＋</b></li>
    <li>粘贴上面的地址 → <b>添加</b></li>
    <li>搜索插件名 → 安装</li>
  </ol>

  <h2>插件总表（按功能分类）</h2>
  <table>
    <tr><th>分类</th><th>插件</th><th>包名</th><th>版本</th></tr>
__TABLE__
  </table>

  <h2>插件详情</h2>

__SECTIONS__

  <h2>索引文件</h2>
  <p style="font-size:15px">
    <a href="./Release">Release</a> ·
    <a href="./Packages">Packages</a> ·
    <a href="./Packages.bz2">Packages.bz2</a> ·
    <a href="./depictions/">Sileo Depictions</a> ·
    <a href="__GH__">GitHub 仓库</a>
  </p>

  <footer>
    个人自用插件源，未经全面测试，仅供学习与自用。安装前请自行评估风险。
  </footer>
</div>
</body>
</html>
"""


def main():
    doc = (TPL.replace("__REPO__", REPO_URL)
              .replace("__TABLE__", total_table())
              .replace("__SECTIONS__", sections())
              .replace("__GH__", GH_URL))
    out = os.path.join(ROOT, "index.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(doc)
    print("完成：index.html（%d 包 / %d 分类，%d bytes）" % (len(PKGS), len(CATEGORIES), len(doc)))


if __name__ == "__main__":
    main()
