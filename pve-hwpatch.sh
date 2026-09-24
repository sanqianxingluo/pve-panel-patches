#!/bin/bash
# pve-hwpatch.sh —— 恢复 PVE 节点概要的硬件信息（CPU/主板/硬盘温度、风扇转速、CPU频率）
# 版本：V1.1
#
# 作用：PVE 原生节点 Summary 不显示温度/风扇/频率。本脚本向以下两处注入补丁，
#       使节点概要页新增「硬件概要」区块：
#         - 后端 /usr/share/perl5/PVE/API2/Nodes.pm   （注入 $res->{tdata}）
#         - 前端 /usr/share/pve-manager/js/pvemanagerlib.js （新增 hw-* 条目）
#       另写取样脚本 /usr/bin/s.sh，输出单行 JSON 供前端渲染。
#
# 显示内容（V1.1）：
#   CPU温度（封装）、主板温度（两项并排）
#   CPU各核  —— 带核名，如「Core 0 43.0 °C  Core 1 41.0 °C」
#   风扇转速 —— 带序号，如「Fan1 992 RPM  Fan2 1214 RPM」
#   硬盘温度 —— 型号 + 容量 + 温度，如「Lexar SSD NM620 512GB  39 °C  512G」
#   CPU频率   —— 实时 / 最小~最大
#
# 特性：幂等（已打过则跳过，版本升级时自动替换旧块）；可反复执行；由 apt Post-Invoke 调用可自愈。
#       pve-manager 每次升级都会覆盖上述两个文件，故建议配套：
#         /etc/apt/apt.conf.d/98-pve-hwpatch
#         DPkg::Post-Invoke { "/usr/local/bin/pve-hwpatch.sh"; };
#
# 依赖：lm-sensors（必需，提供 sensors）、smartmontools（可选，读 SATA 盘温）、
#       python3（必需，做文本注入）、node（可选，前端语法预检）
#
# 设计要点：/usr/bin/s.sh 只输出「纯 ASCII 数字与名称」，单位（°C / RPM / MHz）一律由前端 JS 补，
#       以避开 Perl 反引号读 UTF-8 时被二次编码（° → Â°）的陷阱；字符类过滤一律 LC_ALL=C，
#       否则 GNU sed 会按 collation 排序解释 [^ -~] 而误删数字。
#
# 前端注入块以 // PVE_HWPATCH:BEGIN / :END 包裹，便于版本升级时整块替换。
# 备份：改写前自动备份到 /root/pve-upgrade-backup/，失败时自动回滚。
set -u
MARK=PVE_HWPATCH
J=/usr/share/pve-manager/js/pvemanagerlib.js
N=/usr/share/perl5/PVE/API2/Nodes.pm
SH=/usr/bin/s.sh
BK=/root/pve-upgrade-backup
mkdir -p "$BK"
changed=0

# ---------- 1) 传感器取样脚本（纯 ASCII 数值与名称）----------
if [ ! -f "$SH" ] || ! grep -q "$MARK-v7" "$SH" 2>/dev/null; then
  cat > "$SH" <<'EOS'
#!/bin/bash
# PVE_HWPATCH-v7 —— 输出节点硬件概要 JSON（单行，纯 ASCII 数值与名称，单位由前端补）
je(){ printf '%s' "$1" | LC_ALL=C sed 's/\\/\\\\/g; s/"/\\"/g; s/[^ -~]//g'; }
command -v sensors >/dev/null 2>&1 || { echo '{}'; exit 0; }
S=$(sensors 2>/dev/null)

CPU_PKG=$(printf '%s\n' "$S" | awk '/Package id 0/{print $4; exit}' | tr -d '+C')
[ -z "$CPU_PKG" ] && CPU_PKG=$(cat /sys/class/hwmon/hwmon*/temp1_input 2>/dev/null | head -1 | awk '{printf "%.1f", $1/1000}')

# 各核：带核名（Core 0:44.0,Core 1:43.0,...  逗号分隔，因核名内含空格）
CORES=$(printf '%s\n' "$S" | awk '/^Core [0-9]+:/{n=$1" "$2; sub(/:$/,"",n); v=$3; gsub(/[+C]/,"",v); printf "%s:%s,", n, v}' | sed 's/,$//')

BOARD=$(printf '%s\n' "$S" | awk '/CPUTIN/{print $2; exit}' | tr -d '+C')
[ -z "$BOARD" ] && BOARD=$(printf '%s\n' "$S" | awk '/SYSTIN/{print $2; exit}' | tr -d '+C')

# 风扇：带序号（fan1:1106,fan2:1407）；型号名前端美化
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
# NVMe：hwmon -> 控制器 -> 块设备
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
# SATA/SAS：smartctl
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

printf '{"cpu_pkg":"%s","cpu_cores":"%s","disks":"%s","board":"%s","fans":"%s","cpu_cur":"%s","cpu_min":"%s","cpu_max":"%s"}\n' \
  "$(je "${CPU_PKG:--}")" "$(je "${CORES:--}")" "$(je "$DISKS")" "$(je "${BOARD:--}")" \
  "$(je "${FANS:--}")" "${CUR:-0}" "${MIN:-0}" "${MAX:-0}"
EOS
  chmod +x "$SH"; changed=1; echo "  [1] 已写 $SH（v7，含核名/风扇序号/硬盘型号容量）"
else
  echo "  [1] $SH 已是 v7，跳过"
fi

# ---------- 2) 后端：注入 $res->{tdata} ----------
md5_before=$(md5sum "$N" | cut -d' ' -f1)
if ! grep -q "$MARK" "$N" 2>/dev/null; then
  cp -a "$N" "$BK/Nodes.pm.bak.hwpatch"
  python3 - "$N" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='surrogateescape').read()
