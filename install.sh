#!/bin/bash
# pve-hwtools-install.sh —— PVE 面板补丁集 一键部署 / 卸载
# 版本：V1.0
#
# 用法（须 root）：
#   bash install.sh                 # 安装（幂等，可反复跑）
#   bash install.sh --uninstall     # 卸载：摘钩子、还原原厂文件、清补丁
#   bash install.sh --ref v2.1      # 指定版本（默认 main）
#   bash install.sh --no-deps       # 跳过依赖安装
#   bash install.sh --help
#
# 亦可直接管道执行：
#   curl -fsSL https://raw.githubusercontent.com/sanqianxingluo/pve-panel-patches/main/install.sh | bash
#
# 部署内容：
#   /usr/local/bin/pve-hwpatch.sh      概要硬件信息 + PVE 工具集设置页（打补丁）
#   /usr/local/bin/pve-hwtools-agent   状态代理（配置读写 / 调频 / 重渲染）
#   /usr/local/bin/pve-nosub-patch.sh  订阅提示屏蔽（双向可逆）
#   /usr/local/bin/pve-mirror-switch.sh 软件源镜像切换（Debian / Proxmox）
#   /etc/apt/apt.conf.d/98-pve-hwpatch       apt 钩子：升级后自动重打
#   /etc/apt/apt.conf.d/99-pve-nosub-patch   apt 钩子：同上
# 由 pve-hwpatch.sh 自行落盘（无需手工放）：
#   /usr/bin/s.sh、/usr/local/lib/pve-hwtools/cpu-model.sh、
#   /etc/default/pve-hwtools、/etc/systemd/system/pve-hwtools-apply.service
# 使用说明（面板里「使用说明」按钮弹出的那份）：
#   /usr/local/lib/pve-hwtools/doc.html —— 来自仓库的 pve-hwtools-doc.html；
#   在 git 工作副本里若装了 python-markdown，则改由 tools/mkdoc.py 从 README.md 现生成。

set -u

REPO="sanqianxingluo/pve-panel-patches"
REF="${PVE_HWTOOLS_REF:-main}"
FILES="pve-hwpatch.sh pve-hwtools-agent pve-nosub-patch.sh pve-mirror-switch.sh"
# 说明书是数据文件（不执行），单独下载：不进 FILES 的语法检查与 SHA256 清单，
# 缺了只影响面板上那个按钮，不该让整个安装失败。
DOCFILE="pve-hwtools-doc.html"
DEST=/usr/local/bin
HWDEST=/usr/local/lib/pve-hwtools
BK=/root/pve-upgrade-backup
HOOK98=/etc/apt/apt.conf.d/98-pve-hwpatch
HOOK99=/etc/apt/apt.conf.d/99-pve-nosub-patch
SVC=pve-hwtools-apply.service

MODE=install
WITH_DEPS=1

say() { echo "  $*"; }
step() { echo; echo "== $* =="; }
die() { echo; echo "错误：$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --uninstall|-u) MODE=uninstall ;;
    --no-deps)      WITH_DEPS=0 ;;
    --ref)          shift; [ $# -gt 0 ] || die "--ref 后面要给版本号" ; REF="$1" ;;
    --help|-h)
      cat <<'USAGE'
pve-hwtools-install.sh —— PVE 面板补丁集 一键部署 / 卸载

用法（须 root）：
  bash install.sh                 # 安装（幂等，可反复跑）
  bash install.sh --uninstall     # 卸载：摘钩子、还原原厂文件、清补丁
  bash install.sh --ref v2.1      # 指定版本（默认 main）
  bash install.sh --no-deps       # 跳过依赖安装
  bash install.sh --help

亦可直接管道执行：
  curl -fsSL https://raw.githubusercontent.com/sanqianxingluo/pve-panel-patches/main/install.sh | bash

