# Proxmox VE 面板补丁集

> **当前版本：V2.1** · 发布于 2026-09-24

自用的 PVE Web 界面增强补丁，纯 shell，无第三方依赖（除系统已有的 python3 / lm-sensors）。

## 包含

| 文件 | 作用 |
|---|---|
| `pve-hwpatch.sh` | 概要页硬件信息 + 「PVE 工具集」设置页 + 注入后端 API |
| `pve-hwtools-agent` | 状态代理：读写配置、施加 CPU 调频、触发界面重渲染 |
| `pve-nosub-patch.sh` | 按配置屏蔽 / 恢复「无有效订阅」弹窗（双向可逆） |

### `pve-hwpatch.sh` —— 节点概要显示硬件信息

给 PVE 节点 **Summary（概要）** 页加上一整块「硬件概要」：

- CPU 温度（封装）、主板温度
- **CPU 各核** —— 带核名：`Core 0 43.0 °C | Core 1 42.0 °C | ...`
- **风扇转速** —— 带路名：`Fan 1 1053 RPM | Fan 2 1331 RPM`（只列非零）
- **硬盘温度** —— 型号 + 容量 + 温度：`Lexar SSD NM620 512GB 40 °C 512G`（NVMe 走 hwmon，SATA 走 smartctl）
- CPU 频率（实时 / 最小 / 最大 MHz）——下方第二行显示 **CPU 代号与基准频率**（由 CPUID 映射，如 `Alder Lake (12th Gen Core) · 基准 3300 MHz`）

四项**可分别开关**（见下「设置页」），关掉的条目连同占位一起隐藏，面板高度随之收缩。

PVE 原生界面不显示这些；此前常用 pvetools 的 `chSensors` 实现，但**每次 `pve-manager` 升级都会把补丁覆盖掉**，于是概要信息就「消失」了。本脚本改成**幂等 + 可自愈**的写法。

### 「PVE 工具集」设置页 —— 图形化开关与 CPU 调频

在节点左菜单（**System → PVE 工具集**）新增一页，三组：

1. **概要显示** —— 四个勾选框：CPU 温度（含各核）、风扇转速、硬盘概要（型号 / 容量 / 温度）、CPU 频率
2. **CPU 调频** —— 调频模式下拉（`performance` / `powersave` / `ondemand` / `conservative` / `schedutil`）+ **频率下限 / 上限数字框（MHz，受硬件能力钳制）** + **Turbo 加速**（启用 / 关闭）+ **能效偏好 EPP**（`performance` / `balance_performance` / `balance_power` / `power`，仅部分平台支持时可用）。下方灰字实时显示本机 CPU 型号与代号、驱动、硬件能力范围、内核实际生效值与当前频率
3. **订阅提示** —— 勾选即屏蔽「无有效订阅」登录弹窗（取消勾选即恢复）

「保存并应用」**真写系统**：调频模式与上下限经 `cpupower frequency-set` 落内核，可随时改回。

唯一的配置真相是 `/etc/default/pve-hwtools`——面板页读写的都是它，也可手工编辑后执行 `pve-hwtools-agent apply`。

```bash
# 配置文件 /etc/default/pve-hwtools 形如：
SHOW_CPU_TEMP=1
SHOW_FAN=1
SHOW_DISK=1
SHOW_CPU_FREQ=1
BLOCK_SUBSCRIPTION_PROMPT=1
CPU_GOVERNOR=conservative
CPU_FREQ_MIN=800          # 单位 MHz
CPU_FREQ_MAX=3800         # 单位 MHz
CPU_TURBO=1               # Turbo 加速：1 启用 / 0 关闭
CPU_EPP=balance_performance   # 能效偏好（仅部分平台）
```

#### 它改了什么

| 文件 | 改动 |
|---|---|
| `/usr/bin/s.sh` | 新建：取样脚本，输出单行 JSON（纯 ASCII 数值，频率单位 MHz） |
| `/usr/local/lib/pve-hwtools/cpu-model.sh` | 新建：CPUID（family/model）→ Intel/AMD 代号映射；`s.sh` 与 `pve-hwtools-agent` 共用 |
| `/usr/share/perl5/PVE/API2/Nodes.pm` | 注入 `$res->{tdata}`；并注册节点级接口 `GET/PUT /nodes/{node}/hwtools`（PUT 带 `protected => 1`，见下） |
| `/usr/share/pve-manager/js/pvemanagerlib.js` | 在 `PVE.node.StatusView` 的 items 里插入 `hw-*` 条目（`PVE_HWPATCH:BEGIN/END` 包裹），加隐藏逻辑与设置页，左菜单加菜单项 |
| `/usr/local/bin/pve-hwtools-agent` | 状态代理（配置读写、调频、重渲染） |
| `/etc/default/pve-hwtools` | 配置真相 |

