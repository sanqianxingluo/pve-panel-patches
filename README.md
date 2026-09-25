# Proxmox VE 面板补丁集

> **当前版本：V2.13** · 发布于 2026-09-25
> 适用：**Proxmox VE 9.x**（在 `pve-manager` 9.2.20 上实测通过）· 需 root

给 PVE 原生 Web 界面补上它不显示的东西：**节点概要的硬件信息**、
**图形化的 CPU 调频与风扇控制**、**软件源镜像切换**、**订阅弹窗屏蔽**。

纯 shell 实现，除系统自带的 `python3` / `lm-sensors` / `smartmontools` 外无第三方依赖。
所有改动**可逆**：卸载即还原原厂文件；风扇控制默认不动任何风扇。

---

## 功能总览

| 功能 | 位置 | 说明 |
|---|---|---|
| **硬件概要** | 节点 → Summary | CPU 温度（封装）/ 核心温度平均值 / 主板温度 / 风扇转速（带名字）/ 硬盘型号容量温度 / CPU 频率与代号。四项可分别开关 |
| **CPU 调频** | System → PVE 工具集 | 调速器模式、频率上下限（MHz，受硬件钳制）、Turbo 开关、EPP 能效偏好 |
| **风扇控制** | System → PVE 工具集 | 自动曲线（主板硬件执行）/ 手动定值 / 关闭三态；通道命名、自动识别、测试识别、逐通道显示开关 |
| **订阅提示** | System → PVE 工具集 | 屏蔽「无有效订阅」登录弹窗，可逆 |
| **软件源镜像** | System → PVE 工具集 | 中科大 / 清华 / 阿里云 / 腾讯云 / 华为云 / 官方源一键切换 |
| **使用说明** | System → PVE 工具集 | 页面内弹窗查看完整说明书（与仓库 README 同源） |

**为什么需要它**：PVE 原生界面不显示温度、风扇、硬盘温度这些。以前常用 pvetools 的
`chSensors`，但**每次 `pve-manager` 升级都会把补丁覆盖掉**，概要信息就「消失」。
本补丁集做成**幂等 + 可自愈**：挂上 apt 钩子后，升级结束会自动重打。

---

## 一、安装

### 方式 A：一键（推荐）

在 **PVE 宿主**上以 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/sanqianxingluo/pve-panel-patches/main/install.sh | bash
```

脚本会自动：装依赖 → 放脚本 → 挂 apt 钩子 → 打补丁 → 探测传感器 → 自检。
**幂等**，可反复跑。

### 方式 B：先克隆再本地跑

```bash
git clone https://github.com/sanqianxingluo/pve-panel-patches.git
cd pve-panel-patches
bash install.sh                    # 安装
bash install.sh --uninstall        # 卸载
bash install.sh --help             # 全部参数
```

`install.sh` 的参数：

| 参数 | 作用 |
|---|---|
| （无） | 安装。幂等，可反复执行 |
| `--uninstall` / `-u` | 卸载：摘钩子、还原原厂文件、清补丁 |
| `--ref <分支/标签>` | 指定版本，如 `--ref v2.9`。默认 `main` |
| `--no-deps` | 跳过依赖安装（自己已装好时） |
| `--help` / `-h` | 用法 |

### 方式 C：手工部署（想自己掌控每一步）

```bash
# 1) 依赖（install.sh 会装的一整套）
apt-get install -y lm-sensors smartmontools cpufrequtils linux-cpupower python3
sensors-detect --auto                 # 首次需探测传感器

# 2) 放脚本
install -m 755 pve-hwpatch.sh       /usr/local/bin/pve-hwpatch.sh
install -m 755 pve-hwtools-agent    /usr/local/bin/pve-hwtools-agent
install -m 755 pve-nosub-patch.sh   /usr/local/bin/pve-nosub-patch.sh
install -m 755 pve-mirror-switch.sh /usr/local/bin/pve-mirror-switch.sh

# 3) 打补丁（幂等，可反复跑）
/usr/local/bin/pve-hwpatch.sh

# 4) 使用说明（面板「使用说明」按钮弹出的那份；可选）
mkdir -p /usr/local/lib/pve-hwtools
pip install markdown && python3 tools/mkdoc.py    # 或直接用仓库里的产物
install -m 644 pve-hwtools-doc.html /usr/local/lib/pve-hwtools/doc.html

