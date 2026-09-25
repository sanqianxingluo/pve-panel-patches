#!/bin/bash
# pve-hwpatch.sh —— PVE 面板工具集（硬件概要 + CPU 调频 + 订阅提示屏蔽）
# 版本：V2.4
#
# 注入三样，全部幂等、可自愈：
#   1) 节点概要的「硬件概要」区块（温度 / 风扇 / 硬盘 / 频率）——四项可分别开关
#   2) 节点左菜单新增「PVE 工具集」页：显示开关、CPU 调频模式与频率上下限、订阅提示屏蔽
#   3) 节点级 API /nodes/{node}/hwtools（GET 读状态 / PUT 写配置），由 pve-hwtools-agent 落地
#
# 唯一的配置真相： /etc/default/pve-hwtools
# 权限代理：       /usr/local/bin/pve-hwtools-agent
# CPU 世代映射：   /usr/local/lib/pve-hwtools/cpu-model.sh（s.sh 与 agent 共用）
#
# 注入点（各有 BEGIN/END 标记，重复执行只替换不叠加）：
#   /usr/share/perl5/PVE/API2/Nodes.pm            —— PVE_HWPATCH（tdata）+ PVE_HWAPI（hwtools）
#   /usr/share/pve-manager/js/pvemanagerlib.js    —— PVE_HWPATCH（概要条目）
#                                                    PVE_HWUI:HOME（渲染后按配置隐藏）
#                                                    PVE_HWUI:MENU（左菜单项）
#                                                    PVE_HWUI（设置页 + 隐藏逻辑，追加于文件末尾）
#   /usr/bin/s.sh                                 —— 取样脚本
#
# 显示开关的实现方式：条目照旧全部注入，等面板渲染完再按配置隐藏对应行。
#   之所以不在构造时就决定注入哪些条目——items 是 ExtJS 的原型属性（数组字面量赋给了原型），
#   直接 push 会污染 PVE.node.StatusView 原型，波及全部实例。
#
# 特性：幂等；失败自动回滚；改前后做语法预检（perl -c / node --check）。
#
# 依赖：lm-sensors（必需）、smartmontools（可选）、linux-cpupower（调频必需）、python3
set -u
MARK=PVE_HWPATCH
CONF=/etc/default/pve-hwtools
AGENT=/usr/local/bin/pve-hwtools-agent
J=/usr/share/pve-manager/js/pvemanagerlib.js
N=/usr/share/perl5/PVE/API2/Nodes.pm
SH=/usr/bin/s.sh
CPUDBDIR=/usr/local/lib/pve-hwtools
CPUDB="$CPUDBDIR/cpu-model.sh"
MIRROR=/usr/local/bin/pve-mirror-switch.sh
BK=/root/pve-upgrade-backup
mkdir -p "$BK"
changed=0
backend_changed=0

# ---------- 0) 配置文件（缺省全套）----------
if [ ! -f "$CONF" ]; then
  cat > "$CONF" <<'EOC'
# PVE 工具集配置 —— 由面板「PVE 工具集」页生成，也可手工编辑
# 改后执行： /usr/local/bin/pve-hwtools-agent apply
#
# 概要显示开关（1 开 / 0 关）
SHOW_CPU_TEMP=1
SHOW_FAN=1
SHOW_DISK=1
SHOW_CPU_FREQ=1
#
# 屏蔽「无有效订阅」弹窗
BLOCK_SUBSCRIPTION_PROMPT=1
#
# CPU 调频（频率单位 **MHz**；范围须落在硬件能力内）
CPU_GOVERNOR=conservative
CPU_FREQ_MIN=800
CPU_FREQ_MAX=3800
# Turbo 加速（1 启用 / 0 关闭；本机不支持时忽略）
CPU_TURBO=1
# 能效偏好 EPP（仅部分新平台支持）
CPU_EPP=balance_performance
#
ustc 中科大 / tuna 清华 / aliyun 阿里云 / tencent 腾讯云 / huawei 华为云 / official 官方源
APT_MIRROR=ustc
EOC
  chmod 644 "$CONF"; changed=1; echo "  [0] 已建 $CONF"
else
  echo "  [0] $CONF 已存在，保留"
  # 升级迁移：老配置里没有的键补上（幂等；只加不改，绝不覆盖用户已设的值）
  for kv in "APT_MIRROR=ustc"; do
    k="${kv%%=*}"
    if ! grep -qE "^[[:space:]]*$k=" "$CONF"; then
      printf '\n# 软件源镜像（ustc 中科大 / tuna 清华 / aliyun 阿里云 / tencent 腾讯云 / huawei 华为云 / official 官方源）\n%s\n' "$kv" >> "$CONF"
      changed=1; echo "  [0] 已补默认项 $k 到 $CONF"
    fi
  done
fi

# ---------- 0b) 订阅提示屏蔽：按配置执行（可屏蔽、可恢复）----------
NOSUB=/usr/local/bin/pve-nosub-patch.sh
if [ -x "$NOSUB" ]; then
  "$NOSUB" >/dev/null 2>&1
  echo "  [0b] 订阅提示屏蔽已按配置执行（当前：$("$NOSUB" status 2>/dev/null | tr '\n' ' '))"
else
  echo "  [0b] 警告：$NOSUB 不存在，订阅提示屏蔽未处理" >&2
fi

# ---------- 0.5) CPU 世代映射（s.sh 与 agent 共用一份，避免两处走偏）----------
mkdir -p "$CPUDBDIR"
if [ ! -f "$CPUDB" ] || ! grep -q "^# cpu-model.sh v1" "$CPUDB" 2>/dev/null; then
  [ ! -f "$CPUDB.orig" ] && [ -f "$CPUDB" ] && cp -a "$CPUDB" "$CPUDB.orig"
  cat > "$CPUDB" <<'EOCPU'
#!/bin/bash
# cpu-model.sh v1 —— CPUID 家族/型号 → 微架构代号 的映射（共享片段）
#
# 数据来源（权威）：
#   Intel：Linux 内核 arch/x86/include/asm/intel-family.h 的 INTEL_FAM6_* 型号表
#   AMD  ：Linux 内核 arch/x86/kernel/cpu/amd.c 的 Zen 世代判定 + 内核文档（k10temp 等）
# 覆盖 2000 年至今主流 Intel/AMD 桌面与移动处理器；未收录者回退为「family/model」。
#
# 用法： . /usr/local/lib/pve-hwtools/cpu-model.sh ; cpu_gen
# 依赖： /proc/cpuinfo

cpu_vendor() { grep -m1 '^vendor_id' /proc/cpuinfo 2>/dev/null | awk '{print $3}'; }
cpu_fam()    { grep -m1 '^cpu family' /proc/cpuinfo 2>/dev/null | awk '{print $4}'; }
cpu_mod()    { grep -m1 '^model' /proc/cpuinfo 2>/dev/null | head -1 | sed 's/^model[[:space:]]*:[[:space:]]*//'; }
cpu_brand()  { grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | sed 's/^model name[[:space:]]*:[[:space:]]*//'; }