#### 安装

```bash
# 依赖
apt-get install -y lm-sensors smartmontools cpufrequtils linux-cpupower
sensors-detect --auto                          # 首次需探测传感器

# 部署
install -m 755 pve-hwpatch.sh    /usr/local/bin/pve-hwpatch.sh
install -m 755 pve-hwtools-agent /usr/local/bin/pve-hwtools-agent
install -m 755 pve-nosub-patch.sh /usr/local/bin/pve-nosub-patch.sh
/usr/local/bin/pve-hwpatch.sh                  # 打补丁（幂等，可反复跑）
```

#### 关键：让它经得住升级

`pve-manager` 每次升级都会覆盖那几个文件，所以务必挂上 apt 钩子：

```bash
cat > /etc/apt/apt.conf.d/98-pve-hwpatch <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-hwpatch.sh"; };
EOF

cat > /etc/apt/apt.conf.d/99-pve-nosub-patch <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-nosub-patch.sh"; };
EOF

apt-config dump | grep -i post-invoke           # 校验钩子已被 apt 读到
```

此后每次 `apt upgrade` 事务结束都会自动重打，无需人工干预。

#### 卸载 / 还原

```bash
# 备份在 /root/pve-upgrade-backup/，直接还原即可
cp /root/pve-upgrade-backup/Nodes.pm.bak.hwpatch            /usr/share/perl5/PVE/API2/Nodes.pm
cp /root/pve-upgrade-backup/pvemanagerlib.js.bak.hwpatch    /usr/share/pve-manager/js/pvemanagerlib.js
rm -f /usr/bin/s.sh /etc/default/pve-hwtools
# 订阅弹窗若被屏蔽，先把配置改回 0 再跑一次脚本以恢复原厂行为：
#   sed -i 's/^BLOCK_SUBSCRIPTION_PROMPT=1/BLOCK_SUBSCRIPTION_PROMPT=0/' /etc/default/pve-hwtools
#   /usr/local/bin/pve-nosub-patch.sh
rm -f /etc/apt/apt.conf.d/98-pve-hwpatch /etc/apt/apt.conf.d/99-pve-nosub-patch
systemctl restart pvedaemon pveproxy
```

或直接 `apt install --reinstall pve-manager` 覆盖回原厂文件（但记得先删钩子，否则会被自动重打）。

#### 验证

浏览器登录 PVE → 点左侧资源树里的节点 → 点左菜单 **Summary** → 右侧应出现「硬件概要」区块；
点 **System → PVE 工具集** → 应出现上述三组设置。

也可先在命令行确认后端已生效：

```bash
pvesh get /nodes/<节点名>/hwtools --output-format json
# 预期返回配置、硬件范围与内核实况
```

## 注意与踩坑

1. **脚本只输出纯 ASCII 数值，单位由前端 JS 补。**
   Perl 反引号 `` `s.sh` `` 读入 UTF-8 时会二次编码，`°C` 会变 `Â°C` 乱码；把单位全交给前端 `renderer` 拼接即可绕开。

2. **凡用字符类过滤，一律 `LC_ALL=C`.**
   `sed 's/[^ -~]//g'` 在 UTF-8 locale 下会按 **collation 排序**解释括号范围（非 ASCII 字节序），`0`~`9` 竟会被判为越界删掉（`+45.0°C` → `+.`）。加 `LC_ALL=C` 才按字节序。

3. **改完必须校验语法再重启。**
   `perl -c` 校验 `Nodes.pm`、`node --check` 校验 `pvemanagerlib.js`；本脚本已在失败时自动回滚。

4. **`protected => 1` 是必需的——这是本版本踩得最深的坑。**
   `pveproxy` 以 `www-data` 运行。节点级接口若**不带** `protected => 1`，请求就在 pveproxy 进程里**就地降权执行**（`HTTPServer.pm`：只有 `protected` 且 euid≠0 才转给 root 的 `pvedaemon`），于是同目录下的特权动作会以非 root 身份失败。原厂所有需 root 的节点级接口都带这一项（`Nodes.pm` 共 20 处，注释写着 “avoid problems with proxy code”）。