# 5) 挂 apt 钩子（强烈建议，见「四、升级与维护」）
printf 'DPkg::Post-Invoke { "/usr/local/bin/pve-hwpatch.sh"; };\n'    > /etc/apt/apt.conf.d/98-pve-hwpatch
printf 'DPkg::Post-Invoke { "/usr/local/bin/pve-nosub-patch.sh"; };\n' > /etc/apt/apt.conf.d/99-pve-nosub-patch
apt-config dump | grep -i post-invoke   # 校验钩子已被 apt 读到
```

> **只需这四个文件**。`/usr/bin/s.sh`、`/usr/local/lib/pve-hwtools/cpu-model.sh`、
> `/etc/default/pve-hwtools`、systemd 单元 `pve-hwtools-apply.service`
> 都由 `pve-hwpatch.sh` 自行落盘，无需手工放。

### 装完怎么确认成功

一键脚本结尾有自检，应看到 12 项全绿（顺序与脚本实际一致）：

```
✅ 补丁脚本就位
✅ 状态代理就位
✅ 订阅屏蔽脚本就位
✅ 镜像切换脚本就位
✅ 取样脚本 /usr/bin/s.sh 就位
✅ CPU 世代映射就位
✅ 配置 /etc/default/pve-hwtools 就位
✅ 后端已注入 Nodes.pm
✅ 前端已注入 pvemanagerlib.js
✅ 使用说明 doc.html 就位
✅ pvedaemon 正常
✅ pveproxy 正常
```

然后在**浏览器**里：登录 → **Ctrl+Shift+R 强刷一次**（旧 JS 有缓存）→
点左侧资源树的节点 → 左菜单 **Summary** 应出现「硬件概要」；
点 **System → PVE 工具集** 应出现全部设置分组。

命令行也能直接验：

```bash
/usr/bin/s.sh                                    # 取样脚本的单行 JSON
pve-hwtools-agent status                         # 状态代理的完整状态
pvesh get /nodes/<节点名>/hwtools --output-format json
```

---

## 二、使用

### 2.1 节点概要的「硬件概要」

节点 → **Summary**，右侧出现一整块：

- **CPU 温度**（封装）、**核心温度平均值**（带核数：`44.0 °C（4 核平均）`）、**主板温度**
- **风扇转速** —— 带名字：`CPU 风扇 1053 RPM | 机箱风扇 1331 RPM`
- **硬盘温度** —— 型号 + 容量 + 温度：`Lexar SSD NM620 512GB 39 °C`
  （NVMe 走 hwmon，SATA 走 `smartctl`）
- **CPU 频率** —— 实时 / 最小 / 最大（MHz）；下方第二行显示 **CPU 代号与基准频率**，
  如 `Alder Lake (12th Gen Core) · 基准 3300 MHz`

四项**可分别开关**（见 2.2 的「概要显示」），关掉的条目连同占位一起隐藏，
面板高度随之收缩。

### 2.2 「PVE 工具集」设置页

节点 → **System → PVE 工具集**，五组设置。

页面底部的三个按钮：

| 按钮 | 作用 |
|---|---|
| **保存并应用** | 写入配置并施加（调频落内核、风扇下发给主板） |
| **重新载入** | 丢弃未保存的改动，重新读一遍配置 |
| **使用说明** | 弹出这份说明书（就是本文件） |

> **「使用说明」按钮**：弹出的说明书与仓库的 `README.md` **同源** ——
> 由 `tools/mkdoc.py` 把 README 转成 HTML，安装时落到
> `/usr/local/lib/pve-hwtools/doc.html`，面板通过节点接口 `GET /nodes/{node}/hwhelp`
> 取回后显示。想改说明内容，改 README 再重跑一次 `install.sh` 即可，两边不会各说各话。
>
> 面板版只收「安装 / 使用 / 配置 / 升级 / 卸载 / 常见问题」六章；`实现要点与踩坑`
> 及其后的变更日志属开发笔记，不进面板（免得弹窗又长又难翻）。
>
> 在 git 工作副本里跑 `install.sh` 时，若本机装了 `python-markdown`，
> 会**当场从 README 重新生成**，连重新提交都不必。

#### 概要显示

四个勾选框：CPU 温度（封装与核心平均）/ 风扇转速 / 硬盘概要 / CPU 频率。

#### CPU 调频

- **调频模式** —— `performance` / `powersave` / `ondemand` / `conservative` / `schedutil`
- **频率下限 / 上限** —— 单位 **MHz**，输入范围**受 `/sys` 报告的硬件能力钳制**，
  越界会被后端拒绝
- **Turbo 加速** —— 启用 / 关闭（不支持的平台该控件自动禁用）
- **能效偏好 EPP** —— `performance` / `balance_performance` / `balance_power` / `power`
  （仅平台支持时可用）

下方灰字实时显示本机 CPU 型号与代号、驱动、硬件能力范围、内核实际生效值与当前频率。

「保存并应用」**真写系统**：经 `cpupower frequency-set` 落内核，可随时改回。

#### 订阅提示

勾选即屏蔽「无有效订阅」登录弹窗，取消勾选即恢复。由独立脚本 `pve-nosub-patch.sh`
实现，双向可逆。

#### 软件源

选择 Debian / Proxmox 的软件源镜像：

| 镜像 | 代号 | Debian | Proxmox |
|---|---|---|---|
| 中科大 | `ustc` | ✅ | ✅ |
| 清华大学 | `tuna` | ✅ | ✅ |
| 阿里云 | `aliyun` | ✅ | ✗ 无 `/proxmox/` 路径 |
| 腾讯云 | `tencent` | ✅ | ✗ 无 `/proxmox/` 路径 |
| 华为云 | `huawei` | ✅ | ✗ 索引签名无效，apt 拒用 |
| 官方源 | `official` | ✅ | ✅（国内访问较慢） |

> 阿里云、腾讯云、华为云的 **PVE 包会自动走官方源**（Debian 部分仍走本地镜像，照样快）——
> 这三家的 Proxmox 镜像要么不存在、要么坏了，这是实测踩过才知道的。

**设计取舍**：**切换本身不做连通性检查**，只改写源文件；镜像通不通由你 `apt-get update`
自测。镜像可达性随时间波动，把它当切换成功与否的判据会让切换动不动就失败回滚。
另外只改**认得出的公共镜像**，自家内网仓库等自定义源**原样保留**。

#### 风扇控制

这一组最需要解释，单独一节。见 **2.3**。

### 2.3 风扇控制

面板：**System → PVE 工具集 → 风扇控制**。

#### 先理解「控制器」和「风扇名」是两件事

主板的 Super I/O 芯片只提供 **pwm 控制器通道**（`pwm1` / `pwm2` / `pwm3` …），
**它不知道哪个通道上插的是哪个风扇**。所以：

- **通道号**（`pwm1`、`pwm2`…）是硬件给的，固定
- **名字**是你绑定的，存进配置，显示在概要页

#### 每行有哪些控件

| 控件 | 作用 |
|---|---|
| **模式**（三选一） | `关闭（用主板设置）` / `自动曲线` / `手动定值` |
| **占空比** | 仅「手动定值」可用，1~255（**下限锁 1，绝不写 0** —— 0 就是停转） |
| **跟哪路温度** | 仅「自动曲线」可用。决定该通道随哪一路温度升降 |
| **名字** | 自由文本，支持中文。留空则界面显示「通道 N」 |
| **显示** | `自动显示` / `始终显示` / `不显示` —— 只影响概要页是否列出该通道 |
| **测试识别** | 见下 |

#### 三种模式

| 模式 | 含义 |
|---|---|
| **关闭（用主板设置）** | **默认**。完全不动主板原有策略，补丁不改变任何风扇行为 |
| **自动曲线** | 把五点曲线下发给主板芯片，**由硬件自己调速**——主机侧无需任何常驻程序，不占 CPU、不受系统负载影响，重启后由 `pve-hwtools-apply.service` 自动铺回 |
| **手动定值** | 固定占空比（1~255），用于排查问题或固定风量 |

#### 「跟哪路温度」

下拉里的选项是**人话**，不是芯片的原始标签：

```
CPU 核心温度 （推荐） · 46.0 °C      ← PECI，CPU 硅片自身，最准
CPU 插座温度 （推荐） · 40.0 °C      ← CPUTIN，CPU 插座处
主板温度 · 41.0 °C                   ← SYSTIN
未接传感器 （未接） · 35.0 °C        ← AUXTIN*，绝大多数主板这里没接东西
```

- **推荐的排最前**（`CPU 核心温度` / `CPU 插座温度`）
- **`未接传感器` 排最后并标注** —— 选中空脚意味着风扇**不跟任何温度走**
- 括号里是**当前读数**，选之前就知道这路现在多少度

> **一个通道只能跟一路温度。** 芯片的 `pwmN_temp_sel` 是单值（实测范围 `1~12` =
> `temp1~temp12`）。想让 CPU 风扇跟 CPU 温度、机箱风扇跟主板温度，就把它们**分到不同通道**去。
>
> 模式为「关闭」时，该列显示的是**主板当前实际在跟的温度源**（不是配置里存的值）——
> 因为配置值要切到「自动曲线」才生效，显示它只会误导。

#### 曲线怎么写

五个点，形如「温度 → 占空比」，**温度必须严格递增**：

```
FAN1_CURVE=25:30,30:60,45:120,60:200,80:255
              ↑ 25°C 时 30%   ↑ 30°C 时 60%  …  ↑ 80°C 时 255（满速）
