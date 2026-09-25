#!/bin/bash
# pve-hwpatch.sh —— PVE 面板工具集（硬件概要 + CPU 调频 + 订阅提示屏蔽）
# 版本：V3.0
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
if [ ! -f "$SH" ] || ! grep -q "$MARK-v12" "$SH" 2>/dev/null; then
  cat > "$SH" <<'EOS'
#!/bin/bash
# PVE_HWPATCH-v12 —— 输出节点硬件概要 JSON（单行，纯 ASCII 数值与名称，单位由前端补）
je(){ printf '%s' "$1" | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g; s/[^ -~]//g'; }
command -v sensors >/dev/null 2>&1 || { echo '{}'; exit 0; }
S=$(sensors 2>/dev/null)

CPU_PKG=$(printf '%s\n' "$S" | awk '/Package id 0/{print $4; exit}' | tr -d '+C')
[ -z "$CPU_PKG" ] && CPU_PKG=$(cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | head -1 | awk '{printf "%.1f", $1/1000}')

# 核心温度：只输出**平均值 + 核数**，不再逐核列出。
#   逐核列会随核心数增长（64 核的机器能把概要行撑成好几行），且核名格式
#   各驱动不一（coretemp 是 "Core N:"，部分平台是 "CPU N:"）。取平均后
#   一行固定长度，界面再补上核数即可。
CORE_N=$(printf '%s\n' "$S" | awk '/^Core [0-9]+:|^CPU [0-9]+:/{c++} END{print c+0}')
CORE_AVG=$(printf '%s\n' "$S" | awk '/^Core [0-9]+:|^CPU [0-9]+:/{v=$3; gsub(/[^0-9.-]/,"",v); if(v ~ /^-?[0-9]+(\.[0-9]+)?$/){s+=v; n++}} END{if(n>0) printf "%.1f", s/n; else printf "-"}')

BOARD=$(printf '%s\n' "$S" | awk '/CPUTIN/{print $2; exit}' | tr -d '+C')
[ -z "$BOARD" ] && BOARD=$(printf '%s\n' "$S" | awk '/SYSTIN/{print $2; exit}' | tr -d '+C')

# 风扇：带序号、名字、显示策略（每行 fanN:rpm:label，label 是百分号编码的名字）
#   为何每行一条：名字里可能有空格，用空格或逗号分隔都会被拆碎。
#   为何百分号编码：Perl 反引号读 UTF-8 会二次编码变乱码；编码成纯 ASCII 后，
#   前端 decodeURIComponent 就能完整还原中文。
FANS=""
if [ -r /etc/default/pve-hwtools ]; then
  . /etc/default/pve-hwtools 2>/dev/null || true
  HWM=""
  for _h in /sys/class/hwmon/hwmon*; do
    case "$(cat $_h/name 2>/dev/null)" in
      nct6775|nct6776|nct6779|nct6791|nct6792|nct6793|nct6795|nct6796|nct6797|nct6798)
        HWM=$_h ;;
    esac
  done
  if [ -n "$HWM" ]; then
    for _f in "$HWM"/fan[0-9]*_input; do
      [ -e "$_f" ] || continue
      _n=$(basename "$_f" _input); _n=${_n#fan}
      _r=$(cat "$_f" 2>/dev/null || echo 0)
      eval "_nm=\${FAN${_n}_NAME:-}"
      eval "_sh=\${SHOW_FANCH_${_n}:-\${FANCH_SHOW_DEFAULT:-auto}}"
      case "$_sh" in
        off) continue ;;
        auto) [ "${_r:-0}" -gt 0 ] 2>/dev/null || continue ;;
      esac
      if [ -n "$_nm" ]; then
        _esc=$(printf '%s' "$_nm" | od -An -tx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g')
      else
        _esc=""
      fi
      FANS="${FANS}fan${_n}:${_r}:${_esc}|"
    done
  fi
fi
FANS=${FANS%|}
[ -z "$FANS" ] && FANS="-"

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

printf '{"cpu_pkg":"%s","cpu_core_avg":"%s","cpu_core_n":"%s","disks":"%s","board":"%s","fans":"%s","cpu_cur":"%s","cpu_min":"%s","cpu_max":"%s","cpu_gen":"%s","cpu_base":"%s"}\n' \
  "$(je "${CPU_PKG:--}")" "$(je "${CORE_AVG:--}")" "${CORE_N:-0}" "$(je "$DISKS")" "$(je "${BOARD:--}")" \
  "$(je "${FANS:--}")" "${CUR:-0}" "${MIN:-0}" "${MAX:-0}" "$(je "$CPUGEN")" "${BASEF:-0}"
EOS
  chmod +x "$SH"; changed=1; echo "  [1] 已写 $SH（v12）"
else
  echo "  [1] $SH 已是 v12，跳过"
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
    # protected => 1 必须有，**读接口也一样**：agent status 要做 sysfs/传感器读取，
    # 跑着 need_root 校验。不带这项时请求就在 pveproxy 进程里以 www-data 降权执行，
    # agent 直接 die，于是接口静默返回 {"data":{}}（200，零字段）—— 界面满屏
    # undefined / 「本机未检测到可控风扇通道」，看着像补丁没装，其实是权限。
    # 空响应不报错，这是它最难查的地方。
    protected => 1,
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
            # 冒号与逗号（风扇曲线 25:12,30:24,45:47,60:78,80:100）。
            # 仍只允许字母数字下划线点减号冒号逗号，杜绝 shell 元字符——防注入且不误伤合法取值。
            # 键名必须允许**数字**：风扇配置项形如 fan1_mode / fan3_curve。
            # 曾经只写 [a-z_]+，于是 fan1_mode 一律被判非法、保存永远失败。
            die "非法参数：$kv\\n" if $kv !~ /^[a-z][a-z0-9_]*=[0-9a-zA-Z_.:,%+-]*$/;
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
__PACKAGE__->register_method({
    name => 'hwfantest',
    path => 'hwfantest',
    method => 'POST',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    description => "让指定风扇通道短暂改变转速，便于识别对应风扇；完成后自动还原。",
    proxyto => 'node',
    # protected => 1 必需：pveproxy 以 www-data 跑，不带此标记会被就地降权执行，
    # 而 fan-test 要写 sysfs（需 root）。
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            channel => { type => 'integer', minimum => 1, maximum => 32 },
        },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        my $out = '';
        eval {
            run_command(['/usr/local/bin/pve-hwtools-agent', 'fan-test', "$param->{channel}"],
                        outfunc => sub { $out .= shift });
        };
        die "测试失败：$@\n" if $@;
        my $res = {};
        eval { $res = decode_json($out) };
        return $res;
    },
});
__PACKAGE__->register_method({
    name => 'hwfanbind',
    path => 'hwfanbind',
    method => 'POST',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    description => "自动识别风扇：探测哪些插针真接了风扇，并用 CPU 负载关联推断哪个是 CPU 风扇，随后写回通道名。",
    proxyto => 'node',
    # protected => 1：探测要写 sysfs 与 sched 负载，pveproxy 会降权执行，必须回宿主以 root 跑。
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        # 后台启动立刻返回：识别要 40~60 秒，同步等会撞代理超时。
        # 进度与结果都写在 /run/pve-hwtools-fanbind.json，面板按它轮询。
        my $log = '/run/pve-hwtools-fanbind.log';
        system('setsid nohup /usr/local/bin/pve-hwtools-agent fan-bind '
               . '>' . $log . ' 2>&1 < /dev/null &');
        return { started => 1 };
    },
});

