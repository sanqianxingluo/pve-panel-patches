#!/bin/bash
# pve-mirror-switch.sh —— PVE / Debian 软件源镜像一键切换
#
# 用法：
#   pve-mirror-switch.sh list              列出全部镜像（含各自的 Debian / 安全 / PVE 地址）
#   pve-mirror-switch.sh status            显示当前源（JSON，供面板读取）
#   pve-mirror-switch.sh set <镜像>        切换到指定镜像
#   pve-mirror-switch.sh probe             探测各镜像当前可达性（查询用，不参与切换）
#
# 设计要点：
#   * 发行版代号**现读** /etc/os-release，不写死 trixie——PVE 10 换到 forky 时无需改脚本。
#   * 只改「认得出的公共镜像」的那些行；自定义私有源（内网仓库等）原样保留。
#   * 首次接管前把原始源文件整份存到 $ORIGDIR，永不覆盖；每次改动另有时间戳快照。
#   * **切换本身不验证连通性**：只负责改写源文件。镜像通不通由用户判断，
#     随时可 `apt-get update` 自测。不把网络波动当作切换失败的理由。
#   * 支持经典格式（sources.list / *.list）与 deb822 格式（*.sources）两种写法。
set -u

# 便于测试：可用 PVE_MIRROR_ROOT 把所有路径重定向到沙盒
ROOT="${PVE_MIRROR_ROOT:-}"
APT="${ROOT}/etc/apt"
LIB="${ROOT}/usr/local/lib/pve-hwtools"
ORIGDIR="$LIB/apt-sources.orig"
STATE="$LIB/apt-mirror.state"
BK="${ROOT}/root/pve-upgrade-backup"

die() { echo "错误：$*" >&2; exit 1; }
say() { echo "$*"; }

need_root() { [ "$(id -u)" = 0 ] || die "需要 root 权限"; }

# ---------------------------------------------------------------- 镜像预设
# 格式：代号|显示名|Debian 主源|Debian 安全源|Proxmox 源
#
# 实测（2026-09-24，trixie）：
#   * 阿里云、腾讯云**根本没有 /proxmox/ 路径**（404），其 PVE 包只能走官方源。
#   * 华为云虽有该路径，但返回的 InRelease **签名无效**（`Clearsigned file isn't valid,
#     got 'NOSPLIT'`），apt 直接拒用 —— 其 PVE 也只能走官方源。
#   * 官方 download.proxmox.com 可用，但国内访问慢（实测约 44 秒抓一次索引）。
#   结论：只有中科大、清华镜像 Proxmox；其余国内站的 PVE 走官方源（Debian 仍走本地镜像，照样快）。
MIRRORS='ustc|中科大|https://mirrors.ustc.edu.cn/debian|https://mirrors.ustc.edu.cn/debian-security|https://mirrors.ustc.edu.cn/proxmox/debian/pve
tuna|清华大学|https://mirrors.tuna.tsinghua.edu.cn/debian|https://mirrors.tuna.tsinghua.edu.cn/debian-security|https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve
aliyun|阿里云|https://mirrors.aliyun.com/debian|https://mirrors.aliyun.com/debian-security|https://download.proxmox.com/debian/pve
tencent|腾讯云|https://mirrors.cloud.tencent.com/debian|https://mirrors.cloud.tencent.com/debian-security|https://download.proxmox.com/debian/pve
huawei|华为云|https://mirrors.huaweicloud.com/debian|https://mirrors.huaweicloud.com/debian-security|https://download.proxmox.com/debian/pve
official|官方源|https://deb.debian.org/debian|https://security.debian.org/debian-security|http://download.proxmox.com/debian/pve'

codename() {
  local c=""
  [ -r "${ROOT}/etc/os-release" ] && c=$(. "${ROOT}/etc/os-release" 2>/dev/null; echo "${VERSION_CODENAME:-}")
  printf '%s' "${c:-trixie}"
}

# 取某镜像的第 N 个字段（1=代号 2=名 3=主源 4=安全源 5=PVE源）
mirror_field() {
  local want="$1" n="$2" line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line%%|*}" = "$want" ] && { printf '%s' "$line" | cut -d'|' -f"$n"; return 0; }
  done <<EOF
$MIRRORS
EOF
  return 1
}

all_names()  { printf '%s\n' "$MIRRORS" | cut -d'|' -f1 | tr '\n' ' '; }
all_choices() { printf '%s\n' "$MIRRORS" | cut -d'|' -f1,2; }