```

温度单位写摄氏度，脚本会折成芯片要的毫摄氏度。

#### 自动识别风扇

分组顶部的「**自动识别风扇**」按钮，做两件**能被证实**的事：

1. 逐个试探各插针，认出哪些插针**真接了风扇**
   （**只试静止的**；正在转的已确认有风扇，且动它风险最大——绝不打扰）
2. 按各通道自己声明的温度源归类命名，**未接风扇的通道自动隐藏**

**已有名字不会被覆盖**——那是你自己标的，比推断可信。

#### 测试识别

每行一个按钮，让该通道**明显变一次转速**（实测 1060 → 1620 RPM），
便于你**听声辨位**；测完**无条件还原**主板设置。

这是唯一可靠的「认风扇」办法 —— 原因见下。

> ### 必须如实知道的一点
>
> 主板芯片**不提供风扇名**（`fan*_label` 全空），也**无法从硬件区分哪个插头是 CPU 风扇**。
>
> 实测过：把靠 CPU 的通道从 1108 转压到 349 转，CPU 温度只从 47 °C 动到 46 °C ——
> 待机功耗太低，信号全在噪声里，**靠升温差判不出来**。
>
> 所以自动识别**只做能证实的判断**，名字按温度源归类，**不猜物理身份**。
> 若名字不对，用「测试识别」听声后手动改名 —— 这是唯一可靠的办法。

#### 重新识别芯片与通道（换主板用）

分组顶部的「**重新识别芯片与通道**」按钮。

芯片是**按能力找**的，不是按型号名找：哪个 `hwmon` 目录里有可写的 `pwmN`，
就是可控风扇芯片 —— 所以换成 ITE / Fintek / Winbond 等其他 Super I/O 也能认出来。
型号家族只用于**排序**（优先认 NCT67xx）。

点它会重扫本机所有 `hwmon` 设备并列出结果：

```
扫描完成
已识别风扇芯片：nct6798，可控通道 1 2 3 4 5 7。
/sys/class/hwmon/hwmon0  acpitz     无 pwm 通道
/sys/class/hwmon/hwmon1  nvme       无 pwm 通道
/sys/class/hwmon/hwmon2  coretemp   无 pwm 通道
/sys/class/hwmon/hwmon3  nct6798    通道 1,2,3,4,5,7
```

**换主板时它会问你要「保留名字」还是「清空名字」** —— 这一步必须由你决定，
因为新板子的通道号含义完全不同：旧板上的「机箱风扇」（pwm2）到新板上可能正好是
CPU 插针，**留着名字就是张冠李戴**。

概要页也会显示识别到的芯片，换板后一眼看出认对没有：

```
风扇：nct6798（/sys/class/hwmon/hwmon3）· 通道 1,2,3,4,5,7，本机可控
```

#### 命令行

```bash
pve-hwtools-agent status                          # 各通道转速、模式、温度源、名字
pve-hwtools-agent status | python3 -m json.tool   # 完整状态（含 fan_chip / fan_hwid）

# 自动曲线
pve-hwtools-agent set fan1_mode=auto fan1_sel=8 \
    fan1_curve=25:30,30:60,45:120,60:200,80:255

# 手动定值
pve-hwtools-agent set fan1_mode=manual fan1_manual=128

# 还原主板设置
pve-hwtools-agent set fan1_mode=off

# 命名（名字用百分号编码传递：Perl 反引号读 UTF-8 会二次编码变乱码）
pve-hwtools-agent set fan1_name=CPU%20%E9%A3%8E%E6%89%87              # 「CPU 风扇」
pve-hwtools-agent set fan2_name=%E6%9C%BA%E7%AE%B1%E9%A3%8E%E6%89%87   # 「机箱风扇」
pve-hwtools-agent set fan3_name=                                      # 清空名字

# 逐通道显示（概要页）
pve-hwtools-agent set show_fanch_3=off            # auto / on / off

# 识别与扫描
pve-hwtools-agent fan-detect                      # 只探测，不改配置
pve-hwtools-agent fan-bind                        # 自动识别并写入名字
pve-hwtools-agent fan-test 1                      # 测试通道 1（约 12 秒，自动还原）
pve-hwtools-agent fan-rescan 1                    # 重扫芯片与通道，保留名字
pve-hwtools-agent fan-rescan 0                    # 重扫并清空通道配置
pve-hwtools-agent fan-scan                        # 看探测缓存
```

**百分号编码怎么算**（要写中文名字时）：

```bash
printf '%s' "CPU 风扇" | od -An -tx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g'
# → %43%50%55%20%e9%a3%8e%e6%89%87
```

**为什么不直接写中文**：宿主侧 Perl 反引号读 UTF-8 会二次编码，
`CPU 风扇` 过一趟只剩 `CPU `（尾部被吃）。编码成纯 ASCII 才安全。

#### 安全设计

风扇写错可能烧硬件，所以守得比较严：

- **默认全 `off`** —— 装上补丁不改变任何风扇行为，要动必须明确指定
- 首次碰某通道前，先把它的**全部原始值**存进
  `/usr/local/lib/pve-hwtools/fan-baseline/pwmN.saved` —— 内容是 `enable` / `mode` /
  `temp_sel` / `floor` / `start` / `stop_time` / `step_up_time` / `step_down_time` /
  `temp_tolerance` / 当前 `pwm`，外加五组曲线点 `pointN_temp` / `pointN_pwm`；
  `off` 即按此逐项还原（实测该文件 19 行，本机通道 1、2、3、4、5、7 各一份）
- **基线只在首次创建、绝不覆盖**
- 施加后 3 秒复读转速：**原本在转、现在变 0 → 立即还原并报错**
- 手动占空比下限强制 `>= 1`，**绝不写 0**
- `auto` 模式**先铺好曲线、最后才写 `enable`**，避免中途以半截曲线运行
- 手动定值**必须先写 `enable`、再写 `pwm`** —— 顺序反了会看到「写 255 反而变慢」
  （SmartFan→手动 的切换瞬间占空比被锁存到旧值）
- 自动识别**只试静止的插针**，正在转的绝不打扰
- **换硬件后基线自动重存**（见「四、升级与维护」）

---

## 三、配置参考

### `pve-hwtools-agent` 全部子命令

| 命令 | 作用 |
|---|---|
| `status` | 输出完整状态 JSON（含硬件信息、风扇、配置） |
| `set k=v …` | 批量改配置并施加（任一非法则**一条都不生效**） |
| `apply` | 按当前配置重新施加（改过配置文件后跑这个） |
| `mirrors` | 软件源镜像相关操作 |
| `fan-test N` | 测试通道 N（约 12 秒，自动还原） |
| `fan-detect` | 只探测风扇存在性，不改配置 |
| `fan-bind` | 自动识别并写入通道名 |
| `fan-bind-progress` | 查自动识别的进度 JSON |
| `fan-rescan [keep]` | 重扫芯片与通道；`keep=1` 保留名字 |
| `fan-scan` | 查看探测缓存 |

### `pve-mirror-switch.sh` 全部子命令

| 命令 | 作用 |
|---|---|
| `list` | 列出全部镜像及各自地址 |
| `status` | 显示当前镜像（JSON） |
| `set <代号>` | 切换镜像（只改写源文件，不做连通性检查） |
| `probe` | 探测各镜像当前可达性（查询用） |

### `/etc/default/pve-hwtools` 配置全表

这是唯一的配置真相 —— 面板读写的都是它，也可手工编辑后执行
`pve-hwtools-agent apply`。

```bash
# ── 概要显示开关（1 开 / 0 关）──
SHOW_CPU_TEMP=1
SHOW_FAN=1
SHOW_DISK=1
SHOW_CPU_FREQ=1