部署内容：
  /usr/local/bin/pve-hwpatch.sh      概要硬件信息 + PVE 工具集设置页（打补丁）
  /usr/local/bin/pve-hwtools-agent   状态代理（配置读写 / 调频 / 重渲染）
  /usr/local/bin/pve-nosub-patch.sh  订阅提示屏蔽（双向可逆）
  /etc/apt/apt.conf.d/98-pve-hwpatch       钩子：升级后自动重打
  /etc/apt/apt.conf.d/99-pve-nosub-patch   钩子：同上
由 pve-hwpatch.sh 自行落盘（无需手工放）：
  /usr/bin/s.sh、/usr/local/lib/pve-hwtools/cpu-model.sh、
  /etc/default/pve-hwtools、/etc/systemd/system/pve-hwtools-apply.service
使用说明（面板「使用说明」按钮弹出的那份）：
  /usr/local/lib/pve-hwtools/doc.html —— 来自仓库的 pve-hwtools-doc.html

卸载不会删除 /etc/default/pve-hwtools 与 /root/pve-upgrade-backup（留作回退）。
USAGE
      exit 0 ;;
    *) die "未知参数：$1（--help 看用法）" ;;
  esac
  shift
done

# ---------- 前置检查 ----------
[ "$(id -u)" -eq 0 ] || die "必须以 root 运行（试试 sudo bash install.sh）"
[ -d /usr/share/pve-manager ] || die "没找到 PVE：/usr/share/pve-manager 不存在。本补丁只适用于 Proxmox VE。"

PVEVER=$(pveversion 2>/dev/null | sed 's|^pve-manager/||; s|/.*||' || echo "未知")
case "$PVEVER" in
  9.*) : ;;
  未知) say "警告：探不到 pveversion，继续但请自行确认是 PVE 9.x" ;;
  *)   say "警告：检测到 PVE $PVEVER，本补丁在 9.2 上实测通过。"
       say "      跨大版本时锚点可能失配——脚本会自己报错并回滚，不会把面板改坏。" ;;
esac

# ---------- 卸载 ----------
if [ "$MODE" = uninstall ]; then
  step "卸载 PVE 面板补丁集"
  say "[1] 摘除 apt 钩子"
  rm -f "$HOOK98" "$HOOK99"
  say "    已删 $HOOK98"
  say "    已删 $HOOK99"

  say "[2] 停用并移除开机应用单元"
  systemctl disable --now "$SVC" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$SVC"
  systemctl disable --now pve-hwtools-smart.timer >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/pve-hwtools-smart.timer /etc/systemd/system/pve-hwtools-smart.service
  systemctl daemon-reload >/dev/null 2>&1 || true

  say "[3] 还原被改的 PVE 原厂文件"
  N=/usr/share/perl5/PVE/API2/Nodes.pm
  J=/usr/share/pve-manager/js/pvemanagerlib.js
  W=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
  # 还原方式有两层，先试更强的那层：
  #   ① 重装包 —— 唯一能 100% 回到**当前版本**原厂内容的办法（含面板高度等
  #      标记块外的改动）。但需要网络能取到 .deb。
  #   ② 剥离注入 —— 无需网络：删掉所有 BEGIN/END 标记块、把面板高度复位成原厂值。
  # 绝不能盲信 *.bak.hwpatch：它可能是上一代大版本的原厂件（本机 8.4.19 的备份
  # vs 现役 9.2.20），用它覆盖会让 PVE 核心文件版本错乱、pvedaemon 起不来。
  if DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y pve-manager proxmox-widget-toolkit >/dev/null 2>&1; then
    say "    已重装 pve-manager + proxmox-widget-toolkit，回到当前版本原厂"
  else
    say "    重装失败（多半是网络），改用剥离注入块的方式还原"
    python3 - "$N" "$J" <<'PY'