intel_gen() {
  local m=$1
  case "$m" in
        1) printf '%s' "Pentium Pro" ;;
        3) printf '%s' "Pentium II (Klamath)" ;;
        5) printf '%s' "Pentium III (Deschutes)" ;;
        11) printf '%s' "Pentium III (Tualatin)" ;;
        13) printf '%s' "Pentium M (Dothan)" ;;
        14) printf '%s' "Core (Yonah)" ;;
        15) printf '%s' "Core 2 (Merom/Conroe)" ;;
        22) printf '%s' "Core 2 Mobile (Merom)" ;;
        23) printf '%s' "Core 2 (Penryn/Wolfdale)" ;;
        26) printf '%s' "Nehalem-EP (Gainestown)" ;;
        28) printf '%s' "Atom (Bonnell)" ;;
        29) printf '%s' "Core 2 Extreme (Dunnington)" ;;
        30) printf '%s' "Nehalem (1st Gen Core)" ;;
        31) printf '%s' "Nehalem (Auburndale/Havendale)" ;;
        37) printf '%s' "Westmere (1st Gen Core)" ;;
        38) printf '%s' "Atom (Bonnell MID)" ;;
        39) printf '%s' "Atom (Saltwell MID)" ;;
        42) printf '%s' "Sandy Bridge (2nd Gen Core)" ;;
        44) printf '%s' "Westmere-EP (Gulftown)" ;;
        45) printf '%s' "Sandy Bridge-E" ;;
        46) printf '%s' "Nehalem-EX (Beckton)" ;;
        47) printf '%s' "Westmere-EX (Westmere-EX)" ;;
        53) printf '%s' "Atom (Saltwell Tablet)" ;;
        54) printf '%s' "Atom (Saltwell)" ;;
        55) printf '%s' "Atom (Silvermont)" ;;
        58) printf '%s' "Ivy Bridge (3rd Gen Core)" ;;
        60) printf '%s' "Haswell (4th Gen Core)" ;;
        61) printf '%s' "Broadwell (5th Gen Core)" ;;
        62) printf '%s' "Ivy Bridge-E" ;;
        63) printf '%s' "Haswell-E" ;;
        69) printf '%s' "Haswell Mobile" ;;
        70) printf '%s' "Haswell (Crystal Well)" ;;
        71) printf '%s' "Broadwell (Crystal Well)" ;;
        74) printf '%s' "Atom (Silvermont MID)" ;;
        76) printf '%s' "Atom (Airmont)" ;;
        77) printf '%s' "Atom (Silvermont-D)" ;;
        78) printf '%s' "Skylake Mobile (6th Gen Core)" ;;
        79) printf '%s' "Broadwell-E" ;;
        85) printf '%s' "Skylake-X (Xeon)" ;;
        86) printf '%s' "Broadwell-DE (Xeon D)" ;;
        87) printf '%s' "Xeon Phi Knl" ;;
        90) printf '%s' "Atom (Silvermont MID2)" ;;
        92) printf '%s' "Atom (Goldmont)" ;;
        94) printf '%s' "Skylake (6th Gen Core)" ;;
        95) printf '%s' "Atom (Goldmont-D)" ;;
        102) printf '%s' "Cannon Lake (8th Gen Core)" ;;
        106) printf '%s' "Ice Lake-X (Xeon)" ;;
        108) printf '%s' "Ice Lake-D (Xeon D)" ;;
        117) printf '%s' "Atom (Airmont NP)" ;;
        122) printf '%s' "Atom (Goldmont Plus)" ;;
        125) printf '%s' "Ice Lake (10th Gen Core)" ;;
        126) printf '%s' "Ice Lake Mobile (10th Gen Core)" ;;
        133) printf '%s' "Xeon Phi Knm" ;;
        134) printf '%s' "Atom (Tremont-D)" ;;
        138) printf '%s' "Lakefield" ;;
        140) printf '%s' "Tiger Lake Mobile (11th Gen Core)" ;;
        141) printf '%s' "Tiger Lake (11th Gen Core)" ;;
        142) printf '%s' "Kaby Lake Mobile (7th Gen Core)" ;;
        143) printf '%s' "Sapphire Rapids (Xeon)" ;;
        150) printf '%s' "Atom (Tremont)" ;;
        151) printf '%s' "Alder Lake (12th Gen Core)" ;;
        154) printf '%s' "Alder Lake Mobile (12th Gen Core)" ;;
        156) printf '%s' "Atom (Tremont-L)" ;;
        157) printf '%s' "Ice Lake NNPI" ;;
        158) printf '%s' "Kaby Lake (7th Gen Core)" ;;
        165) printf '%s' "Comet Lake (10th Gen Core)" ;;
        166) printf '%s' "Comet Lake Mobile (10th Gen Core)" ;;
        167) printf '%s' "Rocket Lake (11th Gen Core)" ;;
        170) printf '%s' "Meteor Lake Mobile (Core Ultra 1)" ;;
        172) printf '%s' "Meteor Lake (Core Ultra 1)" ;;
        173) printf '%s' "Granite Rapids (Xeon)" ;;
        174) printf '%s' "Granite Rapids-D (Xeon)" ;;
        175) printf '%s' "Atom (Crestmont-X)" ;;
        181) printf '%s' "Arrow Lake-U (Core Ultra 2)" ;;
        182) printf '%s' "Atom (Crestmont)" ;;
        183) printf '%s' "Raptor Lake (13th Gen Core)" ;;
        186) printf '%s' "Raptor Lake-P Mobile" ;;
        189) printf '%s' "Lunar Lake (Core Ultra 2)" ;;
        190) printf '%s' "Atom (Gracemont)" ;;
        191) printf '%s' "Raptor Lake-S (14th Gen Core)" ;;
        197) printf '%s' "Arrow Lake-H (Core Ultra 2)" ;;
        198) printf '%s' "Arrow Lake-S (Core Ultra 2)" ;;
        204) printf '%s' "Panther Lake (Core Ultra 3)" ;;
        207) printf '%s' "Emerald Rapids (Xeon)" ;;
        213) printf '%s' "Wildcatlake L" ;;
        215) printf '%s' "Bartlett Lake" ;;
        221) printf '%s' "Atom (Darkmont-X)" ;;
        229) printf '%s' "Panther Lake-R" ;;
    *) printf 'Intel family 6 model %s（未收录）' "$m" ;;
  esac
}

amd_gen() {
  local f=$1 m=$2
  case "$f" in
    23)
      if [ "$m" -ge 0 ] && [ "$m" -le 47 ]; then printf '%s' "Zen / Zen+"; return 0; fi
      if [ "$m" -ge 48 ] && [ "$m" -le 79 ]; then printf '%s' "Zen 2"; return 0; fi
      if [ "$m" -ge 80 ] && [ "$m" -le 95 ]; then printf '%s' "Zen / Zen+"; return 0; fi
      if [ "$m" -ge 96 ] && [ "$m" -le 127 ]; then printf '%s' "Zen 2"; return 0; fi
      if [ "$m" -ge 144 ] && [ "$m" -le 145 ]; then printf '%s' "Zen 2"; return 0; fi
      if [ "$m" -ge 160 ] && [ "$m" -le 175 ]; then printf '%s' "Zen 2"; return 0; fi
      ;;
    25)
      if [ "$m" -ge 0 ] && [ "$m" -le 15 ]; then printf '%s' "Zen 3"; return 0; fi
      if [ "$m" -ge 16 ] && [ "$m" -le 31 ]; then printf '%s' "Zen 4"; return 0; fi
      if [ "$m" -ge 32 ] && [ "$m" -le 95 ]; then printf '%s' "Zen 3 / Zen 3+"; return 0; fi
      if [ "$m" -ge 96 ] && [ "$m" -le 175 ]; then printf '%s' "Zen 4 / Zen 4c"; return 0; fi
      ;;
  esac
  case "$f" in
      5) printf '%s' "K6 (K6/K6-2/K6-III)" ;;
      6) printf '%s' "K7 (Athlon/Athlon XP/Duron/Sempron)" ;;
      15) printf '%s' "K8 (Athlon 64/64 X2/Opteron/Turion 64)" ;;
      16) printf '%s' "K10 (Phenom/Phenom II/Athlon II/Opteron)" ;;
      17) printf '%s' "K8 移动版 (Turion X2 Ultra/Griffin)" ;;
      18) printf '%s' "Llano (12h APU)" ;;
      20) printf '%s' "Bobcat (Brazos: E/C/G/Z 系列)" ;;
      21) printf '%s' "Bulldozer/Piledriver/Steamroller/Excavator (FX/A 系列)" ;;
      22) printf '%s' "Jaguar/Puma (Kabini/Mullins)" ;;
      23) printf '%s' "Zen / Zen+ / Zen 2" ;;
      24) printf '%s' "Hygon Dhyana" ;;
      25) printf '%s' "Zen 3 / Zen 3+ / Zen 4" ;;
      26) printf '%s' "Zen 5 / Zen 5c" ;;
    *) printf 'AMD family %s model %s（未收录）' "$f" "$m" ;;
  esac
}

cpu_gen() {
  local v f m
  v=$(cpu_vendor); f=$(cpu_fam); m=$(cpu_mod)
  case "$v" in
    GenuineIntel)
      case "$f" in
        5)  printf 'Intel Pentium (P5 世代)' ;;
        6)  intel_gen "$m" ;;
        15) printf 'Intel NetBurst (Pentium 4 / Pentium D)' ;;
        11) printf 'Intel Knights (Xeon Phi)' ;;
        19) printf 'Intel Xeon 6 (Diamond Rapids)' ;;
        *)  printf 'Intel family %s model %s' "$f" "$m" ;;
      esac ;;
    AuthenticAMD) amd_gen "$f" "$m" ;;
    HygonGenuine) printf 'Hygon Dhyana (AMD Zen 衍生)' ;;
    *) printf '%s family %s model %s' "${v:-未知}" "$f" "$m" ;;
  esac
}
EOCPU
  chmod 644 "$CPUDB"
  changed=1; echo "  [0.5] 已写 $CPUDB（CPU 世代映射）"