# ── 订阅提示屏蔽 ──
BLOCK_SUBSCRIPTION_PROMPT=1

# ── CPU 调频（频率单位 MHz；范围须落在硬件能力内）──
CPU_GOVERNOR=conservative     # performance/powersave/ondemand/conservative/schedutil
CPU_FREQ_MIN=800
CPU_FREQ_MAX=3800
CPU_TURBO=1                   # 1 启用 / 0 关闭
CPU_EPP=balance_performance   # performance/balance_performance/balance_power/power

# ── 软件源镜像 ──
APT_MIRROR=ustc               # ustc/tuna/aliyun/tencent/huawei/official

# ── 风扇控制（默认 off = 不改动主板原有策略）──
#   FANn_MODE   off / auto / manual
#   FANn_SEL    温度源编号（1=SYSTIN 2=CPUTIN 8=PECI…）
#   FANn_MANUAL 手动占空比 1~255
#   FANn_CURVE  五个点「温度:占空比」，温度须严格递增
FAN1_MODE=off
FAN1_SEL=2
FAN1_MANUAL=128
FAN1_CURVE=25:30,30:60,45:120,60:200,80:255
# … FAN2 ~ FAN7 同构

# ── 概要页每通道显示（auto=有转速才显示 / on=始终显示 / off=不显示）──
FANCH_SHOW_DEFAULT=auto
SHOW_FANCH_1=auto
SHOW_FANCH_2=auto
# …（按本机通道数）

# ── 各通道名字（通道号 != 名字；留空则界面显示「通道 N」）──
#   值带空格必须加引号——本文件会被 bash source，不加引号会把名字当命令执行
FAN1_NAME='CPU 风扇'
FAN2_NAME='机箱风扇'
FAN3_NAME=''
```

### 它改了/新建了哪些文件

| 文件 | 说明 |
|---|---|
| `/usr/local/bin/pve-hwpatch.sh` | 概要硬件信息 + 工具集设置页（打补丁脚本） |
| `/usr/local/bin/pve-hwtools-agent` | 状态代理：读写配置、施加调频与风扇、触发重渲染 |
| `/usr/local/bin/pve-nosub-patch.sh` | 订阅提示屏蔽（双向可逆） |
| `/usr/local/bin/pve-mirror-switch.sh` | 软件源镜像切换 |
| `/usr/bin/s.sh` | 取样脚本，输出单行 JSON（纯 ASCII 数值，频率单位 MHz） |
| `/usr/local/lib/pve-hwtools/cpu-model.sh` | CPUID(family/model) → Intel/AMD 代号映射；`s.sh` 与 agent 共用 |
| `/usr/local/lib/pve-hwtools/fan-baseline/` | 风扇各通道**原值**基线（`off` 的还原依据） |
| `/usr/local/lib/pve-hwtools/fanscan.conf` | 风扇芯片探测缓存（换硬件时自动重写） |
| `/usr/local/lib/pve-hwtools/doc.html` | 面板「使用说明」弹出的说明书 HTML（由 README 生成） |
| `/etc/default/pve-hwtools` | **配置真相** |
| `/etc/systemd/system/pve-hwtools-apply.service` | 开机自动施加配置 |
| `/usr/share/perl5/PVE/API2/Nodes.pm` | 注入 `$res->{tdata}` + 注册节点级接口 |
| `/usr/share/pve-manager/js/pvemanagerlib.js` | 插入概要条目、隐藏逻辑、设置页、菜单项 |
| `/etc/apt/apt.conf.d/98-pve-hwpatch`<br>`/etc/apt/apt.conf.d/99-pve-nosub-patch` | apt 钩子：升级后自动重打 |
| `/root/pve-upgrade-backup/` | 原厂文件备份、源文件快照 |

---

## 四、升级与维护

### 让它经得住 `apt upgrade`（重要）

`pve-manager` 每次升级都会覆盖 `Nodes.pm` 与 `pvemanagerlib.js`，
所以**务必挂上 apt 钩子**（一键脚本会自动挂）：

```bash
cat > /etc/apt/apt.conf.d/98-pve-hwpatch <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-hwpatch.sh"; };
EOF

cat > /etc/apt/apt.conf.d/99-pve-nosub-patch <<'EOF'
DPkg::Post-Invoke { "/usr/local/bin/pve-nosub-patch.sh"; };
EOF