# ---------------------------------------------------------------- 仓库识别
# 只认「我们知道的公共镜像」。自定义的私有源（内网 Nexus、自建仓库等）
# **一律原样保留**——否则会把不认识的 URL 硬改成公共镜像，等于删了人家的源。
# 判定依据是「以某个已知镜像基址开头」，而不是「路径里含有 debian 字样」。
KNOWN_BASES='https://mirrors.ustc.edu.cn/debian|debian
https://mirrors.ustc.edu.cn/debian-security|security
https://mirrors.ustc.edu.cn/proxmox/debian/pve|pve
https://mirrors.tuna.tsinghua.edu.cn/debian|debian
https://mirrors.tuna.tsinghua.edu.cn/debian-security|security
https://mirrors.tuna.tsinghua.edu.cn/proxmox/debian/pve|pve
https://mirrors.aliyun.com/debian|debian
https://mirrors.aliyun.com/debian-security|security
https://mirrors.cloud.tencent.com/debian|debian
https://mirrors.cloud.tencent.com/debian-security|security
https://mirrors.huaweicloud.com/debian|debian
https://mirrors.huaweicloud.com/debian-security|security
https://mirrors.huaweicloud.com/proxmox/debian/pve|pve
https://deb.debian.org/debian|debian
https://security.debian.org/debian-security|security
http://deb.debian.org/debian|debian
http://security.debian.org/debian-security|security
http://download.proxmox.com/debian/pve|pve
https://download.proxmox.com/debian/pve|pve
http://enterprise.proxmox.com/debian/pve|pve
https://enterprise.proxmox.com/debian/pve|pve'

base_for() {   # $1=镜像 $2=种类
  case "$2" in
    pve)      mirror_field "$1" 5 ;;
    security) mirror_field "$1" 4 ;;
    *)        mirror_field "$1" 3 ;;
  esac
}

# 给出 URL 属于哪一类公共仓库；不认识的返回空
url_kind() {
  local url="$1" line base kind
  # 长的先比，免得 /debian 抢在 /debian-security 前面
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    base="${line%|*}"; kind="${line##*|}"
    case "$url" in "$base"*) printf '%s' "$kind"; return 0 ;; esac
  done <<EOF
$(printf '%s\n' "$KNOWN_BASES" | awk -F'|' '{print length($1)"|"$0}' | sort -rn -t'|' -k1 | cut -d'|' -f2-)
EOF
  return 1
}

# 把一行里的 URL 换成目标镜像的对应 URL（保留原有结尾斜杠风格）。
# 认不出的 URL 返回失败，调用方应原样保留该行。
rewrite_url() {   # $1=镜像 $2=原 URL
  local kind new old="$2" slash=""
  kind=$(url_kind "$old") || return 1
  new=$(base_for "$1" "$kind") || return 1
  [ -n "$new" ] || return 1
  case "$old" in */) slash="/" ;; esac
  printf '%s%s' "$new" "$slash"
}

# ---------------------------------------------------------------- 内容改写
# 经典格式：deb [opts] URL suite comps...
rewrite_classic() {   # $1=镜像  $2=文件内容  -> stdout
  local want="$1" wrote=0 line pre url rest newurl
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) printf '%s\n' "$line"; continue ;;
    esac
    case "$line" in
      deb\ *|deb-src\ *)
        pre="${line%% *}"                       # deb / deb-src
        rest="${line#* }"
        # 跳过可能的 [arch=...] 选项块
        if [ "${rest#\[}" != "$rest" ]; then
          rest="${rest#*] }"
        fi
        url="${rest%% *}"
        rest="${rest#* }"                       # suite + comps
        if newurl=$(rewrite_url "$want" "$url"); then
          printf '%s %s %s\n' "$pre" "$newurl" "$rest"; wrote=1
        else
          printf '%s\n' "$line"
        fi
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

# deb822 格式：URIs: https://...  （可能多行、多个 URL）
rewrite_deb822() {   # $1=镜像  $2=文件内容  -> stdout
  local want="$1" line out="" u newu first
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      URIs:*|uris:*)
        out="${line%%:*}:"
        for u in ${line#*:}; do
          if newu=$(rewrite_url "$want" "$u"); then out="$out $newu"; else out="$out $u"; fi
        done
        printf '%s\n' "$out"
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done
}

rewrite_any() {   # $1=镜像 $2=文件
  case "$2" in
    *.sources) rewrite_deb822 "$1" < "$2" ;;
    *)         rewrite_classic "$1" < "$2" ;;
  esac
}