else
  echo "  [0.5] $CPUDB 已是最新，跳过"
fi

# ---------- 1) 传感器取样脚本（纯 ASCII 数值与名称）----------
if [ ! -f "$SH" ] || ! grep -q "$MARK-v8" "$SH" 2>/dev/null; then
  cat > "$SH" <<'EOS'
#!/bin/bash
# PVE_HWPATCH-v8 —— 输出节点硬件概要 JSON（单行，纯 ASCII 数值与名称，单位由前端补）
je(){ printf '%s' "$1" | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g; s/[^ -~]//g'; }
command -v sensors >/dev/null 2>&1 || { echo '{}'; exit 0; }
S=$(sensors 2>/dev/null)

CPU_PKG=$(printf '%s\n' "$S" | awk '/Package id 0/{print $4; exit}' | tr -d '+C')
[ -z "$CPU_PKG" ] && CPU_PKG=$(cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | head -1 | awk '{printf "%.1f", $1/1000}')

# 各核：带核名（Core 0:44.0,Core 1:43.0,...  逗号分隔，因核名内含空格）
CORES=$(printf '%s\n' "$S" | awk '/^Core [0-9]+:/{n=$1" "$2; sub(/:$/,"",n); v=$3; gsub(/[+C]/,"",v); printf "%s:%s,", n, v}' | sed 's/,$//')

BOARD=$(printf '%s\n' "$S" | awk '/CPUTIN/{print $2; exit}' | tr -d '+C')
[ -z "$BOARD" ] && BOARD=$(printf '%s\n' "$S" | awk '/SYSTIN/{print $2; exit}' | tr -d '+C')

# 风扇：带序号（fan1:1106,fan2:1407）
FANS=$(printf '%s\n' "$S" | awk '/^fan[0-9]+:/{n=$1; sub(/:$/,"",n); if($2+0>0) printf "%s:%s,", n, $2}' | sed 's/,$//')

# 磁盘：型号|温度(毫度)|容量
DISKS=""
add_disk(){
  local dev="$1" tm="$2" model cap sz
  [ -e /sys/block/$dev ] || return
  model=$(cat /sys/block/$dev/device/model 2>/dev/null | tr -d '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/  */ /g')
  [ -z "$model" ] && model="$dev"
  sz=$(cat /sys/block/$dev/size 2>/dev/null)
  if [ -n "$sz" ] && [ "$sz" -gt 0 ] 2>/dev/null; then
    cap=$(awk "BEGIN{printf \"%.0fG\", $sz*512/1000/1000/1000}")
  else cap="?"; fi
  DISKS="${DISKS}${model}|${tm}|${cap};"
}
for h in /sys/class/hwmon/hwmon*; do
  [ "$(cat $h/name 2>/dev/null)" = "nvme" ] || continue
  t=$(cat $h/temp1_input 2>/dev/null)
  [ -n "$t" ] || continue
  ctrl=$(basename "$(readlink -f $h/device 2>/dev/null)" 2>/dev/null)
  dev=""
  [ -n "$ctrl" ] && dev=$(ls /sys/block 2>/dev/null | grep -m1 "^${ctrl}n")
  [ -z "$dev" ] && dev="$ctrl"
  add_disk "$dev" "$t"
done
if command -v smartctl >/dev/null 2>&1; then
  for d in /dev/sd[a-z]; do
    [ -e "$d" ] || continue
    t=$(smartctl -A "$d" 2>/dev/null | awk '/Temperature_Celsius|Airflow_Temperature_Cel/{print $10; exit}')
    [ -n "$t" ] && add_disk "$(basename $d)" "$((t*1000))"
  done
fi
DISKS=$(printf '%s' "$DISKS" | sed 's/;$//'); [ -z "$DISKS" ] && DISKS="-"

CUR=$(awk '/cpu MHz/{printf "%d", $4; exit}' /proc/cpuinfo)
MAXK=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
MINK=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null)
if [ -n "$MAXK" ]; then MAX=$(awk "BEGIN{printf \"%d\", $MAXK/1000}"); else
  MAX=$(lscpu 2>/dev/null | awk -F: '/Model name/{if(match($2,/[0-9.]+GHz/)){print substr($2,RSTART,RLENGTH)}}' | head -1 | sed 's/GHz//')
  [ -n "$MAX" ] && MAX=$(awk "BEGIN{printf \"%d\", $MAX*1000}")
fi
if [ -n "$MINK" ]; then MIN=$(awk "BEGIN{printf \"%d\", $MINK/1000}"); else
  MIN=$(lscpu 2>/dev/null | awk -F: '/min MHz/{gsub(/ /,"",$2); printf "%d", $2}' | head -1)
fi

# CPU 代号与基准频率（映射见共享文件 cpu-model.sh，与设置页同一份数据）
CPUGEN="-"; BASEF=0
[ -r /usr/local/lib/pve-hwtools/cpu-model.sh ] && { . /usr/local/lib/pve-hwtools/cpu-model.sh; CPUGEN=$(cpu_gen); }
b=$(cat /sys/devices/system/cpu/cpu0/cpufreq/base_frequency 2>/dev/null)
[ -n "$b" ] && BASEF=$(awk "BEGIN{printf \"%d\", $b/1000}")

printf '{"cpu_pkg":"%s","cpu_cores":"%s","disks":"%s","board":"%s","fans":"%s","cpu_cur":"%s","cpu_min":"%s","cpu_max":"%s","cpu_gen":"%s","cpu_base":"%s"}\n' \
  "$(je "${CPU_PKG:--}")" "$(je "${CORES:--}")" "$(je "$DISKS")" "$(je "${BOARD:--}")" \
  "$(je "${FANS:--}")" "${CUR:-0}" "${MIN:-0}" "${MAX:-0}" "$(je "$CPUGEN")" "${BASEF:-0}"
EOS
  chmod +x "$SH"; changed=1; echo "  [1] 已写 $SH（v8）"
else
  echo "  [1] $SH 已是 v8，跳过"
fi

# ---------- 2) 后端：概要取值（tdata）+ 工具集 API（hwtools）----------
# 每次都「先剥旧块、再重新注入」——不能因为「已含标记」就跳过，
# 否则补丁自身的升级（例如后来才补上的 protected => 1）永远装不进去。
#
# 备份策略：只在**当前文件干净（无补丁标记）**时才（重新）备份。
#   不可只判「备份不存在」——PVE 大版本升级后原厂文件已换新，
#   而旧备份仍是上一版的原厂件；一旦注入失败回滚到旧版本文件，
#   就会让 9.2 的 Nodes.pm 退回 8.4.19，且 pvedaemon 起不来。
#   故：文件干净 → 刷新备份；文件带标记 → 保留原备份（此时若失败，
#   注入函数的「删块并复原」是唯一正确回退，绝不用备份覆盖）。
if ! grep -q "PVE_HWPATCH\|PVE_HWAPI" "$N" 2>/dev/null; then
  cp -a "$N" "$BK/Nodes.pm.bak.hwpatch"
fi
python3 - "$N" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='surrogateescape').read()
orig = s

# 2-0) 剥掉任何旧的注入块（幂等，可反复执行）
# 注意只删块本身、不吞其后的换行，否则会多出空行使下面的精确锚点失配。
s = re.sub(r"\n *# PVE_HWPATCH\n[^\n]*\n", "", s)
s = re.sub(r"\n# PVE_HWAPI:BEGIN.*?# PVE_HWAPI:END\n", "", s, flags=re.S)

# 2a) 概要取值：在 status 的返回里加 tdata
a1 = "            free => $dinfo->{blocks} - $dinfo->{used},\n        };\n"
if a1 not in s:
    sys.exit("ERROR: 后端 tdata 锚点失配——未找到预期代码")
if "# PVE_HWPATCH" not in s:
    s = s.replace(a1, a1 + "\n        # PVE_HWPATCH\n        $res->{tdata} = `/usr/bin/s.sh 2>/dev/null`;\n", 1)

# 2b) 工具集 API：挂在 Nodeinfo 包（use base 之后）
# 注意：本文件里 `use base qw(PVE::RESTHandler);` 有**两处**（Nodeinfo 与 Nodes），
# 只能挂在第一处（Nodeinfo），否则接口挂错包。用 replace(...,1) 取第一处。
a2 = "use base qw(PVE::RESTHandler);\n"
if a2 not in s:
    sys.exit("ERROR: 后端 API 锚点失配——未找到 'use base qw(PVE::RESTHandler);'")