apt-config dump | grep -i post-invoke     # 校验钩子已被 apt 读到
```

此后每次 `apt upgrade` 事务结束都会自动重打，无需人工干预。

补丁脚本**幂等**：每次先剥掉自己的旧注入块再重打，所以可反复执行，
升版后也能自我更新。（只用单一标记的写法打完一次就再也改不动——本补丁不是。）

### 换主板

风扇芯片换了，需要重探。点面板上的「**重新识别芯片与通道**」，或：

```bash
pve-hwtools-agent fan-rescan 0   # 重扫 + 清空通道配置（换板建议）
pve-hwtools-agent fan-rescan 1   # 重扫 + 保留名字与显示设置
```

另外**硬件变化会被自动发现**：探测结果按 `HWID`（芯片名 + 通道集合）缓存，
指纹一变（换主板、换内核）就自动重探，并把**原值基线**挪走重存 ——

> 旧的 `pwmN.saved` 里记的是**前一块板子**的原值。换板后拿它去还原，
> 等于把旧板的设置往新板上写。所以必须重存。

旧基线按时间戳存为 `fan-baseline.old-<时间戳>`，**不删**，万一要回查还在。

### 换内核

`pve-hwpatch.sh` 本身与内核无关，`hwmon` 与驱动随内核走，风扇部分无需额外操作。

> 但**若你用了核显 SR-IOV 之类的 DKMS 模块**，注意 DKMS 只编给被钉选的内核，
> 换内核必须同改钉选并重编 DKMS，否则重启仍进旧内核、相关设备全失。

### 修改配置后

面板上点「保存并应用」即生效。手工改过 `/etc/default/pve-hwtools` 后执行：

```bash
pve-hwtools-agent apply
```

---

## 五、卸载 / 还原

```bash
bash install.sh --uninstall
```

脚本按顺序做：

1. **摘除 apt 钩子**（`98-pve-hwpatch` / `99-pve-nosub-patch`）
2. **停用并移除** `pve-hwtools-apply.service`
3. **还原被改的 PVE 原厂文件** —— 两级策略，优先更强的那层：
   - ① **重装包**：`apt install --reinstall pve-manager proxmox-widget-toolkit`
     —— 唯一能 100% 回到**当前版本**原厂内容的办法
   - ② **剥离注入**（离线时）：删掉所有注入标记块、把面板高度复位成原厂值。
     实测剥离后与当前版本原厂文件**逐字节一致**
4. **关闭订阅提示屏蔽**（改配置为 0 并重跑一次以恢复原厂行为）
5. **删除补丁文件**（四个脚本 + `/usr/bin/s.sh` + `/usr/local/lib/pve-hwtools/`）
6. **重启** `pvedaemon` + `pveproxy`

> **不要手工 `cp` 备份文件去还原。** 那正是 V2.2 修掉的坑：
> `*.bak.hwpatch` 可能是**上一代大版本**的原厂件（例如 8.4.19 的备份 vs 现役 9.2.20 的
> 文件），用它覆盖会让 PVE 核心文件版本错乱、`pvedaemon` 起不来。
> 走 `--uninstall` 的两级还原才对。

卸载**会保留**：

- `/etc/default/pve-hwtools`（配置，含你的风扇名字等）
- `/root/pve-upgrade-backup/`（原厂备份）

要彻底清除自行删除即可。

---

## 六、常见问题

**Q：刷新页面后没看到「硬件概要」？**
先 **Ctrl+Shift+R** 强刷（旧 JS 有缓存）。仍不行则查
`grep -c PVE_HWAPI /usr/share/perl5/PVE/API2/Nodes.pm` 是否非 0，
以及 `systemctl status pvedaemon pveproxy`。

**Q：温度/风扇不显示或不全？**
`lm-sensors` 可能没探测过：`sensors-detect --auto`，然后 `sensors` 看有没有读数。

**Q：风扇分组是空的 / 显示「本机未识别到可控风扇通道」？**
说明没找到可控 pwm 通道。点「重新识别芯片与通道」看扫描结果：
若所有设备的通道都是空的，可能是 Super I/O 驱动没加载
（`modprobe nct6775`，或对应的 `it87` / `w83627ehf` 等），或本机确实没有可控风扇。

**Q：为什么名字要自己填，不能自动读出来？**
因为**芯片不提供风扇名**（`fan*_label` 全空），也**无法从硬件区分哪个是 CPU 风扇**
（实测压转速看温升，信号淹没在噪声里）。所以只能用「测试识别」听声后手动命名。

**Q：想同时跟主板温度和 CPU 温度？**
做不到 —— 单通道的 `temp_sel` 只能选一路。把 CPU 风扇和机箱风扇分到不同通道，
各跟一路即可。

**Q：改了名字，概要页没变化？**
概要按「显示」设置过滤：若该通道是 `自动显示` 且转速为 0，就不列出。
把它设为 `始终显示`。

**Q：`pve-hwtools-agent set` 报「未知配置项」？**
配置键有白名单校验。`show_*` / `block_*` / `governor` / `freq_*` / `turbo` / `epp` /
`apt_mirror` / `fan*` / `show_fanch_*` 之外一律拒绝。整批参数里**任一非法则一条都不生效**。

**Q：面板保存提示 500 / 报 `command ... failed`？**
多半是参数没过校验。整批参数任一非法则全部不写，配置保持原样——不会写坏。

**Q：PVE 大版本升级后功能消失？**
apt 钩子没挂上。检查 `apt-config dump | grep -i post-invoke`，
或升级后手工跑一次 `/usr/local/bin/pve-hwpatch.sh`。
若锚点失配（PVE 改了 `StatusView` 结构），脚本会自己报错并回滚，不会把面板改坏。

---

## 实现要点与踩坑

<details>
<summary>展开（开发/排障时看）</summary>

1. **脚本只输出纯 ASCII 数值，单位由前端 JS 补。**
   Perl 反引号 `` `s.sh` `` 读入 UTF-8 时会二次编码，`°C` 会变 `Â°C` 乱码；
   把单位全交给前端 `renderer` 拼接即可绕开。
   - 任意用户文本（风扇名）没法「只输出 ASCII」时，改用**百分号编码**：
     宿主侧 `od -An -tx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g'`，
     前端 `decodeURIComponent` 还原。
   - 条目的分隔符别用**字面换行**（JSON 解析器拒为非法控制字符），改用 `|` 之类单字符，
     用之前先禁掉该字符出现在条目内。

2. **凡用字符类过滤，一律 `LC_ALL=C`。**
   `sed 's/[^ -~]//g'` 在 UTF-8 locale 下会按 **collation 排序**解释括号范围
   （非 ASCII 字节序），`0`~`9` 竟被判为越界删掉（`+45.0°C` → `+.`）。加 `LC_ALL=C` 才按字节序。

3. **改完必须校验语法再重启。**
   `perl -c` 校验 `Nodes.pm`、`node --check` 校验 `pvemanagerlib.js`；失败时自动回滚。

4. **`protected => 1` 是必需的——踩得最深的坑，读接口也一样。**
   `pveproxy` 以 `www-data` 运行。节点级接口若**不带** `protected => 1`，
   请求就在 pveproxy 进程里**就地降权执行**（`HTTPServer.pm`：只有 `protected` 且 euid≠0
   才转给 root 的 `pvedaemon`），于是特权动作会以非 root 身份失败。原厂所有需 root 的
   节点级接口都带这一项。
   - **失败是静默的，这是它最难查的地方。** 本补丁的 `hwtools_status`（一个**读**接口）
     就漏了它：agent 因 `need_root` 直接 die，接口照样返回 **200**、内容是
     `{"data":{}}`（11 字节、零字段）。前端拿到空对象后，频率显示 `undefined MHz`、
     风扇说「本机未检测到可控风扇通道」—— 看着像补丁没装，其实全都装好了。
     **别用「返回 200」判断接口正常，要看正文里有没有真字段。**
   - **凡是会调 agent（或任何需 root 的命令）的接口，读也要带。** 脚本里已加护栏：
     注入后逐个断言 `register_method` 块里都有 `protected => 1`，缺一个就拒绝注入。
   - **连带教训：测「新按钮」测不出这种问题。** 当时验证「使用说明」按钮是通过的 ——
     因为它读的是 644 的静态文件，不需要 root，恰好绕开了这个坑。**一条链路通了
     不等于同页面其它接口都通。**

