# Proxmox VE 面板补丁集

> **当前版本：V2.9** · 发布于 2026-09-25

自用的 PVE Web 界面增强补丁，纯 shell，无第三方依赖（除系统已有的 python3 / lm-sensors）。

## 包含

| 文件 | 作用 |
|---|---|
| `install.sh` | **一键部署 / 卸载**（装依赖、放脚本、挂 apt 钩子、自检） |
| `pve-hwpatch.sh` | 概要页硬件信息 + 「PVE 工具集」设置页 + 注入后端 API |
| `pve-hwtools-agent` | 状态代理：读写配置、施加 CPU 调频、触发界面重渲染 |
| `pve-nosub-patch.sh` | 按配置屏蔽 / 恢复「无有效订阅」弹窗（双向可逆） |
| `pve-mirror-switch.sh` | 软件源镜像一键切换（Debian / Proxmox，六种镜像） |
| `pve-hwtools-agent` 内建 | **风扇控制**：自动曲线 / 手动定值（主板硬件级，无需常驻进程）；**通道命名 + 自动识别 + 测试识别 + 逐通道显示开关** |
| `SHA256SUMS` | 五个脚本的校验和（`install.sh` 下载后会自动核对） |

### `pve-hwpatch.sh` —— 节点概要显示硬件信息

给 PVE 节点 **Summary（概要）** 页加上一整块「硬件概要」：

- CPU 温度（封装）、主板温度
- **CPU 各核** —— 带核名：`Core 0 43.0 °C | Core 1 42.0 °C | ...`
- **风扇转速** —— 带名字：`CPU 风扇 1053 RPM | 机箱风扇 1331 RPM`（未接风扇的插针可单独隐藏）
- **硬盘温度** —— 型号 + 容量 + 温度：`Lexar SSD NM620 512GB 40 °C 512G`（NVMe 走 hwmon，SATA 走 smartctl）
- CPU 频率（实时 / 最小 / 最大 MHz）——下方第二行显示 **CPU 代号与基准频率**（由 CPUID 映射，如 `Alder Lake (12th Gen Core) · 基准 3300 MHz`）

四项**可分别开关**（见下「设置页」），关掉的条目连同占位一起隐藏，面板高度随之收缩。

PVE 原生界面不显示这些；此前常用 pvetools 的 `chSensors` 实现，但**每次 `pve-manager` 升级都会把补丁覆盖掉**，于是概要信息就「消失」了。本脚本改成**幂等 + 可自愈**的写法。

### 「PVE 工具集」设置页 —— 图形化开关、CPU 调频与软件源

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
  APT_MIRROR=ustc               # 软件源镜像（ustc/tuna/aliyun/tencent/huawei/official）
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

#### 安装（推荐：一键脚本）

在 **PVE 宿主**上以 root 执行（会自动装依赖、放脚本、挂 apt 钩子，并在结尾自检）：

```bash
curl -fsSL https://raw.githubusercontent.com/sanqianxingluo/pve-panel-patches/main/install.sh | bash
```

也可以先克隆再本地跑（`--help` 看全部参数）：

```bash
git clone https://github.com/sanqianxingluo/pve-panel-patches.git
cd pve-panel-patches
bash install.sh                 # 安装（幂等，可反复跑）
bash install.sh --uninstall     # 卸载：摘钩子、还原原厂文件、清补丁
```

<details>
<summary>或手工部署（想自己掌控每一步时）</summary>

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

</details>

> **只需那三个文件**：`cpu-model.sh`（CPUID→代号映射）、`s.sh`、`/etc/default/pve-hwtools` 与 systemd 单元都由 `pve-hwpatch.sh` 自行落盘。

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

## 风扇控制

面板：节点 → System → **PVE 工具集** → 「风扇控制」分组。每个通道三选一：

| 模式 | 含义 |
| --- | --- |
| 关闭（用主板设置） | **默认**。完全不动主板原有策略 |
| 自动曲线 | 把五点曲线下发给主板芯片，**由硬件自己调速**（无需常驻程序） |
| 手动定值 | 固定占空比（1~255） |

自动曲线的温度源可选（如 CPUTIN、PECI），五点为「温度 → 占空比」，温度须严格递增。

命令行：

