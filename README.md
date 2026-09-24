# Proxmox VE 面板补丁集

> **当前版本：V1.1** · 发布于 2026-09-24

自用的 PVE Web 界面增强补丁，纯 shell，无第三方依赖（除系统已有的 python3 / lm-sensors）。

## 包含

### `pve-hwpatch.sh` —— 节点概要显示硬件信息

给 PVE 节点 **Summary（概要）** 页加上一整块「硬件概要」：

- CPU 温度（封装）、主板温度
- **CPU 各核** —— 带核名：`Core 0 43.0 °C | Core 1 42.0 °C | ...`
- **风扇转速** —— 带路名：`Fan 1 1053 RPM | Fan 2 1331 RPM`（只列非零）
- **硬盘温度** —— 型号 + 容量 + 温度：`Lexar SSD NM620 512GB 40 °C 512G`（NVMe 走 hwmon，SATA 走 smartctl）
- CPU 频率（实时 / 最小 / 最大）

PVE 原生界面不显示这些；此前常用 pvetools 的 `chSensors` 实现，但**每次 `pve-manager` 升级都会把补丁覆盖掉**，于是概要信息就「消失」了。本脚本改成**幂等 + 可自愈**的写法。

#### 它改了什么

| 文件 | 改动 |
|---|---|
| `/usr/bin/s.sh` | 新建：取样脚本，输出单行 JSON（纯 ASCII 数值） |
| `/usr/share/perl5/PVE/API2/Nodes.pm` | 在节点 `status` 接口中注入 `$res->{tdata}` |
| `/usr/share/pve-manager/js/pvemanagerlib.js` | 在 `PVE.node.StatusView` 的 items 里插入 `hw-*` 条目（`PVE_HWPATCH:BEGIN/END` 包裹，便于随版本整块替换），面板高度改 480 |

#### 安装

```bash
# 依赖
apt-get install -y lm-sensors smartmontools    # smartmontools 可选
sensors-detect --auto                          # 首次需探测传感器

# 部署
install -m 755 pve-hwpatch.sh /usr/local/bin/pve-hwpatch.sh
/usr/local/bin/pve-hwpatch.sh                  # 打补丁（幂等，可反复跑）
```

#### 关键：让它经得住升级

`pve-manager` 每次升级都会覆盖那两个文件，所以务必挂上 apt 钩子：

```bash
cat > /etc/apt/apt.conf.d/98-pve-hwpatch <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-hwpatch.sh"; };
EOF

apt-config dump | grep -i post-invoke           # 校验钩子已被 apt 读到
```

此后每次 `apt upgrade` 事务结束都会自动重打，无需人工干预。

#### 卸载 / 还原

```bash
# 备份在 /root/pve-upgrade-backup/，直接还原即可
cp /root/pve-upgrade-backup/Nodes.pm.bak.hwpatch            /usr/share/perl5/PVE/API2/Nodes.pm
cp /root/pve-upgrade-backup/pvemanagerlib.js.bak.hwpatch    /usr/share/pve-manager/js/pvemanagerlib.js
rm -f /usr/bin/s.sh
rm -f /etc/apt/apt.conf.d/98-pve-hwpatch
systemctl restart pvedaemon pveproxy
```

或直接 `apt install --reinstall pve-manager` 覆盖回原厂文件（但记得先删钩子，否则会被自动重打）。

#### 验证

浏览器登录 PVE → 点左侧资源树里的节点 `pve` → 点左菜单 **Summary** → 右侧应出现「硬件概要」区块。

也可先在命令行确认后端已生效：

```bash
pvesh get /nodes/<节点名>/status --output-format json | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('tdata'))"
# 预期：{"cpu_pkg":"46.0","cpu_cores":"Core 0:45.0,Core 1:43.0",...,"disks":"Lexar SSD NM620 512GB|39850|512G",...}
```

## 注意与踩坑

1. **脚本只输出纯 ASCII 数值，单位由前端 JS 补。**
   Perl 反引号 `` `s.sh` `` 读入 UTF-8 时会二次编码，`°C` 会变 `Â°C` 乱码；把单位全交给前端 `renderer` 拼接即可绕开。

2. **凡用字符类过滤，一律 `LC_ALL=C`.**
   `sed 's/[^ -~]//g'` 在 UTF-8 locale 下会按 **collation 排序**解释括号范围（非 ASCII 字节序），`0`~`9` 竟会被判为越界删掉（`+45.0°C` → `+.`）。加 `LC_ALL=C` 才按字节序。

3. **改完必须校验语法再重启。**
   `perl -c` 校验 `Nodes.pm`、`node --check` 校验 `pvemanagerlib.js`；本脚本已在失败时自动回滚。

4. **适配版本。** 在 PVE 9.2（`pve-manager` 9.2.20 / `proxmox-widget-toolkit` 5.2.10）上实测通过。锚点是按 9.2 的源码结构找的，跨大版本升级后若 PVE 改了 `StatusView` 结构，锚点可能失配——脚本会自动报错并回滚，届时按报错提示调整锚点即可。

## 更新日志

### V1.1 · 2026-09-24
- **CPU 各核带核名**（`Core 0` / `Core 1` …），不再只有一串数字
- **风扇转速带序号**（`Fan 1` / `Fan 2`），读自 `sensors` 的 `fanN:` 行
- **硬盘温度附型号与容量**（读 `/sys/block/*/device/model` 与 `size`，去掉内核字段的尾部填充空格）
- 条目改用 ` | ` 分隔（ExtJS 会把连续空格压成单个，故不用空格做分隔）
- 前端注入块改为 `// PVE_HWPATCH:BEGIN / :END` 包裹，**升级时整块替换**——原版打完补丁后就无法再更新，V1.1 起可反复施为
- 面板高度 540 → 480（实测内容底 474，收紧留白）

### V1.0 · 2026-09-24
- 首个版本：CPU/主板温度、风扇转速、硬盘温度、CPU 频率

## 许可

MIT