api = a2 + '''
# PVE_HWAPI:BEGIN
use PVE::Tools qw(run_command);
__PACKAGE__->register_method({
    name => 'hwtools_status',
    path => 'hwtools',
    method => 'GET',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    description => "PVE 工具集状态。",
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my $raw = `/usr/local/bin/pve-hwtools-agent status 2>/dev/null`;
        my $res = {};
        eval { $res = decode_json($raw) };
        return $res;
    },
});
__PACKAGE__->register_method({
    name => 'hwtools_set',
    path => 'hwtools',
    method => 'PUT',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    description => "写入 PVE 工具集配置。",
    proxyto => 'node',
    # protected => 1 必须有：pveproxy 以 www-data 运行，不带 protected 的接口会被它
    # **就地降权执行**（HTTPServer.pm: euid!=0 且 protected 才转 root 的 pvedaemon），
    # 于是本接口调 agent 写配置时是非 root，被 agent 的 root 校验拒绝。
    # 原厂所有需 root 的节点级接口都带这一项（Nodes.pm 共 20 处）。
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            values => { type => 'string' },
        },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        my @args;
        # 分隔符是**空格**不是逗号：风扇曲线取值自带逗号（25:30,30:60,...），
        # 按逗号切会把一条曲线拆成五段。前端各 k=v 之间以空格分隔。
        for my $kv (split(/[ \t]+/, $param->{values} // '')) {
            $kv =~ s/^\\s+|\\s+$//g;
            next if $kv eq '';
            # 值的字符类**必须允许下划线**：EPP 档位名形如 balance_performance。
            # 只允许字母数字下划线点减号，杜绝 shell 元字符——防注入的同时不误伤合法取值。
            # 值的字符类必须允许：下划线（EPP 档位名 balance_performance）、
            # 冒号与逗号（风扇曲线 25:30,30:60,45:120,60:200,80:255）。
            # 仍只允许字母数字下划线点减号冒号逗号，杜绝 shell 元字符——防注入且不误伤合法取值。
            # 键名必须允许**数字**：风扇配置项形如 fan1_mode / fan3_curve。
            # 曾经只写 [a-z_]+，于是 fan1_mode 一律被判非法、保存永远失败。
            die "非法参数：$kv\\n" if $kv !~ /^[a-z][a-z0-9_]*=[0-9a-zA-Z_.:,-]+$/;
            push @args, $kv;
        }
        die "没有可写入的配置项\\n" if !@args;
        my $out = '';
        eval {
            run_command(['/usr/local/bin/pve-hwtools-agent', 'set', @args],
                        outfunc => sub { $out .= shift });
        };
        die "写入失败：$@\\n" if $@;
        my $res = {};
        eval { $res = decode_json($out) };
        if (!scalar(keys %$res)) {
            my $raw = `/usr/local/bin/pve-hwtools-agent status 2>/dev/null`;
            eval { $res = decode_json($raw) };
        }
        return $res;
    },
});
# PVE_HWAPI:END
'''
s = s.replace(a2, api, 1)

# 内容恰好未变（已是最新）也算成功，不再当作错误——曾因误判为失败而触发回滚，
# 用备份把补丁整个覆盖掉。
#
# 但要**如实报告内容是否真的变了**：只有真变才允许上层重启 pvedaemon，
# 否则 agent 每次保存都会触发本脚本（从而重启正在处理该请求的 pvedaemon 自己）
# → 请求被掐断 → HTTP 596 broken pipe。
import hashlib
new_bytes = s.encode("utf-8", "surrogateescape")
h = hashlib.sha256(new_bytes).hexdigest()
old_bytes = orig.encode("utf-8", "surrogateescape")
h_old = hashlib.sha256(old_bytes).hexdigest()
flags = "/var/run/pve-hwpatch.flags"
try:
    with open(flags, "w") as fh:
        fh.write("backend_changed=%s\n" % ("1" if h != h_old else "0"))
except Exception:
    pass
open(p, 'wb').write(new_bytes)
print("  [2] Nodes.pm 已注入（tdata + hwtools API，含 protected）%s"
      % ("" if h != h_old else "（内容未变）"))
PY
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "  后端注入失败，回滚"
    [ -f "$BK/Nodes.pm.bak.hwpatch" ] && cp -a "$BK/Nodes.pm.bak.hwpatch" "$N"
    exit 1
  fi
  perl -c "$N" >/dev/null 2>&1 || { echo "  perl 语法校验失败，回滚"; cp -a "$BK/Nodes.pm.bak.hwpatch" "$N"; exit 1; }
  echo "  [2] perl 语法校验通过"
  changed=1
  if grep -q "^backend_changed=1$" /var/run/pve-hwpatch.flags 2>/dev/null; then
    backend_changed=1
  fi

# ---------- 3) 前端：概要条目 + 按配置隐藏 + 设置页 + 菜单项 ----------
# 备份策略同第 2 段：只在文件干净时刷新备份，绝不用旧版原厂件覆盖新版本文件。
if ! grep -q "PVE_HWPATCH\|PVE_HWUI" "$J" 2>/dev/null; then
  cp -a "$J" "$BK/pvemanagerlib.js.bak.hwpatch"
fi
python3 - "$J" "$0" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='surrogateescape').read()
orig = s

# ---- 3a) 清掉任何旧注入块（可反复执行）----
# 移除时**只删块本身，不吞其后的换行**，否则会多出一个空行、令 3b/3d 的精确锚点失配，
# 注入随即失败并回滚到原厂备份——V1.1 就栽在这里（而只数标记的「幂等测试」分辨不出
# 「成功无变化」与「失败未改动」）。
if "// PVE_HWPATCH:BEGIN" in s:
    s = re.sub(r"\n[ \t]*// PVE_HWPATCH:BEGIN.*?// PVE_HWPATCH:END", "", s, flags=re.S)
elif "// PVE_HWPATCH" in s:
    s = re.sub(r"\n[ \t]*// PVE_HWPATCH\n.*?\n    \],", "\n    ],", s, flags=re.S)
for m in ('HOME', 'MENU'):
    if "// PVE_HWUI:%s:BEGIN" % m in s:
        s = re.sub(r"\n[ \t]*// PVE_HWUI:%s:BEGIN.*?// PVE_HWUI:%s:END" % (m, m), "", s, flags=re.S)
if "// PVE_HWUI:BEGIN" in s:
    s = re.sub(r"\n// PVE_HWUI:BEGIN.*?// PVE_HWUI:END", "", s, flags=re.S)

# ---- 3b) 概要条目（全部注入；显示与否由 PVE.HW 在渲染后决定）----
anchor = "            textField: 'pveversion',\n            value: '',\n        },\n    ],\n"
if anchor not in s:
    sys.exit("ERROR: 概要锚点未找到")

