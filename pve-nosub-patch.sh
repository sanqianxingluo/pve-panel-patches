#!/bin/bash
# pve-nosub-patch.sh —— 按配置屏蔽 / 恢复 PVE「无有效订阅」弹窗
#
# 配置真相： /etc/default/pve-hwtools 里的 BLOCK_SUBSCRIPTION_PROMPT（1 屏蔽 / 0 恢复）
# 目标文件： /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
#            （proxmox-widget-toolkit 每次升级都会覆盖，故由 apt Post-Invoke 钩子重跑）
#
# 原理：Proxmox.Utils.checked_command(orig_cmd) 会先查订阅状态再执行回调。
#       在函数体首行插桩「直接执行回调并 return」，弹窗逻辑便永不抵达。
#
# 与 V1 的区别：V1 只知屏蔽、不知恢复；V2 读配置——设为 0 时把插桩**精确摘除**，
#       恢复原厂行为（不必保存原文件：插桩自带标记，可逆）。
#
# 注意：perl 片段一律用**单引号**包裹。若用双引号，正则里的 "function" 会被 shell
#       提前闭合引号（V2 初版就栽在这里，恢复路径静默失效）。单引号下 shell 不插手，
#       Perl 原样收到引号，替换侧的 \n 也照常译为换行。
#
# 用法： pve-nosub-patch.sh          # 按配置执行
#        pve-nosub-patch.sh status   # 只报状态
set -u
CONF=/etc/default/pve-hwtools
F=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
LEGACY='// PVE_NO_SUBSCRIPTION_PATCH'

[ -f "$F" ] || exit 0

wanted() {
  local v=1
  [ -f "$CONF" ] && v=$(sed -n 's/^BLOCK_SUBSCRIPTION_PROMPT=\([01]\).*/\1/p' "$CONF" | tail -1)
  [ -z "$v" ] && v=1
  printf '%s' "$v"
}
patched() { grep -q "$LEGACY" "$F"; }

case "${1:-apply}" in
  status)
    echo "配置要求屏蔽: $(wanted)"
    echo "当前是否已屏蔽: $(patched && echo 1 || echo 0)"
    exit 0
    ;;
esac

want=$(wanted)

if [ "$want" = "1" ]; then
  if patched; then
    # 已有插桩（新式或旧式）即满足；不动它，免得重复插入
    exit 0
  fi
  cp -a "$F" "${F}.orig.prepatch" 2>/dev/null || true
  perl -0777 -i -pe 's/(checked_command:\s*function\s*\(\s*orig_cmd\s*\)\s*\{)/$1\n            \/\/ PVE_NO_SUBSCRIPTION_PATCH:BEGIN\n            if (typeof orig_cmd === "function") { orig_cmd(); }\n            return;\n            \/\/ PVE_NO_SUBSCRIPTION_PATCH:END/' "$F"
  logger -t pve-nosub-patch "applied no-subscription patch (config=1)"
else
  # 恢复原厂：先摘新式 BEGIN/END 块，再兜底摘旧式三行
  if grep -q 'PVE_NO_SUBSCRIPTION_PATCH:BEGIN' "$F"; then
    perl -0777 -i -pe 's/\n[ \t]*\/\/ PVE_NO_SUBSCRIPTION_PATCH:BEGIN.*?\/\/ PVE_NO_SUBSCRIPTION_PATCH:END\n/\n/s' "$F"
    logger -t pve-nosub-patch "removed no-subscription patch (config=0)"
  elif patched; then
    perl -0777 -i -pe 's/\n[ \t]*\/\/ PVE_NO_SUBSCRIPTION_PATCH\n[ \t]*if \(typeof orig_cmd === "function"\) \{ orig_cmd\(\); \}\n[ \t]*return;\n/\n/s' "$F"
    logger -t pve-nosub-patch "removed legacy no-subscription patch (config=0)"
  fi
fi
exit 0