```bash
pve-hwtools-agent status                                  # 看各通道转速与当前模式
pve-hwtools-agent set fan1_mode=auto fan1_sel=2 \
    fan1_curve=25:30,30:60,45:120,60:200,80:255          # 自动曲线
pve-hwtools-agent set fan1_mode=manual fan1_manual=128    # 手动定值
pve-hwtools-agent set fan1_mode=off                       # 还原主板设置
```

**安全设计**（风扇写错可能烧硬件，故守得严）：

- **默认全 off** —— 装上补丁不改变任何风扇行为，要动必须明确指定
- 首次碰某通道前，先把它的**全部原始值**存进 `/usr/local/lib/pve-hwtools/fan-baseline/`；`off` 即按此还原
- 施加后 3 秒复读转速：**原本在转、现在变 0 → 立即还原并报错**
- 手动值下限强制 >= 1，**绝不写 0**（0 = 停转）
- `auto` 模式先铺好曲线再写 `enable`，避免中途以半截曲线运行

原理：主板 Super I/O 芯片（本机 NCT6798D，`nct6775` 驱动）自带 SmartFan 曲线引擎，内核 hwmon 暴露 `pwmN_auto_point*`。曲线交给芯片执行，**主机侧无需任何守护进程**。

## 软件源镜像切换

面板「PVE 工具集」页的**软件源**分组里可选择 Debian / Proxmox 的软件源镜像；命令行亦可用：

```bash
pve-mirror-switch.sh list              # 列出全部镜像及各自地址
pve-mirror-switch.sh status            # 显示当前镜像（JSON）
pve-mirror-switch.sh set tuna          # 切换（只改写源文件，不做连通性检查）
pve-mirror-switch.sh probe             # 探测各镜像当前可达性（查询用）
```

支持：`ustc` 中科大 / `tuna` 清华 / `aliyun` 阿里云 / `tencent` 腾讯云 / `huawei` 华为云 / `official` 官方源。

**设计取舍（重要）**

- **切换本身不做连通性检查。** 只负责改写源文件；镜像通不通由用户判断，随时 `apt-get update` 自测。镜像可达性会随时间波动，把它当作切换成功与否的判据，会让切换动不动就失败回滚。
- **只改认得出的公共镜像。** 自家内网仓库等自定义源**原样保留**，绝不改动。
- **发行版代号现读** `/etc/os-release`，不写死 `trixie`——将来 PVE 换到 `forky` 无需改脚本。
- 无订阅时自动**停用企业订阅源**（`pve-enterprise.sources` → `.disabled`，原件备份在 `/root/pve-upgrade-backup/`），否则 `apt update` 每次报 401。
- 首次接管前，原始源文件整份存 `/usr/local/lib/pve-hwtools/apt-sources.orig/`（**永不覆盖**）；每次改动另存时间戳快照 `/root/pve-upgrade-backup/apt-sources-<时间>/`，随时可手工回退。

**实测的镜像支持面**（2026-09-24，trixie）

| 镜像 | Debian | Debian 安全 | Proxmox |
|---|---|---|---|
| 中科大 | ✅ | ✅ | ✅ |
| 清华大学 | ✅ | ✅ | ✅ |
| 阿里云 | ✅ | ✅ | ✗ 无 `/proxmox/` 路径 |
| 腾讯云 | ✅ | ✅ | ✗ 无 `/proxmox/` 路径 |
| 华为云 | ✅ | ✅ | ✗ 索引签名无效，apt 拒用 |
| 官方源 | ✅ | ✅ | ✅（国内访问较慢） |

阿里云、腾讯云、华为云的 **PVE 包走官方源**（Debian 部分仍走本地镜像，照样快）——它们的 Proxmox 镜像要么不存在、要么坏了，这是踩过才知道的事。

## 更新日志

### V2.9 · 2026-09-25

**换主板可适配：重新识别芯片与通道。**

原来芯片是**按型号名找**的（NCT6775/NCT6776/… 白名单）。换主板若换成白名单外的
Super I/O（ITE IT87xx、Fintek、Winbond…），功能就**无提示地哑掉**、也说不出为什么。
现在改为**按能力找**：哪个 `hwmon` 目录里存在可写的 `pwmN`，就是可控风扇芯片 ——
型号家族只用于**排序**（优先 NCT67xx），不再是准入门槛。

- **「重新识别芯片与通道」按钮**（风扇控制分组顶部）：重扫本机所有 `hwmon` 设备，
  列出每个设备的目录、芯片名、pwm 通道、是否可控，并给出结论。