import re, sys
N, J = sys.argv[1], sys.argv[2]
# 后端：删掉整段注入
s = open(N, encoding='utf-8', errors='surrogateescape').read()
s = re.sub(r"\n *# PVE_HWPATCH\n[^\n]*\n", "", s)
s = re.sub(r"\n# PVE_HWAPI:BEGIN.*?# PVE_HWAPI:END\n", "", s, flags=re.S)
open(N, 'w', encoding='utf-8', errors='surrogateescape').write(s)
# 前端：先删各专属块，再删文件末尾的设置页大块，最后复位面板高度。
# 注意标记是「PVE_HWUI:MENU:BEGIN」这种带 PVE_ 前缀的全名——漏掉前缀就一条也剥不掉。
s = open(J, encoding='utf-8', errors='surrogateescape').read()
s = re.sub(r"\n[ \t]*// PVE_HWPATCH:BEGIN.*?// PVE_HWPATCH:END", "", s, flags=re.S)
s = re.sub(r"\n[ \t]*// PVE_HWUI:HOME:BEGIN.*?// PVE_HWUI:HOME:END", "", s, flags=re.S)
s = re.sub(r"\n[ \t]*// PVE_HWUI:MENU:BEGIN.*?// PVE_HWUI:MENU:END", "", s, flags=re.S)
# 概要条目：插入在 items 末尾、只有单标记 // PVE_HWPATCH，一直删到数组收尾
s = re.sub(r"\n[ \t]*// PVE_HWPATCH\n.*?\n    \],", "\n    ],", s, flags=re.S)
# 设置页大块（追加在文件末尾）
s = re.sub(r"\n// PVE_HWUI:BEGIN.*?// PVE_HWUI:END", "", s, flags=re.S)
# 面板高度复位成原厂值（这一处改动在标记块之外）
s = re.sub(r"(alias: 'widget\.pveNodeStatus',\n\n    height: )\d+(,)", r"\g<1>350\g<2>", s, count=1)
# 设置页块原本是追加在文件末尾的，剥掉后会多出空行——收尾规范化，与原厂一致
s = s.rstrip() + "\n"
open(J, 'w', encoding='utf-8', errors='surrogateescape').write(s)
# 后端同样收尾规范化
s = open(N, encoding='utf-8', errors='surrogateescape').read().rstrip() + "\n"
open(N, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print("    已剥离注入块并复位面板高度")
PY
    perl -c "$N" >/dev/null 2>&1 && say "    perl 语法校验通过" || say "    ⚠ perl 语法有问题，建议重装 pve-manager"
  fi
  say "[4] 关闭订阅提示屏蔽（改配置为 0 并重跑一次以恢复原厂行为）"
  if [ -f /etc/default/pve-hwtools ]; then
    sed -i 's/^BLOCK_SUBSCRIPTION_PROMPT=1/BLOCK_SUBSCRIPTION_PROMPT=0/' /etc/default/pve-hwtools
    [ -x "$DEST/pve-nosub-patch.sh" ] && "$DEST/pve-nosub-patch.sh" >/dev/null 2>&1 && say "    已恢复原厂订阅提示"
  fi

  say "[5] 删除补丁文件"
  rm -f "$DEST/pve-hwpatch.sh" "$DEST/pve-hwtools-agent" "$DEST/pve-nosub-patch.sh" "$DEST/pve-mirror-switch.sh"
  rm -f /usr/local/bin/pve-hwtools-smart /run/pve-hwtools-smart.txt
  rm -f /usr/bin/s.sh
  rm -rf "$HWDEST"
  find /usr/share/pve-manager /usr/share/perl5 -name '*.orig.hwpatch' -delete 2>/dev/null || true
  say "    已删四个补丁脚本 + SMART 采集器 + /usr/bin/s.sh + $HWDEST（含使用说明 doc.html）"

  say "[6] 重启服务"
  systemctl restart pvedaemon pveproxy 2>/dev/null || true
  say "    已重启 pvedaemon + pveproxy"

  echo
  echo "卸载完成。配置 /etc/default/pve-hwtools 与备份 $BK 已保留（要彻底清除可自行删）。"
  exit 0
fi

# ---------- 安装 ----------
step "PVE 面板补丁集 一键安装"
say "PVE 版本：$PVEVER"
say "来源分支：$REF"

# 1) 取文件：本地有就用本地的，否则下载（支持 curl | bash）
step "[1/7] 获取脚本"
SRC=""
SELFDIR=$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || echo "")
if [ -n "$SELFDIR" ] && [ -f "$SELFDIR/pve-hwpatch.sh" ]; then
  SRC="$SELFDIR"
  say "使用本地文件：$SRC"
