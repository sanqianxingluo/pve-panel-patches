#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 README.md 转成面板内的使用说明 pve-hwtools-doc.html

用法（在仓库根目录）：
    python3 tools/mkdoc.py

产出 pve-hwtools-doc.html：一段可直接塞进 ExtJS 窗口 html 配置的 HTML 片段。
由 install.sh 部署到 /usr/local/share/pve-hwtools/doc.html，再由节点接口
GET /nodes/{node}/hwhelp 读出来交给面板弹窗。

设计取舍：
  * 面板版只保留**用户手册**部分（装/用/配置/升级/卸载/FAQ），到
    `## 实现要点与踩坑` 之前截断 —— 变更日志与开发笔记对用户没用，还会让
    弹窗变得又长又难翻。
  * 全部 CSS 选择器都以 .pve-hwtools-doc 打头：ExtJS 是把这段 HTML 直接
    innerHTML 进面板的，不加作用域会把 h1/table 的样式泄漏到整个 PVE 界面。
  * 颜色一律用继承色 + 半透明灰，浅色/深色主题都能看（PVE 有多种主题）。
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "README.md"
OUT = ROOT / "pve-hwtools-doc.html"
CUT = "## 实现要点与踩坑"          # 面板版到此为止

CSS = """
.pve-hwtools-doc { line-height: 1.7; color: inherit; }
.pve-hwtools-doc h1 { font-size: 20px; margin: 0 0 6px; padding-bottom: 6px;
    border-bottom: 2px solid rgba(128,128,128,.35); }
.pve-hwtools-doc h2 { font-size: 17px; margin: 22px 0 8px; padding-bottom: 4px;
    border-bottom: 1px solid rgba(128,128,128,.25); }
.pve-hwtools-doc h3 { font-size: 15px; margin: 18px 0 6px; }
.pve-hwtools-doc h4 { font-size: 14px; margin: 14px 0 4px; }
.pve-hwtools-doc p, .pve-hwtools-doc li { margin: 5px 0; }
.pve-hwtools-doc ul, .pve-hwtools-doc ol { margin: 5px 0 5px 22px; padding: 0; }
.pve-hwtools-doc hr { border: 0; border-top: 1px solid rgba(128,128,128,.25); margin: 18px 0; }
.pve-hwtools-doc a { color: #1a67b3; text-decoration: none; }
.pve-hwtools-doc a:hover { text-decoration: underline; }
.pve-hwtools-doc code { font-family: Menlo, Consolas, "DejaVu Sans Mono", monospace;
    font-size: 12.5px; background: rgba(128,128,128,.16); padding: 1px 4px;
    border-radius: 3px; }
.pve-hwtools-doc pre { background: rgba(128,128,128,.13); border: 1px solid rgba(128,128,128,.25);
    border-radius: 4px; padding: 9px 11px; overflow-x: auto; margin: 8px 0; }
.pve-hwtools-doc pre code { background: none; padding: 0; font-size: 12.5px; }
.pve-hwtools-doc blockquote { margin: 8px 0; padding: 6px 12px;
    border-left: 3px solid rgba(128,128,128,.5); background: rgba(128,128,128,.08); }
.pve-hwtools-doc blockquote p { margin: 4px 0; }
.pve-hwtools-doc table { border-collapse: collapse; margin: 9px 0; width: auto;
    max-width: 100%; font-size: 13px; }
.pve-hwtools-doc th, .pve-hwtools-doc td { border: 1px solid rgba(128,128,128,.35);
    padding: 4px 9px; text-align: left; vertical-align: top; }
.pve-hwtools-doc th { background: rgba(128,128,128,.14); font-weight: 600; white-space: nowrap; }
.pve-hwtools-doc details { margin: 9px 0; }
.pve-hwtools-doc summary { cursor: pointer; font-weight: 600; margin-bottom: 5px; }
.pve-hwtools-doc strong { font-weight: 600; }
""".strip()


def main():
    if not SRC.exists():
        sys.exit("找不到 %s" % SRC)
    md = SRC.read_text(encoding="utf-8")

    if CUT in md:
        md = md.split(CUT)[0].rstrip() + "\n"
    else:
        print("警告：README 里没找到 %r，整篇转换（面板说明会偏长）" % CUT, file=sys.stderr)

    try:
        import markdown
    except ImportError:
        sys.exit("需要 python-markdown：pip install markdown")

    body = markdown.markdown(
        md,
        extensions=["tables", "fenced_code", "sane_lists", "md_in_html"],
        output_format="html",
    )

    html = (
        "<!-- 由 tools/mkdoc.py 从 README.md 生成，请勿手工编辑 -->\n"
        "<style>\n%s\n</style>\n"
        '<div class="pve-hwtools-doc">\n%s\n</div>\n' % (CSS, body)
    )
    OUT.write_text(html, encoding="utf-8")
    print("已生成 %s（%d 字节）" % (OUT.relative_to(ROOT), len(html.encode("utf-8"))))


if __name__ == "__main__":
    main()