- **换主板时可选「清空名字」**：新板子的通道号含义完全不同，旧「机箱风扇」可能落到
  新板子的 CPU 插针上 —— 留着名字就是张冠李戴。所以会问你要「保留名字」还是「清空名字」；
  清空时把旧通道的 `FANn_*` / `SHOW_FANCH_n` 配置一并删除。
- **硬件变化自动重探 + 重置基线**：探测结果按 `HWID`（芯片名 + 通道集合）缓存。
  发现指纹变了（换主板、换内核）就自动重探，并把**原值基线**挪走重存 ——
  旧 `pwmN.saved` 记的是**前一块板子**的原值，拿它还原等于把旧板设置往新板上写。
  旧基线按时间戳存为 `fan-baseline.old-*`，不删。
- **概要页显示识别到的芯片**：`风扇：nct6798（/sys/class/hwmon/hwmon3）· 通道 1,2,3,4,5,7，本机可控`
  —— 换板后一眼能看出认对没有。未识别到时提示去点「重新识别芯片与通道」。
- 配置缓存改用**紧凑无引号格式**（`目录|名称|通道|可用;…`）再在输出时转 JSON ——
  带引号的 JSON 存进 shell 变量再拼回 JSON，转义层数极易搞错（实测 heredoc 里的 `\"`
  不会被剥掉，拼出来就是非法记号）。

命令行：`pve-hwtools-agent fan-rescan [keep]`、`fan-scan`（看缓存）。

### V2.8 · 2026-09-25

**风扇跟哪路温度：可选，且看得懂。**

- **温度源翻成人话**：原来下拉里是芯片给的名字（`PECI Agent 0`、`AUXTIN0`、`PCH_CHIP_TEMP`），
  没人知道该选哪个。现在按「代表哪里的温度」翻译：
  `CPU 核心温度`（PECI，CPU 硅片自身）/ `CPU 插座温度`（CPUTIN）/ `主板温度`（SYSTIN）/
  `芯片组`（PCH_*）/ `未接传感器`（AUXTIN*）。`CPU` 与 `SYSTIN` 带「（推荐）」标记。
- **候选带实时读数**：`CPU 核心温度 （推荐） · 46.0 °C`，选之前就知道这路现在多少度。
- **排序有用优先**：推荐的排最前，`未接传感器` 一律排最后并标注 —— 免得选中空脚
  （选它意味着风扇不跟任何温度走）。
- **模式为「关闭」时显示内核实际值**：原先把配置里记的 `FANn_SEL` 直接显示出来，
  但模式为 `off` 时内核跟的是主板原厂值，两个可能不同 —— 于是界面会显示一个**并未生效**
  的温度源，误导人。现已改为 `off` 时显示内核实际在跟的那路（新增 `sel_live` 字段）。
- 单通道只能跟**一路**温度（芯片的 `pwmN_temp_sel` 是单值，实测范围 1~12 = temp1~temp12）。

> 关于「同时跟主板和 CPU」：这颗 Super I/O 的单通道 `temp_sel` 只能选一路。
> 只有 `pwm2` 额外带一组加权属性（`weight_temp_sel` / `weight_temp_step`），
> 可做「两路温度步进叠加」，但厂商语义未公开、也无从验证，**没有做进界面** ——
> 宁可少一个功能，也不摆一个说不清行为的开关。单通道跟一路已覆盖绝大多数需求。

### V2.7 · 2026-09-25

**风扇通道命名与识别**（承接 V2.4 的风扇控制）。控制器与风扇名彻底分开：`pwm1/2/3…`
是控制器通道，名字由你绑定。

- **通道名**：设置页每行可直接填名字（支持中文），结果显示在概要页
  （`CPU 风扇 1053 RPM | 机箱风扇 1331 RPM`）。名字存进配置时自动加引号，
  并禁止 `| , =` 与单引号——配置会被 `bash source`，不引号会直接执行名字内容。
- **自动识别风扇**：逐个试探各插针（静止的才试转，正在转的绝不打扰），
  识别哪些插针真接了风扇；再按各通道自己声明的温度源（`pwmN_temp_sel`）
  归类命名，未接风扇的通道自动隐藏。已有名字不覆盖。
- **测试识别**：让指定通道明显变一次转速（实测 1060 → 1620 RPM），
  便于听声辨位；测完无条件还原主板设置。