5. **别在 API 处理期间重启 `pvedaemon`。**
   会掐断正在服务该请求的 daemon 自己，表现为 `failed: exit code 1` 或 HTTP 596。
   故只在**后端内容真的变了**时才重启（比对注入前后 hash）；前端改动刷新即见，本不需重启。

6. **`Ext.define` 的 `items` 在类定义期求值。**
   里面**绝不能放运行期求值**（IIFE、未定义变量），否则整个 `pvemanagerlib.js` 加载失败，
   连登录窗都不渲染——而 `node --check` 只验语法，查不出。
   开关一律走「**条目全静态注入 + 渲染后隐藏**」。

7. **`Proxmox.Utils.API2Request` 的 `url` 不带 `/api2/json` 前缀**（框架自加）；
   **`Ext.Ajax.request` 才需带**。写错会变成 404。两边写法正好相反。

8. **方法不匹配报的是 501，不是参数错。**
   节点级接口有惯例：读 GET、改配置 PUT、执行动作 POST。
   方法不对时返回 `501 method '<M> /<path>' not implemented` —— 遇到 501 先核对注册的 `method`。

9. **注入块里别写反斜杠转义——包括注释。**
   前端 JS 嵌在补丁脚本内 Python 三引号字符串里；写了反斜杠加 `n`/`u`/`t`，
   Python 会**先**把它译成真字符，从而截断 JS 字面量或注释，结果整个 `pvemanagerlib.js`
   加载失败、连登录窗都不渲染。换行用 HTML 标签（`<br/>`）或 `String.fromCharCode`，
   度数符号直接写 `°`。脚本内已加护栏：一旦在注入块源码里发现反斜杠转义就拒绝注入。

10. **往注入块插类方法后，必须验它落在类层级而非 `initComponent` 内部。**
    锚点选在 `me.callParent();` **之前**的话，方法会被插进 `initComponent` 的函数体 ——
    语法上只是「标签 + 函数表达式」，`node --check` **竟然通过**（JS 里是合法的 labeled
    statement），但类一实例化就抛错、菜单项静默不出现。校验手法：把类体整段抽出来
    （从 `Ext.define('...'` 到最后的 `});`），前面加桩，`node --check` 才真正按对象字面量校验。

11. **校验函数绝不能放在 `$(...)` 里调用。**
    `X=$(valid_foo "$v")` 会把函数放进**子 shell**，里面 `die(){ exit 1; }` 只能杀掉子 shell，
    父进程照旧往下走 —— 于是非法输入会「打印了错误却照样把配置写进去」。

12. **参数校验正则要给下划线留位。**
    `^[a-z_]+=[0-9a-zA-Z]+$` 会把值里带下划线的合法取值全拒掉（EPP 档位名
    `balance_performance` 等），症状是「命令行成功、经 API 就 500」。

13. **风扇的硬件细节**（本机 NCT6798D / `nct6775`）：
    - `pwmN_enable` 语义：`0` 全速 / `1` 手动定值 / `2` 温度巡航 / `3` 转速巡航 /
      `5` SmartFanIV（硬件曲线）；`4`（SmartFanIII）在本芯片上被驱动拒绝
    - 曲线五点温度单位是**毫摄氏度**，占空比 `0-255`
    - **手动定值必须先写 `enable` 再写 `pwm`** —— 反序会看到「写 255 反而变慢」
    - 名字写进配置前**必须加引号并禁掉 `| , =` 与单引号**：配置被 `bash source`，
      `FAN1_NAME=a b c` 会让 bash 去**执行 `b`**
    - 芯片**不提供风扇名**（`fan*_label` 全空），也**无法从硬件区分哪个是 CPU 风扇**
      （压转速看温升：1108→349 转，CPU 温只动 1 °C，信号在噪声里）。能证实的只有两件：
      该插针有没有接风扇（**静止的**试转一下）、该通道跟哪路温度（`pwmN_temp_sel`）
    - 单通道 `temp_sel` 只能选一路（实测 `1~12` = `temp1~temp12`，13 以上被拒）
    - 适配不同主板：**按能力找**（哪个 hwmon 目录有可写 `pwmN`），**不按型号名找** ——
      按白名单找的话，换成 ITE / Fintek / Winbond 就无提示地哑掉

14. **探测缓存的存储格式别用带引号的 JSON。**
    存进 shell 变量再拼回 JSON 时，转义层数极易搞错 —— 实测 heredoc 里的 `\"` 不会被剥掉，
    拼出来就是字面反斜杠、JSON 直接非法。改存**紧凑无引号格式**（`目录|名称|通道|可用;…`），
    只在输出给前端时才转 JSON。

15. **`local IFS` 在 `set -u` 下会报 unbound。**
    bash 里声明后未赋值就引用会直接失败。改用 `local savesep="$IFS"; IFS=';'` …
    收尾再 `IFS="$savesep"`。

</details>

---

## 更新日志

### V2.13 · 2026-09-25

**修：设置页一直显示不出数据（从 V2.0 起就坏了）。**

拍设置页截图时发现整页是空的：频率显示 `undefined MHz`、硬件能力 `undefined MHz ~
undefined MHz`、风扇区说「本机未检测到可控风扇通道」、软件源区也是空的 —— 看着像补丁
没装上，但配置、agent、进程全都正常。

根因：**`hwtools_status`（状态**读**接口）漏了 `protected => 1`**，其余七个接口都有。
没有它，请求就在 `pveproxy` 进程里以 `www-data` **降权执行**，而 agent 的 `status`
要读 sysfs 与传感器、跑着 `need_root` 校验，于是直接 `die`：

```
$ su -s /bin/bash www-data -c '/usr/local/bin/pve-hwtools-agent status'
错误：需要 root 权限
```

接口**照样返回 200**，正文却是 `{"data":{}}`（11 字节、零字段）。前端拿到空对象，
于是满屏 `undefined`。**失败是静默的**，这是它最难查的地方。

- 给 `hwtools_status` 与 `hwhelp` 都补上 `protected => 1`（后者只读静态文件、
  本不需要 root，但保持一致，免得日后改动时再踩）。