else
  SRC=$(mktemp -d)
  RAW="https://raw.githubusercontent.com/$REPO/$REF"
  say "本地无脚本，从 $RAW 下载"
  for f in $FILES; do
    curl -fsSL "$RAW/$f" -o "$SRC/$f" || die "下载失败：$RAW/$f（检查网络，或先 git clone 再本地运行）"
    say "    ↓ $f"
  done
  # 说明书：非必需，下载不到只警告（面板那个按钮会提示缺文件）
  if curl -fsSL "$RAW/$DOCFILE" -o "$SRC/$DOCFILE" 2>/dev/null; then
    say "    ↓ $DOCFILE"
  else
    say "    （$DOCFILE 未取到，面板「使用说明」按钮将不可用）"
  fi
  # 有 SHA256SUMS 就核对，防截断/篡改
  if curl -fsSL "$RAW/SHA256SUMS" -o "$SRC/SHA256SUMS" 2>/dev/null; then
    if (cd "$SRC" && sha256sum -c --quiet SHA256SUMS 2>/dev/null); then
      say "    校验和 OK"
    else
      die "校验和不符——下载可能被截断或篡改，已中止"
    fi
  else
    say "    （上游无 SHA256SUMS，跳过校验）"
  fi
fi
for f in $FILES; do
  bash -n "$SRC/$f" || die "$f 语法有误，中止"
done
say "三个脚本语法检查通过"

# 2) 依赖
step "[2/7] 依赖"
if [ "$WITH_DEPS" -eq 1 ]; then
  DEPS="lm-sensors smartmontools cpufrequtils linux-cpupower python3"
  MISSING=""
  for p in $DEPS; do
    dpkg-query -Wf '${Status}' "$p" 2>/dev/null | grep -q "installed" || MISSING="$MISSING $p"
  done
  if [ -n "$MISSING" ]; then
    say "安装缺失依赖：$MISSING"
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y $MISSING >/dev/null 2>&1 \
      || say "警告：apt 安装未全部成功，可稍后手工补装"
  else
    say "依赖已齐（lm-sensors / smartmontools / cpufrequtils / linux-cpupower / python3）"
  fi
else
  say "已按 --no-deps 跳过"
fi

# 3) 部署脚本
step "[3/7] 部署脚本到 $DEST"
for f in $FILES; do
  install -m 755 "$SRC/$f" "$DEST/$f" || die "安装 $f 失败"
  say "    $DEST/$f"
done

# 3b) 使用说明（面板「使用说明」按钮弹出的那份）
#     在 git 工作副本里若装了 python-markdown，就从 README.md 现生成 ——
#     保证面板里的说明永远和仓库 README 同源，不会各改各的。
say "    使用说明 -> $HWDEST/doc.html"
mkdir -p "$HWDEST"
DOCSRC=""
if [ -f "$SRC/tools/mkdoc.py" ] && [ -f "$SRC/README.md" ]; then
  if (cd "$SRC" && python3 tools/mkdoc.py >/dev/null 2>&1) && [ -s "$SRC/$DOCFILE" ]; then
    DOCSRC="$SRC/$DOCFILE"
    say "    （已由 tools/mkdoc.py 从 README.md 现生成）"
  fi
fi
[ -n "$DOCSRC" ] || DOCSRC="$SRC/$DOCFILE"
if [ -f "$DOCSRC" ] && [ -s "$DOCSRC" ]; then
  install -m 644 "$DOCSRC" "$HWDEST/doc.html"
else
  say "    ⚠ 没取到 $DOCFILE —— 面板「使用说明」按钮将提示缺文件（其余功能不受影响）"
fi