5. **别在 API 处理期间重启 `pvedaemon`。**
   本补丁的后端注入会调 `systemctl restart pvedaemon`——若在保存配置（进而触发重渲染）的路径上无条件重启，就会**掐断正在服务该请求的 pvedaemon 自己**，表现为 `failed: exit code 1` 或 HTTP 596 broken pipe。故第 6 步只在**后端内容真的变了**时才重启（比对注入前后 hash）。

6. **`Ext.define` 的 `items` 在类定义期求值。**
   里面**绝不能放运行期求值**（IIFE、未定义变量），否则整个 `pvemanagerlib.js` 加载失败，连登录窗都不渲染——而 `node --check` 只验语法，查不出。
   开关一律走「**条目全静态注入 + 渲染后隐藏**」。

7. **`Proxmox.Utils.API2Request` 的 `url` 不带 `/api2/json` 前缀**（框架自加）；`Ext.Ajax.request` 才需带。写错会变成双前缀 404。

8. **适配版本。** 在 PVE 9.2（`pve-manager` 9.2.20 / `proxmox-widget-toolkit` 5.2.10）上实测通过。锚点是按 9.2 的源码结构找的，跨大版本升级后若 PVE 改了 `StatusView` 结构，锚点可能失配——脚本会自动报错并回滚，届时按报错提示调整锚点即可。

9. **注入块里别写反斜杠转义——包括注释。**
   前端 JS 是嵌在补丁脚本内 Python 三引号字符串里的；写了反斜杠加 `n` / `u` / `t` 之类，Python 会**先**把它译成真字符，从而截断 JS 字面量或注释，结果整个 `pvemanagerlib.js` 加载失败、连登录窗都不渲染。换行用 HTML 标签（`<br/>`）或 `String.fromCharCode`，度数符号直接写 `°`。脚本内已加护栏：一旦在注入块源码里发现反斜杠转义就拒绝注入、保持原文件不动。

## 更新日志

### V2.1 · 2026-09-24
- **频率单位由 kHz 改为 MHz**（面板输入、配置文件、状态回显、概要显示全部统一）
- **新增 Turbo 加速开关**（`/sys/devices/system/cpu/intel_pstate/no_turbo`；不支持的平台自动禁用该控件）
- **新增能效偏好 EPP**（四档，仅平台支持 `/sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference` 时可用）
- **新增 CPUID → 代号映射**：内置 2000 年至今主流 Intel（family 6 全部型号，98 项）与 AMD（family 0xF / 0x10 / 0x17 / 0x19 / 0x1A）代号；面板显示「处理器：xxx」、概要页第二行显示「代号 · 基准频率」。映射抽成 `/usr/local/lib/pve-hwtools/cpu-model.sh`，`s.sh` 与 `pve-hwtools-agent` 共用
- 修复后端参数校验拒绝含下划线的取值（EPP 档位名如 `balance_performance` 曾被误拒）
- 修复注入块内反斜杠转义被 Python 提前求值、导致整份前端 JS 加载失败的问题；并加护栏（踩坑 9）

### V2.0 · 2026-09-24
- **新增「PVE 工具集」设置页**（节点左菜单 System 下），三组：概要显示开关 / CPU 调频 / 订阅提示
- **概要四项可分别开关**（CPU 温度、风扇转速、硬盘概要、CPU 频率）；关掉的条目连同占位隐藏，面板高度随之收缩
- **CPU 调频可图形设置**：模式（五种调速器）+ 频率上下限，范围**受 `/sys` 报告的硬件能力钳制**；后端拒绝越界与参数注入
- **订阅提示屏蔽改为可逆**，由配置项 `BLOCK_SUBSCRIPTION_PROMPT` 驱动（独立脚本 `pve-nosub-patch.sh`）
- 新增 `pve-hwtools-agent`：状态代理，配置真相 `/etc/default/pve-hwtools`
- 新增节点级接口 `GET/PUT /nodes/{node}/hwtools`；PUT 带 `protected => 1`（否则被 pveproxy 降权执行，见踩坑 4）
- 补丁脚本改为**可自升级**：每次先剥旧注入块再重打；并在后端内容真变时才重启服务（踩坑 5）
- 保存后概要页**当轮刷新即生效**，无需手动刷新整页

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