- **加护栏**：注入前逐个检查 `register_method` 块，凡缺 `protected => 1` 就
  **拒绝注入并报出接口名**。这类 bug 从此不可能再溜进产物。
- 顺带说明「为什么之前没测出来」：验证「使用说明」按钮是**通过**的 —— 它读的是
  权限 644 的静态文件，恰好不需要 root。**一条链路通了，不代表同一页面的其它接口都通。**

实测（修后）：接口由 `{"data":{}}` 变为 2892 字节 / 42 个字段；设置页显示
`处理器 Alder Lake (12th Gen Core)、驱动 intel_cpufreq、策略数 8、硬件能力 800~4300 MHz`，
风扇区 `nct6798 · 通道 1,2,3,4,5,7，本机可控`，页面零 `undefined`。

### V2.12 · 2026-09-25

**修一个会「整块藏掉硬件概要」的坑**（在 V2.11 的验证中发现的真问题）。

显示开关首次读取失败时，原来的写法会把**整块硬件概要隐藏**：

```js
var d = Ext.decode(rq.responseText).data || {};   // 接口瞬时报错 → 变成 {}
if (!one(d.show_cpu_temp)) { ... }                // 四个开关全判 false
if (ids.length >= 4) { ids.push('hw-header'); }   // 连表头一起收
```

状态接口在**会话尚未就绪**时可能返回不含 `data` 的响应，此时 `|| {}` 让四个开关全成
`false`，于是七个条目全部 `display:none` —— 看到的现象是「补丁没生效」，而配置、接口、
数据其实一切正常。这条 XHR 是**同步**发出的，正好容易抢在会话就绪之前。

- **取不到开关值就当作全开**（`readSwitches()` 返回 `null` → 什么都不隐藏）。
  宁可多显示，不可误隐藏。
- **首读失败自动重试一次**（1.5 秒后），拿到真值再应用。
- 顺带修另一个老 bug：「CPU 温度」和「风扇转速」**只关这两项**也会凑满 4 个 id，
  从而误把表头一起收起 —— 改为**四项全关**才收表头。

### V2.11 · 2026-09-25

**CPU 核心温度改显示平均值**，不再逐核列出。

原先概要页把每个核心单独列一行（`Core 0 43.0 °C | Core 1 42.0 °C | …`）。核心一多
（16 核、64 核）这行就会被撑成好几行，把概要面板顶得很难看。

- 改为**平均值 + 核数**：`CPU核心温度 44.0 °C（4 核平均）`
- 数据源也一并精简：`s.sh` 不再输出逐核列表，只给 `cpu_core_avg` 与 `cpu_core_n`；
  逐核求和时**剥掉度数符号**（`+44.0°C` → `44.0`，只剥 `+` 和 `C` 是不够的）
- 核名匹配兼顾两种驱动写法（`Core N:` 与 `CPU N:`）；一个核心都没有时回退显示 `-`
- 条目标题 `CPU各核` → `CPU核心温度`；设置页勾选框文案改为
  「显示 CPU 温度（封装与核心平均）」

### V2.10 · 2026-09-25

**面板里就能看说明书：设置页新增「使用说明」按钮。**

- **「使用说明」按钮**（设置页底部，与「保存并应用 / 重新载入」并列）：弹出可滚动、
  可最大化的窗口，内含完整安装与使用说明。
- **说明书与仓库 README 同源**：`tools/mkdoc.py` 把 README 转成 HTML（只取
  「安装 / 使用 / 配置 / 升级 / 卸载 / 常见问题」六章，开发笔记与变更日志不入面板），
  安装时落到 `/usr/local/lib/pve-hwtools/doc.html`；新节点接口
  `GET /nodes/{node}/hwhelp` 读出来交给前端弹窗。改说明只需改 README + 重跑安装。
- **正文刻意不内联进前端注入块**：那份 HTML 有三万多字符、满是反斜杠与引号，
  内联会踩中「注入块禁止反斜杠转义」这条铁律（Python 三引号会先把它译掉，
  整个 `pvemanagerlib.js` 加载失败）。改成独立数据文件 + 接口读取，注入块里
  只有几行取回与弹窗逻辑。
- **CSS 全部以 `.pve-hwtools-doc` 打头**：ExtJS 是把这段 HTML 直接塞进面板的，
  不加作用域会让 `h1` / `table` 样式泄漏到整个 PVE 界面。
- `install.sh` 自检加一项（`使用说明 doc.html 就位`，共 12 项）；说明书下载失败
  **不会**让安装中止——只影响这个按钮，其余功能照常。卸载连 `doc.html` 一并清除。

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
  发现指纹变了（换主板、换内核）就自动重探，并把**原值基线**挪走重存。
  旧基线按时间戳存为 `fan-baseline.old-*`，不删。
- **概要页显示识别到的芯片**：`风扇：nct6798（/sys/class/hwmon/hwmon3）· 通道 1,2,3,4,5,7，本机可控`
- 探测缓存改用**紧凑无引号格式**再在输出时转 JSON —— 带引号的 JSON 存进 shell 变量
  再拼回 JSON，转义层数极易搞错。

命令行：`pve-hwtools-agent fan-rescan [keep]`、`fan-scan`（看缓存）。

### V2.8 · 2026-09-25

**风扇跟哪路温度：可选，且看得懂。**

- **温度源翻成人话**：原来下拉里是芯片给的名字（`PECI Agent 0`、`AUXTIN0`、`PCH_CHIP_TEMP`），
  没人知道该选哪个。现在按「代表哪里的温度」翻译：
  `CPU 核心温度`（PECI）/ `CPU 插座温度`（CPUTIN）/ `主板温度`（SYSTIN）/
  `芯片组`（PCH_*）/ `未接传感器`（AUXTIN*）。CPU 与主板温度带「（推荐）」标记。
- **候选带实时读数**：`CPU 核心温度 （推荐） · 46.0 °C`，选之前就知道这路现在多少度。
- **排序有用优先**：推荐的排最前，`未接传感器` 一律排最后并标注。
- **模式为「关闭」时显示内核实际值**：原先把配置里记的 `FANn_SEL` 直接显示，
  但 `off` 时内核跟的是主板原厂值，两个可能不同 —— 界面会显示一个**并未生效**的温度源。
  现已改为 `off` 时显示内核实际在跟的那路（新增 `sel_live` 字段）。
- 单通道只能跟**一路**温度（`pwmN_temp_sel` 是单值，实测范围 1~12）。

> 关于「同时跟主板和 CPU」：这颗 Super I/O 的单通道 `temp_sel` 只能选一路。
> 只有 `pwm2` 额外带一组加权属性（`weight_temp_sel` / `weight_temp_step`），
> 可做「两路温度步进叠加」，但厂商语义未公开、也无从验证，**没有做进界面** ——
> 宁可少一个功能，也不摆一个说不清行为的开关。