items = """            textField: 'pveversion',
            value: '',
        },
        // PVE_HWPATCH:BEGIN
        // 六条一律静态注入。
        // 注意：Ext.define 的 items 在**类定义时就求值**，此处绝不能写运行期判断
        // （`me` 尚未存在）——否则脚本一加载即抛错，整个界面都起不来，连登录窗
        // 都不渲染，而 `node --check` 只验语法、查不出这类错。
        // 因此显示与否交给 PVE.HW 在面板渲染后按配置隐藏（见文件末尾 PVE_HWUI 块）。
        {
            xtype: 'box',
            colspan: 2,
            padding: '10 0 6 0',
            itemId: 'hw-header',
            html: '<b>' + gettext('硬件概要') + '</b>',
        },
        {
            itemId: 'hw-cputemp',
            colspan: 1,
            printBar: false,
            title: gettext('CPU温度'),
            textField: 'tdata',
            renderer: function (v) {
                try { return JSON.parse(v).cpu_pkg + ' °C'; } catch (e) { return '-'; }
            },
        },
        {
            itemId: 'hw-board',
            colspan: 1,
            printBar: false,
            title: gettext('主板温度'),
            textField: 'tdata',
            renderer: function (v) {
                try { return JSON.parse(v).board + ' °C'; } catch (e) { return '-'; }
            },
        },
        {
            itemId: 'hw-cpucores',
            colspan: 2,
            printBar: false,
            title: gettext('CPU各核'),
            textField: 'tdata',
            renderer: function (v) {
                try {
                    return JSON.parse(v).cpu_cores.split(',').map(function (x) {
                        var q = x.split(':');
                        return q[0] + ' ' + q[1] + ' °C';
                    }).join(' | ');
                } catch (e) { return '-'; }
            },
        },
        {
            itemId: 'hw-fans',
            colspan: 2,
            printBar: false,
            title: gettext('风扇转速'),
            textField: 'tdata',
            renderer: function (v) {
                try {
                    var x = JSON.parse(v).fans;
                    if (x === '-') { return '-'; }
                    return x.split(',').map(function (y) {
                        var q = y.split(':');
                        return q[0].replace(/^fan/i, 'Fan ') + ' ' + q[1] + ' RPM';
                    }).join(' | ');
                } catch (e) { return '-'; }
            },
        },
        {
            itemId: 'hw-disktemp',
            colspan: 2,
            printBar: false,
            title: gettext('硬盘温度'),
            textField: 'tdata',
            renderer: function (v) {
                try {
                    var d = JSON.parse(v).disks;
                    if (d === '-') { return '-'; }
                    return d.split(';').map(function (r) {
                        var q = r.split('|');
                        var t = (parseInt(q[1], 10) / 1000).toFixed(0);
                        return q[0] + '  ' + t + ' °C  ' + q[2];
                    }).join('      |      ');
                } catch (e) { return '-'; }
            },
        },
        {
            itemId: 'hw-cpufreq',
            colspan: 2,
            printBar: false,
            title: gettext('CPU频率'),
            textField: 'tdata',
            renderer: function (v) {
                try {
                    var d = JSON.parse(v);
                    var cur = d.cpu_cur && d.cpu_cur !== '0' ? d.cpu_cur + ' MHz' : '-';
                    var rng = (d.cpu_min && d.cpu_min !== '0' ? d.cpu_min : '-') + ' ~ ' +
                              (d.cpu_max && d.cpu_max !== '0' ? d.cpu_max + ' MHz' : '-');
                    var out = cur + '  (min~max: ' + rng + ')';
                    // 换行用 HTML 标签：单元格内容按 HTML 渲染，纯换行字符会被折叠成空格。
                    // （也避免了在 Python 三引号块里写反斜杠转义。）
                    // 代号与基准频率（CPUID 映射；AMD 机器同样适用）
                    if (d.cpu_gen && d.cpu_gen !== '-') {
                        out += '<br/>' + d.cpu_gen +
                               ((d.cpu_base && d.cpu_base !== '0') ? (' · 基准 ' + d.cpu_base + ' MHz') : '');
                    }
                    return out;
                } catch (e) { return '-'; }
            },
        },
        // PVE_HWPATCH:END
    ],
"""
s = s.replace(anchor, items, 1)

# 结构性护栏：这段 JS 嵌在 Python 三引号字符串里，若里面写了反斜杠转义（典型是换行写成
# 反斜杠加 n），Python 会先把它译成真字符，从而截断 JS 字面量或注释——结果是整个
# pvemanagerlib.js 加载失败、连登录窗都不渲染（node --check 也只报个难定位的行号）。
# 注意：护栏必须扫**脚本原始文本**——等 Python 变量成型时反斜杠已被吃掉，查变量是查不出的。
_src = ""
try:
    _src = open(sys.argv[2], encoding='utf-8').read()
except Exception:
    pass
if _src:
    _a = _src.find('items = """')
    _b = _src.find('"""', _a + 12) if _a >= 0 else -1
    if _a >= 0 and _b > _a:
        _blk = _src[_a + 12:_b]
        for _m in re.finditer(r"\\[nrtbfv0-9ux]", _blk):
            sys.exit("ERROR: 概要条目块的源码里出现反斜杠转义：%s\n"
                     "       请改用 HTML 标签（<br/>）或 String.fromCharCode，"
                     "否则整份前端 JS 会加载失败。"
                     % _blk[max(0, _m.start()-50):_m.start()+50].replace("\n", " / "))

# ---- 3c) 概要面板：渲染后按配置隐藏（开关改动后无需重登）----
home_anchor = """        let nodeStatus = Ext.create('PVE.node.StatusView', {
            xtype: 'pveNodeStatus',
            rstore: rstore,
            width: 770,
            pveSelNode: me.pveSelNode,
        });
"""
if home_anchor not in s:
    sys.exit("ERROR: 概要面板锚点未找到")
home_new = home_anchor + """        // PVE_HWUI:HOME:BEGIN
        PVE.HW.attach(nodeStatus, nodename);
        // PVE_HWUI:HOME:END
"""
s = s.replace(home_anchor, home_new, 1)

# ---- 3d) 左菜单注册「PVE 工具集」----
menu_anchor = """                itemId: 'support',
                xtype: 'pveNodeSubscription',
                nodename: nodename,
            },
        );
"""
if menu_anchor not in s:
    sys.exit("ERROR: 菜单锚点未找到")
menu_new = """                itemId: 'support',
                xtype: 'pveNodeSubscription',
                nodename: nodename,
            },
            // PVE_HWUI:MENU:BEGIN
            {
                title: gettext('PVE 工具集'),
                iconCls: 'fa fa-wrench',
                groups: ['services'],
                itemId: 'hwtools',
                xtype: 'pveNodeHwTools',
                nodename: nodename,
            },
            // PVE_HWUI:MENU:END
        );
"""
s = s.replace(menu_anchor, menu_new, 1)