# 4) apt 钩子
step "[4/7] 挂 apt 钩子（升级后自动重打）"
printf 'DPkg::Post-Invoke { "%s/pve-hwpatch.sh"; };\n' "$DEST" > "$HOOK98"
printf 'DPkg::Post-Invoke { "%s/pve-nosub-patch.sh"; };\n' "$DEST" > "$HOOK99"
say "$HOOK98"
say "$HOOK99"
if apt-config dump 2>/dev/null | grep -q "98-pve-hwpatch\|pve-hwpatch.sh"; then
  say "apt 已读到钩子"
else
  say "警告：apt 未读到钩子，请检查 $HOOK98 内容"
fi

# 5) 打补丁
step "[5/7] 施加补丁"
"$DEST/pve-hwpatch.sh" || die "补丁脚本失败（上面有报错；原厂文件已自动回滚，面板不会坏）"

# 6) 传感器探测
step "[6/7] 传感器"
if sensors 2>/dev/null | grep -qE "°C|RPM"; then
  say "sensors 已有读数，跳过探测"
else
  if [ -x /usr/sbin/sensors-detect ]; then
    say "首次使用，运行 sensors-detect --auto（约需数十秒）"
    /usr/sbin/sensors-detect --auto >/dev/null 2>&1 || say "警告：sensors-detect 未完全成功，温度可能不全"
    say "完成"
  else
    say "警告：没有 sensors-detect，请手工确认传感器已探测"
  fi
fi

# 7) 自检
step "[7/7] 自检"
FAIL=0
chk() { if eval "$2" >/dev/null 2>&1; then say "✅ $1"; else say "❌ $1"; FAIL=$((FAIL+1)); fi; }
chk "补丁脚本就位"        "[ -x $DEST/pve-hwpatch.sh ]"
chk "状态代理就位"        "[ -x $DEST/pve-hwtools-agent ]"
chk "订阅屏蔽脚本就位"    "[ -x $DEST/pve-nosub-patch.sh ]"
chk "镜像切换脚本就位"    "[ -x $DEST/pve-mirror-switch.sh ]"
chk "取样脚本 /usr/bin/s.sh 就位" "[ -f /usr/bin/s.sh ]"
chk "SMART 采集器就位"    "[ -x /usr/local/bin/pve-hwtools-smart ]"
chk "SMART 采集定时器已启用" "systemctl is-enabled --quiet pve-hwtools-smart.timer"
chk "CPU 世代映射就位"    "[ -f $HWDEST/cpu-model.sh ]"
chk "配置 /etc/default/pve-hwtools 就位" "[ -f /etc/default/pve-hwtools ]"
chk "后端已注入 Nodes.pm" "grep -q PVE_HWAPI /usr/share/perl5/PVE/API2/Nodes.pm"
chk "前端已注入 pvemanagerlib.js" "grep -q 'PVE_HWUI:BEGIN' /usr/share/pve-manager/js/pvemanagerlib.js"
chk "使用说明 doc.html 就位" "[ -s $HWDEST/doc.html ]"
chk "pvedaemon 正常"      "systemctl is-active --quiet pvedaemon"
chk "pveproxy 正常"       "systemctl is-active --quiet pveproxy"

if [ -f /usr/bin/s.sh ]; then
  echo
  say "实取硬件数据："
  /usr/bin/s.sh 2>/dev/null | sed 's/^/      /' || say "    （取样脚本无输出，检查 lm-sensors）"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  cat <<'EOM'
安装完成 ✅

接下来：
  1. 浏览器登录 PVE → 刷新页面（Ctrl+Shift+R 强刷一次）
  2. 点左侧资源树里的节点 → 左菜单 Summary  → 右侧出现「硬件概要」
  3. 点左菜单 System → PVE 工具集  → 开关显示项、设置 CPU 调频与频率上下限

卸载：bash install.sh --uninstall
EOM
else
  echo "安装基本完成，但有 $FAIL 项自检未通过（见上）。请把上面输出发出来以便排查。"
fi