- **逐通道显示开关**（`SHOW_FANn`）：`自动显示`（只显在转的）/ `始终显示` / `不显示`，
  用来把没接风扇的插针位从概要里去掉。
- 自动识别与测试识别都是**长任务**：识别后台跑 + 面板轮询进度，
  避免撞上代理超时；结果写 `/run/pve-hwtools-fanbind.json`。
- 写入顺序修正：**先写 enable 再写 pwm**——反序（先 pwm）会让风扇在
  SmartFan→手动 的切换瞬间先掉速，出现「写 255 反而变慢」的假象。

**须如实知道的一点**：主板芯片**不提供风扇名**（`fan*_label` 全空），
也无法从硬件区分哪个插头是 CPU 风扇。已实测——把 CPU 附近通道从 1108 转压到
349 转，CPU 温度只动 1°C（待机功耗太低），靠升温差判不出物理身份。
所以自动识别只做「能证实的判断」，名字按温度源归类，**不猜物理身份**；
若名字不对，用「测试识别」听声后手动改名。

### V2.4 · 2026-09-25

- **新增风扇控制**：自动曲线 / 手动定值 / 关闭三态，面板可配、命令行可配
  - 自动曲线由**主板硬件执行**（SmartFan IV），无需常驻进程
  - 默认全 `off`，装上不改动任何风扇行为；`off` 可完整还原主板原始设置
  - 安全阀：写后 3 秒复读转速，原本在转却变 0 就**立刻还原并报错**
  - 手动占空比下限 1，拒绝 0（停转）
- **修正一个已发布版本里的隐患**：`governor` / `freq_min` / `freq_max` / `turbo` / `epp` / `apt_mirror` 的取值校验原先跑在**子 shell** 里，`die` 终止不了父进程 —— 于是非法输入会「打印了错误却照样写配置」。现已改为直接调用、真正中止，整批参数任一非法则**一条都不生效**
- **修正 Perl 侧参数键名正则**：原先只允许 `[a-z_]+`，导致 `fan1_mode` 这类含数字的键被判非法 → 保存永远失败
- 参数分隔符由逗号改为**空格**（曲线取值自带逗号，按逗号切会被拆碎）

### V2.3 · 2026-09-24
- **新增 `pve-mirror-switch.sh`：软件源镜像一键切换**，并在「PVE 工具集」页加「软件源」分组；支持中科大 / 清华 / 阿里云 / 腾讯云 / 华为云 / 官方源六种
  - 只改公共镜像的源行，**自定义私有源原样保留**（内网仓库不会被误改）
  - 发行版代号现读 `os-release`，不写死 `trixie`
  - 自动停用企业订阅源；原件存 `apt-sources.orig`（永不覆盖）+ 每次改动留时间戳快照
  - 支持经典 `sources.list` / `*.list` 与 deb822 `*.sources` 两种格式
  - **切换不做连通性检查**——只改写源文件，是否可达由用户 `apt-get update` 自测
- 实测结论：阿里云、腾讯云**无 Proxmox 镜像**（404），华为云的 Proxmox 镜像**签名无效**（apt 报 `Clearsigned file isn't valid`）→ 这三家的 PVE 包走官方源
- 老配置自动补 `APT_MIRROR` 默认项（幂等，不覆盖用户已设的值）


### V2.2 · 2026-09-24
- **新增 `install.sh` 一键部署 / 卸载脚本**：自动装依赖、放脚本、挂 apt 钩子、结尾自检；`--uninstall` 完整还原
  - 支持 `curl … | bash` 与本地运行两种方式；`--ref` 指定版本、`--no-deps` 跳过依赖
  - 下载后自动核对 `SHA256SUMS`，不符即中止
- **卸载改为「重装包 → 剥离注入」两级还原**：优先 `apt install --reinstall pve-manager proxmox-widget-toolkit`；离线时则剥离所有注入块并把面板高度复位成原厂值。实测剥离后与当前版本原厂文件**逐字节一致**
- **修：备份文件可能过期导致回滚错版本。** 原逻辑「备份不存在才建」，PVE 大版本升级后旧备份仍是上一版原厂件；一旦注入失败回滚到它，就会把 9.2 的文件退回 8.4.19、`pvedaemon` 起不来。现改为**仅在文件干净（无补丁标记）时才刷新备份**
- 另修：剥离注入时的标记名要与脚本一致（`PVE_` 前缀不可省），否则一条也剥不掉

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