# ---------------------------------------------------------------- 源文件清单
# 要接管的文件：经典 .list 与 sources.list、deb822 .sources
target_files() {
  [ -f "$APT/sources.list" ] && printf '%s\n' "$APT/sources.list"
  for f in "$APT"/sources.list.d/*.list "$APT"/sources.list.d/*.sources; do
    [ -f "$f" ] || continue
    # 企业订阅源不镜像、且无订阅时必然 401 —— 由本脚本负责停用，不作为切换目标
    case "$f" in *pve-enterprise*) continue ;; esac
    printf '%s\n' "$f"
  done
}

# 备份：原始件只存一次（永不覆盖）；每次改动另存时间戳快照
snapshot_originals() {
  mkdir -p "$ORIGDIR"
  local f
  while IFS= read -r f; do
    local key; key=$(printf '%s' "$f" | sed "s#^$ROOT##; s#/#_#g; s#^_##")
    [ -f "$ORIGDIR/$key" ] || cp -a "$f" "$ORIGDIR/$key"
  done <<EOF
$(target_files)
EOF
}

# 停用企业订阅源（无订阅时 apt update 必报 401）
disable_enterprise() {
  local f moved=0
  for f in "$APT"/sources.list.d/*pve-enterprise*; do
    [ -f "$f" ] || continue
    case "$f" in *.disabled) continue ;; esac
    mkdir -p "$BK"
    cp -a "$f" "$BK/$(basename "$f").disabled" 2>/dev/null || true
    mv "$f" "$f.disabled"
    say "    已停用企业订阅源：$(basename "$f") → $(basename "$f").disabled（备份在 $BK/）"
    moved=1
  done
  return 0
}

# ---------------------------------------------------------------- 当前镜像识别
detect_current() {
  local f url hit="" name base
  # 优先看 PVE 源（最能代表整套预设），再看 Debian 主源
  while IFS= read -r f; do
    while read -r url; do
      [ -n "$url" ] || continue
      [ "$(url_kind "$url" 2>/dev/null)" = "pve" ] || continue
      hit="$url"; break
    done <<EOF
$(grep -ohE 'https?://[^ ]+' "$f" 2>/dev/null)
EOF
    [ -n "$hit" ] && break
  done <<EOF
$(target_files)
EOF
  if [ -z "$hit" ]; then
    while IFS= read -r f; do
      while read -r url; do
        [ -n "$url" ] || continue
        [ "$(url_kind "$url" 2>/dev/null)" = "debian" ] || continue
        hit="$url"; break
      done <<EOF
$(grep -ohE 'https?://[^ ]+' "$f" 2>/dev/null)
EOF
      [ -n "$hit" ] && break
    done <<EOF
$(target_files)
EOF
  fi
  [ -n "$hit" ] || { printf 'unknown'; return; }
  for name in $(all_names); do
    base=$(mirror_field "$name" 5)
    case "$hit" in "$base"*) printf '%s' "$name"; return ;; esac
  done
  for name in $(all_names); do
    base=$(mirror_field "$name" 3)
    case "$hit" in "$base"*) printf '%s' "$name"; return ;; esac
  done
  printf 'custom'
}

# ---------------------------------------------------------------- 应用
do_set() {   # $1=镜像代号
  local want="$1"
  mirror_field "$want" 1 >/dev/null 2>&1 || die "未知镜像「$want」。可用：$(all_names)"

  local co; co=$(codename)
  local files; files=$(target_files)
  [ -n "$files" ] || die "找不到任何软件源文件（$APT/sources.list 或 $APT/sources.list.d/*.list）"

  snapshot_originals

  # 舞台区：先写临时件，验证通过再落盘
  local stage; stage=$(mktemp -d)
  local f out rel
  while IFS= read -r f; do
    out="$stage/$(basename "$f")"
    rewrite_any "$want" "$f" > "$out" || { rm -rf "$stage"; die "改写失败：$f"; }
    # 校验**只在确实改过此文件时**做。
    # 不可对所有文件都要求含发行版代号——私有源（如 `deb http://内网/ repo main`）
    # 的套件名根本不是代号，那样会被误判为「改写跑偏」而中断整个切换。
    if ! cmp -s "$f" "$out"; then
      grep -q "$co" "$out" || { rm -rf "$stage"; die "改写后未出现发行版套件「$co」，已中止（文件：$f）"; }
    fi
    printf '%s\t%s\n' "$f" "$out" >> "$stage/.manifest"
  done <<EOF
$files
EOF

  # 展示将要发生的改动
  say "  即将改写："
  while IFS=$'\t' read -r rel out; do
    local before after
    before=$(grep -ohE 'https?://[^ ]+' "$rel" 2>/dev/null | head -1)
    after=$(grep -ohE 'https?://[^ ]+' "$out" 2>/dev/null | head -1)
    if [ "$before" = "$after" ]; then
      say "    $(basename "$rel")：已是目标镜像，无变化"
    else
      say "    $(basename "$rel")：$before → $after"
    fi
  done < "$stage/.manifest"

  # 时间戳快照，便于手工回退
  mkdir -p "$BK"
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BK/apt-sources-$ts"
  while IFS=$'\t' read -r rel out; do cp -a "$rel" "$BK/apt-sources-$ts/$(basename "$rel")"; done < "$stage/.manifest"

  # 落盘（原子替换）
  local restore_needed=0
  while IFS=$'\t' read -r rel out; do
    cat "$out" > "$rel" || { restore_needed=1; break; }
  done < "$stage/.manifest"

  if [ "$restore_needed" = 1 ]; then
    while IFS=$'\t' read -r rel out; do cp -a "$BK/apt-sources-$ts/$(basename "$rel")" "$rel"; done < "$stage/.manifest"
    rm -rf "$stage"
    die "写入失败，已回滚"
  fi

  disable_enterprise

  # 不做连通性验证——本功能只负责改写源，不管目标站能不能连上。
  # 理由：镜像可达性会随时间波动，把它当判据会让「切换」动不动就失败回滚；
  # 而且用户可能明知某镜像暂时不通、仍要先切过去。是否可用交给用户判断。
  mkdir -p "$LIB"
  { echo "preset=$want"; echo "applied_at=$(date -Is)"; } > "$STATE"
  rm -rf "$stage"
  say "  ✅ 已切换到 $(mirror_field "$want" 2)（$want）"
  say "     提示：未做连通性检查。要确认能否使用，可执行 apt-get update。"
}

# ---------------------------------------------------------------- 命令实现
cmd_list() {
  local name disp d s p
  say "可用镜像："
  for name in $(all_names); do
    disp=$(mirror_field "$name" 2); d=$(mirror_field "$name" 3)
    s=$(mirror_field "$name" 4);    p=$(mirror_field "$name" 5)
    say "  $name  $disp"
    say "      Debian: $d"
    say "      安全源: $s"
    say "      PVE:    $p"
  done
}

cmd_status() {
  local cur preset; cur=$(detect_current)
  preset=""
  [ -f "$STATE" ] && preset=$(. "$STATE" 2>/dev/null; printf '%s' "${preset:-}")
  printf '{"apt_mirror":"%s","apt_mirror_detected":"%s","apt_mirror_applied_at":"%s","apt_codename":"%s"}\n' \
    "${preset:-$cur}" "$cur" \
    "$([ -f "$STATE" ] && . "$STATE" 2>/dev/null; printf '%s' "${applied_at:-}")" \
    "$(codename)"
}

cmd_probe() {
  local co; co=$(codename)
  local name d s p code
  say "镜像可达性探测（发行版代号 $co）："
  for name in $(all_names); do
    disp=$(mirror_field "$name" 2); d=$(mirror_field "$name" 3)
    s=$(mirror_field "$name" 4);    p=$(mirror_field "$name" 5)
    printf '  %-8s %s\n' "$name" "$disp"
    for pair in "Debian:$d" "安全源:$s" "PVE:$p"; do
      local label="${pair%%:*}" url="${pair#*:}"
      case "$label" in
        Debian|PVE) code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$url/dists/$co/Release" 2>/dev/null) ;;
        安全源)     code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$url/dists/${co}-security/Release" 2>/dev/null) ;;
      esac
      if [ "$code" = "200" ]; then printf '      %-7s ✅ %s\n' "$label" "$code"
      else                          printf '      %-7s ✗ %s  %s\n' "$label" "${code:-超时}" "$url"; fi
    done
  done
}

case "${1:-status}" in
  list)   cmd_list ;;
  status) cmd_status ;;
  probe)  need_root; cmd_probe ;;
  set)    need_root; shift; [ $# -ge 1 ] || die "用法：pve-mirror-switch.sh set <镜像代号>"; do_set "$1" ;;
  *)      die "用法：pve-mirror-switch.sh {list|status|probe|set <镜像>}" ;;
esac