# ---- 3e) 追加：隐藏逻辑 + 设置页（文件末尾）----
ui = """
// PVE_HWUI:BEGIN
// ---------------------------------------------------------------------------
// PVE 工具集：概要显示开关的运行时隐藏 + 设置页
// 本块由 /usr/local/bin/pve-hwpatch.sh 注入；重复执行会整块替换。
// ---------------------------------------------------------------------------
PVE.HW = PVE.HW || {};

// 隐藏开关关掉的概要行（配置改动后无需重新登录：每次装载概要存储都会重新判读）。
// 每条目占一行的高度（实测：六条 = 480，故每条 24px，超出即高度不足而出现滚动条）
PVE.HW.ROW = 24;
PVE.HW.BASE = 480;

// 全部硬件概要条目（供复位用）
PVE.HW.ALL = [
    'hw-header',
    'hw-cputemp',
    'hw-board',
    'hw-cpucores',
    'hw-fans',
    'hw-disktemp',
    'hw-cpufreq',
];

// 按配置隐藏。先**全部复位**再隐藏该隐的——否则开关从 0 改回 1 后，
// 先前隐藏的行不会自己回来（V2 初版即漏了这步）。
PVE.HW.hide = function (panel) {
    var el = panel.getEl();
    if (!el) {
        return;
    }
    var hidden = panel._hwHidden || [];
    for (var i = 0; i < PVE.HW.ALL.length; i++) {
        var id = PVE.HW.ALL[i];
        var f = panel.down('[itemId=' + id + ']');
        if (!f) {
            continue;
        }
        var fe = f.getEl();
        if (!fe) {
            continue;
        }
        var dom = fe.dom || fe;
        var tr = dom.closest ? dom.closest('tr') : null;
        if (Ext.Array.indexOf(hidden, id) >= 0) {
            fe.hide();
            if (tr) {
                tr.style.display = 'none';
            }
        } else {
            fe.show();
            if (tr && tr.style.display === 'none') {
                tr.style.display = '';
            }
        }
    }
    // 高度随隐藏的行数递减
    panel.setHeight(Math.max(150, PVE.HW.BASE - hidden.length * PVE.HW.ROW));
};

// 保存配置后置位，令概要面板在下一轮刷新时重新取一次开关
PVE.HW.refreshPending = false;

// 每轮存储装载都重判一次（配置改了立刻生效，无需刷新页面）
var _hwUpdateValues = PVE.node.StatusView.prototype.updateValues;
PVE.node.StatusView.prototype.updateValues = function (store, records, success) {
    _hwUpdateValues.apply(this, arguments);
    if (PVE.HW.refreshPending) {
        // 设置页刚保存过：开关可能变了，重新取一次再决定显隐。
        // 必须延后一拍：attach() 里是同步 XHR，若在 store 装载 / 容器布局途中就地执行，
        // 会在 Ext 尚未初始化完的容器上动作（表现为 "Cannot read properties of null"）。
        PVE.HW.refreshPending = false;
        var _p = this, _n = this._hwNode || PVE.NodeName;
        Ext.defer(function () { PVE.HW.attach(_p, _n); }, 60);
    } else {
        PVE.HW.hide(this);
    }
};

PVE.HW.attach = function (panel, nodename) {
    panel._hwNode = nodename;
    panel._hwHidden = [];
    try {
        var rq = Ext.Ajax.request({ url: '/api2/json/nodes/' + nodename + '/hwtools', async: false });
        var d = Ext.decode(rq.responseText).data || {};
        var one = function (v) { return String(v) === '1'; };
        var ids = [];
        if (!one(d.show_cpu_temp)) { ids.push('hw-cputemp', 'hw-board', 'hw-cpucores'); }
        if (!one(d.show_fan)) { ids.push('hw-fans'); }
        if (!one(d.show_disk)) { ids.push('hw-disktemp'); }
        if (!one(d.show_cpu_freq)) { ids.push('hw-cpufreq'); }
        if (ids.length >= 4) { ids.push('hw-header'); }  // 全关则连表头一并收起
        panel._hwHidden = ids;
    } catch (e) {
        panel._hwHidden = [];
    }
    var run = function () {
        PVE.HW.hide(panel);
    };
    if (panel.rendered) {
        run();
    } else {
        panel.on('afterrender', run);
    }
};

Ext.define('PVE.node.HwTools', {
    extend: 'Ext.panel.Panel',
    xtype: 'pveNodeHwTools',

    scrollable: true,
    bodyPadding: 10,
    border: 0,

    initComponent: function () {
        var me = this;
        var nodename = me.pveSelNode.data.node;
        me.nodename = nodename;

        var hwLine = Ext.create('Ext.form.Label', { html: '', margin: '0 0 10 0' });

        var mkCb = function (label, name) {
            return Ext.create('Ext.form.field.Checkbox', {
                boxLabel: gettext(label),
                name: name,
                inputValue: 1,
                uncheckedValue: 0,
                margin: '4 0',
            });
        };

        var form = Ext.create('Ext.form.Panel', {
            border: 0,
            bodyPadding: 0,
            items: [
                {
                    xtype: 'fieldset',
                    title: gettext('概要显示'),
                    defaults: { margin: '4 0' },
                    items: [
                        mkCb('显示 CPU 温度（含各核）', 'show_cpu_temp'),
                        mkCb('显示风扇转速', 'show_fan'),
                        mkCb('显示硬盘概要（型号 / 容量 / 温度）', 'show_disk'),
                        mkCb('显示 CPU 频率', 'show_cpu_freq'),
                    ],
                },
                {
                    xtype: 'fieldset',
                    title: gettext('CPU 调频'),
                    defaults: { margin: '4 0' },
                    items: [
                        {
                            xtype: 'combo',
                            fieldLabel: gettext('调频模式'),
                            name: 'governor',
                            editable: false,
                            forceSelection: true,
                            queryMode: 'local',
                            displayField: 'v',
                            valueField: 'v',
                            store: { fields: ['v'], data: [] },
                        },
                        {
                            xtype: 'numberfield',
                            fieldLabel: gettext('频率下限（MHz）'),
                            name: 'freq_min',
                            allowDecimals: false,
                            minValue: 0,
                            width: 340,
                        },
                        {
                            xtype: 'numberfield',
                            fieldLabel: gettext('频率上限（MHz）'),
                            name: 'freq_max',
                            allowDecimals: false,
                            minValue: 0,
                            width: 340,
                        },
                        {
                            xtype: 'combo',
                            fieldLabel: gettext('Turbo 加速'),
                            name: 'turbo',
                            editable: false,
                            forceSelection: true,
                            queryMode: 'local',
                            displayField: 'v',
                            valueField: 'val',
                            store: { fields: ['v', 'val'], data: [
                                { v: gettext('启用'), val: '1' },
                                { v: gettext('关闭'), val: '0' },
                            ] },
                        },
                        {
                            xtype: 'combo',
                            fieldLabel: gettext('能效偏好（EPP）'),
                            name: 'epp',
                            editable: false,
                            forceSelection: true,
                            queryMode: 'local',
                            displayField: 'v',
                            valueField: 'v',
                            emptyText: gettext('本机不支持'),
                            store: { fields: ['v'], data: [] },
                        },
                        {
                            xtype: 'component',
                            itemId: 'freqhint',
                            margin: '6 0 0 0',
                            html: '',
                        },
                    ],
                },
                {
                    xtype: 'fieldset',
                    title: gettext('订阅提示'),
                    defaults: { margin: '4 0' },
                    items: [mkCb('屏蔽「无有效订阅」登录弹窗', 'block_subscription')],
                },
                {
                    xtype: 'fieldset',
                    title: gettext('软件源'),
                    defaults: { margin: '4 0' },
                    items: [
                        {
                            xtype: 'combo',
                            fieldLabel: gettext('Debian / PVE 镜像'),
                            name: 'apt_mirror',
                            editable: false,
                            forceSelection: true,
                            queryMode: 'local',
                            displayField: 'v',
                            valueField: 'val',
                            emptyText: gettext('本机无切换脚本'),
                            store: { fields: ['v', 'val'], data: [] },
                        },
                        {
                            xtype: 'component',
                            itemId: 'mirrorhint',
                            margin: '6 0 0 0',
                            html: '',
                        },
                    ],
                },
                {
                    xtype: 'fieldset',
                    title: gettext('风扇控制'),
                    itemId: 'fanfs',
                    defaults: { margin: '4 0' },
                    items: [
                        {
                            xtype: 'component',
                            itemId: 'fanhint',
                            html: '',
                        },
                    ],
                },
                {
                    xtype: 'container',
                    layout: 'hbox',
                    margin: '14 0 0 0',
                    items: [
                        {
                            xtype: 'button',
                            text: gettext('保存并应用'),
                            iconCls: 'fa fa-save',
                            handler: function () { me.save(); },
                        },
                        {
                            xtype: 'button',
                            text: gettext('重新载入'),
                            iconCls: 'fa fa-refresh',
                            margin: '0 0 0 8',
                            handler: function () { me.reload(); },
                        },
                    ],
                },
            ],
        });

        Ext.apply(me, { items: [hwLine, form] });
        me.callParent();

        me.on('afterrender', function () {
            me.reload();
        });
    },


        // 风扇通道控件**必须在这里动态创建**，不能写进 items 数组：
        // 面板类的 items 在脚本加载期就求值，那时既不知道本机有几个通道、也拿不到配置，
        // 更要命的是会引入运行期求值 → 整个 pvemanagerlib.js 加载失败（连登录窗都不渲染）。
        fanVal: function (name) {
            var c = this.down('[name=' + name + ']');
            return c ? c.getValue() : null;
        },

        buildFanRows: function (d) {
            var me = this;
            var fs = me.down('#fanfs');
            if (!fs) { return; }
            var fans = d.fans || [];
            var sources = (d.fan_sources || []).map(function (x) {
                return { v: x.n + ' · ' + x.label, val: String(x.n) };
            });
            var hint = me.down('#fanhint');
            if (hint) {
                hint.setHtml('<span style="color:#888">' +
                    (fans.length
                        ? (gettext('共 ') + fans.length + gettext(' 个通道。自动 = 交给主板硬件按曲线调速（无需常驻程序）；手动 = 固定占空比。曲线五点须按温度由低到高。'))
                        : gettext('本机未检测到可控风扇通道。')) + '</span>');
            }
            // 每次 reload 都重建：模式与曲线会变，旧控件留着会读到过期值
            var old = fs.query('[itemId^=fanrow]');
            (old || []).forEach(function (c) { fs.remove(c, true); });

            fans.forEach(function (f) {
                var n = f.n;
                var pts = String(f.curve || '').split(',');
                var cpts = [];
                pts.forEach(function (x) {
                    var kv = String(x).split(':');
                    if (kv.length === 2) { cpts.push({ t: parseInt(kv[0], 10), w: parseInt(kv[1], 10) }); }
                });
                while (cpts.length < 5) { cpts.push({ t: 30 + cpts.length * 10, w: 64 + cpts.length * 48 }); }

                fs.add(Ext.create('Ext.container.Container', {
                    itemId: 'fanrow' + n,
                    margin: '2 0',
                    layout: 'hbox',
                    defaults: { margin: '0 8 0 0', xtype: 'numberfield', width: 76 },
                    items: [
                        { xtype: 'component', width: 100, margin: '6 8 0 0',
                          html: '<b>' + gettext('通道 ') + n + '</b>' +
                                '<br/><span style="color:#888">' + (f.rpm || 0) + ' RPM</span>' },
                        { name: 'fan' + n + '_mode', xtype: 'combo', width: 128,
                          hideLabel: true, editable: false, forceSelection: true, queryMode: 'local',
                          displayField: 'v', valueField: 'val',
                          store: { fields: ['v', 'val'], data: [
                              { v: gettext('关闭（用主板设置）'), val: 'off' },
                              { v: gettext('自动曲线'), val: 'auto' },
                              { v: gettext('手动定值'), val: 'manual' } ] },
                          value: f.mode || 'off',
                          listeners: { change: function () { me.fanSyncRow(n); } } },
                        { name: 'fan' + n + '_manual', width: 84,
                          emptyText: gettext('占空比'), minValue: 1, maxValue: 255,
                          value: f.manual || 128, allowBlank: false,
                          listeners: { change: function () { me.fanSyncRow(n); } } },
                        { name: 'fan' + n + '_sel', xtype: 'combo', width: 168,
                          hideLabel: true, editable: false, forceSelection: true,
                          queryMode: 'local', displayField: 'v', valueField: 'val',
                          emptyText: gettext('温度源'), store: { fields: ['v', 'val'], data: sources },
                          value: String(f.sel || '') },
                    ],
                }));

                // 曲线第二行：温度 → 占空比，五组
                var crow = Ext.create('Ext.container.Container', {
                    itemId: 'fanrow' + n + 'c',
                    margin: '0 0 6 108',
                    layout: 'hbox',
                    items: [{ xtype: 'component', margin: '6 6 0 0',
                              html: '<span style="color:#888">' + gettext('曲线') + '</span>' }],
                });
                cpts.forEach(function (x, i) {
                    crow.add({ xtype: 'numberfield', name: 'fan' + n + '_pt' + i + '_t',
                               width: 58, emptyText: gettext('温度'), minValue: 0, maxValue: 120,
                               value: x.t, hideLabel: true, margin: '0 4 0 0' });
                    crow.add({ xtype: 'component', margin: '6 4 0 0', html: '℃ →' });
                    crow.add({ xtype: 'numberfield', name: 'fan' + n + '_pt' + i + '_w',
                               width: 58, emptyText: gettext('占空比'), minValue: 1, maxValue: 255,
                               value: x.w, hideLabel: true, margin: '0 10 0 0' });
                });
                fs.add(crow);

                me.fanSyncRow(n);
            });
        },

        // 按模式启用/禁用该通道的控件——别让人填了不生效的东西
        fanSyncRow: function (n) {
            var me = this;
            var mode = me.down('[name=fan' + n + '_mode]');
            var v = mode ? mode.getValue() : 'off';
            var man = me.down('[name=fan' + n + '_manual]');
            var sel = me.down('[name=fan' + n + '_sel]');
            var crow = me.down('#fanrow' + n + 'c');
            if (man) { man.setDisabled(v !== 'manual'); }
            if (sel) { sel.setDisabled(v !== 'auto'); }
            if (crow) { crow.query('numberfield').forEach(function (x) { x.setDisabled(v !== 'auto'); }); }
        },

    reload: function () {
        var me = this;
        Proxmox.Utils.API2Request({
            url: '/nodes/' + me.nodename + '/hwtools',
            method: 'GET',
            waitMsgTarget: me,
            success: function (response) {
                // 面板可能已被销毁（切走卡片 / 重建），此时迟到的响应会打在死对象上
                // （表现为 Cannot read properties of null）。先挡住。
                if (me.destroyed || !me.down) { return; }
                var d = response.result.data || {};
                var f = me.down('form').getForm();
                var one = function (v) { return String(v) === '1'; };

                // 顺序要紧：先把调速器候选灌进下拉，再 setValues，
                // 否则 combo 因 store 为空而无法匹配、回填成空。
                var cb = me.down('combo[name=governor]');
                cb.getStore().loadData((d.governors || []).map(function (g) { return { v: g }; }));

                // 能效偏好：仅本机支持的档位；不支持则禁用并标注
                var cbEpp = me.down('combo[name=epp]');
                var eppList = d.epp_list || [];
                cbEpp.getStore().loadData(eppList.map(function (e) { return { v: e }; }));
                cbEpp.setDisabled(!d.epp_avail || !eppList.length);

                // Turbo：本机不支持则禁用
                var cbTurbo = me.down('combo[name=turbo]');
                cbTurbo.setDisabled(!d.turbo_avail);

                // 软件源镜像：候选来自切换脚本自报的一览（含中文显示名）
                var cbMir = me.down('combo[name=apt_mirror]');
                var mirNames = {'ustc': gettext('中科大'), 'tuna': gettext('清华大学'),
                                'aliyun': gettext('阿里云'), 'tencent': gettext('腾讯云'),
                                'huawei': gettext('华为云'), 'official': gettext('官方源')};
                var mirList = d.mirror_list ? String(d.mirror_list).split(',').filter(function (x) { return x; }) : [];
                cbMir.getStore().loadData(mirList.map(function (m) {
                    return { v: (mirNames[m] ? mirNames[m] + '（' + m + '）' : m), val: m };
                }));
                cbMir.setDisabled(!d.apt_mirror_avail || !mirList.length);

                // 风扇通道与温度源都来自本机实测，控件只能在此动态创建
                me.buildFanRows(d);

                // 数字框的合法范围也须在 setValues 之前设好，否则被当作越界而清空。
                // 单位一律 MHz（状态接口已折算好）。
                var nfMin = me.down('numberfield[name=freq_min]');
                var nfMax = me.down('numberfield[name=freq_max]');
                nfMin.setMinValue(d.freq_hw_min);
                nfMin.setMaxValue(d.freq_hw_max);
                nfMax.setMinValue(d.freq_hw_min);
                nfMax.setMaxValue(d.freq_hw_max);

                f.setValues({
                    show_cpu_temp: one(d.show_cpu_temp),
                    show_fan: one(d.show_fan),
                    show_disk: one(d.show_disk),
                    show_cpu_freq: one(d.show_cpu_freq),
                    block_subscription: one(d.block_subscription),
                    governor: d.governor,
                    freq_min: parseInt(d.freq_min, 10),
                    freq_max: parseInt(d.freq_max, 10),
                    turbo: String(d.turbo),
                    epp: d.epp,
                    apt_mirror: d.apt_mirror,
                });

                var mhz = function (v) { return v + ' MHz'; };
                var gv = (d.cpu_gen || '');
                me.down('#freqhint').setHtml(
                    '<span style="color:#888">' +
                    gettext('处理器：') + gv + '<br/>' +
                    gettext('驱动：') + (d.driver || '?') +
                        (d.amd_pstate ? ('（amd_pstate: ' + d.amd_pstate + '）') : '') +
                        '，' + gettext('策略数：') + (d.policies || 0) + '<br/>' +
                    gettext('硬件能力：') + mhz(d.freq_hw_min) + ' ~ ' + mhz(d.freq_hw_max) +
                        (d.base_freq ? ('，' + gettext('基准频率 ') + mhz(d.base_freq)) : '') + '<br/>' +
                    gettext('内核实际生效：') + d.governor_live + '，' +
                        mhz(d.freq_min_live) + ' ~ ' + mhz(d.freq_max_live) +
                        '，' + gettext('当前 ') + mhz(d.freq_cur) + '<br/>' +
                    gettext('Turbo：') + (d.turbo_avail ? (String(d.turbo) === '1' ? gettext('启用') : gettext('关闭')) : gettext('本机不支持')) +
                        (d.epp_avail ? ('，' + gettext('EPP：') + (d.epp || '-')) : '') + '<br/>' +
                    gettext('配置文件：') + d.config_file + '<br/>' +
                    gettext('软件源：') + (d.apt_mirror_avail
                        ? (gettext('当前文件为 ') + (d.apt_mirror_live || '?') +
                           gettext('（配置为 ') + (d.apt_mirror || '?') + gettext('）'))
                        : gettext('本机未装镜像切换脚本')) + '<br/>' +
                    gettext('风扇：') + (d.fan_avail
                        ? (gettext('通道 ') + d.fan_channels + gettext('，本机可控'))
                        : gettext('本机无可控风扇通道')) +
                    '</span>'
                );
            },
            failure: function (response) {
                Ext.Msg.alert(gettext('错误'), response.htmlStatus);
            },
        });
    },

    save: function () {
        var me = this;
        var f = me.down('form').getForm();
        if (!f.isValid()) {
            return;
        }
        var val = f.getValues();
        var on = function (name) { return f.findField(name).getValue() ? 1 : 0; };
        var kv = [
            'show_cpu_temp=' + on('show_cpu_temp'),
            'show_fan=' + on('show_fan'),
            'show_disk=' + on('show_disk'),
            'show_cpu_freq=' + on('show_cpu_freq'),
            'block_subscription=' + on('block_subscription'),
            'governor=' + val.governor,
            // 单位 MHz（后端按 MHz 校验并折算成 kHz 写入内核）
            'freq_min=' + Math.round(val.freq_min),
            'freq_max=' + Math.round(val.freq_max),
        ];
        // Turbo / EPP 仅在本机支持时才提交，免得把不支持的值写进配置
        var cbTurbo = me.down('combo[name=turbo]');
        if (cbTurbo && !cbTurbo.isDisabled() && val.turbo !== undefined && val.turbo !== null && val.turbo !== '') {
            kv.push('turbo=' + val.turbo);
        }
        var cbEpp = me.down('combo[name=epp]');
        if (cbEpp && !cbEpp.isDisabled() && val.epp) {
            kv.push('epp=' + val.epp);
        }
        // 软件源：仅当本机装了切换脚本且确有选择时才提交
        var cbMir = me.down('combo[name=apt_mirror]');
        if (cbMir && !cbMir.isDisabled() && val.apt_mirror) {
            kv.push('apt_mirror=' + val.apt_mirror);
        }
        // 风扇：只提交本机真实存在的通道。
        // 注意曲线值**自带逗号**，故各 k=v 之间改用空格分隔（后端同步支持空格切片）。
        var fanErr = null;
        me.query('combo').forEach(function (c) {
            var nm = c.name || '';
            // 不用正则匹配通道号：注入块是 Python 三引号字符串，里面出现反斜杠
            // 会被提前转义，历来是这套补丁的翻车点。改用纯字符串切分。
            if (nm.indexOf('fan') !== 0 || nm.slice(-5) !== '_mode' || fanErr) { return; }
            var n = nm.slice(3, -5);
            for (var q = 0; q < n.length; q++) {
                var ch = n.charCodeAt(q);
                if (ch < 48 || ch > 57) { return; }
            }
            if (!n) { return; }
            var mode = c.getValue();
            if (!mode) { return; }
            kv.push('fan' + n + '_mode=' + mode);
            if (mode === 'manual') {
                kv.push('fan' + n + '_manual=' + Math.round(me.fanVal('fan' + n + '_manual')));
            } else if (mode === 'auto') {
                var sel = me.fanVal('fan' + n + '_sel');
                if (sel) { kv.push('fan' + n + '_sel=' + sel); }
                var pts = [], last = -1;
                for (var i = 0; i < 5; i++) {
                    var t = me.fanVal('fan' + n + '_pt' + i + '_t');
                    var w = me.fanVal('fan' + n + '_pt' + i + '_w');
                    if (t === null || w === null) {
                        fanErr = gettext('通道 ') + n + gettext(' 的曲线有空格未填。');
                        return;
                    }
                    t = Math.round(t); w = Math.round(w);
                    if (t <= last) {
                        fanErr = gettext('通道 ') + n + gettext(' 的曲线温度必须由低到高（第 ') + (i + 1) + gettext(' 点不大于前一点）。');
                        return;
                    }
                    last = t;
                    pts.push(t + ':' + w);
                }
                kv.push('fan' + n + '_curve=' + pts.join(','));
            }
        });
        if (fanErr) {
            Ext.Msg.alert(gettext('风扇设置有误'), fanErr);
            return;
        }
        // 空格分隔：曲线值里的逗号得以保留
        kv = kv.join(' ');

        Proxmox.Utils.API2Request({
            url: '/nodes/' + me.nodename + '/hwtools',
            method: 'PUT',
            params: { values: kv },
            waitMsgTarget: me,
            success: function () {
                // 让概要面板下一轮刷新时重新取开关（否则要刷新整个页面才见变化）
                PVE.HW.refreshPending = true;
                Ext.Msg.show({
                    title: gettext('已保存'),
                    msg: gettext('设置已写入并生效。软件源与风扇同步切换 / 下发给主板；概要页会在下一次刷新时按新开关显示。'),
                    buttons: Ext.Msg.OK,
                    icon: Ext.Msg.INFO,
                });
                me.reload();
            },
            failure: function (response) {
                Ext.Msg.alert(gettext('保存失败'), response.htmlStatus);
            },
        });
    },
});
// PVE_HWUI:END
"""
if s.rstrip().endswith('// PVE_HWUI:END'):
    s = s.rstrip()[: -len('// PVE_HWUI:END')].rstrip() + '\n' + ui.lstrip('\n')