__PACKAGE__->register_method({
    name => 'hwfanbindprogress',
    path => 'hwfanbind-progress',
    method => 'GET',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    description => "查询自动识别风扇的进度（面板轮询用）。",
    proxyto => 'node',
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        my $f = '/run/pve-hwtools-fanbind.json';
        return { state => 'idle' } if !-r $f;
        my $raw = '';
        eval {
            open(my $fh, '<', $f) or die "$!";
            local $/; $raw = <$fh>; close($fh);
        };
        return { state => 'idle' } if $raw eq '';
        my $res = {};
        eval { $res = decode_json($raw) };
        return $res;
    },
});
__PACKAGE__->register_method({
    name => 'hwfantestget',
    path => 'hwfantest-get',
    method => 'GET',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    description => "测试识别（GET 别名）：面板 POST 读不到响应正文，故本地发起、原样回传。",
    proxyto => 'node',
    # protected => 1：要写 sysfs（需 root），pveproxy 会降权执行，必须回宿主跑。
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            channel => { type => 'integer', minimum => 1, maximum => 32 },
        },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        my $out = '';
        my $err = '';
        eval {
            run_command(['/usr/local/bin/pve-hwtools-agent', 'fan-test', "$param->{channel}"],
                        outfunc => sub { $out .= shift },
                        errfunc => sub { $err .= shift });
        };
        $err .= $@ if $@;
        my $res = {};
        eval { $res = decode_json($out) };
        $res->{error} = $err if ($err ne '' && !$res->{error});
        return $res;
    },
});
__PACKAGE__->register_method({
    name => 'hwfanrescan',
    path => 'hwfan-rescan',
    method => 'POST',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    description => "重新探测风扇硬件：按能力重找可控芯片与 pwm 通道，并重置原值基线。换主板后用。",
    proxyto => 'node',
    # protected => 1：探测要遍历 sysfs（需 root），pveproxy 会降权执行，必须回宿主跑。
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
            keep => { type => 'boolean', default => 0, optional => 1 },
        },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        my $out = '';
        eval {
            run_command(['/usr/local/bin/pve-hwtools-agent', 'fan-rescan',
                         ($param->{keep} ? '1' : '0')],
                        outfunc => sub { $out .= shift });
        };
        die "重新扫描失败：$@\n" if $@;
        my $res = {};
        eval { $res = decode_json($out) };
        return $res;
    },
});
__PACKAGE__->register_method({
    name => 'hwhelp',
    path => 'hwhelp',
    method => 'GET',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    description => "面板「使用说明」：返回说明书 HTML（由仓库 README 生成）。",
    proxyto => 'node',
    # 只读 644 的静态文件、不需要 root，但照样加上 protected => 1：
    # 保持本文件里所有接口一致，免得以后有人改成读需 root 的东西时踩同一个坑
    # （少 protected 会被降权成 www-data 执行、且失败是静默的）。
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        # 说明书是纯数据文件，按行读出来即可（不用 run_command，免得给 Perl 字符串
        # 加一层转义）。内容由 tools/mkdoc.py 从 README.md 生成，安装时落到这里。
        my $f = '/usr/local/lib/pve-hwtools/doc.html';
        my $html = '';
        if (open(my $fh, '<:encoding(UTF-8)', $f)) {
            local $/;
            $html = <$fh>;
            close($fh);
        }
        return { found => ($html ne '' ? 1 : 0), html => ($html // '') };
    },
});
__PACKAGE__->register_method({
    name => 'hwupgradestatus',
    path => 'hwupgrade-status',
    method => 'GET',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    description => "系统更新状态：当前/已装/可回退内核，可升级包计数，是否有更新在跑。",
    proxyto => 'node',
    # protected => 1：要读 /etc/kernel、apt-mark、dpkg 并可能写基线文件，需 root。
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        my $out = '';
        eval {
            run_command(['/usr/local/bin/pve-hwtools-agent', 'upgrade-status'],
                        outfunc => sub { $out .= shift },
                        errfunc => sub { });
        };
        my $res = {};
        eval { $res = decode_json($out) };
        return $res;
    },
});
__PACKAGE__->register_method({
    name => 'hwupgradecheck',
    path => 'hwupgrade-check',
    method => 'GET',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Audit']] },
    description => "检查更新（GET 别名）：跑一次 apt update 并统计可升级的 PVE / 内核包。",
    proxyto => 'node',
    # protected => 1：apt update 要写 /var/lib/apt（需 root），pveproxy 会降权执行。
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        my $out = '';
        eval {
            run_command(['/usr/local/bin/pve-hwtools-agent', 'upgrade-check'],
                        outfunc => sub { $out .= shift },
                        errfunc => sub { });
        };
        my $res = {};
        eval { $res = decode_json($out) };
        return $res;
    },
});
__PACKAGE__->register_method({
    name => 'hwupgradepve',
    path => 'hwupgrade-pve-get',
    method => 'GET',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    description => "更新 PVE 软件（GET 别名）：只升软件包，内核一枚不动。面板 POST 读不到响应正文。",
    proxyto => 'node',
    # protected => 1：apt dist-upgrade 必须 root。
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node     => get_standard_option('pve-node'),
            simulate => { type => 'boolean', default => 0, optional => 1 },
        },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        my @cmd = ('/usr/local/bin/pve-hwtools-agent', 'upgrade-pve');
        push @cmd, 'simulate' if $param->{simulate};
        my $out = '';
        eval {
            run_command(\@cmd, outfunc => sub { $out .= shift }, errfunc => sub { });
        };
        my $res = {};
        eval { $res = decode_json($out) };
        $res->{error} = $@ if ($@ && !$res->{error});
        return $res;
    },
});
__PACKAGE__->register_method({
    name => 'hwupgradekernel',
    path => 'hwupgrade-kernel-get',
    method => 'GET',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    description => "更新内核（GET 别名）：装最新内核并保留旧内核，可一键回退。",
    proxyto => 'node',
    # protected => 1：装内核包必须 root。
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => {
            node     => get_standard_option('pve-node'),
            simulate => { type => 'boolean', default => 0, optional => 1 },
        },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        my @cmd = ('/usr/local/bin/pve-hwtools-agent', 'upgrade-kernel');
        push @cmd, 'simulate' if $param->{simulate};
        my $out = '';
        eval {
            run_command(\@cmd, outfunc => sub { $out .= shift }, errfunc => sub { });
        };
        my $res = {};
        eval { $res = decode_json($out) };
        $res->{error} = $@ if ($@ && !$res->{error});
        return $res;
    },
});
__PACKAGE__->register_method({
    name => 'hwkernelrollback',
    path => 'hwkernel-rollback-get',
    method => 'GET',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    description => "回退到保留的旧内核（GET 别名）：把启动项指回更新前那枚内核，重启后生效。",
    proxyto => 'node',
    # protected => 1：要调 proxmox-boot-tool 改启动项（需 root）。
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        my $out = '';
        eval {
            run_command(['/usr/local/bin/pve-hwtools-agent', 'kernel-rollback'],
                        outfunc => sub { $out .= shift }, errfunc => sub { });
        };
        my $res = {};
        eval { $res = decode_json($out) };
        $res->{error} = $@ if ($@ && !$res->{error});
        return $res;
    },
});
__PACKAGE__->register_method({
    name => 'hwkernelrelease',
    path => 'hwkernel-release-get',
    method => 'GET',
    permissions => { check => ['perm', '/nodes/{node}', ['Sys.Modify']] },
    description => "解除对旧内核的保留（GET 别名）：确认新内核一切正常后使用。",
    proxyto => 'node',
    # protected => 1：要调 apt-mark 与 proxmox-boot-tool（需 root）。
    protected => 1,
    parameters => {
        additionalProperties => 0,
        properties => { node => get_standard_option('pve-node') },
    },
    returns => { type => 'object', properties => {} },
    code => sub {
        my ($param) = @_;
        my $out = '';
        eval {
            run_command(['/usr/local/bin/pve-hwtools-agent', 'kernel-release'],
                        outfunc => sub { $out .= shift }, errfunc => sub { });
        };
        my $res = {};
        eval { $res = decode_json($out) };
        $res->{error} = $@ if ($@ && !$res->{error});
        return $res;
    },
});
# PVE_HWAPI:END
'''
s = s.replace(a2, api, 1)

# 2b-1) 护栏：本文件注入的每个接口都必须带 protected => 1。
#   踩过的坑：hwtools_status（读接口）漏了它，于是请求被 pveproxy 以 www-data
#   降权执行、agent 因 need_root 直接 die，接口静默返回 {"data":{}} ——
#   界面满屏 undefined，而一切「看起来」都装好了，极难定位。
#   凡是本补丁注册的方法都调 agent（需 root），一个都不能漏，这里直接拦住。
_bad = []
for _part in api.split("__PACKAGE__->register_method({")[1:]:
    _m = re.search(r"name => '(\w+)'", _part)
    if _m and "protected => 1" not in _part.split("});")[0]:
        _bad.append(_m.group(1))
if _bad:
    sys.exit("ERROR: 以下接口缺少 protected => 1，会在 pveproxy 里被降权执行而静默失败：%s"
             % ", ".join(_bad))

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
            title: gettext('CPU核心温度'),
            textField: 'tdata',
            renderer: function (v) {
                try {
                    var d = JSON.parse(v);
                    var avg = d.cpu_core_avg;
                    if (!avg || avg === '-') { return '-'; }
                    var n = parseInt(d.cpu_core_n, 10) || 0;
                    // 只显示平均值，括号里注明核数（核多的机器逐核列会撑成好几行）
                    return avg + ' °C' + (n > 0 ? '（' + n + ' 核平均）' : '');
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
                    // 记录形如 fanN:转速:名字（名字为百分号编码，可能为空），用 | 分隔。
                    // 名字里已禁止含 | ，故可安全按 | 切。
                    return x.split('|').map(function (y) {
                        if (!y) { return null; }
                        var q = y.split(':');
                        var n = q[0].replace(/^fan/i, '');
                        var rpm = q[1];
                        var nm = '';
                        if (q.length > 2 && q[2]) {
                            try { nm = decodeURIComponent(q[2]); } catch (e) { nm = q[2]; }
                        }
                        return (nm || (gettext('风扇 ') + n)) + ' ' + rpm + ' RPM';
                    }).filter(function (z) { return z !== null; }).join(' | ');
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
// 百分号编码的名字 → 可读文本（后端为避免 Perl 二次编码，名字以 %XX 传递）
PVE.HW.dec = function (x) {
    if (!x) { return ''; }
    try { return decodeURIComponent(x); } catch (e) { return x; }
};

// 百分号编码（ASCII 安全）——名字里可能含中文
PVE.HW.enc = function (x) {
    if (x === undefined || x === null) { return ''; }
    try { return encodeURIComponent(x); } catch (e) { return ''; }
};

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
    // 取显示开关。**取不到就当作全开**（绝不隐藏任何东西）——
    // 这里的失败模式很坑：状态接口一旦瞬时报错（如会话未就绪时返回 {"data":null}），
    // 下面的 `|| {}` 会让四个开关全判 false，于是整块硬件概要被 display:none 藏掉，
    // 用户看到的是「补丁没生效」，而配置、接口、数据其实全都正常。
    // 宁可多显示，不可误隐藏。
    var readSwitches = function () {
        var rq = Ext.Ajax.request({ url: '/api2/json/nodes/' + nodename + '/hwtools', async: false });
        var j = Ext.decode(rq.responseText, true);
        // Ext.decode 带 useNull 参数：解析失败返回 null，不会抛
        if (!j || !j.data) { return null; }
        var d = j.data;
        // 四个开关一个都没有 => 认为这不是有效的状态响应
        if (d.show_cpu_temp === undefined && d.show_fan === undefined
            && d.show_disk === undefined && d.show_cpu_freq === undefined) { return null; }
        var on = function (v) { return String(v) === '1'; };
        return { cpu_temp: on(d.show_cpu_temp), fan: on(d.show_fan),
                 disk: on(d.show_disk), cpu_freq: on(d.show_cpu_freq) };
    };
    var apply = function (sw) {
        if (!sw) { panel._hwHidden = []; return; }   // 读不到 => 什么都不藏
        var ids = [];
        if (!sw.cpu_temp) { ids.push('hw-cputemp', 'hw-board', 'hw-cpucores'); }
        if (!sw.fan) { ids.push('hw-fans'); }
        if (!sw.disk) { ids.push('hw-disktemp'); }
        if (!sw.cpu_freq) { ids.push('hw-cpufreq'); }
        // 四项全关才收表头。注意不能用 ids.length >= 4 判断：
        // 「CPU 温度 + 风扇」两项关掉也会凑满 4 个 id，那样会把表头一起误藏。
        if (!sw.cpu_temp && !sw.fan && !sw.disk && !sw.cpu_freq) { ids.push('hw-header'); }
        panel._hwHidden = ids;
    };
    var sw = null;
    try { sw = readSwitches(); } catch (e) { sw = null; }
    apply(sw);
    var run = function () { PVE.HW.hide(panel); };
    if (panel.rendered) {
        run();
    } else {
        panel.on('afterrender', run);
    }
    // 首读失败（常见于会话还没就绪）则稍后重试一次，拿到真值后再应用
    if (!sw) {
        Ext.defer(function () {
            var s2 = null;
            try { s2 = readSwitches(); } catch (e) { s2 = null; }
            if (s2) { apply(s2); PVE.HW.hide(panel); }
        }, 1500);
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
                        mkCb('显示 CPU 温度（封装与核心平均）', 'show_cpu_temp'),
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
                        {
                            xtype: 'container',
                            layout: 'hbox',
                            margin: '6 0 2 0',
                            items: [
                                { xtype: 'button', text: gettext('自动识别风扇'),
                                  iconCls: 'fa fa-magic', width: 148,
                                  handler: function () { me.fanBind(); } },
                                { xtype: 'button', text: gettext('重新识别芯片与通道'),
                                  iconCls: 'fa fa-refresh', width: 186,
                                  margin: '0 0 0 8',
                                  handler: function () { me.fanRescan(); } },
                            ],
                        },
                    ],
                },
                {
                    xtype: 'fieldset',
                    title: gettext('系统更新'),
                    itemId: 'upgfs',
                    defaults: { margin: '4 0' },
                    items: [
                        {
                            xtype: 'component',
                            itemId: 'upghint',
                            html: '',
                        },
                        {
                            xtype: 'container',
                            layout: 'hbox',
                            margin: '6 0 2 0',
                            items: [
                                { xtype: 'button', text: gettext('检查更新'),
                                  iconCls: 'fa fa-search', width: 112,
                                  handler: function () { me.upgCheck(); } },
                                { xtype: 'button', text: gettext('更新 PVE 软件'),
                                  iconCls: 'fa fa-arrow-circle-up', width: 152,
                                  margin: '0 0 0 8',
                                  handler: function () { me.upgRun('pve'); } },
                                { xtype: 'button', text: gettext('更新内核'),
                                  iconCls: 'fa fa-microchip', width: 122,
                                  margin: '0 0 0 8',
                                  handler: function () { me.upgRun('kernel'); } },
                            ],
                        },
                        {
                            xtype: 'container',
                            layout: 'hbox',
                            margin: '2 0 0 0',
                            items: [
                                { xtype: 'button', text: gettext('回退到旧内核'),
                                  iconCls: 'fa fa-undo', width: 152, itemId: 'btrollback',
                                  handler: function () { me.upgRollback(); } },
                                { xtype: 'button', text: gettext('确认新内核正常，解除保留'),
                                  iconCls: 'fa fa-check-circle', width: 236,
                                  margin: '0 0 0 8', itemId: 'btrelease',
                                  handler: function () { me.upgRelease(); } },
                            ],
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
                        {
                            xtype: 'button',
                            text: gettext('使用说明'),
                            iconCls: 'fa fa-book',
                            margin: '0 0 0 8',
                            handler: function () { me.showHelp(); },
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


        // 使用说明：说明书正文由宿主文件 /usr/local/lib/pve-hwtools/doc.html 提供
        // （安装时由 tools/mkdoc.py 从仓库 README 生成），这里只负责取回并弹窗。
        // 刻意不把正文内联进本注入块——那会往 ui 块塞进大量反斜杠与引号，
        // 踩中「注入块禁止反斜杠转义」的铁律，一做就废。
        showHelp: function () {
            var me = this;
            me.setLoading(gettext('正在载入说明书…'));
            Proxmox.Utils.API2Request({
                url: '/nodes/' + me.nodename + '/hwhelp',
                method: 'GET',
                failure: function (r) {
                    me.setLoading(false);
                    Ext.Msg.alert(gettext('使用说明'), gettext('读取失败：') + r.htmlStatus);
                },
                success: function (response) {
                    me.setLoading(false);
                    var d = (response.result && response.result.data) || {};
                    if (!d.found || !d.html) {
                        Ext.Msg.alert(gettext('使用说明'),
                            gettext('宿主上没有说明书文件 /usr/local/lib/pve-hwtools/doc.html。') +
                            gettext('重新执行一次 install.sh 即可装好；完整说明也可看仓库 README.md。'));
                        return;
                    }
                    // 关掉旧的再开：反复点按钮不会层层叠窗
                    if (me._helpWin) { me._helpWin.close(); me._helpWin = null; }
                    var win = Ext.create('Ext.window.Window', {
                        title: gettext('PVE 工具集 · 使用说明'),
                        width: Math.min(980, Math.round(Ext.getBody().getWidth() * 0.92)),
                        height: Math.round(Ext.getBody().getHeight() * 0.88),
                        layout: 'fit',
                        maximizable: true,
                        modal: true,
                        scrollable: true,
                        bodyPadding: 14,
                        html: d.html,
                        listeners: { close: function () { me._helpWin = null; } },
                    });
                    me._helpWin = win;
                    win.show();
                },
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
            // 芯片给的标签（PECI Agent 0 / AUXTIN0）没人看得懂，后端已翻成人话。
            // 「推荐」= 该路真的代表 CPU 温度；没接传感器的 AUXTIN 一律排后面并标注，
            // 免得选了个空脚（风扇就不会跟任何温度走了）。
            var sources = (d.fan_sources || []).map(function (x) {
                var rec = x.rec ? (' ' + gettext('（推荐）')) : '';
                var dead = (x.role === 'aux') ? (' ' + gettext('（未接）')) : '';
                return {
                    v: x.human + rec + dead + ' · ' + (x.temp / 1000).toFixed(1) + ' °C',
                    val: String(x.n),
                    human: x.human, role: x.role, rec: x.rec || 0, temp: x.temp || 0,
                };
            }).sort(function (a, b) {
                if ((a.rec ? 1 : 0) !== (b.rec ? 1 : 0)) { return b.rec - a.rec; }
                if ((a.role === 'aux' ? 1 : 0) !== (b.role === 'aux' ? 1 : 0)) {
                    return (a.role === 'aux' ? 1 : 0) - (b.role === 'aux' ? 1 : 0);
                }
                return Number(a.val) - Number(b.val);
            });
            var hint = me.down('#fanhint');
            if (hint) {
                hint.setHtml('<span style="color:#888">' +
                    (fans.length
                        ? (gettext('共 ') + fans.length + gettext(' 个通道。自动 = 交给主板硬件按曲线调速（无需常驻程序）；手动 = 固定占空比。占空比一律填百分比（1~100%）。曲线五点须按温度由低到高。') +
                           '<br/>' + gettext('「跟哪路温度」决定该通道随哪一路温度升降 —— CPU 风扇选「CPU 核心温度」，机箱风扇可跟「主板温度」。括号里的数值是当前读数。') +
                           '<br/>' + gettext('模式为「关闭（用主板设置）」时，该列显示的是主板当前实际在跟的温度源；要改需先切到「自动曲线」。'))
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
                while (cpts.length < 5) { cpts.push({ t: 30 + cpts.length * 10, w: 12 + cpts.length * 22 }); }

                fs.add(Ext.create('Ext.container.Container', {
                    itemId: 'fanrow' + n,
                    margin: '2 0',
                    layout: 'hbox',
                    defaults: { margin: '0 8 0 0', xtype: 'numberfield', width: 76 },
                    items: [
                        { xtype: 'component', width: 108, margin: '6 8 0 0',
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
                          emptyText: gettext('占空比%'), minValue: 1, maxValue: 100,
                          // 占空比一律用百分比；内核要的 0~255 由后端换算
                          value: (f.manual !== undefined && f.manual !== null) ? f.manual : 50,
                          allowBlank: false,
                          listeners: { change: function () { me.fanSyncRow(n); } } },
                        { name: 'fan' + n + '_sel', xtype: 'combo', width: 232,
                          hideLabel: true, editable: false, forceSelection: true,
                          queryMode: 'local', displayField: 'v', valueField: 'val',
                          emptyText: gettext('跟哪路温度'),
                          store: { fields: ['v', 'val'], data: sources },
                          value: String((f.mode === 'off' ? (f.sel_live !== undefined ? f.sel_live : f.sel) : f.sel) || '') },
                        { name: 'fan' + n + '_name', xtype: 'textfield', width: 130,
                          hideLabel: true, emptyText: gettext('名字（可留空）'),
                          value: PVE.HW.dec(f.name || '') },
                        { name: 'show_fanch_' + n, xtype: 'combo', width: 122,
                          hideLabel: true, editable: false, forceSelection: true,
                          queryMode: 'local', displayField: 'v', valueField: 'val',
                          store: { fields: ['v', 'val'], data: [
                              { v: gettext('自动显示'), val: 'auto' },
                              { v: gettext('始终显示'), val: 'on' },
                              { v: gettext('不显示'), val: 'off' } ] },
                          value: f.show || 'auto' },
                        { xtype: 'button', text: gettext('测试识别'), width: 86,
                          margin: '0 0 0 4',
                          handler: function () { me.fanTest(n); } },
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
                               width: 58, emptyText: gettext('占空比%'), minValue: 1, maxValue: 100,
                               value: x.w, hideLabel: true, margin: '0 10 0 0' });
                });
                fs.add(crow);

                me.fanSyncRow(n);
            });
        },

        // 换主板后重探：按能力重找可控芯片与 pwm 通道（不写死型号）。
        // 必须先问清要不要保留通道名——新板子的通道号可能完全不同，
        // 留着旧名字会张冠李戴（旧「机箱风扇」可能落到新板子的 CPU 插针上）。
        fanRescan: function () {
            var me = this;
            Ext.Msg.show({
                title: gettext('重新识别芯片与通道'),
                msg: gettext('将重新扫描本机的风扇控制芯片与 pwm 通道。换主板后请点这里。<br/><br/>'
                    + '换主板时通道号往往会变，旧名字可能张冠李戴 —— 是否保留现有的通道名与显示设置？'),
                buttons: Ext.Msg.YESNOCANCEL,
                buttonText: {
                    yes: gettext('保留名字'),
                    no: gettext('清空名字'),
                    cancel: gettext('取消'),
                },
                icon: Ext.Msg.QUESTION,
                fn: function (btn) {
                    if (btn === 'cancel') { return; }
                    var keep = (btn === 'yes') ? 1 : 0;
                    me.setLoading(gettext('正在重新扫描…'));
                    Proxmox.Utils.API2Request({
                        url: '/nodes/' + me.nodename + '/hwfan-rescan',
                        method: 'POST',
                        params: { keep: keep },
                        success: function (response) {
                            me.setLoading(false);
                            var d = response.result.data || {};
                            var lines = [];
                            (d.all || []).forEach(function (c) {
                                lines.push(c.dir + '  ' + c.name + '  ' +
                                    (c.channels ? (gettext('通道 ') + c.channels) : gettext('无 pwm 通道')));
                            });
                            var head = d.chip
                                ? (gettext('已识别风扇芯片：') + d.chip + gettext('，可控通道 ') + d.channels + '。')
                                : gettext('未找到任何可控风扇通道（本机可能没有 Super I/O 或驱动未加载）。');
                            var extra = '';
                            if (d.prev_hwid && d.prev_hwid !== d.hwid && d.prev_hwid !== 'none') {
                                extra += '<br/><span style="color:#a60">' + gettext('检测到硬件已变化：')
                                    + d.prev_hwid + ' → ' + d.hwid + gettext('，原值基线已重置。') + '</span>';
                            }
                            if (d.pruned) {
                                extra += '<br/>' + gettext('已清理不再存在的通道配置：') + d.pruned;
                            }
                            Ext.Msg.alert(gettext('扫描完成'), head +
                                (lines.length ? ('<br/><br/>' + lines.join('<br/>')) : '') + extra);
                            me.reload();
                        },
                        failure: function (response) {
                            me.setLoading(false);
                            Ext.Msg.alert(gettext('扫描失败'), response.htmlStatus);
                        },
                    });
                },
            });
        },

        // 自动识别：探测哪些插针真接了风扇，再用 CPU 负载关联推断哪个是 CPU 风扇，
        // 随后自动写好通道名；没接风扇的通道自动隐藏显示。约 20 秒，期间 CPU 会满载。
        fanBind: function () {
            var me = this;
            Ext.Msg.confirm(gettext('自动识别风扇'),
                gettext('将逐个试探各通道（约 15 秒，期间风扇会有明显响动），识别哪些插针真接了风扇，并按温度源自动起名；未接风扇的通道将自动隐藏。已有名字不会被覆盖。继续？'),
                function (btn) {
                    if (btn !== 'yes') { return; }
                    me.setLoading(gettext('正在识别…'));
                    // 后台任务 + 轮询：识别要 40~60 秒，一个请求等不下来。
                    Proxmox.Utils.API2Request({
                        url: '/nodes/' + me.nodename + '/hwfanbind',
                        method: 'POST',
                        success: function () { me.fanBindPoll(0); },
                        failure: function (r) {
                            me.setLoading(false);
                            Ext.Msg.alert(gettext('识别失败'), r.htmlStatus);
                        },
                    });
                });
        },

        fanBindPoll: function (n) {
            var me = this;
            if (n > 60) {
                me.setLoading(false);
                Ext.Msg.alert(gettext('识别超时'), gettext('任务未在预期时间内结束，请到节点 Shell 执行 pve-hwtools-agent fan-bind 查看。'));
                return;
            }
            Ext.Ajax.request({
                url: '/api2/json/nodes/' + me.nodename + '/hwfanbind-progress',
                method: 'GET',
                success: function (response) {
                    var d = {};
                    try { d = JSON.parse(response.responseText || '{}'); } catch (e) { d = {}; }
                    d = d.data || {};
                    if (d.state === 'done') {
                        me.setLoading(false);
                        me.fanBindReport(d.result);
                        me.reload();
                        return;
                    }
                    if (d.state === 'idle') { me.setLoading(false); return; }
                    me.setLoading((d.step || gettext('识别中…')) + ' ' + (d.pct || 0) + '%');
                    setTimeout(function () { me.fanBindPoll(n + 1); }, 2000);
                },
                failure: function () {
                    me.setLoading(false);
                    Ext.Msg.alert(gettext('识别失败'), gettext('无法读取进度，请重试。'));
                },
            });
        },

        // 把识别结果讲清楚——尤其要说明「分不出物理身份」这件事，别让人以为已完全认准。
        fanBindReport: function (res) {
            var me = this;
            var d = res || {};
            var ch = (d.channels || []);
            var rows = [];
            var order = me.stringifyOrder || [];
            ch.forEach(function (c) {
                var nm = me.fanNameOf(c.n);
                rows.push(gettext('通道 ') + c.n + '：' + (c.present
                    ? (nm ? nm : gettext('已接风扇')) + gettext('　转速 ') + c.rpm + gettext(' RPM')
                    : gettext('未检测到风扇（已隐藏）')));
            });
            var head = gettext('已按「该通道跟随哪一路温度」自动归类命名。');
            if (d.hidden) { head += gettext(' 未接风扇的通道：') + d.hidden + gettext('，已设为不显示。'); }
            var tail = '<br/><br/><span style="color:#a60">' + gettext(
                '注意：主板芯片不提供风扇名称，也无法从硬件区分哪个插头是 CPU 风扇。若名字不对，请点对应行的「测试识别」听声辨位后改名。') + '</span>';
            Ext.Msg.alert(gettext('识别完成'), head + (rows.length ? ('<br/><br/>' + rows.join('<br/>')) : '') + tail);
        },

        // 从当前面板里读出某通道现已保存的名字（保存后会回读）
        fanNameOf: function (n) {
            var me = this;
            var c = me.down('[name=fan' + n + '_name]');
            return c ? PVE.HW.dec(c.getValue() || '') : '';
        },


        // 测试识别：让该通道转一次，便于听声或盯着看辨位。后端做完无条件还原。
        fanTest: function (n) {
            var me = this;
            Ext.Msg.show({
                title: gettext('测试识别'),
                msg: gettext('会让通道 ') + n + gettext(' 明显变一次转速（约 15 秒），随后自动还原主板设置。请留意是哪个风扇在响。'),
                buttons: Ext.Msg.OKCANCEL,
                icon: Ext.Msg.QUESTION,
                fn: function (btn) {
                    if (btn !== 'ok') { return; }
                    me.setLoading(gettext('测试中…'));
                    // 走宿主侧 GET 别名而非直发 POST：面板的 POST 响应正文读不到，
                    // 别名在宿主本地发起请求，结果能完整回传。
                    Ext.Ajax.request({
                        url: '/api2/json/nodes/' + me.nodename + '/hwfantest-get?channel=' + n,
                        method: 'GET',
                        success: function (response) {
                            me.setLoading(false);
                            var r = {};
                            try { r = JSON.parse(response.responseText || '{}'); } catch (e) { r = {}; }
                            r = r.data || {};
                            var txt = r.moved
                                ? (gettext('已制造明显变化：') + r.before + ' → ' + r.peak + gettext(' RPM，现已还原原状。'))
                                : (gettext('转速未见明显变化（') + r.before + ' → ' + r.peak + gettext(' RPM）——该通道可能没接风扇，或风扇不支持调速。（试转用的占空比：') + (r.target !== undefined ? r.target + '%' : '') + gettext('）'));
                            Ext.Msg.alert(gettext('测试完成'), txt);
                            me.reload();
                        },
                        failure: function (response) {
                            me.setLoading(false);
                            Ext.Msg.alert(gettext('测试失败'), response.htmlStatus);
                        },
                    });
                },
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

        // ── 系统更新 ───────────────────────────────────────────────────
        // 更新区与「保存并应用」互不相干：它直接动宿主包与启动项，不写本页配置。
        upgRefresh: function () {
            var me = this;
            Ext.Ajax.request({
                url: '/api2/json/nodes/' + me.nodename + '/hwupgrade-status',
                method: 'GET',
                success: function (response) {
                    if (me.destroyed || !me.down) { return; }
                    var r = {};
                    try { r = JSON.parse(response.responseText || '{}'); } catch (e) { r = {}; }
                    me.upgRender((r.data || {}));
                },
                failure: function () {
                    if (me.destroyed || !me.down) { return; }
                    me.upgRender(null);
                },
            });
        },

        upgRender: function (d) {
            var me = this;
            var hint = me.down('#upghint');
            if (!hint) { return; }
            var btRoll = me.down('#btrollback');
            var btRel = me.down('#btrelease');
            if (!d) {
                hint.setHtml('<span style="color:#a00">' + gettext('更新状态读取失败。') + '</span>');
                if (btRoll) { btRoll.setDisabled(true); }
                if (btRel) { btRel.setDisabled(true); }
                return;
            }
            var fmt = function (ts) {
                if (!ts) { return ''; }
                var x = new Date(ts * 1000);
                var p = function (n) { return (n < 10 ? '0' : '') + n; };
                return x.getFullYear() + '-' + p(x.getMonth() + 1) + '-' + p(x.getDate()) + ' ' +
                       p(x.getHours()) + ':' + p(x.getMinutes());
            };
            var L = [];
            L.push(gettext('运行内核：') + '<b>' + (d.running_kernel || '?') + '</b>' +
                   (d.pinned_kernel ? (gettext('　启动项：') + d.pinned_kernel) : ''));
            if (d.installed_kernels) {
                L.push(gettext('已装内核：') + d.installed_kernels);
            }
            var held = parseInt(d.fallback_held_n, 10) || 0;
            var all = parseInt(d.fallback_all_n, 10) || 0;
            if (d.fallback_kernel) {
                var okAll = (all > 0 && held === all);
                var tail = okAll
                    ? '<span style="color:#080">' + gettext('已保留，可回退') + '</span>'
                    : '<span style="color:#a60">' + gettext('保留不完整（') + held + '/' + all +
                      gettext(' 个包仍被钉住），回退可能失败') + '</span>';
                L.push(gettext('保留的旧内核：') + '<b>' + d.fallback_kernel + '</b>　' + tail +
                       (d.fallback_ts ? ('　' + gettext('（记录于 ') + fmt(d.fallback_ts) + '）') : ''));
            } else {
                L.push('<span style="color:#888">' + gettext('尚未保留旧内核。执行一次「更新 PVE 软件」或「更新内核」时会自动把当前内核保留下来。') + '</span>');
            }
            if (d.upgrading) {
                L.push('<span style="color:#a60">' + gettext('有更新任务正在执行…') + '</span>');
            } else if (d.upgrade_pve || d.upgrade_kernel) {
                L.push(gettext('可升级：PVE 软件 ') + d.upgrade_pve + gettext(' 项，内核 ') + d.upgrade_kernel +
                       gettext(' 项') + (d.kernel_update_available ? gettext('（有内核更新）') : '') +
                       (d.upgrade_ts ? ('　' + gettext('（检查于 ') + fmt(d.upgrade_ts) + '）') : ''));
            } else {
                L.push(d.upgrade_ts
                    ? (gettext('可升级：无（检查于 ') + fmt(d.upgrade_ts) + '）')
                    : gettext('点「检查更新」查看可用更新（会联机刷新一次软件源索引）。'));
            }
            L.push('<span style="color:#888">' + gettext('更新不会自动重启。内核更新后需自行重启才生效；重启前确认新内核没问题，再点「解除保留」。') + '</span>');
            L.push('<span style="color:#888">' + gettext('核显 SR-IOV（i915-sriov-dkms）的驱动编译不在本工具处理范围内 —— 更新内核后如需重建，请自行处理。') + '</span>');
            hint.setHtml(L.join('<br/>'));

            if (btRoll) { btRoll.setDisabled(!d.fallback_kernel || d.upgrading); }
            if (btRel) { btRel.setDisabled(!d.fallback_kernel || d.upgrading); }
        },

        upgCheck: function () {
            var me = this;
            me.setLoading(gettext('正在检查更新…'));
            Ext.Ajax.request({
                url: '/api2/json/nodes/' + me.nodename + '/hwupgrade-check',
                method: 'GET',
                timeout: 180000,
                success: function (response) {
                    me.setLoading(false);
                    if (me.destroyed || !me.down) { return; }
                    var r = {};
                    try { r = JSON.parse(response.responseText || '{}'); } catch (e) { r = {}; }
                    var d = r.data || {};
                    if (d.ok === false) {
                        Ext.Msg.alert(gettext('检查失败'), gettext('软件源索引刷新失败（退出码 ') + d.rc + gettext('）。详见宿主上的日志。'));
                    } else {
                        Ext.Msg.alert(gettext('检查完成'),
                            gettext('可升级：PVE 软件 ') + d.pve + gettext(' 项，内核 ') + d.kernel + gettext(' 项。'));
                    }
                    me.upgRefresh();
                },
                failure: function (response) {
                    me.setLoading(false);
                    Ext.Msg.alert(gettext('检查失败'), response.htmlStatus);
                },
            });
        },

        upgRun: function (what) {
            var me = this;
            var isPve = (what === 'pve');
            var title = isPve ? gettext('更新 PVE 软件') : gettext('更新内核');
            var body = isPve
                ? gettext('将更新 PVE 与 Debian 的软件包（<b>内核一枚都不动</b>）。<br/><br/>动手前会自动把<b>当前内核</b>保留下来（apt-mark hold），万一更新失败可一键回退。不会自动重启。<br/><br/>继续？')
                : gettext('将安装最新内核，并<b>保留当前内核</b>以便回退。装好后启动项会切到新内核，但<b>需自行重启才生效</b>。不会自动重启。<br/><br/>继续？');
            Ext.Msg.confirm(title, body, function (btn) {
                if (btn !== 'yes') { return; }
                me.setLoading(isPve ? gettext('正在更新 PVE 软件…') : gettext('正在更新内核…'));
                var url = '/api2/json/nodes/' + me.nodename + (isPve ? '/hwupgrade-pve-get' : '/hwupgrade-kernel-get');
                Ext.Ajax.request({
                    url: url,
                    method: 'GET',
                    timeout: 1800000,
                    success: function (response) {
                        var r = {};
                        try { r = JSON.parse(response.responseText || '{}'); } catch (e) { r = {}; }
                        var d = r.data || {};
                        me.setLoading(false);
                        if (me.destroyed || !me.down) { return; }
                        var msg = d.msg || '';
                        if (!d.ok) {
                            Ext.Msg.alert(title + gettext(' 未成功'), msg || gettext('详见宿主日志。'));
                        } else {
                            var extra = '';
                            if (!isPve && d.reboot_needed) {
                                extra = '<br/><br/>' + gettext('重启后才会用上新内核。重启前若发现问题，可点「回退到旧内核」。');
                            }
                            Ext.Msg.alert(title + gettext(' 完成'), msg + extra);
                        }
                        me.upgRefresh();
                    },
                    failure: function (response) {
                        me.setLoading(false);
                        Ext.Msg.alert(title + gettext(' 失败'), response.htmlStatus);
                    },
                });
            });
        },

        upgRollback: function () {
            var me = this;
            Ext.Msg.confirm(gettext('回退到旧内核'),
                gettext('将把启动项切回更新前保留的那枚内核。<b>需要重启才生效</b>，重启后这台主机会运行旧内核。<br/><br/>继续？'),
                function (btn) {
                    if (btn !== 'yes') { return; }
                    me.setLoading(gettext('正在切换启动内核…'));
                    Ext.Ajax.request({
                        url: '/api2/json/nodes/' + me.nodename + '/hwkernel-rollback-get',
                        method: 'GET',
                        timeout: 180000,
                        success: function (response) {
                            me.setLoading(false);
                            if (me.destroyed || !me.down) { return; }
                            var r = {};
                            try { r = JSON.parse(response.responseText || '{}'); } catch (e) { r = {}; }
                            var d = r.data || {};
                            if (!d.ok) {
                                Ext.Msg.alert(gettext('回退失败'), d.msg || gettext('详见宿主日志。'));
                            } else {
                                me.reload();
                                Ext.Msg.alert(gettext('已切换启动内核'), d.msg);
                            }
                        },
                        failure: function (response) {
                            me.setLoading(false);
                            Ext.Msg.alert(gettext('回退失败'), response.htmlStatus);
                        },
                    });
                });
        },

        upgRelease: function () {
            var me = this;
            Ext.Msg.confirm(gettext('解除旧内核保留'),
                gettext('确认新内核一切正常后再做这一步。解除后旧内核不再被钉住（仍留在启动菜单里），今后清理内核时可能被移除。<br/><br/>继续？'),
                function (btn) {
                    if (btn !== 'yes') { return; }
                    me.setLoading(gettext('正在解除保留…'));
                    Ext.Ajax.request({
                        url: '/api2/json/nodes/' + me.nodename + '/hwkernel-release-get',
                        method: 'GET',
                        timeout: 180000,
                        success: function (response) {
                            me.setLoading(false);
                            if (me.destroyed || !me.down) { return; }
                            var r = {};
                            try { r = JSON.parse(response.responseText || '{}'); } catch (e) { r = {}; }
                            var d = r.data || {};
                            if (!d.ok) {
                                Ext.Msg.alert(gettext('解除失败'), d.msg || gettext('详见宿主日志。'));
                            } else {
                                me.upgRefresh();
                                Ext.Msg.alert(gettext('已解除保留'), d.msg);
                            }
                        },
                        failure: function (response) {
                            me.setLoading(false);
                            Ext.Msg.alert(gettext('解除失败'), response.htmlStatus);
                        },
                    });
                });
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

                // 更新区：另走 hwupgrade-status（读内核/apt 状态），随每次载入刷新
                me.upgRefresh();

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
                        ? ((d.fan_chip ? (d.fan_chip + '（' + (d.fan_dir || '') + '）· ') : '') +
                           gettext('通道 ') + d.fan_channels + gettext('，本机可控'))
                        : gettext('本机未识别到可控风扇通道（可点「重新识别芯片与通道」重试）')) +
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
            // 名字：即使模式是 off 也要提交（命名与调速是两件事）
            var nm = me.fanVal('fan' + n + '_name');
            kv.push('fan' + n + '_name=' + PVE.HW.enc(nm === null ? '' : String(nm)));
            var sh = me.fanVal('show_fanch_' + n);
            if (sh) { kv.push('show_fanch_' + n + '=' + sh); }
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
s = re.sub(r"(alias: 'widget\.pveNodeStatus',<br/><br/>    height: )\d+(,)", r"\g<1>480\g<2>", s, count=1)

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