### V2.7 · 2026-09-25

**风扇通道命名与识别**（承接 V2.4 的风扇控制）。控制器与风扇名彻底分开。

- **通道名**：设置页每行可直接填名字（支持中文），结果显示在概要页。
  名字存进配置时自动加引号，并禁止 `| , =` 与单引号——配置会被 `bash source`，
  不加引号会直接执行名字内容。
- **自动识别风扇**：逐个试探各插针（静止的才试转，正在转的绝不打扰），
  识别哪些插针真接了风扇；再按各通道自己声明的温度源归类命名，未接风扇的通道自动隐藏。
  已有名字不覆盖。
- **测试识别**：让指定通道明显变一次转速（实测 1060 → 1620 RPM），便于听声辨位；
  测完无条件还原主板设置。
- **逐通道显示开关**（`SHOW_FANCH_n`）：`自动显示` / `始终显示` / `不显示`。
- 长任务改为**后台执行 + 面板轮询进度**，避免撞上代理超时。
- 写入顺序修正：**先写 enable 再写 pwm**。

**须如实知道的一点**：主板芯片**不提供风扇名**，也无法从硬件区分哪个插头是 CPU 风扇
（实测压转速看温升，信号淹没在噪声里）。所以自动识别只做「能证实的判断」，
名字按温度源归类，**不猜物理身份**；若名字不对，用「测试识别」听声后手动改名。

### V2.4 · 2026-09-25

- **新增风扇控制**：自动曲线 / 手动定值 / 关闭三态，面板可配、命令行可配
  - 自动曲线由**主板硬件执行**（SmartFan IV），无需常驻进程
  - 默认全 `off`，装上不改动任何风扇行为；`off` 可完整还原主板原始设置
  - 安全阀：写后 3 秒复读转速，原本在转却变 0 就**立刻还原并报错**
  - 手动占空比下限 1，拒绝 0（停转）
- **修正一个已发布版本里的隐患**：`governor` / `freq_min` / `freq_max` / `turbo` / `epp` /
  `apt_mirror` 的取值校验原先跑在**子 shell** 里，`die` 终止不了父进程 ——
  于是非法输入会「打印了错误却照样写配置」。现已改为直接调用、真正中止。
- **修正 Perl 侧参数键名正则**：原先只允许 `[a-z_]+`，导致 `fan1_mode` 这类含数字的键
  被判非法 → 保存永远失败
- 参数分隔符由逗号改为**空格**（曲线取值自带逗号，按逗号切会被拆碎）

### V2.3 · 2026-09-24

- **新增 `pve-mirror-switch.sh`：软件源镜像一键切换**，并在设置页加「软件源」分组；
  支持中科大 / 清华 / 阿里云 / 腾讯云 / 华为云 / 官方源六种
  - 只改公共镜像的源行，**自定义私有源原样保留**
  - 发行版代号现读 `os-release`，不写死 `trixie`
  - 自动停用企业订阅源；原件存 `apt-sources.orig`（永不覆盖）+ 每次改动留时间戳快照
  - 支持经典 `sources.list` / `*.list` 与 deb822 `*.sources` 两种格式
  - **切换不做连通性检查**
- 实测结论：阿里云、腾讯云**无 Proxmox 镜像**（404），华为云的 Proxmox 镜像
  **签名无效** → 这三家的 PVE 包走官方源

### V2.2 · 2026-09-24

- **新增 `install.sh` 一键部署 / 卸载脚本**：自动装依赖、放脚本、挂 apt 钩子、结尾自检；
  `--uninstall` 完整还原
  - 支持 `curl … | bash` 与本地运行两种方式；`--ref` 指定版本、`--no-deps` 跳过依赖
  - 下载后自动核对 `SHA256SUMS`，不符即中止
- **卸载改为「重装包 → 剥离注入」两级还原**：实测剥离后与当前版本原厂文件**逐字节一致**
- **修：备份文件可能过期导致回滚错版本。** 原逻辑「备份不存在才建」，PVE 大版本升级后
  旧备份仍是上一版原厂件；一旦注入失败回滚到它，就会把 9.2 的文件退回 8.4.19、
  `pvedaemon` 起不来。现改为**仅在文件干净（无补丁标记）时才刷新备份**
- 另修：剥离注入时的标记名要与脚本一致（`PVE_` 前缀不可省），否则一条也剥不掉

### V2.1 · 2026-09-24

- **频率单位由 kHz 改为 MHz**（面板输入、配置文件、状态回显、概要显示全部统一）
- **新增 Turbo 加速开关**（`intel_pstate/no_turbo`；不支持的平台自动禁用该控件）
- **新增能效偏好 EPP**（四档，仅平台支持时可用）
- **新增 CPUID → 代号映射**：内置主流 Intel（family 6 全部型号，98 项）与
  AMD（family 0xF / 0x10 / 0x17 / 0x19 / 0x1A）代号
- 修复后端参数校验拒绝含下划线的取值（EPP 档位名曾被误拒）
- 修复注入块内反斜杠转义被 Python 提前求值、导致整份前端 JS 加载失败的问题

### V2.0 · 2026-09-24

- **新增「PVE 工具集」设置页**（节点左菜单 System 下），三组：概要显示开关 / CPU 调频 / 订阅提示
- **概要四项可分别开关**；关掉的条目连同占位隐藏，面板高度随之收缩
- **CPU 调频可图形设置**：模式（五种调速器）+ 频率上下限，范围**受 `/sys` 报告的硬件能力钳制**
- **订阅提示屏蔽改为可逆**，由 `BLOCK_SUBSCRIPTION_PROMPT` 驱动
- 新增 `pve-hwtools-agent`：状态代理，配置真相 `/etc/default/pve-hwtools`
- 新增节点级接口 `GET/PUT /nodes/{node}/hwtools`；PUT 带 `protected => 1`
- 补丁脚本改为**可自升级**：每次先剥旧注入块再重打；并在后端内容真变时才重启服务
- 保存后概要页**当轮刷新即生效**

### V1.1 · 2026-09-24

- **CPU 各核带核名**（`Core 0` / `Core 1` …）
- **风扇转速带序号**（`Fan 1` / `Fan 2`）
- **硬盘温度附型号与容量**（读 `/sys/block/*/device/model` 与 `size`）
- 条目改用 ` | ` 分隔（ExtJS 会把连续空格压成单个）
- 前端注入块改为 `// PVE_HWPATCH:BEGIN / :END` 包裹，**升级时整块替换**
- 面板高度 540 → 480

### V1.0 · 2026-09-24

- 首个版本：CPU/主板温度、风扇转速、硬盘温度、CPU 频率

---

## 许可

MIT