else:
    s = s.rstrip() + '\n' + ui

# 同一道护栏，罩住设置页那一大块 JS（理由见上）。同样必须扫**源码文本**。
if _src:
    _a = _src.find('ui = """')
    _b = _src.find('"""', _a + 8) if _a >= 0 else -1
    if _a >= 0 and _b > _a:
        _blk = _src[_a + 8:_b]
        for _m in re.finditer(r"\\[nrtbfv0-9ux]", _blk):
            sys.exit("ERROR: 设置页 JS 的源码里出现反斜杠转义：%s\n"
                     "       请改用 HTML 标签（<br/>）或 String.fromCharCode。"
                     % _blk[max(0, _m.start()-50):_m.start()+50].replace("\n", " / "))

# 概要面板高度基线
s = re.sub(r"(alias: 'widget\.pveNodeStatus',\n\n    height: )\d+(,)", r"\g<1>480\g<2>", s, count=1)

# 注意：**不能**因为 s == orig 就报错。已打过补丁的文件再跑一遍时，
# 「移除旧块 + 重新注入」恰好等于原文，s == orig 是正常结果；若判为失败并回滚，
# 会把补丁连同备份一起抹掉（备份可能还是更早的版本）。
# 真正该失败的情形是四处锚点全都没命中——那时 s == orig 且文件里本无任何标记。
if s == orig and "// PVE_HWPATCH:BEGIN" not in orig:
    sys.exit("ERROR: 前端未发生改动——四处锚点都未命中，PVE 结构可能变过")
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print("  [3] pvemanagerlib.js 已注入（概要条目 + 隐藏逻辑 + 设置页 + 菜单项）")
PY
rc=$?
if [ $rc -ne 0 ]; then
  echo "  前端注入失败，**保持原文件不动**（不回滚，免得把已生效的补丁反倒抹掉）"
  exit 1