anchor = "            free => $dinfo->{blocks} - $dinfo->{used},\n        };\n"
if anchor not in s:
    sys.exit("ERROR: 后端锚点未找到")
add = anchor + "\n        # PVE_HWPATCH\n        $res->{tdata} = `/usr/bin/s.sh 2>/dev/null`;\n"
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s.replace(anchor, add, 1))
print("  [2] Nodes.pm 已插桩")
PY
  [ $? -ne 0 ] && { echo "  后端插桩失败"; cp -a "$BK/Nodes.pm.bak.hwpatch" "$N"; exit 1; }
  perl -c "$N" >/dev/null 2>&1 || { echo "  perl 语法校验失败，回滚"; cp -a "$BK/Nodes.pm.bak.hwpatch" "$N"; exit 1; }
  echo "  [2] perl 语法校验通过"
  changed=1
else
  echo "  [2] Nodes.pm 已含补丁，跳过"
fi

# ---------- 3) 前端：插入/替换概要条目（以 BEGIN/END 包裹，可随版本替换）----------
md5_j_before=$(md5sum "$J" | cut -d' ' -f1)
[ ! -f "$BK/pvemanagerlib.js.bak.hwpatch" ] && cp -a "$J" "$BK/pvemanagerlib.js.bak.hwpatch"
python3 - "$J" <<'PY'
import sys, re
p = sys.argv[1]
s = open(p, encoding='utf-8', errors='surrogateescape').read()

# --- 先移除任何已存在的注入块（新式 BEGIN/END，或旧式单标记）---
if "// PVE_HWPATCH:BEGIN" in s:
    s = re.sub(r"\n *// PVE_HWPATCH:BEGIN.*?// PVE_HWPATCH:END\n", "\n", s, flags=re.S)
elif "// PVE_HWPATCH" in s:
    s = re.sub(r"\n *// PVE_HWPATCH\n.*?\n    \],\n", "\n    ],\n", s, flags=re.S)

anchor = "            textField: 'pveversion',\n            value: '',\n        },\n    ],\n"
if anchor not in s:
    sys.exit("ERROR: 前端锚点未找到")

items = """            textField: 'pveversion',
            value: '',
        },
        // PVE_HWPATCH:BEGIN
        {
            xtype: 'box',
            colspan: 2,
            padding: '10 0 6 0',
            html: '<b>' + gettext('硬件概要') + '</b>',
        },
        {
            itemId: 'hw-cputemp',
            colspan: 1,
            printBar: false,
            title: gettext('CPU温度'),
            textField: 'tdata',
            renderer: function (v) { try { return JSON.parse(v).cpu_pkg + ' \\u00b0C'; } catch (e) { return '-'; } },
        },
        {
            itemId: 'hw-board',
            colspan: 1,
            printBar: false,
            title: gettext('主板温度'),
            textField: 'tdata',
            renderer: function (v) { try { return JSON.parse(v).board + ' \\u00b0C'; } catch (e) { return '-'; } },
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
                        let q = x.split(':');
                        return q[0] + ' ' + q[1] + ' \\u00b0C';
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
                    let f = JSON.parse(v).fans;
                    if (f === '-') { return '-'; }
                    return f.split(',').map(function (x) {
                        let q = x.split(':');
                        let nm = q[0].replace(/^fan/i, 'Fan ');
                        return nm + ' ' + q[1] + ' RPM';
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
                    let d = JSON.parse(v).disks;
                    if (d === '-') { return '-'; }
                    return d.split(';').map(function (r) {
                        let q = r.split('|');
                        let t = (parseInt(q[1], 10) / 1000).toFixed(0);
                        return q[0] + '  ' + t + ' \\u00b0C  ' + q[2];
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
                    let d = JSON.parse(v);
                    let cur = d.cpu_cur && d.cpu_cur !== '0' ? d.cpu_cur + ' MHz' : '-';
                    let rng = (d.cpu_min && d.cpu_min !== '0' ? d.cpu_min : '-') + ' ~ ' +
                              (d.cpu_max && d.cpu_max !== '0' ? d.cpu_max + ' MHz' : '-');
                    return cur + '  (min~max: ' + rng + ')';
                } catch (e) { return '-'; }
            },
        },
        // PVE_HWPATCH:END
    ],
"""
s = s.replace(anchor, items, 1)
s = re.sub(r"(alias: 'widget\.pveNodeStatus',\n\n    height: )\d+(,)", r"\g<1>480\g<2>", s, count=1)
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(s)
print("  [3] pvemanagerlib.js 已注入（BEGIN/END 块，高度 480）")
PY
rc=$?
if [ $rc -ne 0 ]; then
  echo "  前端注入失败，回滚"
  cp -a "$BK/pvemanagerlib.js.bak.hwpatch" "$J"
  exit 1
fi
if command -v node >/dev/null 2>&1; then
  node --check "$J" >/dev/null 2>&1 \
    && echo "  [3] node 语法校验通过" \
    || { echo "  node 语法校验失败，回滚"; cp -a "$BK/pvemanagerlib.js.bak.hwpatch" "$J"; exit 1; }
else
  echo "  [3] 无 node，跳过语法校验（浏览器侧验证）"
fi
md5_j_after=$(md5sum "$J" | cut -d' ' -f1)
[ "$md5_j_before" != "$md5_j_after" ] && changed=1

# ---------- 4) 生效 ----------
if [ "$changed" = "1" ]; then
  systemctl restart pvedaemon 2>/dev/null
  systemctl restart pveproxy  2>/dev/null
  echo "  [4] 已重启 pvedaemon + pveproxy"
else
  echo "  [4] 无改动，不重启"
fi
exit 0