fi
if command -v node >/dev/null 2>&1; then
  node --check "$J" >/dev/null 2>&1 \
    && echo "  [3] node 语法校验通过" \
    || { echo "  node 语法校验失败，回滚"; cp -a "$BK/pvemanagerlib.js.bak.hwpatch" "$J"; exit 1; }
else
  echo "  [3] 无 node，跳过语法校验（浏览器侧验证）"
fi

# ---------- 4) 权限代理与 CPU 世代映射 ----------
if [ -x "$AGENT" ]; then
  echo "  [4] $AGENT 就位"
else
  echo "  [4] 警告：$AGENT 不存在或不可执行，请随本脚本一同部署" >&2
fi
if [ -f "$CPUDB" ]; then
  echo "  [4] $CPUDB 就位（CPU 世代映射，s.sh 与 agent 共用）"
else
  echo "  [4] 警告：$CPUDB 缺失，CPU 代号将退化为 family/model" >&2
fi
# 镜像切换脚本：缺失只影响「软件源」那一项，其余功能照常
if [ -x "$MIRROR" ]; then
  echo "  [4] $MIRROR 就位（软件源镜像切换）"
else
  echo "  [4] 提示：$MIRROR 不存在，界面上的「软件源」一项将不可用" >&2
fi

# ---------- 5) 开机自启：施加调频 + 重渲染 ----------
if [ ! -f /etc/systemd/system/pve-hwtools-apply.service ]; then
  cat > /etc/systemd/system/pve-hwtools-apply.service <<'EOU'
[Unit]
Description=Apply PVE hwtools settings (CPU governor / frequency limits, summary render)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pve-hwtools-agent apply

[Install]
WantedBy=multi-user.target
EOU
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable pve-hwtools-apply.service >/dev/null 2>&1
  changed=1; echo "  [5] 已建并启用 pve-hwtools-apply.service"
else
  echo "  [5] pve-hwtools-apply.service 已存在"
fi

# ---------- 6) 生效 ----------
# 只在**后端 Perl 真有改动**时才重启 pvedaemon/pveproxy——那是唯一需要重启才能生效的部分。
# 前端 JS 不必重启：pveproxy 每次请求都读盘，改完普通刷新即见。
# 关键：agent 每次保存配置都会调用本脚本重渲染；若在这里无条件重启，
# 就会重启**正在服务该 API 请求的 pvedaemon 自己**，请求被掐断，
# PVE 遂报 `failed: exit code 1`，界面显示「保存失败」——而配置其实已经写入。
if [ "$backend_changed" = "1" ]; then
  systemctl restart pvedaemon 2>/dev/null
  systemctl restart pveproxy  2>/dev/null
  echo "  [6] 后端有改动，已重启 pvedaemon + pveproxy"
else
  echo "  [6] 后端无改动，不重启（前端改动刷新即生效）"
fi
exit 0
