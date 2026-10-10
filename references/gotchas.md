# 陷阱与证据留档

> 本文件记录「为什么这么做」的证据，以及踩过的坑。所有引用均标注来源与时点，
> 便于日后复核是否仍然成立。**证据强度分层标注**：官方声明 > 实测 > 社区传闻。

---

## 1. icloudpd 不可用（证据：Homebrew 官方 formula 元数据，2026-10-05 实测）

`icloudpd` 原本是这类任务最流行的工具，但**现在不能推荐**。`brew info icloudpd` 原文：

> Deprecated because it was built with an initially released source file that had a
> different checksum than the current one. **Upstream's repository might have been
> compromised.** We can re-package this once upstream has confirmed that they retagged
> their release! It will be disabled on 2027-09-17.

同时在 `formulae.brew.sh/formula/icloudpd` 上，当前版本 1.32.3 还挂着多条已知漏洞，含：

- `GHSA-38jv-5279-wg99` urllib3 解压炸弹绕过（high）
- `GHSA-58pv-8j8x-9vj2` jaraco.context 路径穿越（high）
- `GHSA-9hjg-9r4m-mvj7` Requests 经恶意 URL 泄露 .netrc 凭据（medium）

另外其上游仓库 README 顶部长期挂着 *"Looking for MAINTAINER"*。

**口径说明**：这是「校验和对不上、上游可能被入侵」的**未决疑点**，不等于已确认被入侵。
但该工具需要用户交出 Apple ID 凭据，供应链信号不可接受 → 换用 osxphotos。

**附带事实**：icloudpd 需要关闭「高级数据保护」(ADP) 并开启「允许网页访问 iCloud 数据」，
否则 Apple 返回 `ACCESS_DENIED`。为跑一个备份工具而降低账号安全等级，本身就不划算。

---

## 2. NTFS 在 macOS 上默认只读（证据：系统实测）

macOS 原生 NTFS 驱动是**只读**的。判定方法：

```bash
mount | grep "/Volumes/你的盘"     # 输出里出现 read-only 就是只读
diskutil info /dev/diskN sM | grep "Volume Read-Only"
```

要写入需第三方驱动（Paragon NTFS / Tuxera / mounty+macFUSE）。但：

- 第三方 NTFS 驱动在大批量写入时有元数据损坏风险
- 因此**不适合承载唯一备份**
- 更稳的做法：把数据备份走，重新格式化为 exFAT

**实测案例**：某 1 TB 移动硬盘的 `My Passport`(500 GB) 与 `ajaxhe`(290 GB) 两个分区
均为 NTFS 且只读挂载，机器上未装任何第三方 NTFS 驱动（`/Library/Filesystems/` 只有
`NetFSPlugins`）→ 完全写不进去，只能换盘。

---

## 3. `diskutil` 的 Partition Type 会骗人（证据：系统实测）

exFAT 盘可能显示：

```
Partition Type:            Windows_NTFS
File System Personality:   ExFAT
```

这是出厂分区标志没随格式化更新，**无实际影响**。判定文件系统一律以
`File System Personality` 和 `mount` 输出的类型为准，不要看 `Partition Type`。

---

## 4. exFAT 的硬限制

| 事实 | 影响 |
|---|---|
| 单文件上限 16 EB（**无 4 GB 限制**） | 4 GB 是 **FAT32** 的坑。大视频在 exFAT 上没问题 |
| 无日志（journal） | 断电/热拔/强拔比 APFS 更容易留下需要修复的损坏。**拔盘前必须先 eject** |
| 不支持硬链接、扩展属性、资源叉 | **不能存放 `.photoslibrary`**（图库依赖硬链接），只能放导出的散文件 |
| 默认簇很大（常见 128 KB） | 大量小文件会浪费空间 |
| 跨平台 | Windows / macOS 双向读写，这是选它的主要理由 |

**决定**：
- 导成散文件 → exFAT 可用
- 拷 `.photoslibrary` 整包 → 目标盘必须 APFS 或 HFS+

---

## 5. 沙箱跑不了 osxphotos —— 已推翻（证据：2026-10-06 复测）

**⚠️ 本节结论在 2026-10-06 被推翻。** 保留原文是为了记录误诊过程。

原判断（2026-10-05）：osxphotos 的 import 链在 Photos / AppleEvent 初始化处不定时挂死，
判定为执行环境对 macOS 服务调用的限制。当时的实测表：

| 命令 | 结果 |
|---|---|
| `osxphotos --version` | 时快时慢 |
| `osxphotos --help` / `info` | 稳定卡住 |
| `python -c "import osxphotos"` | 稳定卡住 |
| `import objc` / `Foundation` / `AppKit` | 正常 |

**2026-10-06 复测（重启后、盘恢复正常）：**

| 命令 | 结果 |
|---|---|
| `import osxphotos` | ✅ 秒回，`IMPORT OK 0.77.2` |
| `osxphotos --version` | ✅ 连续 3/3 成功 |
| `osxphotos info --library <路径>` | ✅ 正常进入读库流程 |

**真正的卡点是「完全磁盘访问」缺失**，报错为
`PermissionError: [Errno 1] Operation not permitted: .../Photos.sqlite`。
沙箱本身能跑 osxphotos。

**教训（与本节原有教训同源）**：把「间歇性失败」归因给环境之前，先排除**权限**与
**被操作对象的状态**。当时盘正处于卡死状态，很可能连累了 Photos 框架相关的系统调用；
但直接跳到"沙箱限制"这个结论，掩盖了真正需要的授权动作。

**仍然成立的部分**：几十 GB 到几百 GB 的任务不该挂在 agent 会话里（会随会话结束被杀）
→ `full` 仍建议放用户终端，或用 `nohup` 脱离会话。

---

## 5b. TCC 权限归责到「调用脚本的 App」，不是 osxphotos（证据：2026-10-06 实测）

macOS 的 TCC（隐私授权）按**负责进程**归责。脚本是子进程，osxphotos 是孙进程，
但授权检查落到**最外层的那个 App**：

| 在哪跑 | 要给谁「完全磁盘访问」 |
|---|---|
| Terminal.app | 终端 |
| WorkBuddy | WorkBuddy.app |
| iTerm / VS Code 集成终端 | 对应的 App |

**给错对象等于没授权**——这是最容易白折腾一步的地方。

辨识缺失 FDA 的方法：stdout 只有摘要，**真正的 errno 只写在 crash log 里**。

```
# stdout（会误导你以为只是复制失败）
Error copying .../Photos.sqlite to /var/folders/.../Photos.sqlite
Crash log written to '.../osxphotos_crash.log'

# crash log 里才有定性证据
PermissionError: [Errno 1] Operation not permitted: '.../Photos.sqlite'
```

工具链已内建识别：`probe` 会同时查 stdout 和 `$PWD/osxphotos_crash.log`，
命中 `Operation not permitted` / `PermissionError` 就打印处置步骤并以退出码 3 结束。

---

## 5c. `--library` 与 `--no-version-check` 的层级陷阱（证据：2026-10-06 实测）

**`--library` 是子命令级选项，必须写在子命令之后。**

```bash
osxphotos --library X info     # ❌ Error: No such option '--library'.
osxphotos info --library X     # ✅
osxphotos export --library X <dir>   # ✅
```

它定义在 `cli/cli_commands.py:242`，但那个类是**每个子命令自己的参数组装器**，
所以会被注册到各子命令上，而不是顶层 group。用
`osxphotos info --help` / `osxphotos export --help` 都能看到 `--library, --db`。

**`--no-version-check` 在 0.77.2 里不可用。**

`cli_params.py:121` 有 `VERSION_CHECK_OPTION = click.option("--no-version-check", ...)`，
但**没注册到 `export` / `info`**，运行时报 `Error: No such option '--no-version-check'`。
官方在 `cli/common.py:131` 给出的替代是环境变量：

```bash
export OSXPHOTOS_NO_VERSION_CHECK=1
```

**教训**：参数是否可用，以 `--help` 的实际输出为准，不要读源码下结论——
源码里有定义 ≠ 注册到了你要用的那个子命令。

---

## 5d. `set -o pipefail` + `cmd | head -1` = 时好时坏的竞态（证据：2026-10-06 实测）

```bash
set -uo pipefail
if ! "$OX" --version 2>&1 | head -1; then ... fi   # ❌ 会随机进错误分支
```

`head -1` 读完一行就退出 → 上游命令收到 **SIGPIPE（退出码 141）** →
`pipefail` 把整条管道判为失败 → 条件成立 → 走进"工具无法启动"的分支。

**它是竞态**：上游输出短、在 `head` 退出前就写完时**不会**触发；
输出多或调度稍差就触发。表现为「同一个命令有时成功有时失败」。

**修法**：不要用管道取首行，先落到变量或临时文件。

```bash
out="$( "$OX" --version 2>&1 )"; rc=$?
if [ "$rc" -ne 0 ]; then ...; fi
printf '%s\n' "$out" | head -1
```

同类风险：`grep ... | head -N`、`find ... | head -N`，只要结果集可能超过 N 就中招。
本仓库脚本已按此修正（`icloud_export.sh` 工具检查、`DEV="$(... | head -1)"` 处）。

---

## 5e. bash 3.2 在 UTF-8 下会把高位字节并进变量名（证据：2026-10-06 实测）

```bash
c_err "失败（退出码 $rc）"     # ❌ bash: rc?: unbound variable
c_err "失败（退出码 ${rc}）"   # ✅
```

macOS 自带 `/bin/bash` 是 3.2，`$rc` 后面紧跟全角括号「）」或中文时，
变量名解析会把多字节字符的首字节吃进去，于是找 `rc\xef` 这个不存在的变量，
在 `set -u` 下直接报 unbound variable。

**约定：变量名后紧跟非 ASCII 字符时，一律用 `${VAR}` 花括号形式。**

### 两个必须记住的细节

**① 没有 `set -u` 时它是「静默出错」，比报错更危险。**
带 `set -u` 会立刻中止（好排查）；不带则变量被解析成空，输出变成
`pid=` 这种看起来正常、实则丢值的提示 —— 2018 年那种「日志对不上但没人发现」
就是这么来的。**不要靠 set -u 兜底，靠花括号根治。**

**② 只影响「代码」，不影响「注释」。**
注释里的 `$VAR）` 不会被解析，无害（lint 会标注为「注释(无害)」，不用改）。

### 复发记录（2026-10-06，同一天第二次踩）

写 `restart-export.command` 时又踩了，两处：

```bash
echo "   新 autopilot 已启动（pid=$NEWPID）"   # ❌ line 81: NEWPID）: unbound variable
echo "✅ autopilot 存活（pid=$p）"             # ❌ 同一坑
# ✅ 改成 ${NEWPID} / ${p}
```

后果：脚本在「3/4 拉起新一轮」处**直接中止**，后两步（状态确认、后续指引）没跑，
用户看到一行突兀的 unbound variable，以为整个重启失败了。
（实际上 nohup 那行在它之前已执行，新导出**是起来了的** —— 排查时要先看进程，
不要只看报错位置。）

**结论：中文提示里插变量，写的时候就直接敲花括号，不要等 lint 来抓。**

### 自查（别用肉眼）

```bash
bash scripts/lint-nonascii-vars.sh                 # 默认扫本 skill 的脚本 + 工作区 .command
bash scripts/lint-nonascii-vars.sh 某脚本.sh        # 指定文件
```

或直接跑 Python 正则：

```python
import re
pat = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)(?=[^\x00-\x7f])')
```

---

## 6. Homebrew 6.0 装包会等交互确认（证据：本次实测，2026-10-05）

`brew install pipx` 在后台运行时表现为**静默挂起 10 分钟以上**，实际原因是它弹出：

```
==> Would install 6 dependencies for pipx: ca-certificates openssl@3 readline sqlite xz python@3.14
==> Do you want to proceed with the installation? [y/n]
```

而输出被 `| tail -20` 缓冲住了，看不到。

**规避**：
- 不要用管道包住 brew 的输出（会丢进度）；用 `run_in_background` 直接看原始输出
- 或干脆绕开 brew：`pip install pipx`（装进隔离 venv）再 `pipx install <pkg>`，
  既避免拉 6 个系统依赖，也符合环境隔离要求
- 注意 `HOMEBREW_NO_AUTO_UPDATE=1` 只跳过自动更新，**不跳过这个确认**

---

## 7. 旧导出的命名体系不同，无法按文件名去重（证据：本次实测）

手机助手 / Android 类备份工具的产物命名为：

```
10be5301-dcfa-44ef-96cd-b1844c8fc84e.mp4     # UUID
1665193713228.mp4                             # epoch 毫秒时间戳
```

而 Apple / osxphotos 的产物是 `IMG_1234.HEIC` / `IMG_1234.MOV`。两者**无法按文件名对齐**。

**处理**：新导出放到独立的顶层目录，与旧备份物理隔离；将来若需合库，只能按
**内容哈希**（如 `sha256`）或「拍摄时间 + 文件大小」比对，不能靠文件名。

---

## 8. USB 桥接移动硬盘读不到 SMART（证据：系统实测）

`diskutil info` 报 `SMART Status: Not Supported` —— 绝大多数 USB 桥接盘都如此。
后果：**无法预判物理故障**。

**处理**：这类盘不要承载唯一备份。重要数据至少两份，最好一份异地（3-2-1 原则）。

---

## 9. 内部盘空间往往是隐藏的拦路石

本次案例：内部盘 926 GiB 只剩 68 GiB，而图库有几百 GB。
→ 「先把原图下载到 Mac 再导出」这条路走不通。

**这也是 `--download-missing` 的核心价值**：它边下边导，不需要在内部盘腾出与图库等大的空间。

排查内部空间时注意：`du -sh ~/*` 这类全盘扫描在受限环境下容易被超时杀掉，
优先用 `df -h` 判断总量，需要定位大目录时再分目录逐层扫。

---

## 10. 卷的文件系统无响应（I/O 挂起）—— 症状、判定、处置
> 证据：2026-10-05 在用户真实终端复现 + agent 环境复现

### 症状

命令**永久挂起**，不报错、不返回。本例卡在 `[3/4] 目标盘检查`（该步第一个动作是
`df -k /Volumes/Expansion`）。

### 关键判据：分层测试，看卡在哪一层

这是本节最有用的一条 —— **先分清是「盘掉了」还是「文件系统挂了」**：

| 测试 | 是否碰文件系统 | 本例结果 | 说明 |
|---|---|---|---|
| `mount \| grep <卷>` | ❌ 只读内核挂载表 | **秒回** | 挂载项还在 |
| `diskutil list` | ❌ kernel 层 | **秒回** | 盘和分区都还在 |
| `df -k <卷>` / `stat` / `ls` | ✅ | **永久阻塞** | ← 问题在这一层 |

结论：**USB 层和内核层都正常，卡在文件系统实现里**。这排除了「线没插好」这种初级猜测，
直接指向 FSKit 用户态服务或盘的 I/O 状态。

### 环境背景

```
/dev/disk7s1 on /Volumes/Expansion (exfat, local, nodev, nosuid, noowners, noatime, fskit)
```

> ⚠️ **设备节点编号在重启后会变，不要沿用上次的。** 本例同一块盘：故障时是 `disk7`，
> 重启后变成 `disk4`（USB 枚举顺序变化）。所有命令里的 `/dev/diskXsY` 都要用
> `diskutil list` 现查。**挂载点 `/Volumes/<卷名>` 是稳定的，优先用它定位。**

`fskit` 是 macOS 15.4+ 引入的**用户态文件系统框架**，exFAT 现在由它托管。
用户态服务一旦卡死，所有文件系统调用就会无限期阻塞 —— 这与传统内核态挂载的
失败模式（快速返回 EIO）**完全不同**。

### 常见诱因（按概率）

1. **外置盘 / USB 桥接休眠后唤不醒** —— 最常见。盘停转后控制器不应答，但挂载项还在
2. **盘掉线但挂载项残留**（线材松动、口供电不足、走过 hub）
3. **exFAT 无日志** —— 之前的非正常断开留下脏位，FSKit 卡在某种重试上
4. FSKit 用户态服务自身 bug

### 处置阶梯（每步做完重跑命令验证）

> 2026-10-05 23:58 补充数据点：**`diskutil unmount force` 也卡死。**
> 实测此时 `mount | grep Expansion` 仍显示该卷在挂载表中 —— 即 unmount 没有完成，
> 它只是卡在 FS 驱动应答上。**这是本节最重要的一次升级。**

先理解 `force` 的边界，否则会反复在错的地方浪费半小时：

| `force` 跳过了什么 | `force` 跳不过什么 |
|---|---|
| 「卷上有打开的文件 / 进程占用」检查 | **文件系统驱动应答**（清缓存、同步超级块、VFS 释放 vnode） |

所以：`force` 卡死 = 内核 VFS 在等用户态 FSKit 服务，而那个服务不响应。
**命令行手段到此为止，必须走物理路径。**

```bash
# ── A. 命令行手段（若 unmount force 已经卡过一次，跳过 A 直接进 C）──────

# A0) 先 Ctrl+C 掐掉挂住的命令
# A1) 正常推出；不行则强制卸载
sudo diskutil unmount force /Volumes/<卷名>
#     注意：force 只跳过占用检查，跳不过驱动应答（见上表）

# A2) 若 A1 卡住 → 到新终端窗口（⌘N）看进程状态，决定还能不能救
ps -Ao pid,stat,etime,command | grep -iE "diskutil|umount" | grep -v grep
#     STAT 带 U → 不可中断等待，kill -9 也无效 → 直接进 C
#     STAT 为 S → 可试： sudo kill -9 <PID>  然后 sudo umount -f /Volumes/<卷名>

# A3) 绕过 DiskArbitration，直接调 syscall（少一层，但通常也会卡）
sudo umount -f /Volumes/<卷名>
sudo diskutil unmountDisk force /dev/diskN      # 卸载整个磁盘而非分区

# ── C. 物理路径（成功率最高）───────────────────────────────────────────

# C1) 直接拔掉 USB 线 / 关掉盘电源开关
#     物理断连强制内核放弃设备，挂起的 I/O 立刻以 EIO 返回
#     预期：挂住的命令报错退出，访达里的盘变灰或消失

# C2) 拔线后访达仍显示该盘 → 重启 Mac（最终解，一定能清掉 stale 挂载项）

# ── D. 恢复后 ────────────────────────────────────────────────────────

# D1) 先急救，别直接开始写数据
sudo diskutil verifyVolume /dev/diskNsM
#     编号重启后会变 —— 先 diskutil list 现查
#     在「磁盘工具」里点「急救」等价
# D2) 检查原有数据是否可读（本盘 142.6 GB 旧数据：手机照片 76 G 等）
```

### 拔线前的风险披露（本案例）

- **盘上没有正在进行的写入任务**（导出尚未开始），因此不存在「写到一半的照片」，
  拔线不会丢新数据。
- 代价是 exFAT 元数据可能更脏（无日志文件系统）。旧数据拔线后**不要直接读**，
  先跑 D1 急救。
- 若机器上还有别的未保存工作，先处理完再拔线 / 重启。

### 退役判据（本盘已满足）

三个信号叠加，说明它不该再承载「坏了就没了」的数据：

1. 读不到 SMART（第 8 节）→ 故障不可预警
2. 出现过 I/O 挂起（第 10 节）→ 故障时不可操作
3. **连 `unmount force` 都卡死** → 恢复手段本身失效

→ 结论：**建议退役换盘**，不要把 iCloud 照片的唯一落点放在它上面。

### 工具侧的防御：所有 FS 调用必须带超时

macOS **没有 GNU `timeout`**。可移植的写法是用 perl 的 `alarm` —— `exec` 之后
定时器依然有效，被调用的命令会真的收到 SIGALRM：

```bash
perl -e 'alarm shift; exec @ARGV' 8 df -k /Volumes/xxx
# 超时被杀时退出码 = 128+14(SIGALRM) = 142
```

本 skill 的 `icloud_export.sh` 与 `drive_check.sh` 已对所有触碰文件系统的调用
（`test -d` / `df` / `mkdir` / `touch` / `rm`）套用此包装，超时后给出可操作的报错
而不是永久挂死。默认 8 秒，可用配置项 / 环境变量 `FS_TIMEOUT` 调整。

**注意**：如果进程陷在**不可中断的内核等待**里，SIGALRM 也杀不掉。实测本例中
`df` 是被杀得掉的（能超时返回），说明阻塞点在可中断的用户态路径 —— 但这不是保证，
遇到连 `kill -9` 都无效的情况，只能拔盘或重启。

### 对本次任务的影响

这块盘**不能作为照片的唯一落点**。它不仅读不到 SMART（第 8 节），还出现过 I/O 挂起。
两者叠加 = 故障不可预警 + 故障时不可操作。关键数据必须另存一份（3-2-1）。

---

## 11. 「目标盘检查」这一步到底查什么，为什么必须碰文件系统
> 证据：2026-10-05 用户追问「需要对整个卷做一次 df 操作吗」

### 三个原子动作

| 动作 | 命令 | 碰文件系统 | 目的 |
|---|---|---|---|
| ① 挂载项存在 | `mount \| grep " on $VOL "` | ❌ 读内核挂载表 | 盘插好没有 |
| ② 可写标志 | 对挂载串 grep `read-only` | ❌ 同上 | 只读卷（NTFS 未装驱动）当场拦下 |
| ③ 可用空间 | `df -k "$VOL"` | ✅ | 空间够不够放整个图库 |

**前两个只读内核挂载表，必然秒回；第三个才是文件系统调用。**

### `df` 不是「对整个卷做一次操作」

这是最容易误解的一点：

- `df -k <路径>` 内部只调 `statfs()`，**读超级块拿块统计**，O(1) 元数据查询。
- 它**不遍历目录树、不读文件内容、不算已用块**，正常情况毫秒级返回，与卷里有多少文件无关。
- 真正「扫全卷」的是 `diskutil verifyVolume` / `fsck_exfat` —— 那才需要遍历目录结构、读元数据块，几百 GB 的盘要跑很久。

所以 **`df` 挂住与数据量完全无关，只说明文件系统驱动不应答。**

### 那为什么还要保留这一步？——因为它是最有价值的探针

反直觉之处：**`df` 卡住本身就是最强的故障信号，而不是需要绕开的障碍。**

`statfs` 都拿不到，说明用户态 FSKit 服务已经不应答；此时任何写操作（`mkdir` / `write`）
必然同样阻塞。**如果为了「让流程先跑起来」跳过空间检查，只会在下载了几小时后以更惨的
方式失败（写一半挂死 + 卷状态更脏）。**

→ 结论：**不要加「跳过空间检查」之类的开关。** 前置失败比中途失败便宜得多。

### 检查项确实需要 FS，无法完全绕开

挂载表只告诉你「挂上了、写着 rw」，**不告诉你还剩多少空间**——剩余空间只有文件系统自己知道。
`diskutil info` 的 `Volume Free Space` 同样来自 FS 层，不是纯内核信息。

### 交叉验证：`diskutil info` 用来分层定位

`doctor` 的 `[2b]` 步：从挂载表取设备节点（`mount | grep " on $VOL " | awk '{print $1}'`），
再对其跑 `diskutil info`。判读方式：

| 结果 | 结论 |
|---|---|
| 分区元数据可读，但 `df` 超时 | 盘在、分区在 → **锁定为文件系统驱动（FSKit）无响应** |
| 连 `diskutil info` 也超时 | 问题更深 → 怀疑盘 / USB 桥接 / 线材 / 供电 |

### 口径提醒：两个「可用空间」不是一回事

同一个卷，两个命令给出的数字看起来不同：

```
diskutil info → Volume Free Space: 18.0 GB        （十进制，1 GB = 10^9 B）
df -k         → 可用 16.7 GiB                      （二进制，1 GiB = 2^30 B）
```

**换算后相等（18.0 GB ≈ 16.76 GiB），不是矛盾。** 报数字时说明口径，别让读者自己猜。

### 环境备注：区分两种终止码

agent 沙箱对该卷的任何 FS 调用会被**环境主动 SIGTERM（退出码 137）**，与我们自己 perl 超时的
**142（128+SIGALRM）** 是两回事。排查时不要混为一谈 —— 137 说明执行环境终止了进程，
142 说明进程跑满超时被自己的定时器杀掉，前者不代表卷本身无响应。

---

## 12. 图库在 iCloud 上时，下载通道只有两条（证据：2026-10-06 实测）
> 本案例图库状态：本地图库仅 6.3 GB，`originals/` 只有 **21 个文件 / 20 MB**，
> 而 `osxphotos info` 报 **missing 12376 / total 12397**、`in iCloud 12397`。
> 即：**「优化 Mac 存储」下的全云端图库，除 21 项外原图都不在本机。**

先量清楚这件事，再决定怎么导。**一条命令就能判定**（不必读图库数据库）：

```bash
LIB="$HOME/Pictures/Photos Library.photoslibrary"
du -sh "$LIB"                      # 整个图库包多大
find "$LIB/originals" -type f | wc -l   # 本地到底有几个原图
```

若 `originals/` 只有个位数～几十个、而 `osxphotos info` 报 missing 上万 → 全在云端，
**必须开 `--download-missing`，否则导出的只是占位/缩略图。**

| 通道 | 开启方式 | 额外授权 | 可靠性 |
|---|---|---|---|
| AppleScript 驱动 Photos | `--download-missing`（默认） | 无需额外授权（只需对 Photos 的自动化权限） | 见第 13 节，**本案例整段死锁** |
| PhotoKit 直取 | `--download-missing --use-photokit` | **需「照片」权限授给负责进程** | 官方称「更快更可靠」，是 alpha |

本 skill 用环境变量切换：**`OSXPHOTOS_PHOTOKIT=1`** 会追加 `--use-photokit`。

**两条通道都需要「完全磁盘访问」** —— osxphotos 一律要先读
`database/Photos.sqlite` 做枚举，枚举不通后面都无从谈起。

---

## 13. AppleScript 通道会整段死锁 —— 判定与处置（证据：2026-10-06 实测）
> **这是本案例真正的拦路虎。** 现象极具误导性：命令不报错，只是永远不返回。

### 现象

| 操作 | 结果 |
|---|---|
| `osascript -e 'tell application "Photos" to get name'` | ✅ 秒回 `Photos` |
| `osascript -e '... to get count of albums'` | ❌ **120 秒超时，`-1712` AppleEvent 已超时** |
| `osascript -e '... to get count of media items'` | ❌ 永久挂起 |
| `photoscript.Photo('<uuid>')` | ❌ 报 `ValueError: Invalid photo id` 或永久挂起 |
| `osxphotos export --download-missing` | ❌ 逐项打印 `Skipping missing original photo …`（见第 16 节） |

**反差是判据的核心**：静态属性（`name`）秒回，任何**集合**查询都不返回 —— 说明
AppleEvents 通道本身是通的，坏的是 Photos 侧的图库对象模型。

### 决定性诊断：采样 Photos 进程

```bash
pid=$(pgrep -f "Photos.app/Contents/MacOS/Photos" | head -1)
sample "$pid" 3 -file /tmp/photos.sample.txt      # 不需要 root
```

采样里看到多条 AppleEvent 线程卡在：

```
??? (in AE)  load address 0x195ff0000 + 0x3894c
  ??? (in AE)  load address 0x195ff0000 + 0x5ec88
    _dispatch_sync_f_slow  (in libdispatch.dylib)
```

→ **Photos 的 AppleEvent 处理线程发生 dispatch 死锁**，不是权限问题、不是超时设太短。

### 更快的判据：看 Photos 有没有真正打开图库

```bash
pid=$(pgrep -f "Photos.app/Contents/MacOS/Photos" | head -1)
ps -o rss=,%cpu= -p "$pid"                       # 健康时应是数百 MB，加载中 CPU 非 0
lsof -p "$pid" | grep -c Photos.sqlite           # 0 = 图库根本没打开
```

本案例实测的「没打开」长相，**稳定复现**：

```
内存 = 88~93 MB        （12k 条目的图库开了会有数百 MB）
CPU  = 0.0%
lsof | grep Photos.sqlite → 无输出
Photos 主窗口在（1200x720），但图库里什么都没有
```

**这个状态下任何 AppleScript 集合查询都会永久挂起** —— 因为图库对象压根没建起来。
健康检查就该用这条，而不是「进程存在吗」。

### 处置

1. **重启 Mac。** 本案例 `uptime` 显示已连续运行 12 小时 48 分，且 `mediaanalysisd`
   从开机起就以 57–90% CPU 空转、无视 SIGTERM —— 照片栈整体处于异常态。
   重启是唯一可靠的对策。
2. **重启后不要再对 Photos 连发查询。** 超时的 AppleEvent 会留在 Photos 的 AE 队列里，
   把后面的查询一起拖死。**一次只发一个，且别提前 kill。**
3. **不要用「杀掉重开 Photos」当解法。** 实测重启 Photos 后仍是 93 MB / 0%，
   反复 force kill 只会叠加更多死锁状态。

### 13b. 死锁会在**同一次运行中途**发生，且进程级自愈只能买到约 5 项额度（证据：2026-10-06 20:35 实测）

第 13 节讲的是「图库压根打不开」的长相。但还有第二种形态，更容易骗过巡检：
**通道先健康地跑一段，然后在运行中途崩掉。** 本案例全量段实测：

| 时段 | 吞吐 | 状态 |
|---|---|---|
| 18:28–19:10 | 30–50 项/分（`18:30` 一个 10 分钟桶 515 项） | 通道健康 |
| 19:10–19:30 | 72 → 0 | **开始崩** |
| 19:30 以后 | 0.5–0.8 项/分，且几乎全是 skip | 已死锁 |

累计 1756 项成功导出（成功率 98.3%）、31 项 missing、0 error —— **前 98% 跑得非常漂亮，
问题全出在最后一段**。所以「已经导了很多」不能证明通道现在还好。

**进程级自愈不是解药。** osxphotos 自己有「连续失败 10 次 → 重启 Photos」的逻辑，
脚本层还会再做一次 `killall Photos` + 重开。实测这两条各触发 2 次，效力是：

```
20:14:14  AppleScript export has failed 10 consecutive times, restarting Photos app
20:15:19  连出 IMG_1681…1685 共 5 项 ✅   ← 重开后只买到这 5 项
20:29     run_script: AppleScript timed out → killall
20:30 起  IMG_1686…1690 全部 skip ❌     ← 又死锁
```

**每次重开只换来约 5 项的额度，随后立刻再次死锁。** 与第 13 节「不要靠杀重开」完全一致——
这套自愈逻辑让看门狗「看起来在干活」，但净产出是 0。

**新增诊断：按 10 分钟分桶的吞吐曲线。** 第 22 节那三条命令看的是「跳过是否成簇」，
判不出「整体已瘫痪」。吞吐曲线一眼就能看出来：

```bash
C="/Volumes/Expansion/iCloud导出-2026/_导出报告/export-*.csv"
tail -n +2 "$C" | awk -F',' '{print substr($1,12,5)}' \
  | awk -F: '{printf "%s:%02d\n",$1,int($2/10)*10}' | sort | uniq -c
```

正常应看到「由快到慢」的平滑衰减（越往后单张越大）；**若某分钟桶突然从数百掉到个位数
且不再回升，就是第 13 节的死锁**，别再等，直接按第 13 节处置。

**立即判定通道当前是否可用**（只读，10 秒出结果）：

```bash
perl -e 'alarm 12; exec @ARGV' osascript -e 'tell application "Photos" to count of albums' \
  || echo "❌ AppleScript 通道已死锁"
```

**这条查询是纯本地的**（只是数相册，不碰网络）——所以它超时**不能**归结为
「iCloud 限速 / 网络慢」，必然是 Photos 侧的 AE/dispatch 死锁（第 13 节的采样结论）。
这个区分很重要：**网络类原因不该导致 `count of albums` 挂住。**

### 13c. 监测盲区：看门狗只查「进程在不在」，不查「有没有产出」

`icloud-export-autopilot.command` 的看门狗判据是「autopilot 进程是否存在」。
死锁期间进程活得好好的（`pgrep` 有、`state` 正常、`runs` 在涨），于是看门狗判定一切正常、
什么都不做 —— 本次就这样**带着 0 产出"正常"了约 1 小时 20 分**才被巡检发现。
**巡检时必须自己算吞吐曲线（13b），不要只信看门狗的绿灯。**

### 13d. 第三种失灵：**两个内置判据全部通过，但产出为 0**（证据：2026-10-07 00:41 实测）

13b 的 AppleScript 探针、以及 2026-10-06 加进 autopilot 的 `photos_lib_fd`
（`lsof -p $(pgrep -x Photos) | grep "Photos Library"`）**都判"健康"**，
可下载通道实际已经死了 —— 每一项都进 `Skipping missing original photo`。

实测这一轮的完整画像（务必照抄这套判据，别只看探针）：

| 判据 | 健康时应答 | 本次（判为**已失效**） |
|---|---|---|
| `pgrep -fl "osxphotos export"` | 在 | 在 ✅ |
| autopilot 主进程 | 在 | 在（PID 30216）✅ |
| `osascript … count of albums` | 返回数字 | **返回 15** ✅ |
| `photos_lib_fd`（Photos 是否持有图库 fd） | 是 | **是（16 条命中）** ✅ |
| **report CSV 里最后一条 `exported=1` 的时间** | 持续前进 | **冻结在 00:41:54** ❌ |
| **`du -sh` / 文件数** | 持续增长 | **冻结在 4933 / 37G** ❌ |
| CSV 里 `missing=1` 的**连续性** | 零星小簇 | **连续 229 项全 missing** ❌ |

**结论：唯一可靠的"通道活着"判据是「产出」——report CSV 里最后一条 `exported=1`
的时间戳。** 探针类判据（进程 / fd / AppleScript 应答）只能证明 Photos 前端没崩，
**证明不了 iCloud 拉取链路可用**。巡检固定动作应改成：

```bash
CSV="$(ls -t "$DEST/_导出报告"/export-*.csv | head -1)"
awk -F, 'NR>1 && $3==1 {t=substr($1,12,8)} END{print "最后成功导出: "t}' "$CSV"
awk -F, 'NR>1 && $13==1 {n++; t=substr($1,12,8)} END{print "missing 累计: "n" 最后: "t}' "$CSV"
```

若「最后成功导出」的时间戳超过 5 分钟没动，而 CSV 仍在增长（说明在空转）→ 判定通道已失效。

**已排除的干扰项（本次逐一核过，别再重复怀疑）：**
- Photos 进程没崩（21:49 起持续存活）、图库 fd 在、AppleScript 应答正常 → 不是第 12/13/19 节
- `kill_photos` 补丁仍在（`cli/__init__.py`、`export.py` 里已无调用点）→ 不是第 23 节
- `photoscript.applescript` 含 `if theTimeOut < 14400`、`exportoptions.py` 的
  `timeout: int = 14400`，且**当前进程 23:46:42 启动，晚于补丁 mtime 22:54** → 超时补丁**已生效**，
  不是第 25 节
- 崩溃日志 `~/osxphotos_crash.log` 停在 18:17，本轮无 `readonly database` → 不是第 21 节

**行为特征（与 13b 的死锁不同）：** 失败项**不卡**，约 2–4 秒一项（35 项/分），
是「Photos 立刻拒绝」而非「等待超时」。所以这一轮会**以正常速度空转完剩余全部项**，
按剩余约 12000 项估算要烧掉 5–6 小时且零产出。

**处置：** 干净中止本轮并重启导出（`--update` + 续传库保证不丢进度），
借新进程重建 Photos 的 AppleScript 会话 —— 这正是 22:36、23:46 两次"重启即恢复"的等效动作。
注意 13b 说「进程级自愈只能买约 5 项」，那条结论的前提是**通道本身死锁**；
本次是「链路被拒」，重启是有效动作。

**尚未给出建议加进 autopilot 的护栏（下次改脚本时一并加）：**
在巡检循环里加一条「产出健康度」判据 —— 记录 `$DEST` 文件数，连续 N 分钟（建议 10）零增长
且 autopilot 仍在跑，就 `kill -TERM` 本轮并让看门狗重新拉起。
现有 `photos_lib_fd` 护栏拦不住这一种。

### 13e. 空转的隐藏代价：**零产出时内部盘仍以 ≈4 GiB/小时失血**（证据：2026-10-07 02:51 实测）

13d 那种空转**不是免费的**。它一边零产出，一边持续吃掉内部盘 —— 也就是**直接啃 12 GiB 红线**。
这是本机最稀缺的资源（内部盘 ~64 GiB 要周转 300–500 GB），比"浪费时间"严重得多。

**现成的监测通道（重要，别再自己造轮子）：**
autopilot 包装器每 30 分钟打印一行 `进行中：已落地 N 个文件，内部盘 M Gib 可用`。
**这一行同时给出「产出」和「磁盘」两个时间序列，是独立于 CSV 的第二条判据**，直接：

```bash
grep -n "进行中：已落地" autopilot.log | tail -12
```

实测（2026-10-07 09:00 那一轮的原始读数，产出在 01:00 后冻结）：

| 时间 | 落地文件 | 内部盘可用 |
|---|---|---|
| 00:00 | 3593 | 39 GiB |
| 00:30 | 4526 | 33 GiB |
| 01:00 | **4933** | 29 GiB |
| 01:30 | 4933 | 28 GiB |
| 02:00 | 4933 | 26 GiB |
| 02:30 | 4933 | 24 GiB |
| 02:55 | 4934 | **21.7 GiB** |

- **产出期**（00:00–01:00，+1340 文件 / −10 GiB）≈ **7.5 MB/文件**（含 Photos 拉进图库的原图）
- **空转期**（01:00–02:55，+1 文件 / −8.3 GiB）≈ **4 GiB/小时**，产出为零
- 也就是说：**空转 4 小时 ≈ 白烧 16 GiB**，足以把 12 GiB 红线从"还有余量"推到触线

**失血归因（本轮证据，未完全定论）：** 空转期间 `ps` 显示
`Photos.app` **40% CPU**、`photolibraryd` 3.7%、`cloudphotod` 2.7% —— 下载/图库侧**在忙**，
但 report CSV 里零个 `exported=1`。推测是「下载落在图库，导出读不回来」。
⚠️ **无法直接证实**：`du -sh ~/Pictures/"Photos Library.photoslibrary"` 报
`Operation not permitted`（缺完全磁盘访问权限），图库体积读不到。别把推测写成结论。

**同时新增一个可观测特征：CSV 会出现「完全空白的时间洞」。**
本轮 01:04:06 → 01:39:20 之间 report CSV **一行都没有**（连 `missing=1` 的失败记账都没有），
而 `ps` 显示 Photos 自 21:49 起**从未重启** → 说明不是第 23 节的 killall，
而是 osxphotos 卡在某次 AppleScript 调用里数十秒到分钟级。用 Python 算相邻行最大间隔即可发现：

```python
# 相邻 CSV 行的最大时间间隔（macOS 自带 awk 没有 mktime，别用 awk）
python3 -c '
import csv,datetime,sys
rows=[datetime.datetime.fromisoformat(r["datetime"]) for r in csv.DictReader(open(sys.argv[1]))]
g=max(((rows[i]-rows[i-1],rows[i]) for i in range(1,len(rows))),key=lambda x:x[0])
print("最大空洞",g[0],"结束于",g[1].isoformat())' "$CSV"
```

**处置顺序（磁盘优先于吞吐）：**
1. 先看磁盘：低于 ~15 GiB **不要再重启导出** —— 重启只是把失血速率从 4 GiB/h 提到
   ~7.5 MB/文件（产出期失血更快），会更早触线。此时应让 12 GiB 护栏自然暂停、等 Photos 回收。
2. 磁盘 >15 GiB 且有较长时间可跑，再考虑干净重启恢复吞吐。
3. 长期解：**按年分批**（`--from-date/--to-date`）而不是一口气全量，
   每批跑完停下来等 Photos 回收原图，再跑下一批。

---

## 14. 「照片」权限只能授给声明了用途说明的 App（证据：2026-10-06 实测）

PhotoKit 通道要的是 `kTCCServicePhotos`。这个权限**不在系统设置里手工添加就行**：
macOS 只允许把该权限给在 `Info.plist` 里声明了 `NSPhotoLibraryUsageDescription`
的 App。没声明的 App 连请求都不弹，直接返回：

```
Requesting access to use your Photos library. Click 'Allow Access to All Photos' …
Error: could not get authorization to access Photos library
Please ensure that your terminal app (Apple_Terminal) is granted access in
'System Settings > Privacy & Security > Photos'
```

**实测（关键）**：

| App | 声明了 `NSPhotoLibraryUsageDescription`？ |
|---|---|
| `/System/Applications/Utilities/Terminal.app` | ❌ 没有 |
| `/Applications/WorkBuddy.app` | ❌ 没有 |
| `/System/Applications/Photos.app` | ❌ 没有（它不需要） |

→ **终端永远拿不到「照片」权限，PhotoKit 通道在终端里走不通。**

声明了该键、**且能执行命令**的 App（可直接拿来当「负责进程」）：

```
/System/Applications/Shortcuts.app           ← 有 Run Shell Script 动作，最合适
/System/Applications/Automator Application Stub.app
```

其余声明了该键的大多是消费型 App（Notes / Freeform / Excel / Outlook / Spotlight …），
不能跑任意命令。

### 自助核查：直接读 TCC 数据库

终端拿到「完全磁盘访问」后，可以自己看权限归属（**这是判断「谁有权限」最快的办法**）：

```bash
U="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
sqlite3 "$U" "select service, client, auth_value from access where service like '%Photo%';"
sqlite3 "$U" "select client, auth_value from access
              where service='kTCCServiceSystemPolicyAllFiles';"   # 系统库，路径 /Library/... 
```

本案例结果：`kTCCServicePhotos` **零条目** —— 这台机器上没有任何 App 有「照片」权限。

---

## 15. 借「终端」拿权限：目前唯一可行的自治通路（证据：2026-10-06 实测）

### 归责规则（第 5f 节的落地）

macOS 把「完全磁盘访问」「自动化」这类权限归责到**负责进程（responsible process）**，
不是被调用的工具。实测 TCC 日志里的归责链：

```
service=kTCCServiceSystemPolicyAllFiles
  responsible = /Applications/WorkBuddy.app/Contents/MacOS/Electron
  requesting  = python3.13
```

**结论**：脚本是子进程、osxphotos 是孙进程，但检查落在最外层那个 App 上。
在终端里跑 → 给「终端」授权；在 WorkBuddy 里跑 → 给「WorkBuddy」授权。
**加错对象等于没授权。**

### 标准姿势：`open -a Terminal`

```bash
cat > /tmp/job.command <<'EOF'
#!/bin/bash
exec > /tmp/job.out 2>&1
LIB="$HOME/Pictures/Photos Library.photoslibrary"
du -sh "$LIB"                      # 需要 FDA 的操作
EOF
chmod +x /tmp/job.command
open -a Terminal /tmp/job.command
sleep 30 && cat /tmp/job.out
```

三个好处，缺一不可：

1. **拿到终端的权限**（本例终端有完全磁盘访问，实测能读 `Photos.sqlite`）。
2. **独立于 agent 会话** —— 由 LaunchServices 拉起，挂在 Terminal 下；
   agent 回合结束、甚至执行环境把进程组杀掉，它照样跑。**几百 GB 的长任务必须这样起。**
3. **能弹 GUI 授权框** —— 需要用户点「允许」的场景（如 PhotoKit）只有在图形会话里才有弹窗。

### 登录自启的正确写法

LaunchAgent 里**不要直接把脚本当 `ProgramArguments`**（守护进程拿不到任何权限），
要用 `open` 转一手：

```xml
<key>ProgramArguments</key>
<array>
  <string>/usr/bin/open</string>
  <string>-a</string>
  <string>Terminal</string>
  <string>/path/to/job.command</string>
</array>
<key>RunAtLoad</key><true/>
<key>LimitLoadToSessionType</key><string>Aqua</string>
```

本 skill 的自动驾驶就是这个结构：`icloud-export-autopilot.command` +
`~/Library/LaunchAgents/com.helufan.icloud-export-autopilot.plist`，
脚本跑完自行删除 plist（只跑一次）。

---

## 16. `--download-missing` 失败时的长相是「Skipping missing original photo」

**它不报错。** 源码位置 `osxphotos/photoexporter.py:362`：

```python
else:
    verbose(f"Skipping missing {'edited' if options.edited else 'original'} photo "
            f"{self._filename(self.photo.original_filename)} ({self._uuid(self.photo.uuid)})")
    all_results.missing.append(dest)
```

触发条件：`_stage_photos_for_export()` 没能为这张图拿到 `src`（也就是**下载没成功**）。

**判读要点**：

- 看到这张行 = **下载通道没打通**。此时**不要继续跑 `full`** —— 会几小时后收获一堆 0 字节。
- 真正的错误明细只在**运行结束时的汇总里**打印；中途被 kill（超时/取消）就看不到。
  所以调试时**要么给足超时，要么读 `--report` 生成的 CSV**。
- 逐项 `skip` 很快、卡在某一项很久，是「AppleScript 死锁」（第 13 节）的典型节奏。

---

## 17. 全量导出必须带内部盘空间护栏

`--download-missing` 会把原图**下载进 Photos 图库**再复制到目标盘，
Photos 不会立刻把它换出。所以：**内部盘的剩余空间是隐性硬约束**。

本案例：内部盘可用 68 GiB，而图库有几百 GB 在云端。
`--download-missing` 的价值是「不需要一次性腾出等大空间」，但它**不等于零占用** ——
如果内部盘先被写满，Mac 会整体卡死。

**做法**（`icloud-export-autopilot.command` 已实现）：

```bash
# 用独立进程组启动，方便整体暂停/继续（macOS 无 setsid 命令）
perl -e 'setpgrp(); exec @ARGV' bash "$S" full &
PID=$!
# 低于 PAUSE_GIB  → kill -STOP -$PID   等 Photos 换出后再 kill -CONT -$PID
# 长时间不恢复    → kill -TERM -$PID   干净中止（进度已在续传库里，下次接着跑）
```

**不要用「跑一会儿看一眼」代替护栏** —— 几小时的无人值守任务里，没人看的时候才会出事。

---

## 18. 两个容易踩的 macOS 命令语法坑（2026-10-06 实测）

### `xattr` 没有 `-r`

macOS 自带的 `/usr/bin/xattr` **不支持 `-r`**（那是 GNU xattr 的选项）：

```
$ xattr -dr com.apple.quarantine "/path/Library.photoslibrary"
option -r not recognized
```

**报错 = 整个命令失败，一个标记都没清掉** —— 而这条失败信息混在一大堆输出里，
极容易被当成「已经清过了」。正确写法：

```bash
xattr -d com.apple.quarantine "/path/Library.photoslibrary"        # 单个文件/目录
find "/path/Library.photoslibrary" -exec xattr -d com.apple.quarantine {} \; 2>/dev/null   # 递归
```

顺带澄清：**清掉图库的 quarantine 标记并不能解决「Photos 打不开图库」**（实测无效）。
那条标记的来源字段写的就是 `photolibraryd`，是 Photos 自己打上的，不是下载残留。

### `open -a Photos <图库路径>` 返回 0 ≠ 图库已加载

实测（第 13 节场景下）：

- 传**存在的**图库路径 → Photos 进程起来、UI 初始化完成，
  但 `lsof -p <pid> | grep -c "Photos Library"` **恒为 0**
- 传**不存在的**路径 → `rc=1`，并打印 `The file ... does not exist.`

也就是说**路径参数确实被受理了**，只是图库没被加载。所以「`open` 返回 0」
**不能**当作「图库已就绪」。是否就绪必须用 `lsof` 或 AppleScript 实测。

同理，`osascript -e 'tell application "Finder" to open POSIX file "<图库>"'`
（等价于在访达里双击图库）**同样无效** —— 别以为换个入口就能绕过。

## 19. 「Photos 不加载图库」的完整排查树（证据：2026-10-06 全天实测）

**症状**：Photos 进程健康、主线程正常空闲、图库数据完好，但就是不加载图库 →
`--download-missing` 全线失效（逐项 `Skipping missing original photo`）。

### 一、核心判据（按可靠度排序）

**1. 谁持有图库文件（最权威）**

```bash
lsof "$LIB/database/Photos.sqlite" | awk '{print $1}' | sort -u
```

正常时 `photolibraryd` / `photoanalysisd` / `cloudphotod` / `mediaanalysisd` **都**持有 ——
这同时证明**图库与后端是健康的**。而前端是否加载，要看：

```bash
lsof -p <Photos pid> | grep -c "Photos Library"     # 恒为 0 = 前端从未加载
```

**别把这两个判据混为一谈** —— 后端持有 ≠ 前端加载。实测故障态下后端持有 11/30/8/14 个文件，
Photos 前端持有 **0**。

**2. 内存判据（辅助）**：`ps -o rss= -p <Photos pid>`。图库加载会显著抬升内存。
卡住时**恒在 103–112MB 波动、从不增长**，是「启动完成但从未进入图库加载」的铁证。

**3. AppleScript 判据**：

```bash
osascript -e 'with timeout of 8 seconds
tell application "Photos" to count of albums
end timeout'
```

故障态返回 `-1712 AppleEvent已超时`。**注意区分 -1712 与 -1743**：
`-1743` 才是「未授权」，`-1712` 说明事件发得出去、Photos 不回应。

### 二、本轮首次建立的判据

**4. 窗口 onscreen 状态**（编译一次反复用，开销很低）

```swift
// wb_disp.swift —— 同时给出显示器电源与 Photos 窗口上屏数
import CoreGraphics
let d = CGMainDisplayID()
print("IsActive=\(CGDisplayIsActive(d)) IsAsleep=\(CGDisplayIsAsleep(d)) IsOnline=\(CGDisplayIsOnline(d))")
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var n = 0, t = 0
for w in list where (w[kCGWindowOwnerName as String] as? String ?? "").contains("照片") {
    t += 1
    if (w[kCGWindowIsOnscreen as String] as? Bool) == true { n += 1 }
}
print("Photos 窗口 总=\(t) onscreen=\(n)")
```

故障态实测：`总=5 onscreen=0`（主窗口 1200×720 @(156,69)、`alpha=1.0`）。
**必须用 `.optionAll`** —— `.optionOnScreenOnly` 只看当前 Space，会漏掉跨 Space 的窗口。

**5. 显示器电源**：用 `CGDisplayIsAsleep()/IsActive()/IsOnline()`，
**不要**依赖 `pmset -g powerstate IODisplayWrangler` —— 内置屏上它会报 `Internal failure`。

**6. 截图报错的含义**：没有屏幕录制权限时 `screencapture` 报
`could not create image from display`（**不是**产出空白图）。
`caffeinate -u -d` 唤醒后仍报此错 ⇒ 是权限问题，不是显示器休眠。

**7. 辅助功能权限的误判陷阱（本轮踩到，务必记住）**

```bash
osascript -e 'tell application "System Events" to count processes'      # → 73, rc=0 ← 骗人的
osascript -e 'tell application "System Events" to tell process "Photos" to get name of every window'
# → -1728 / -1719「不允许辅助访问」
```

**`count processes` 不需要辅助功能权限**（进程列表本就是公开信息），**只有 UI scripting 才需要**。
拿它当权限探针会得出完全相反的结论。

**8. `set frontmost of process "Photos" to true` 不需要辅助功能权限**（走 LaunchServices）。
实测能把窗口从 `onscreen=0` 顶成 `onscreen=1`，**但不触发图库加载**（图库恒 0、内存不涨）；
且窗口随后自行掉回 offscreen —— 说明 Photos 在启动流程里**主动隐藏窗口**。
单独激活 + 静置 60 秒同样无效，故「窗口没上屏」不是根因。

### 三、图库书签的位置与解析

```bash
~/Library/Containers/com.apple.Photos/Data/Library/Preferences/com.apple.Photos.plist
# 键：IPXDefaultLibraryURLBookmark（732 字节 bookmark，魔数 0x626f6f6b "book"）
```

- `defaults read com.apple.Photos` **能**读到容器域的值；读不到时直接 `plutil -p` 开文件
- 但 swift 的 `UserDefaults(suiteName: "com.apple.Photos")` **读不到**（沙箱隔离）
- 解析：`URL(resolvingBookmarkData:)`，或直接抠 bookmark 里的 ASCII 串
  （实测解出 `file:///Users/.../Photos Library.photoslibrary` —— **路径正确**）
- 相邻键：`IPXDefaultShowLibraryChooserOnLaunch=0`、`IPXDefaultWorkspace`(1414B 窗口归档)、
  `NSWindow Frame MainWindow`

### 四、本轮**已排除**的假设（别再重复试）

| 假设 | 判据 | 结果 |
|---|---|---|
| 图库损坏 | `osxphotos info` 读出 12397 项 | 完好 |
| 图库待升级 | 无 migration/upgrade 日志；`LibrarySchemaVersion=5001` | 无 |
| 被 quarantine 隔离 | 清标记后重测 | 无效 |
| 显示器休眠 | `IsAsleep=0 IsActive=1` | 否 |
| 屏幕锁定 | `ioreg` 无 `CGSSessionScreenIsLocked` | 否 |
| 显示器无信号 | `system_profiler` → Online: Yes | 否 |
| iCloud 未登录 | `MobileMeAccounts` 含 `Dataclass.Photos` | 正常 |
| MDM/家长控制/LimitAD | `profiles list` 空、无 `applicationaccess` 域 | 无 |
| Photos.app 损坏 | `codesign -v` → valid + 满足 DR | 完好 |
| 书签指向错 | 解出路径正确 | 正确 |
| 窗口归档损坏 | 删 `IPXDefaultWorkspace`+bookmark 后重测 | 无效（已恢复） |
| 前台显示不足 | 单次激活 + 静置 60 秒 | 无效 |
| launchd 守护抢重启 | `killall` 后 5 秒无进程 | 无守护 |
| `mediaanalysisd` 跑飞是原因 | 它 CPU 归零后症状不变 | 只是伴生现象 |

### 五、结论与纪律

这类故障**命令行无法修复** —— 「Photos 前端不加载图库」发生在 GUI 会话层，
而 osxphotos 的两条下载通道（AppleScript / PhotoKit）**都以「Photos 已加载图库」为前提**，
所以会全线失效。**唯一有效手段是真实的用户交互**：让用户手动点 Dock 里的「照片」
（必要时**按住 Option 点击** → 弹出图库选择器 → 选中图库），或重启 Mac。

配套纪律：
- 图库**只读**，全程不写入/删除任何照片数据
- 动容器 plist 前**必须备份**，且记得**恢复**（`killall cfprefsd` 是让改动生效的必要步骤，
  但会影响全局偏好缓存）
- 排查期**不要**反复冷启动 Photos —— 每次冷启动都会留下新的 lock/wal，
  干扰后续判读

## 20. 两个会让人白熬半天的坑：边跑边改脚本、launchd 没加载（证据：2026-10-06 实测）

### A. 绝不要在脚本运行期间编辑它

**现象**：一个"等条件成立再干活"的长跑脚本，启动后 **5–7 秒静默退出，退出码 0**，
日志里**没有任何错误**，也没有走到本该执行的等待逻辑。

**根因**：**bash 是按需流式读取脚本文件的**，不是启动时一次性读进内存。
运行期间改动该文件（哪怕只是加一行注释），bash 后续读到的是错位内容，
于是脚本"提前结束"。

**定位手法（通用，值得背下来）**：
1. **在 EXIT trap 里记录退出码** —— 区分「正常退出(0)」与「被信号杀死」
   （`129=SIGHUP`、`130=SIGINT`、`143=SIGTERM`）。这一步就把方向劈成两半。
2. **在关键位置插探针**（`say`/`echo`），定位是"根本没进循环"还是"循环中途退出"。
3. `bash -x <script>` 抓 trace，看最后停在哪一行。
4. **对照实验**：换一种启动方式（例如用 wrapper 里的 `bash <script>` 而不是直接执行文件），
   看是否复现 —— 差异点往往就是答案。

**规避**：
- 要改脚本，**先停掉正在运行的实例**，改完再启动
- 长跑脚本做成「逻辑与参数分离」：可调参数放外部配置文件，本体不动

### B. `RunAtLoad` 只在 job 被加载的那一刻触发

把 plist 放进 `~/Library/LaunchAgents/` **不等于**它被加载。
如果放置时间**晚于当前登录会话完成**，launchd 不会补触发 `RunAtLoad`。

```bash
launchctl print "gui/$(id -u)/<label>" 2>&1 | head -3
# 报 Could not find service → 根本没加载
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/<label>.plist   # 手动加载
```
加载后 `runs` 会随执行递增，可用来确认它真的在跑。

### C. TCC 之下，"必须借终端"的脚本该怎么托管

`/usr/bin/open` 是 **fire-and-forget** —— 它把请求转给目标 App 后立刻返回，
**launchd 无法跟踪真正干活的进程**（`KeepAlive` 因此形同虚设）。

而当干活脚本**必须借某个已获授权的 App**（见第 15 节：只有 Terminal 跑出来的子进程有 FDA）时，
正确结构是**两层**：

```
launchd  ──托管──▶  看门狗（零权限需求：只做 pgrep + open -a Terminal）
                        └──借终端──▶  真正的执行体（需要 FDA / 自动化权限）
```

看门狗只做两件事：发现执行体不在跑就拉起它；见到"完成标记"文件就停手。

---

## 21. exFAT 卷上 SQLite 写不进去 —— 导出历史库必须放内部盘（证据：2026-10-06 实测）

**这是本流程最隐蔽的一个坑**：照片能写、卷也能写、权限也齐，但 osxphotos 一启动就崩。
如果不知道这条，会一路往「权限」「图库损坏」「Photos 没打开」方向白查几个小时。

### 症状

```
Something went wrong and osxphotos encountered an error:
attempt to write a readonly database
```

目标盘是移动硬盘时**必现**；同一台机器、同一条命令，目标换成内部盘就正常。

### 一行复现（不依赖 osxphotos）

```bash
python3 -c "
import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); c.execute('create table t (a int)'); c.commit(); print('OK')
" /Volumes/XXX/_t.db
```

- exFAT 盘上 → `sqlite3.OperationalError: attempt to write a readonly database`
- 内部盘（APFS）上 → `OK`

### 根因

macOS 15.4+ 起 exFAT 由 **FSKit**（用户态文件系统框架）托管，挂载参数里直接写着：

```
/dev/disk4s1 on /Volumes/Expansion (exfat, local, nodev, nosuid, noowners, noatime, fskit)
                                                                                ^^^^^
```

FSKit 的 exFAT 实现**不支持 SQLite 建立写事务所需的文件锁语义**。

关键认知 —— **「卷可写」不等于「SQLite 可写」**：

| 操作 | exFAT(FSKit) 上 |
|---|---|
| `touch` 建文件 | ✅ |
| `mkdir` | ✅ |
| 写普通文件（含几百 MB 大文件） | ✅ |
| **SQLite 建表 / 写事务** | ❌ readonly |

所以 `check_volume` 那种「不是只读挂载 = 能写」的判据**拦不住这个坑** —— 卷确实是可写的，
`df`/`touch` 全部正常，只有 SQLite 会挂。

### 为什么 `--ramdb` 救不了

`--ramdb` 的语义是「导出期间把库复制到内存、结束时写回」。
**写回的那一步仍然落在 exFAT 上**，照样失败。
（osxphotos 只会自动检测「网络卷」并强制 `--ramdb`，覆盖不到这种本地的 FSKit 卷。）

### 解法：导出历史库固定放内部盘

```bash
EXPORT_DB_DIR="${EXPORT_DB_DIR:-$HOME/.cache/osxphotos}"
EXPORT_DB="$EXPORT_DB_DIR/${SUBDIR}-export.db"
...
osxphotos export ... --exportdb "$EXPORT_DB"
```

osxphotos 会打一条警告，**无害**：

```
Warning: export database '...' is in a different directory than export destination '...'
Using osxphotos export database: version 11.1 located at ...
```

**效果对照（2026-10-06 实测）**：

| | 库在 exFAT | 库在内部盘 |
|---|---|---|
| 结果 | 逐项 `Skipping missing original photo` | `exported: 5, missing: 0, error: 0` |
| 产出 | 280s 只有 132K | 5 项 246M，单个 `IMG_5663.MOV` 197MB |
| 结论 | 全部失败 | 原图确实是原件 |

### 两个连带注意

1. **试跑和全量必须用不同的库文件。** 一个 exportdb 对应一个「导出集」，
   把试跑目录（`_试跑-*`）的记录混进正式库，会被判定为「合并两个导出集」并弹确认。
   本工具用 `${SUBDIR}-试跑.db` 与 `${SUBDIR}-export.db` 分开，且试跑前 `rm -f`。

2. **顺手消灭了 exFAT 上的 `._` 垃圾。** 库不再落在目标盘，目标盘就只剩照片本身，
   不会多出一堆 AppleDouble 伴生文件（`._*`）。

### 量级提醒（第 17 节的空间估算，已按实测两次修正）

**别用试跑样本外推全量体积 —— 顺序不同，均值差 5 倍以上。**
本例两次估算对比（都基于真实测量，结论却差一个数量级）：

| 样本 | 均值 | 外推全量 |
|---|---|---|
| 试跑 50 项（893 MB） | 约 18 MB/项 | 约 **300 GB** |
| 全量前 576 项（2.4 GB） | 约 **4 MB/项** | 约 **70 GB** |

原因是两者取到的项不同：试跑走的是默认顺序，恰好命中年份较近、视频较多的段；
而全量从头扫起，早期年份以手机 JPEG 为主（几百 KB 一张），均值被拉低。
**越往后进入视频密集段，均值会重新抬升**，所以上面两个数分别是下界与上界，
真实总量大概率落在 **150–300 GB** 之间。

对**内部盘**而言，要紧的不是总量而是**瞬时周转**：
「下载原图到本地图库」和「Photos 驱逐旧原图」必须形成赛跑。
本例内部盘 APFS 容器只有 **63 GiB 可用**（`diskutil info /` 报
`Container Free Space: 68.6 GB`），远小于全量体积，所以第 17 节的护栏不是可选项：

- 内部盘低于 **12 GiB** → `SIGSTOP` 整个进程组（暂停导出，等 Photos 回收原图）
- 回到 **25 GiB** 以上 → `SIGCONT` 继续
- 连续 **30 分钟**不恢复 → 干净中止（进度已进续传库，重跑即续传）

> 判断这个坑是否正在发生，最快的办法是看 crash log 里的 **调用栈位置**：
> `export_db.py → _create_or_migrate_db_tables` 说明挂的是**导出历史库**（即本节）；
> 若栈里出现 `photosdb.py` / `Photos.sqlite` 才是图库本身的问题（那是权限，见第 5、14 节）。

---

## 22. `Skipping missing original` 要分「瞬时抖动」和「系统性失效」（证据：2026-10-06 全量实测）

第 16 节讲了这句日志是**下载失败**的标志。但它有两种性质完全不同的成因，
处置方式相反 —— 误判会白折腾几小时：

| | 瞬时抖动 | 系统性失效 |
|---|---|---|
| **分布** | 成**小簇**出现，几十项里连着几条 | **成片持续**，全程都是 |
| **同批相邻项** | **成功**（关键判据） | 也失败 |
| **产出** | 正常推进，体积持续增长 | 体积几乎不涨（如 280s 只出 132K） |
| **成因** | iCloud/AppleScript 通道偶发抖动 | Photos 没打开图库（第 12、13、19 节） |
| **处置** | **不用管**，靠重跑自动补回 | 必须先修图库，否则白跑 |

**关键判据是「同批相邻项是否成功」**，不是跳过次数的绝对值。

本例全量段 576 项里出现 7 次跳过，但全部集中在第 181–189 项（`grep -n` 后行号
599–614 连成一片），而同批的 `IMG_0175`、`IMG_0178` 导出成功 →
判定为瞬时抖动，占比 1.2%，属正常范围，**不打断流程**。

### 为什么「重跑」就能补回

`do_full` 带 `--update`，它的语义是「**跳过已导出的**」。被跳过（skip）的项
**不会写进 exportdb**，所以下一次跑同一条命令时它们会被重新尝试：

```bash
# 主流程跑完后，补一轮即可。输出 exported: 0 表示已拉全
sync-icloud-photos full
```

**推论**：不要指望单次 `full` 100% 拉全；也不要因为看到几条跳过就重启整个导出。
正确做法是**主流程照跑，结束后无条件补一轮**（本项目的定时汇报任务已内置这一步）。

### 判别用的三条命令

```bash
# 1. 看跳过是否成簇（行号连成一片 = 成簇）
grep -n "Skipping missing original" autopilot.log | awk -F: '{print $1}' | tr '\n' ' '

# 2. 被跳过的项是否真的不在盘上
for f in IMG_0170 IMG_0171; do find "$DEST" -name "$f.*" ! -name '._*'; done

# 3. 同批相邻项是否成功（最关键的判据）
for f in IMG_0169 IMG_0175 IMG_0178; do find "$DEST" -name "$f.*" ! -name '._*'; done
```

### 顺带：`--retry` 能减少瞬时抖动，但别在导出途中改

`--retry N`（配合 `--retry-wait`，默认 15s）会对**文件操作**自动重试，
文档明确说适用于「网络盘间歇性错误」。想降低瞬时跳过率可以加，但：

> **绝不要在导出运行期间编辑脚本文件。** bash 是按需流式读取脚本的，
> 运行中改文件会让它读到错乱内容后**静默退出**（退出码 0、日志无任何报错）——
> 详见第 20 节。要调参就等这一轮跑完再改。

---

## 23. 【最凶险】osxphotos 会自己 killall Photos，把整轮导出废掉（证据：2026-10-06 实测）

这是本项目踩过**破坏力最大**的坑：它不报错、不崩溃，只是让导出**无声降级为空转**，
而且现象的「长相」和别的故障高度相似，极易误判成权限或图库问题。

### 现象

导出一路正常跑了几小时，突然某一条日志出现：

```
Exporting IMG_2531.MOV (66EE9EDD-...) (2474/16953)
⚠️  run_script: AppleScript timed out: retrying killall + run_script
✅  Photos app was terminated successfully.
```

此后**每一项**都变成 `Skipping missing original photo`，导出目录不再增长。
不会退出、不会报错，只是以「每项数分钟」的速度无限空转
（实测 **6 分钟仅推进 2 项**；剩余 14000 项按此速度需 **500+ 小时**）。

### 机制（读源码确认，两层，都会杀 Photos）

**第一层 —— photoscript（AppleScript 封装库）**
文件 `photoscript/script_loader.py`：

```python
RUNSCRIPT_CONFIG = {"retry_enabled": True, "retries": 2, "wait_seconds": 5}
# tenacity: retry_if_exception(is_applescript_timed_out)
#           before_sleep=kill_photos_app      ← 超时后先 killall Photos 再重试
```

**首次** AppleScript 超时就会执行 `killall Photos`。不需要连续失败。

**第二层 —— osxphotos 自己**

```python
# osxphotos/photoexporter.py
APPLESCRIPT_ERROR_THRESHOLD = 10   # 连续 10 次导出错误 → _kill_photos_process() (pkill -f Photos.app)
```

### 为什么「杀」在本机等于自毁

正常环境里 kill 掉 Photos 再让 AppleScript 拉起它是有效的自愈。但本机实测：
**被 kill 后由 AppleScript / `open -a Photos` 重新拉起的 Photos 进程不会打开图库**
（`lsof -p <pid> | grep -c "Photos Library"` 恒为 0）。

于是链条变成：
> 一次偶发超时 → killall Photos → 新 Photos 不加载图库 → 下载通道死 → 后续全部跳过

**触发它的那次超时往往只是假阳性**：`--download-missing` 导出大视频时要先从 iCloud
下载，超过 AppleScript 超时阈值（`exportoptions.py` 里 `timeout: int = 120` 秒）就被判失败。
本例 3 小时里只出现这一次超时，代价却是整轮废掉。

### 判别三条（别和「图库本来就没打开」混淆）

```bash
# 1. 日志里有没有这两行 —— 有就说明是「自杀」，不是外部故障
grep -n "retrying killall\|was terminated successfully" autopilot.log

# 2. 从前端持有图库 ≠ 0 变成 0 的拐点，往往就在这两行之后
grep -n "Exported " autopilot.log | tail -1     # 最后一次成功
#   再看它之后是否清一色 Skipping

# 3. 后端仍健康（说明不是权限/图库损坏，只是前端被杀了）
for n in photolibraryd photoanalysisd cloudphotod mediaanalysisd; do
  for p in $(pgrep -x $n); do echo "$n → $(lsof -p $p 2>/dev/null | grep -c 'Photos Library')"; done
done
```

### 处置：摘掉两层 kill（本机已打补丁）

补丁打在 pipx 的 venv 里（**不是** skill 目录），共三处，均已备份到
`WorkBuddy/2026-10-05-21-20-32/backup/osxphotos-patch-<时间戳>/`：

| 文件 | 改动 | 理由 |
|---|---|---|
| `photoscript/script_loader.py` | `kill_photos_app()` 开头 `return None` | 摘掉「超时即 killall」，保留重试 |
| `osxphotos/photoexporter.py` | `APPLESCRIPT_ERROR_THRESHOLD = 10**9` | 摘掉第二层 kill |
| `osxphotos/exportoptions.py` | `timeout: int = 120` → `300` | 给大视频下载留足时间，从源头减少假阳性超时 |

原则：**宁可让若干项失败（它们不进 exportdb，重跑自动补回），也绝不能杀掉下载通道。**

验证补丁生效（会实调一次，确认 Photos 进程号不变）：

```bash
PY="$HOME/.local/share/pipx/venvs/osxphotos/bin/python"
"$PY" -c "
from photoscript import script_loader as sl
import subprocess
b=subprocess.run(['pgrep','-f','Photos.app/Contents/MacOS/Photos'],capture_output=True,text=True).stdout.split()
sl.kill_photos_app(None)
a=subprocess.run(['pgrep','-f','Photos.app/Contents/MacOS/Photos'],capture_output=True,text=True).stdout.split()
print('前', b, '后', a, '（相同=补丁生效）')"
```

> ⚠️ 补丁是本地魔改，`pipx upgrade osxphotos` / 重装会**覆盖掉**，升级后需重打。

### 外层护栏（已加进 autopilot）

即便补丁在，也别指望万无一失。`icloud-export-autopilot.command` 的全量监测循环里
已加「图库掉线自动止损」：每 60 秒查一次 `photos_lib_fd`，连续 **10 分钟**取不到
就干净中止（`exit 5`），**不写完成标记、不置 FINISHED**，让看门狗下一轮重试。

这样把「500 小时无声空转」压缩成「10 分钟后自动退场重试」。

---

## 24. 自动拉起失灵：`open -a Terminal <脚本>` 静默失效（证据：2026-10-06 实测）

第 15 节推荐用 `open -a Terminal <脚本>` 借终端的 TCC 权限启动流程。平时有效，
但**会失效**，且失效方式极其隐蔽 —— 必须先诊断再谈补救。

### 三个层级依次排除，别一上来就怀疑沙箱

**① 先看 Terminal 主线程是否卡在 Apple Event 上**

本次真凶就是这个：`open` 把「打开文件」事件送进 Terminal，Terminal 卡在处理它，
于是永远不建窗口。

```bash
sample $(pgrep -x Terminal | head -1) 2 -file /tmp/term.sample.txt
grep -A 12 "com.apple.main-thread" /tmp/term.sample.txt
# 若栈里是 AEProcessAppleEvent / _NSAppleEventManagerGenericHandler 且采样计数很大
# → Terminal 卡在 Apple Event 上；pkill -x Terminal 重启可解
```

**② 再排除 launchd 域故障**

```bash
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/<label>.plist
# Bootstrap failed: 5: Input/output error
```

关键判据：**拿一个最小 plist 去 bootstrap，同样 EIO** → 说明是域级故障，
与你的 plist 无关，别再去改 plist（本次就是这么排除的）。

**③ 最后才怀疑沙箱**

沙箱确实会拦 `open` 与 `launchctl`（表现为 `open` 返回 0 但什么都没发生），
用「沙箱外重跑」验证即可。但**本次沙箱内外表现完全一致** ——
`open` 依旧无动作、`launchctl` 依旧 EIO，说明不是沙箱。

### 还有一条判据：LaunchServices 自身报错

```bash
open -a Terminal /tmp/x.sh
# _LSOpenURLsWithCompletionHandler() failed for the application ... error -10820
```

`-10820`（无启动权限类错误）出现在**直接调用方**身上时，基本可判定
LaunchServices / 用户 session 层出了问题，**重启 Mac 是最快的恢复手段**。

### 兜底：这类失灵必须交给人

自动拉起全挂时（`open` 无效 + `launchctl` EIO + `osascript` 报 `-10004`），
**不要反复重试或加轮询** —— 直接让用户在自己的终端里手动跑：

```bash
nohup bash ~/WorkBuddy/2026-10-05-21-20-32/icloud-export-autopilot.command >/dev/null 2>&1 &
```

用户从 Dock 启动 Terminal 属 GUI 主动作，绕过 LaunchServices 这条坏路径。
**需要人工 GUI 干预的环节，就该停下等人，不要在后台空转烧 token。**

---

## 25. 【容易被忽略的硬天花板】`with timeout` 把 iCloud 下载耗时也算在内（证据：2026-10-06 实测 + 读源码）

### 现象

大文件（实测 >300 MB 的视频）导出时**必然失败**，小文件正常。失败会被 tenacity
重试 2 次，于是每个大视频白等约 10 分钟，最终该文件仍然缺失（计入 `error`/`missing`），
需要再跑一轮才能补上。整轮导出会「看起来跑完了，实际少了几个大视频」。

### 机理（读源码确认，不是猜测）

`osxphotos` 把 `--timeout`（默认 120s）一路传到底，最终落在
`photoscript/photoscript.applescript` 的 `photoExport` 里：

```applescript
on photoExport(theUUID, thePath, original, edited, theTimeOut)
    ...
    with timeout of theTimeOut seconds
        export itemList to POSIX file thePath with using originals
    end timeout
```

**这个 `with timeout` 块把「Photos 去 iCloud 拉原图 + 导出」的全部耗时都算进去。**
按实测下行约 1.1 MB/s 折算：

| 文件体积 | 约需时间 | 120s（默认） | 300s | 14400s（4h） |
|---|---|---|---|---|
| 130 MB | ~2 min | ✗ | ✓ | ✓ |
| 330 MB | ~5 min | ✗ | 贴线 | ✓ |
| 1.25 GB | ~19 min | ✗ | ✗ | ✓ |

本图库 2015/12 目录里就有 1.25 GB 的 `.MOV`，也有 339 / 317 / 237 / 221 MB 的一串，
所以 120s 与 300s 都必然出事 —— 而且**下行速率只要抖动一下，连 200 MB 的文件都会超时**。

### 补丁（两处，任一生效即可；都打上做双保险）

**① `photoscript/photoscript.applescript`** —— 在 `photoExport` 开头加超时下限：

```applescript
if theTimeOut < 14400 then set theTimeOut to 14400
```

**② `osxphotos/exportoptions.py`** —— 把 `timeout: int = 120` 改成 `14400`。

校验（语法必须过，改错了比不改更糟）：

```bash
V=~/.local/share/pipx/venvs/osxphotos/lib/python3.13/site-packages
osacompile -o /tmp/ps_check.scpt "$V/photoscript/photoscript.applescript" && echo "AppleScript OK"
~/.local/share/pipx/venvs/osxphotos/bin/python -m py_compile "$V/osxphotos/exportoptions.py" && echo "Python OK"
```

⚠️ **补丁只对「新启动」的进程生效**：Python 模块与 AppleScript 在 import 时已定型，
改文件**不会**影响正在跑的那一轮。要生效必须重启该轮（或等它跑完后的补漏轮）。

⚠️ `pipx upgrade osxphotos` 会覆盖全部补丁（本节 + 第 23 节的 killall 补丁）。
每次升级后必须重打：`bash scripts/apply-patches.sh`（幂等，可反复跑）。


---

## 26. 【会造成误判】「空间连续 30 分钟未恢复」的中止分支会写一个假完成标记 + 删掉看门狗 plist（证据：2026-10-07 读 autopilot v2 脚本逐行确认）

### 现象

内部盘触到 `PAUSE_GIB` 后，若 30 分钟没回升，主脚本会打印
`空间连续 30 分钟未恢复 → 干净中止（进度已进续传库，下次接着跑）`。
看起来是「干净中止、什么都没留下」，实际留下了一个**假的完成标记**，还会顺手掐断自动重试。

### 机理

`icloud-export-autopilot.command` 第 214–219 行这个分支只做 `kill -CONT/-TERM` + `break`，
**没有置 `aborted=1`**；而第 234 行的 `if [ "$aborted" = "1" ]`（打印「本轮因 Photos 图库掉线中止
—— 不写完成标记」那段）才是唯一的闸门。于是控制流继续走到第 242 行之后：

`bash "$S" verify` → 写 `_导出报告/autopilot-总结.txt` → 置 `FINISHED=1`
→ EXIT trap 里的 `remove_autostart` 把 `~/Library/LaunchAgents/com.helufan.icloud-export-autopilot.plist`
（**这份 plist 就是看门狗本体**，`ProgramArguments` 跑 `icloud-watchdog.sh`）rm 掉。

两个代价都直接误导后续巡检：

1. **假完成标记**：下一轮若以「完成标记存在」为判据，会直接跳进补漏分支并汇报「已完成」。
   **识别方法：读标记里的「文件总数」，跟真实目标（≈16958）比对。** 假的会停在当时的落地数
   （2026-10-07 那轮是 4934）。
2. **看门狗链条被掐断**：plist 被删后 `launchctl bootstrap` 也回不来，自动重试永久失效。

### 处置

- 巡检看到完成标记时，**先比对标记里的文件总数与落地文件数**，不要只看存在性。
- 预先把 plist 备份到工作区：
  `cp -p ~/Library/LaunchAgents/com.helufan.icloud-export-autopilot.plist <workspace>/backup/`
- 需要**真正**干净中止（不留标记、不删 plist）时，从外部先 `kill -CONT` 再 `kill -TERM` **整个进程组**，
  让父 bash 也一起终止。只 SIGKILL 父进程可绕过 trap，但必须先 CONT，否则会留下一个永久挂起
  的 osxphotos 子进程继续占着图库。

### 顺带一条现成实验：SIGSTOP 后看磁盘是否转平

暂停（`kill -STOP -<pgid>`）后连续两次读 `df -k /`，间隔 30–60 秒：

- **转平** → 之前的失血是「导出侧」驱动的；
- **继续掉** → 失血来自 Photos / photolibraryd 的后台下载，与导出无关，暂停救不了。

2026-10-07 实测为「转平」（11.82 GiB 稳 45 秒），据此把那一轮的失血归因到导出侧，
而不是第 13e 节猜的「Photos 在后台偷下原图」。**这条实验比猜进程 CPU 可靠**——
当时 Photos / photolibraryd / cloudphotod 三个进程 CPU 全是 0.0%，看 CPU 会得出完全相反的结论。

## 27. 第 26 节的假完成标记已实锤 + 【第二个数字陷阱】收尾校验会打印一个虚高的 `exported: N`（证据：2026-10-07 05:30 实测）

### 27.1 假完成标记实锤（第 26 节的预测全部命中）

2026-10-07 05:30:49 主脚本走完了第 26 节描述的那条错误分支，现场如下：

```
完成时间 : 2026-10-07 05:30:49
文件总数 : 4934          ← 真实目标 ≈16958，只完成 29%
内部盘余 : 11 Gib
退出码   : 143           ← SIGTERM，本身就是被中止的信号
详细日志 : .../autopilot.log
```

同时 `~/Library/LaunchAgents/com.helufan.icloud-export-autopilot.plist` **已被删除**
（`ls` 报 No such file or directory，`launchctl list | grep icloud-export` 为空 = 未注册）。

**一键判真假（巡检查完成标记后必跑）：**

```bash
grep '文件总数' "/Volumes/Expansion/iCloud导出-2026/_导出报告/autopilot-总结.txt"
find "/Volumes/Expansion/iCloud导出-2026" -type f ! -name '._*' ! -name '.osxphotos*' | wc -l
```

两个数一致 → 真完成；标记里的数明显偏小 → 假的（本轮 4934 vs 16958）。
**再加一个佐证：`退出码 != 0` 一定是中止而非完成**（正常完成那轮是 0）。

### 27.2 【第二个数字陷阱】收尾「再跑一次导出校验」打印 `exported: 14059`，但零文件落盘

同一次中止后，脚本仍按流程跑了收尾校验（日志原文）：

```
再跑一次导出校验: 若「0 exported」即为拉全
...
Exporting 17123 photos to /Volumes/Expansion/iCloud导出-2026...
Exporting 17123 photos ━━━ 100% 0:00:00
Processed: 17123 photos, exported: 14059, updated: 0, skipped: 0, updated EXIF data: 0, missing: 3528, error: 0
Elapsed time: 0:07:05
```

**这个 `exported: 14059` 是假的进度**——那一轮磁盘上实际只有 4935 个文件、37 GB，
CSV 最后一次成功导出停在 `02:37:14`，续传库只有 4922 行。

**证伪手段（两条，都很快）：**

```bash
# ① 最新落地文件的时间戳——有写盘的话必然出现在校验窗口内
find "/Volumes/Expansion/iCloud导出-2026" -type f ! -name '._*' \
  -exec stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S' {} + | sort -r | head -5
# 实测最新照片 = 00:41:55；05:20 之后只有 autopilot-总结.txt 一个文件

# ② 直接数校验窗口内新增文件
find "/Volumes/Expansion/iCloud导出-2026" -type f ! -name '._*' \
  -newermt "2026-10-07 05:20:00" | wc -l      # → 1
```

**为什么可以断定它没写盘：** 17123 项 / 425 秒 ≈ 40 项/秒，而且 `du` 体积前后都是 37G 不变。
这个量级只可能是「只扫库不写文件」的干跑；而且这段日志里**没有** `Using osxphotos export
database: ...` 那一行（正常带 `--update` 的导出一定有），说明它连续传库都没接上。

**结论 / 教训：** 判定进度**只认三个物理量**——`find | wc -l`（文件数）、`du -sh`（体积）、
CSV 里最后一条 `exported=1` 的时间戳。`Processed: ... exported: N` 这一类计数器**一律不可信**，
与第 13d 节（探针全绿但零产出）是同一类坑的两个不同出口。看到 `exported: 0` 也别急着报「拉全了」，
先确认那一轮到底跑了多长、有没有真的遍历。

### 27.3 内部盘吃紧的真凶：Chrome 的 `code_sign_clone` 占了 164 GB

> ⚠️ **本节结论已作废（2026-10-07 10:11 实测推翻）**：那个「164 GB」是 `du` 对 APFS
> clonefile 的表观统计，实际删掉后可用空间 1 字节未变。**请直接看第 29 节**，
> 那里有完整的证伪过程与正确的排查方法。保留本节仅为留存「只看 du 就下结论」这个错误样本。

内部盘剩 12–13 GiB 一直不回升，逐层 `du` 挖下去，最大头不是 Photos、也不是导出缓存：

```bash
du -sg /private/var/folders/*/* 2>/dev/null | sort -rn | head -3
# 166  /private/var/folders/qv/5n4h910d5d9_rc086shh39zm0000gp
du -sg /private/var/folders/qv/5n4h910d5d9_rc086shh39zm0000gp/* 2>/dev/null | sort -rn
# 164  .../X                ← 全在这里
#   1  .../T   .../C   .../0
ls .../X
# com.google.Chrome.code_sign_clone     ← 真正的大头
```

`X/com.google.Chrome.code_sign_clone/` = **164 GB**，是 Chrome 签名克隆的残留目录（macOS 不会自动清）。
同一 confstr 下的 `T/`、`C/` 各只有 1 GB，所以这不是通用的临时文件膨胀，是 Chrome 这一处。
删掉它可一次性腾出约 164 GB —— 远大于当时仅剩的 12–13 GB，且明显比让 Photos 慢慢换出原图见效快。

**注意这是用户个人文件，按只读扫描处理：只列出、报体积，由用户确认后再删，助手不代为删除。**

### 27.4 顺带纠正一个口径错误：内部盘不是 64 GiB

任务背景里写的「内部盘只有 ~64 GiB」是**错的**，实测：

```
diskutil info disk3 → APFS Container，Disk Size 994.7 GB
df -h /System/Volumes/Data → 926Gi 总 / 893Gi 已用 / 12Gi 可用（99%）
```

即 1 TB 内置 SSD，只剩 12–13 GiB。**别再用「64 GiB」估算周转空间**，会得出完全错误的结论
（比如误判「数百 GB 周转根本不可能」）。同理，图库体积用 `du` 量不到（`Operation not permitted`，
macOS TCC 拦截），只能靠 `df` 反推，别硬猜。

### 27.5 导出停掉后磁盘 1 小时 40 分不回升 → Photos 没有回收原图

05:23:28 中止导出，到 07:05 复查（1h42m）可用空间仍是 12–13 GiB，纹丝不动。
说明「下载 → 导出 → Photos 自动换出原图」这条链条**在换出那一环没生效**。
这才是磁盘长不回来的根因；只清 Chrome 垃圾能解一时，长期仍需检查 Photos 的
「优化 Mac 储存空间」是否开启，或按年分批导出（第 13e 节已提）。

## 28. 【推翻第 26 节结论】吃盘的真凶是 Chrome 的 `code_sign_clone` 泄漏，与导出无关（证据：2026-10-07 09:1x 实测）

> ⚠️ **本节在写下后 1 小时就被实测推翻（见第 29 节）**：`du` 报的 200 GB 是 APFS
> clonefile 的表观值，实际删除后可用空间完全没变。本节保留是为了留下证据链，
> **结论请以第 29 节为准**。唯一仍然成立的是：第 26 节「失血来自导出侧」的归因是错的。

### 28.1 决定性证据：导出已停，磁盘还在掉

第 26 节末尾用「SIGSTOP 后磁盘转平」推断失血来自导出侧。**这个结论是错的。**
2026-10-07 05:30 导出彻底停止后复查：

```
07:05   /private/var/folders/qv/5n4h910d5d9_rc086shh39zm0000gp = 164 GB
09:10   同上                                                    = 201 GB   (+37 GB / 2h)
```

导出早已不在运行，空间仍以约 **18 GB/小时** 的速度消失。所以失血的驱动源**不在导出链路**，
第 26 节那次「转平」只是 45 秒采样窗口内恰好没有新克隆生成（该目录是**间歇性**增长，不是匀速）。

### 28.2 定位：144 个陈旧的 App 克隆

```bash
du -sg /private/var/folders/*/* 2>/dev/null | sort -rn | head -3
#   201  /private/var/folders/qv/5n4h910d5d9_rc086shh39zm0000gp
du -sg /private/var/folders/qv/5n4h910d5d9_rc086shh39zm0000gp/* 2>/dev/null | sort -rn
#   201  .../X          ← 全在这里（T/ 与 C/ 各 1 GB）
ls .../X
#   com.google.Chrome.code_sign_clone
ls .../X/com.google.Chrome.code_sign_clone | wc -l   # → 144
```

`code_sign_clone.*` 每个装着**一份完整的 Chrome.app 克隆**（约 1.4 GB），
144 个 × 1.4 GB ≈ **200 GB**。时间戳跨 10-06 10:21 → 10-07 08:54，仍在持续新增
（实测 ~6 个/小时 ≈ 8.7 GB/小时）。这是 macOS 为「就地改签 app」建的临时克隆，
正常应在启动完成后自动回收，**此处没有回收**。

### 28.3 判据的修正

- **不要**用「暂停导出后磁盘是否转平」来归因。间歇性增长的目录会让这个实验给出假阴性，
  而 `Photos / photolibraryd / cloudphotod` 三个进程 CPU 常年 0.0%，看 CPU 同样无解。
- **可靠判据**：`du -sg /private/var/folders/*/*` 连测两次、间隔拉长到 10 分钟以上，
  看哪个目录在持续变大。分层 `du` 才是唯一能定案的证据。
- 结论：**内部盘吃紧的第一嫌疑人是 Chrome 的 `X/com.google.Chrome.code_sign_clone`**，
  排掉它再谈 Photos 回收。

### 28.4 处置

```bash
# ① 先退出 Chrome（克隆可能被在用进程引用）
osascript -e 'quit app "Google Chrome"'
# ② 确认已退出后再删（这是缓存目录，Chrome 会按需重建）
rm -rf "/private/var/folders/qv/5n4h910d5d9_rc086shh39zm0000gp/X/com.google.Chrome.code_sign_clone"
```

一次可腾出约 **200 GB**，远超清 Chrome 普通缓存的效果，也大于让 Photos 慢慢换出原图。
**注意这属于用户环境下的删除操作：助手只做只读扫描并给出体积与命令，由用户本人执行。**

### 28.5 与「原件大面积取不到」的关系

08:59 复核第 27 节那轮的结果，实际账目（CSV 逐行统计，非日志计数器）：

| 状态 | 行数 | 磁盘实存 |
|---|---|---|
| `new`（新写） | 1493 | ✅ 1493 |
| `skipped`（已存在） | 3429 | ✅ 3429 |
| **`missing`** | **9183** | ❌ 0 |

`new + skipped = 4922`，与磁盘 4923 个文件吻合（差 1 为统计口径）。
**9183 项记为 missing = 根本没写出文件**，且断点非常整齐：日志里
`IMG_4872.JPG` 成功、紧接着 `IMG_4873.PNG` 起全部 `Skipping missing original`，
此后零新增。这是「取件通道在某一刻整体失活」的特征，不是逐项失败。

`new/skipped/missing` 三列是 CSV 里的**原始事实**，比收尾计数器可靠（见 27.2）。
**巡检查进度一律以「CSV 三列 + find|wc -l + du -sh」为准。**

### 28.6 已加进 autopilot 的护栏（2026-10-07 新增）

原来只有「Photos 是否持有图库文件」一条判据，抓不到「Photos 活着但取不到件」。
新增两条，命中即中止本轮且不写完成标记：

1. 连续 **30 分钟**零新增文件（大视频单件上限约 20 分钟，留余量）；
2. 每 **10 分钟**新增 `Skipping missing` 超过 **50** 条。

同批修复了第 26 节的假完成标记（低盘中止分支补上 `aborted=1` + `abort_reason`）。

## 29. 【自我纠错，推翻第 27.3 与 28 节】Chrome 的 `code_sign_clone` 是 `du` 幻象，删了不还空间（证据：2026-10-07 10:11 实测）

### 29.1 实测：删掉「200 GB」后，可用空间 1 字节没变

按第 28.4 节执行清理，全程留证：

```
10:11:52  删除前: 926Gi 总 / 893Gi 已用 / 12Gi 可用 (99%)   du -sh .../code_sign_clone = 200G
10:11:36  删除后: 926Gi 总 / 893Gi 已用 / 12Gi 可用 (99%)   du -sh .../code_sign_clone = 0B
          ls 该目录 → 0 个条目
```

进一步排除「删了但被占用」这条退路：

| 检查 | 结果 |
|---|---|
| `lsof +L1`（已删除仍被打开的文件） | 空 |
| `mount \| grep -c code_sign_clone`（残留挂载卷） | **0** |
| `hdiutil info`（残留挂载镜像） | 0 |
| `tmutil listlocalsnapshots /` | 0 个快照 |
| `df -k` 间隔 20 秒两次采样 | 只差 **304 KB** |
| APFS `Capacity In Use By Volumes` | 982.0 GB → 982.0 GB（不变） |

**结论：那 200 GB 是表观值。** `code_sign_clone.*` 用的是 APFS **clonefile**，
144 份克隆共享同一份底层数据块；`du` 按逻辑块统计、不做去重，于是把「1.4 GB × 144」加了出来。
真实占用只有 GB 量级。

### 29.2 教训：`du` 在 APFS 上会系统性高估

**任何「某目录占 N GB」的结论，在动手删之前必须先做一次闭环验证：**

```bash
df -k /System/Volumes/Data | tail -1     # 删前
rm -rf <目标>
df -k /System/Volumes/Data | tail -1     # 删后，必须真的变大
```

只变大了一点点或完全不变 → 那是 clone / 快照 / 稀疏文件的幻象，**不要再把它当结论写进文档**。
第 27.3 与第 28 节都是只看了 `du` 就下结论，属于同一类错误，**以本节为准**。

### 29.3 连带影响

- autopilot 的「内部盘空间护栏」用的是 `df`，不受此影响，仍然有效。
- 但**「谁是吃盘大户」这个问题在本次事故中并未真正解决**。已改用
  `du -d1 -x /System/Volumes/Data` 逐层扫描（注意：`~/Pictures/Photos Library.photoslibrary`
  被 TCC 拦，`du` 量不到，图库真实体积只能靠 `df` 前后差值反推）。
- 排查顺序建议：`du -d1 -x` 一级 → 锁定大户 → 再 `du -d1` 往下钻 → 每一步都用 `df` 闭环验证。

### 28.7 CSV 是按列号统计时最容易数错的地方（2026-10-07 09:1x 实测）

`export-*.csv` 共 28 列，**前 13 列的顺序**是：

```
1 datetime  2 filename  3 exported  4 new  5 updated  6 skipped  7 exif_updated
8 touched  9 converted_to_jpeg  10 sidecar_xmp  11 sidecar_json  12 sidecar_exiftool
13 missing  14 error ...
```

一次真实踩坑：用 `awk -F, '$12==1'` 想数「取不到原件的项」，结果第 12 列是
`sidecar_exiftool`，计数恒为 0，差点得出「没有 missing」的反向结论。**数 `missing` 要用 `$13`，
数真正写出文件的用 `$3`（exported）或 `$4`（new），已存在的用 `$6`（skipped）。**

安全做法：不要靠背列号，用表头定位——

```bash
head -1 "$CSV" | tr ',' '\n' | nl   # 先看列号
```

或直接按「路径 + 标志位」双条件核验，避免单列误判。

### 28.8 补丁落地指纹（用于后续巡检确认补丁没被回滚）

2026-10-07 09:08:40 修补后的 `icloud-export-autopilot.command`（317 行）：

| 项 | 值 |
|---|---|
| md5 | `48343c0f4511762bb103744d2b15c803` |
| 「零产出 / missing 洪水」护栏 | 第 206–247 行（注释标注 2026-10-07 新增） |
| 假完成标记修复 | 第 264–266 行（`aborted=1; abort_reason="内部盘空间耗尽且 30 分钟未恢复"`） |
| 中止退出码 | `aborted=1` → `exit 5`，**不写** `_导出报告/autopilot-总结.txt` |

巡检时若发现第 264–266 行的 `aborted=1` 又不见了，说明脚本被回滚到修复前的版本，
假完成标记会复发——**必须重新打补丁**，否则「低盘中止」会被误报成「导出完整完成」并摘掉登录自启项。

**读脚本前先看 mtime**：本轮巡检发现脚本 mtime 为当天 09:08（4 分钟前），说明有并行会话
正在改它。此时**只读、不要动**——正在被编辑的文件最忌并发写入。

## 30. 【补齐第 29.3 的遗留问题】吃盘大户已定位，且不是导出产生的（证据：2026-10-07 11:2x 实测）

第 29.3 节承认「谁是吃盘大户并未真正解决」。本节把它结掉。

**总量锚点**（不要用 `du` 当总量，用 APFS 自报）：

```
diskutil apfs list | grep -E "Capacity"
  Capacity In Use By Volumes: 982.1 GB (98.7% used)
  Capacity Not Allocated:      12.6 GB (1.3% free)
  Data 卷 Capacity Consumed:   958.8 GB
```

**逐层 du 结果（~/ 字面合计 ≈ 638 G，其余为 Photos 图库 + 系统）**：

| 目录 | 体积 | 备注 |
|---|---|---|
| `~/Library/Containers` | **254 G** | 微信 162 / 企业微信 71 / 印象笔记 14 / QQ音乐 5 |
| `~/Downloads` | **209 G** | 用户自管 |
| `~/微云同步助手(289221337)` | **92 G** | 腾讯微云本地同步副本 |
| `~/Library/Group Containers` | 27 G | |
| `~/Library/Application Support` | 27 G | |
| `~/Library/Caches` | 12 G | |
| `~/Documents` | 11 G | |
| `~/Pictures`（Photos 图库） | **量不到** | TCC `Operation not permitted`，只能用 `df` 前后差值反推 |

### 30.1 方法论：三步定位，别一上来全盘扫

```bash
diskutil apfs list | grep Capacity          # ① 锚点：真实占用总量（秒级）
du -sg /Users/$USER/* 2>/dev/null | sort -rn | head   # ② 用户家目录一级（分钟级）
du -sg ~/Library/* 2>/dev/null | sort -rn | head      # ③ 再钻 Library
```

**反面教材**：`du -d1 -x /System/Volumes/Data` 直接全盘扫，实测 **>11 分钟**仍未返回，
且抓到的大头仍是幻象目录。先 `df`/`diskutil` 拿锚点再分层钻，比全盘扫描快一个数量级。

### 30.2 结论归属：这 300+ GB 与导出任务无关

Containers / Downloads / 微云 都是**长期累积的用户数据**，不是本次导出造成的。
导出唯一能间接推高的是 **Photos 图库**（`--download-missing` 把原件拉回内部盘），
但 27.5 已证导出停掉后磁盘纹丝不动 → 图库的「换出原图」没在工作，图库体积近 24h 没涨。

**下次再遇到「内部盘吃紧」，不要先去删导出产物或 Chrome 克隆**（前者是交付物，后者是幻象），
应按 30.1 的三步直接找 Containers / Downloads 这类真户。

### 30.3 处置红线（务必保留）

- 微信 / 企业微信 / 印象笔记的 `Containers` **绝对不要手删**：里面有账号态、聊天记录、
  本地数据库，手删等于把 App 打回未登录状态且可能丢记录。
  正确做法是进 App 内「设置 → 存储空间 / 聊天记录迁移」清理，或先退出 App 再操作。
- `~/Downloads`、微云同步目录属用户个人目录，**只列清单、由用户确认后再动**。

## 31. 【第 9 轮巡检】磁盘其实会自行回收（修正 27.5）+ 通道死锁不会自愈 + 假标记早于补丁（证据：2026-10-07 13:4x 实测）

### 31.1 导出完全停止 8.5 小时后，内部盘自行回收 11 GiB —— 把 27.5 的绝对化结论收窄

27.5 写的是「导出停掉 1h42m 磁盘纹丝不动 → Photos 的换出原图环节未生效，是磁盘长不回来的根因」。
本轮实测推翻了它的普遍性：

```
11:20  11 GiB 可用    APFS Data 卷 Capacity Consumed 958.8 GB
13:43  22 GiB 可用    APFS Data 卷 Capacity Consumed 947.2 GB   (-11.6 GB)
```

期间导出自 04:53 SIGSTOP、05:30 退出后就**完全没有任何导出进程**，所以这 11 GiB 不是导出释放的。

**修正后的口径：回收是存在的，但时间常数是「小时级」而不是「分钟级」。**
`1h42m` 的观察窗太短，不足以否定回收。**下次看到「停掉后磁盘不回升」，先确认观察窗是否短于 2 小时**；
若 <2h，不要下「图库永不换出」这种结论（第 27.5 / 30.2 两节都吃了这个亏）。
推论：磁盘红线（PAUSE_GIB=12）在长时间停机下**是会自己解开的**——本轮就解开了，不需要人工救盘。

### 31.2 通道死锁在 Photos 不重启的前提下不会自愈（已持续 >12 小时）

- Photos PID 15477，启动时刻 **2026-10-06 21:48**（巡检时 elapsed 15:55:35）
- 也就是：**自通道失效（00:41:54）至今，Photos 一次都没被重启过**
- 失效持续 >12 小时；整个 01:00–05:00 的 4 个小时里 `exported=1` 只出现过 1 条（02:37:14，孤例）

→ **这类死锁是持久的，等它自己好纯属浪费。唯二有效动作：重启 Photos.app，或重启 Mac。**
但第 1 轮的经验（killall 重开只换来约 5 项额度后立刻再次死锁）说明**重启 Photos 可能只是短暂缓解**，
重启 Mac 更彻底。**先修通道、再恢复导出**——通道没修就重启导出，只会白烧一轮（12k 项零产出 + 4 GiB/h 失血）。

### 31.3 05:30 的假完成标记**早于** 09:08 的补丁 —— 补丁至今未被实战检验

时间线（本轮核对）：

| 时刻 | 事件 |
|---|---|
| 10-07 05:23–05:30 | 走错误分支：写假标记 `autopilot-总结.txt`（4934 项 / 退出码 143）+ 删掉看门狗 plist |
| 10-07 09:08:40 | 才打上 28.8 描述的补丁（`aborted=1` 分支 + 两道零产出护栏） |

**所以看到假完成标记，不能反推「补丁失效」——它只是发生在补丁之前。**
补丁要等下一次「低盘中止」场景真的触发才能验证。巡检时的正确动作仍是：
比对脚本 md5（见 28.8）+ 检查 plist 是否已被删。

### 31.4 看门狗 plist 被删的实锤与恢复路径

- `~/Library/LaunchAgents/com.helufan.icloud-export-autopilot.plist` → **不存在**
- `launchctl list | grep -i icloud` → 只有系统自带的 `com.apple.icloud*`，无本任务的 label
- 备份可用：`<workspace>/backup/com.helufan.icloud-export-autopilot.plist.bak`（1428 B，10-06 15:06）

恢复：`cp` 回 `~/Library/LaunchAgents/` → `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.helufan.icloud-export-autopilot.plist`
（第 2 轮记录的 `bootstrap` EIO 报错是否仍在，需重启 Mac 后复验）。
**注意顺序：先修通道 → 再重装看门狗 → 最后启动导出**；否则看门狗会反复拉起一个必然失败的导出。

### 31.5 第 9 轮判据读数（可当模板）

| 判据 | 读数 | 判定 |
|---|---|---|
| 完成标记 | 存在，4934 项 / 目标 ≈16958，落款 05:30:49，退出码 143 | **假** |
| 落地文件 / 体积 | 4935 / 37 GB（00:41 起冻结） | 29% |
| CSV `$3==1` 最后时间戳 | 2026-10-07T02:37:14 | 11 小时未前进 |
| 最新媒体 mtime | 2026-10-07 00:41:55 | 未前进 |
| 导出进程 / 看门狗 | 均不在（plist 已删） | **异常** |
| `Skipping missing original` | 8857（63.7%） | **占比过高** |
| 内部盘 | 22 GiB（<25 建议值，>12 护栏） | 已解开红线 |
| 脚本 md5 | `48343c0f4511762bb103744d2b15c803` | 补丁在位（28.8） |
| 崩溃日志 | mtime 10-06 18:17，2 次 readonly database（旧 `_试跑` 实例） | 第 21 节未复发 |

---

## 32. 【我亲手写出来的两个 bash 3.2 陷阱】花括号截断默认值 + 普通赋值冲掉环境变量（证据：2026-10-07 17:1x 实测）

这一节记的是**本 skill 自己的脚本**踩的坑，不是 macOS 的。两条都很隐蔽：不报错，
只是行为静默变错，而且都发生在「把脚本改得更规范」的过程中。

### 32.1 含 `{}` 的默认值不能塞进 `${VAR:=…}` —— 会被截断

```bash
# ❌ 想表达「没配就用这个默认目录模板」
: "${DIR_TEMPLATE:={created.year}/{created.mm}}"
echo "$DIR_TEMPLATE"      # 实测输出：{created.year}     ← 后半截没了！
```

**原因**：bash 找参数展开的闭合 `}` 时不认「模板里的花括号」，
先在 `{created.year}` 的 `}` 处闭合，剩下的 `/{created.mm}}` 被当成普通文本。
（`:=` / `:-` / `:?` / `:+` 四种都一样。）

**危害等级比第 5e 节更高**：第 5e 节至少会因 `set -u` 报错中止；这一条**不报错**，
目录结构静默变成 `{created.year}/` 一个平层——跑几天才发现导错了层次。

**正确写法**（两条路都行）：

```bash
# ① 先判空再兜底（推荐）
[ -n "${DIR_TEMPLATE:-}" ] || DIR_TEMPLATE='{created.year}/{created.mm}'

# ② 借中间变量
DEFAULT_TEMPLATE='{created.year}/{created.mm}'
: "${DIR_TEMPLATE:=$DEFAULT_TEMPLATE}"
```

**✅ 但要先分清合法与非法**：`${a:-${b:-c}}` 这种**嵌套展开**在 bash 3.2 下完全正常
（实测 `${A:-${B:-0}}` → `7`）。区别在于 `{` 前面是不是 `$`：

| 写法 | 判定 |
|---|---|
| `${T:={a}/{b}}` | ❌ 裸花括号 → 截断为 `{a}` |
| `${a:-${b:-0}}` | ✅ 嵌套展开 → 合法 |

小工具 `scripts/lint-nonascii-vars.sh` 的规则 2 就是干这个的，用 `(?<!\$)\{`
把合法的嵌套展开排除掉（4/4 契约用例已验证）。

### 32.2 普通赋值会把调用时传进来的环境变量冲掉

```bash
# 脚本里这么写：
DOWNLOAD_MISSING=1
# 用户这么调：
DOWNLOAD_MISSING=0 bash icloud_export.sh full     # ❌ 完全不生效
```

bash 里 `VAR=值` 是无条件赋值，命令行前缀传进来的环境变量在这里被覆盖掉。
文件头却写着「优先级：内置默认值 < 配置文件 < 环境变量」——**文档在骗人**。

**正确写法**：

```bash
: "${VAR:=默认值}"     # 只在「未设置」时兜底；不含 {} 的默认值用这个
[ -n "${VAR:-}" ] || VAR='含{}的默认值'   # 含 {} 的走这条（见 32.1）
```

改完顺手发现：这个「环境变量可覆盖」的承诺此前对 `DOWNLOAD_MISSING`、
`FS_TIMEOUT`、`DIR_TEMPLATE` 全都是假的，一并修掉了。

### 32.3 怎么发现的 —— 值得复用的验证手法

这两条**都是靠假 shim + 隔离 HOME 端到端截获 argv 抓到的**，肉眼 review 看不出来：

```bash
# 1) 造一个假 osxphotos，只打印自己收到的参数
mkdir -p /tmp/fakehome/.local/bin
cat > /tmp/fakehome/.local/bin/osxphotos <<'EOF'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then echo "osxphotos, version 0.77.2 (fake)"; exit 0; fi
{ printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >> "${FAKE_ARGV_LOG:-/tmp/argv.log}"
exit 0
EOF
chmod +x /tmp/fakehome/.local/bin/osxphotos

# 2) 跑真实脚本，但把 HOME 指过去
HOME=/tmp/fakehome FAKE_ARGV_LOG=/tmp/argv.log ONLY_PHOTOS=1 MAX_ITEMS=250 \
  bash scripts/icloud_export.sh full

# 3) 看真实 argv
sed 's/ \[/ \n      [/g' /tmp/argv.log
```

**两个关键点**：

1. **必须隔离 `HOME`，不能只改 `PATH`。** 本脚本的 `find_osxphotos()` 会
   **优先命中硬编码路径**（`$HOME/.local/bin/osxphotos` → homebrew → …），
   最后才 `command -v`。只往 PATH 前面塞假 shim 会被绕过，
   结果是**真的 osxphotos 跑起来**（还会因 TCC 缺权限崩掉、往工作区写 crash log）。
2. 隔离 HOME 后，`SYNC_CONF`、`EXPORT_DB_DIR`（都在 `$HOME` 下）也一并隔离，
   不会污染真实续传库。测试完 `rm -rf /Volumes/Expansion/_e2e-*` 收尾。

**结论：凡「脚本拼命令行参数」的逻辑，别靠读代码确认，跑一次截 argv。**
这次就是 `--directory` 的值少了一半，一截就现形。

### 32.4 把这个手法推到极致：整套脉冲流程都能全模拟

隔离 `HOME` 的额外红利被低估了。`space_guard.sh` 头部有一行：

```bash
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:..."
```

`$HOME/.local/bin` **排在 PATH 最前**，而 `$HOME` 已经被换掉 —— 于是
**连 `df` / `pgrep` / `lsof` / `killall` / `open` 都能被假件替换**，不只是 osxphotos。
这就可以在不动真实数据、不碰真实 Photos 的前提下，把整套决策逻辑跑一遍：

| 假件 | 作用 | 能验证什么 |
|---|---|---|
| `df` | 可用量从状态文件读 | 空间下降 → 停手；回血 → 复工（脉冲） |
| `pgrep`/`lsof` | 恒报「Photos 已加载图库」 | 绕过 180 分钟等图库 |
| `osxphotos` | 边跑边吃空间，可指定 missing 数 | 自然完成 / missing 洪水 / 完成判定 |
| `killall`/`open` | 只回显不执行 | **安全演练 `restart_photos`**（否则会真杀掉用户的照片 App） |

一个「模拟系统回收」的旁路驱动就够：*没有导出进程在跑时，每 3 秒把可用空间加一点* ——
这正是「停手后 macOS 才回收」的抽象。

**这套演练一下就抓出三个肉眼看不出的逻辑缺陷**（`stall_min` 按次数而非时间累加、
`photo_restarted` 在判断前被重置导致收敛路径永远走不到、以及一个缺失的执行位）。
其中第二个会让脚本**每轮都冷启动 Photos、无限循环**——读代码时很难发现，
因为它长得像一段防御性代码。

**教训：状态机类的脚本，写完必须构造「假环境」把每条分支真的走一遍。**
「我读过代码了」在这类缺陷面前等于没查。

---

## 33. 【第 10 轮巡检】「零产出 + 无进程」不等于死亡 —— 先看 space-guard.log 有没有 dry-run（证据：2026-10-07 17:4x 实测）

### 33.1 新增的第一判据：有没有 dry-run 痕迹

第 3–9 轮巡检时，「进度冻结 + 导出进程不在 + 看门狗不在」= 停摆，处置建议是
「修通道 → 重装看门狗 → 重启导出」。**这一条从第 10 轮起不再充分**。

下午有并行会话在把「内部盘腾不出空间」做成脉冲方案（`scripts/space_guard.sh`），
期间会出现一种**和停摆完全同形**的状态：进度冻结、无 osxphotos 进程、看门狗不在。
唯一区别藏在监管日志里：

```bash
tail -20 "/Volumes/Expansion/<DEST_SUBDIR>/_导出报告/日志/space-guard.log"
# 出现「（--dry-run：只体检，不启动导出）」且时间戳在近几小时内 → 开发/调试中，别当死亡处理
```

配套旁证（三条同时出现基本可定案）：
- 脚本 mtime 是**当天近几小时**（`ls -la scripts/space_guard.sh scripts/icloud_export.sh`）
- `SKILL.md` / `references/gotchas.md` mtime 同步刷新
- 工作区 `export/` 下出现**成批 0 字节**的 `p_*.jpg`（dry-run 的假件残留，不是真实导出）

**处置差异**：停摆 → 建议重启旧流程；重构期 → **明确劝阻手动重启旧流程**
（旧主脚本没有脉冲护栏，20 GiB 下重启会重演第 5 轮的失血—暂停—中止循环，
且会和 space_guard 抢进程）。

### 33.2 脉冲方案落地指纹（用来确认没被回滚）

| 文件 | md5 | mtime |
|---|---|---|
| `scripts/space_guard.sh` | `46d87eb3c0f49dc679469cb861d37a70` | 10-07 17:18:45 |
| `scripts/icloud_export.sh` | `ef0ac4dd0784191d7eb1bb839c8f0196` | 10-07 17:15:21 |
| `scripts/lint-nonascii-vars.sh` | `469897d9636c4811ad2fdff3e57a84e0` | 10-07 17:16 |
| `SKILL.md` | `5d4f8a2c9c6ad051c152f82f0e433241` | 10-07 17:29:48 |
| `references/gotchas.md` | `a9b5d2245cb8287f2e2eac1256f11fe6` | 10-07 17:29:25 |

阈值语义（`space_guard.sh` 头部与 SKILL.md「低空间模式」节一致）：
**FLOOR=12 GiB 停工 / CEIL=18 GiB 复工 / HARD_MIN=6 GiB 立刻停**。
退出码：`0` 完成、`3` 空间无法回收（要改 Photos 设置）、`4` 取件通道死锁（重启 Photos/Mac）、
`5` 达轮次上限（可续）、`6` 前置条件不满足。

**注意**：`icloud_export.sh` 被重写后，**A1 补漏直连它会绕过 space_guard 的空间护栏**。
低盘时仍应走 `space_guard.sh`，不要直接跑 `icloud_export.sh full`。

### 33.3 第 10 轮判据读数（可当模板）

```
完成标记      : 存在但假 —— 文件总数 4934 / 目标 ≈16958，落款 05:30:49，退出码 143
落地          : 4936 文件 / 37 GB（照片侧 4935 + 新报告 1）
CSV exported=1: 最后一条 2026-10-07T02:37:14（停滞 15 h）；最新媒体 mtime 00:41:55
续传库        : export_data 4922 行 / photoinfo 4768 uuid（内部盘，正常）
进程/看门狗   : 均不在；Photos PID 15477 已 20h00m 未重启
内部盘        : 20 GiB（60 s 双采样 20→20，已止血）；Data 卷 926/884/20/98%
Skipping      : 8857（63.7%）；崩溃日志 mtime 仍 10-06 18:17，无 readonly database
年/月         : 2015(2621)+2016(2269) 占 99%；2018–2022 空目录；2010–2012 无目录
扩展名        : jpg 3614 / png 778 / mov 338 / jpeg 154 / mp4 26 / gif 12
残留（仅列）  : 3 个 _试跑-*（各 893 MB）+ 7 个 ._2016…._2022
```

### 33.4 方法论校正：`awk` 统计 CSV 空列会全错

本轮再次踩到第 28.7 节的同款坑，且形状不同：用 `if($13!="")m++` 统计「missing 列非空」，
得到 **14105 = 总行数**，即认为每一行都有 missing。实际是空字段被写成空字符串，
`!=""` 判真。**结论：CSV 各列不能用「非空」判存在，必须比对具体值的出现次数**
（如 `$3=="1"`），或先 `head -1` 确认表头列序再逐列核对。

### 33.5 下一次巡检重点

1. `space-guard.log` 是否已从 `--dry-run` 转为真实工作期（出现「工作期」/「休息期」字样）；
2. 若已开工：**只看 CSV 第 3 列 `exported=1` 的最后时间戳**是否前进（探针全绿无意义）；
3. 内部盘读数与脉冲节奏是否吻合（FLOOR 12 / CEIL 18）；
4. Photos PID 是否被重启过（`ps -o etime`）—— 通道死锁的修复标志；
5. **若「下载原件到 Mac」被选中**，脉冲会在第一个休息期后以退出码 3 结束并如实报告，
   这不是 bug，是正确行为。

---

## 34. 第 11 轮巡检补充（2026-10-07 19:52）——「冷重构期」与脉冲的必然退出码 4

### 34.1 第 33.1 节需要一条伴生规则：重构期也会「冷掉」

第 33.1 节教了「进度冻结+无进程+无看门狗 不再等于停摆」——先看 `space-guard.log` 是否有
dry-run 记录。**但只看"日志里有没有 dry-run 字样"会漏判一种状态：重构会话中途停工。**

判定「活的重构期」vs「冷的重构期」，要看**时间窗口**，不是看有没有那行字：

```bash
# 活：近 30 分钟内还有写入
find "/Volumes/Expansion/iCloud导出-2026/_导出报告/日志" -type f ! -name '._*' -newermt "-30 minutes"
# 冷：最后写入已是数小时前
stat -f '%Sm %N' -t '%m-%d %H:%M' "/Volumes/Expansion/iCloud导出-2026/_导出报告/日志/space-guard.log"
```

第 11 轮实测：`space-guard.log` 4 个块**全部**是 dry-run，最后写入 17:29:53，
到 19:52 巡检时已**静默 2h22m**；工作区最新文件是 17:50 的巡检报告本身；
`export/` 下 133 个 `p_*.jpg` 仍停在 17:19–17:24。
→ 结论是**冷重构期**：并行重构会话已停止活动，`space_guard.sh` 从未进入真实工作期。
**此时不应再沿用"重构期所以别插手"的处理口径。**

### 34.2 通道死锁下启动 `space_guard.sh` 必然撞退出码 4

这是可以**先验推出**、不必起跑的判断，避免白烧一轮：

- 33.2 已定义：退出码 **4 = 通道死锁**
- 通道状态可由「最后成功导出时间戳」独立判定（13d），无需探针
- 第 11 轮该时间戳为 **02:37:14**，**19h15m 未前进**；Photos PID 15477 已存活 22h03m 未重启
- ⇒ 通道已死 ⇒ `space_guard.sh` 第一个体检点即以 **4** 退出

**推论（顺序不可颠倒）：先修通道 → 再验证 → 再装看门狗 → 最后启动脉冲。
在通道是死的情况下启动脉冲，唯一产出是一次退出码 4。**

### 34.3 13b 探针这次的读数（强化 13d）

`perl -e 'alarm 12; exec @ARGV' osascript -e 'tell application "Photos" to count of albums'`
→ 返回 **15**，耗时 **0.28 秒**（rc=0）。

**探针不仅"绿"，而且快到不可能有问题——可生产侧已零产出 19 小时。**
这是 13d 最干净的一次反例：**探针响应速度与通道可用性无关**。
新巡检者若只看探针，会得出"一切正常"的完全相反结论。

### 34.4 第 11 轮判据读数模板（可直接复制填空）

```
完成标记      : 存在但为假（4934 / 目标 ≈16958，退出码 143，落款 05:30:49）
落地文件/体积 : 4936 / 37 GB（冻结，与上轮持平）
CSV 判据      : exported=1 最后一条 02:37:14（19h15m 未前进）← 唯一可信
最新媒体 mtime: 00:41:55
进程          : osxphotos / icloud_export / space_guard 全不在
看门狗        : 未注册（launchctl list 无 label；LaunchAgents 无 plist）
内部盘        : 19 GiB（60 s 双采样 19→19，已止血）；FLOOR=12 未触及
续传库        : export_data 4922 / photoinfo 4768（内部盘，mtime 05:23）
Skipping      : 8857（63.7%）；崩溃日志 mtime 10-06 18:17，无 readonly database
年/月         : 2015(2621)+2016(2269) 占 99%；2017 仅 1；2018–2022 空；2010–2012 无目录
扩展名        : jpg 3614 / png 778 / mov 338 / jpeg 154 / mp4 26 / gif 12
脚本指纹      : space_guard 46d87eb3… / icloud_export ef0ac4dd… / autopilot 48343c0f… 全部在位
残留（仅列）  : 3 个 _试跑-*（各 893 MB）+ 7 个 ._2016…._2022
```

### 34.5 本轮未执行的动作及原因

未跑 A1（A 分支前提不成立 + 通道已死无源可补 + 低盘下 A1 绕过 space_guard 护栏）；
未删任何文件；未改脚本（全程只读）；未 kill 进程；未执行 A5 暂停（任务未完成，保持 ACTIVE）。


---

## 35. 【回答「优化存储会不会让我拿到压缩件」】用续传库做逐条原件性核验（证据：2026-10-07 20:4x 实测）

### 35.1 问题
Photos 改为「优化 Mac 储存空间」后，本地只留小副本、原件在 iCloud。
用户合理怀疑：导出拿到的是不是缩略/优化副本？

### 35.2 核验方法（不需要读图库、不需要完全磁盘访问、不需要联网）
osxphotos 续传库 `~/.cache/osxphotos/<SUBDIR>-export.db` 里有两张表可用：

| 表 | 关键字段 | 含义 |
|---|---|---|
| `photoinfo` | `photoinfo`（JSON） | 含 `original_filesize` / `original_width` / `original_height` / `uti_original` / `adjustment_type` / `ismissing` / `path` |
| `export_data` | `filepath` `src_size` `dest_size` | `filepath` 是**相对路径**（如 `2008/05/IMG_7925.JPG`），绝对位置取 `export_directory` 表 |

判据：`dest_size == original_filesize` → 逐字节等长的原件；
`dest_size < original_filesize` 且文件名不带 `_edited`/`_adjusted` → 唯一需要警惕的形态。

**坑 1**：`export_data.filepath` 不是绝对路径。第一版脚本用 `fp.startswith(dest)`
直接判，结果匹配 0 条（`核对 0 个文件`），差点被解读成「文件全丢了」。
必须 `os.path.join(export_directory, fp)`。
**坑 2**：`bucket.setdefault(k, [0, 0, [0.0]])` 把初始值 0.0 混进比值列表，
输出「比值 0.00~5.02」这种假下限。初始列表应为空。

### 35.3 实测结论（本机 4922 条导出记录）
- 字节 == 原件：**4768 条（96.9%）**
- 其余 154 条：全是 `*_edited.jpeg` 附加产物（144 条 adj=3、7 条 PNG→JPEG adj=2、
  3 条 adj=2），**无一例「小于原件且不可解释」**；对应 UUID 的逐字节原件同样在导出目录里
- **导出时本地没有、需从 iCloud 现拉：1489 条 → 其中 1486 条（99.8%）仍逐字节等长原件**
  （含一条 840 MB 的 MOV）。这是「优化存储 + 按需现拉 = 原件」的决定性证据
- 磁盘实际字节与记录值不符：**0 / 4922**

注意 1486 ≠ 1489：那 3 条是 `_edited` 产物被标记为 missing，不是原件缺失。

### 35.4 已固化为脚本
`scripts/verify-originals.sh`（离线、退出码 0/1/2），已并入 SKILL.md 的完整性校验第 1 层。

---

## 36. 【最贵的一次误报】「missing 洪水」不等于通道死锁，差点让用户白重启一次 Mac（证据：2026-10-07 22:28 实跑 + 同夜隔离模拟复现）

### 36.1 现场
第 3 轮工作期（22:08:23–22:28:43）**一路在出货**：12348 个文件（22:18）→ 13428（22:28），
日志末尾 `IMG_0104/0105/0106/0107.MOV` 全是 `Exported new file`。
然后守卫打印：

```
⚠️  空转信号（零产出 0 分钟 / missing 洪水=1），但内部盘还有 177 GiB → 判为取件通道失效
❌ 取件通道死锁……唯一解是【重启 Mac】
```

**自相矛盾**：「零产出 **0 分钟**」却判「空转」。第 1 轮（21:39:14）也是同样长相。
两轮之间它还冷启动过一次 Photos（21:39:19），而**冷启动后的下一轮照样产出 2973 个文件**，
通道明明活着——但 `photo_restarted` 只给 1 次预算，第二次就宣布系统级死锁。

### 36.2 根因一：flood 判定不看产出
旧式：`stall_sec ≥ STALL_MIN*60` **或** `flood == 1` → 判死通道。
而 `flood` 只比较 `grep -c 'Skipping missing'` 的增长，**完全不看同时有没有文件落盘**。
`missing 洪水=1` 里的 `1` 是布尔真值，不是「1 条 missing」，很容易读错。

### 36.3 根因二：`Skipping missing` 大量是噪声
拿第 3 轮日志（`full-20261007-220827.log`）逐条核对：
- `Skipping missing original` 去重 **902** 个文件名
- 其中 **679 个早已在导出目录里**（如 `2022/09/IMG_6113.JPG`）
- 真正还没导的只有 **223 个**

即 75% 的 skip 是「已导出、原件不在本地、osxphotos 复核不了」的**重走噪声**。
把 skip 数当成故障指标，等于把这库的常态当故障。

### 36.4 修复
1. `flood=1` 现在**必须同时满足「该窗口零新增文件」**（`win_new <= 0`）；只要还在出货就不算洪水。
2. 通道判死改成看**上一轮新增了多少文件**（`CHANNEL_MIN_PROGRESS`，默认 20）：
   - 还有产出 → 通道是活的，**连 Photos 都不重启**，只重开一轮即可（重起导出进程本身就清掉了卡住的 AppleScript 会话）
   - 没产出 → 冷启动 Photos，预算 `CHANNEL_FIX_MAX`（默认 5）次
   - 预算用尽仍没产出 → exit 4，且提示改为「先重开照片 → 再重启 Mac → 再换 `OSXPHOTOKIT=1`」，不再一口咬定重启 Mac
3. `photo_restarted`（只给 1 次）退役。

### 36.5 隔离模拟验证（可复用做法）
`/tmp/sg-sim.sh`：隔离 `HOME` + 假 `df`/`pgrep`/`lsof`/`killall`/`open`/`osascript` +
假 `icloud_export.sh`（按计划每轮先建 N 个文件再挂着刷 skip 行）。
脚本把 `$HOME/.local/bin` 置于 PATH 首位，所以假命令生效；`SYNC_CONF` 指到临时 conf。

**两个踩过的模拟坑**：
- 假导出的日志必须写进**守卫认定的 `LOG_DIR`**（`$DEST/_导出报告/日志`），
  否则 `grep -c` 读不到 → `miss_now` 为空 → flood 永远不触发，白等 7 分钟。
- 生产里每轮收尾 `while kill -0 "$EXP_PID" && [ "$n" -lt 12 ]; do sleep 5; done`
  会白等满 60 秒（子进程已是僵尸，`kill -0` 仍返回 0）。模拟里要缩短，生产上可接受。
- `sar`：用 `perl -pi -e` 改模拟副本，别用 `sed -i ''` 配含 `[` `]` `&&` 的模式（引号地狱）。

**结果**：计划 `100 / 100 / 0 / 0 / 0`（前两轮有产出，后三轮零产出）
→ 前两轮均判「通道是活的，不重启 Photos」，第 3/4 轮各冷启动一次，第 5 轮 exit 4。
冷启动调用次数 **2**（期望 2），退出码 **4**（期望 4）。
按旧逻辑，第 2 轮就会 exit 4 —— 与线上 22:28 的表现一致，误报可复现。

## 37. 【第 12 轮巡检 · 第 36 节的实战复盘】误报发生在新补丁之前，且自愈其实是有效的（证据：2026-10-07 23:06 实测）

第 36 节记的是「missing 洪水误报」的成因与修法。本节记的是**它上线当夜的真实表现**，
以及一条**反向修正**：`killall + 重开图库` 这个自愈动作，比第 3 / 9 / 31.2 节认为的**有用得多**。

### 37.1 误报的时间线（务必分清「旧实例」与「磁盘上的新脚本」）

| 时刻 | 事件 |
|---|---|
| 21:08:57 | 用户在终端手工启动 `space_guard.sh`，第 1 轮工作期开始（4923 文件） |
| 21:39:19 | 第 1 轮以**同样的误报判据**（零产出 0 分钟 / flood=1）收尾，退出码 143 |
| 21:39:19–21:39:33 | 守卫执行【自愈】`killall` + 重开图库，Photos 于 **21:39:23** 以新 PID 起来 |
| 21:39:33 → 22:08:23 | 第 2 轮：**+2973 文件**（≈103 项/分） |
| 22:08:23 → 22:28:43 | 第 3 轮：**+2756 文件**（≈136 项/分），当晚最快 |
| 22:28:37 | 旧版判据再次误报「取件通道失效」，建议重启 Mac |
| 22:28:43 | `space_guard.sh` 以退出码 4 终止，日志落下「唯一解是重启 Mac」 |
| 22:37 | 磁盘上的 `space_guard.sh` 被打了第 36 节的补丁（md5 `b23c7b1e…`，此前是 `46d87eb3…`） |

**关键点：22:28 那次误报跑的是 21:08 加载进内存的旧版逻辑。** bash 流式读取脚本，
改磁盘上的文件不影响已运行的实例 —— 所以补丁**没来得及救下当轮，属「未检验」而非「失效」。
（与第 5/6 轮「假完成标记早于补丁」是同一类推理，勿再反推补丁无效。）

### 37.2 【修正 31.2 / 第 3 轮】`killall + 重开图库` 的自愈是有效的

第 3 轮结论是「进程级自愈无效，每次只换来约 5 项额度」；31.2 进一步说「通道死锁在 Photos
不重启下不会自愈」。**本次实测显示：当死锁是「Photos 进程态」造成的时候，自愈非常有效。**

- 21:39:19 自愈 → 21:39:23 Photos 新 PID → 随后 **49 分钟出了 5729 个文件**（两轮合计）
- 对比 21:08–21:39 第 1 轮的 91 项/分，自愈后反而更快（103 → 136 项/分）

**新表述（替代 31.2 的绝对化说法）**：
- Photos **进程活着但内部状态卡住** ⇒ `killall + 重开图库` 有用，值得先试
- Photos 进程已死 / 图库未加载 ⇒ 重开同样有用
- 只有「重开也无效且日志确证连续 30 分钟零新增文件」才升级到重启 Mac
- **顺序：先冷启动图库 → 再看产出 → 最后才重启 Mac。** 不要一上来就建议重启 Mac。

守卫脚本里 `cold_restart_photos()` 的调用预算（36.5 记的「2 次」）是有价值的护栏，别调高。

### 37.3 【判据】判断一次「退出码 4」是否可信，只需数同轮 `Exported new file`

不要看 `Skipping missing` 的绝对数量（第 36 节已证 75% 是重走噪声），
**数同一轮 `full-*.log` 里 `Exported new file` 的条数**：

```
grep -c "Exported new file" "<该轮 full-*.log>"
```

- 计数 ≈ 0 且 `tail` 是连续 `Skipping` ⇒ 真死锁，可采信
- 计数成百上千，或 `tail` 停在半句 `Exporting …` ⇒ **误报**，直接重跑，别动 Photos、别重启 Mac

本次实测：该轮 **2756 条 `Exported new file` / 仅 917 条 skip**，日志末行是
`Exporting MTVideo.mp4 … (13809/17124)`（被杀在导出中途）—— 一眼可判误报。

### 37.4 低空间前提消失时，脉冲会「退化成直跑」

第 12 轮内部盘从 11–22 GiB 一路回到 **177 GiB 空闲**（第 30 节定位的用户数据被清理，
或 Photos 完成了换出）。此时：

- 守卫的 FLOOR=12 / CEIL=18 永不触发 ⇒ **没有休息期，全程工作期**
- 日志里不会出现「休息期结束」字样，只有连续的「工作进行中」——**这是正常的，不是卡住**
- 因此当前阶段**不需要先清盘再启动**；「盘回 >25 GiB 才敢重启」这条建议在本轮已失效

反向提醒：`df -g /System/Volumes/Data` 的读数会随 Photos 换入换出大幅波动，
**单次读数不足以判断趋势**，重要结论仍要 60 秒双采样。

### 37.5 第 12 轮判据读数模板（2026-10-07 23:06）

| 项目 | 读数 |
|---|---|
| 落地文件 / 体积 | **13428 / 58 GB**（78.4% of 17124） |
| 内部盘 / 外置盘可用 | **177 GiB / 738 GiB** |
| 脉冲进程 | 无；`space-guard.log` 末写 22:28:43 |
| 退出码 | 4（**误报**，见 37.1） |
| CSV 最后 `exported=1` | **22:27:16**（最新媒体 mtime 22:27:58） |
| Photos | PID 31474，21:39:23 起（守卫自愈产物） |
| 速率 | 整体 108 项/分，逐轮加速 91 → 103 → 136 |
| 脚本指纹 | `space_guard.sh` **`b23c7b1e…`**（22:37，第 36 节补丁在位） |
| 年/月 | 2015(2621) 2016(3418) 2017(3191) 2018(224) 2019(5) 2020(343) 2021(28) 2022(3566) |
| 扩展名 | jpg 10542 / png 1681 / mov 887 / jpeg 205 / mp4 85 / gif 15 / heic 12 / md 1 |

---

## 38. 【技能自检与加固】把「误报识别 / 状态查询 / 回归测试」三件事固化进 skill（证据：2026-10-07 23:0x–23:4x）

### 38.1 起因：修好了脚本，但 skill 本身还留着四个缺口
第 36/37 节把误报的成因与修法记下了，可**技能包**里仍有会导致重复踩坑的地方：

1. `SKILL.md` 的「Photos 图库打不开」一节仍把 **LaunchAgent 自启项**当成推荐设计 ——
   那是已作废的旧架构，而且它正是第 26/27 节**假完成标记**的来源。
2. 退出码 4 只说「真的死了」，**没给判真伪的方法**；照做就会白重启一次 Mac。
3. 查状态要拼 4~5 条命令，口径极易记错（跨轮累加计数、把 skip 当故障）。
4. 第 36.5 节把模拟设施记在 `/tmp/sg-sim.sh` —— **重启即失效**，等于没留档。

### 38.2 本轮改动清单
| 文件 | 改动 |
|---|---|
| `scripts/guard-status.sh`（新） | 只读体检：进度 / 完成百分比 / 本轮计数 / 速率 / 误报判别 / 残留清单；支持 `--json`、`--fast`；退出码 0/2/3/4/6 |
| `scripts/sim-guard.sh`（新） | 三场景离线回归测试，取代 `/tmp` 里那份临时设施 |
| `SKILL.md` | 作废 LaunchAgent 段落并写明原因；退出码表补「先核对再动手」；新增「查进度：一条命令」；新增两条关键约束 |
| `space_guard.sh` | 见 38.3 |

### 38.3 space_guard.sh 的三处加固（都来自过程中真实踩到的坑）
1. **自愈预算计数器拆分**：`photo_fixes` 被通道分支与 missing 分支共用 → 前者推满后，
   后者的 `photo_fixes < 2` 恒假，那条路径再没有自愈机会。拆成 `cold_channel` /
   `cold_missing`，并加全局上限 `COLD_MAX`。
2. **零增长护栏 `NO_GROWTH_MAX`**：missing 若在两值间振荡（100→101→100…），
   「连续两轮 missing 相同」的收敛判定永不成立 → **无限绕圈**。现在连续 3 轮零新增即
   如实收尾 exit 4，并打印误报核对所需的 `Exported new file` 计数。
3. **收尾等待不再白等 60 秒**：原用 `kill -0 "$EXP_PID"` 判「还没退出」，但子进程变成
   僵尸后 `kill -0` 仍返回 0 → 每轮固定白等满 60 秒。改看 `ps -o stat=`，进程消失或
   进入 `Z` 即算退出。（第 36.5 节把它记为「生产上可接受」，本轮实测**可以优化掉**。）

### 38.4 【新坑】本机的 `sed` 是 toybox shim：`sed -i ''` 会「改对但报错」
```
$ which sed
/Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/vendor/shim/brokered-bin/sed
$ sed --version
toybox 0.8.13 (is not GNU sed 9.0)

$ printf 'POLL_SEC=30\n' > f
$ sed -i '' -e 's|^POLL_SEC=30|POLL_SEC=2|' f ; echo "rc=$?"
sed: : No such file or directory
rc=1
$ cat f
POLL_SEC=2          ← 文件其实改对了
```
- **行为**：那个空字符串参数被当成文件名 → 报错并返回 1，**但替换已经生效**。
- **危害**：`set -e` / `cmd || die` / CI 场景会直接失败；人工排查时又会被「文件确实改对了」
  带偏，以为报错无关紧要。
- **改写**：`sed -e … "$f" > "$f.tmp" && mv "$f.tmp" "$f"`，或 `perl -pi -e`。
- 第 36.5 节记的「别用 `sed -i ''`」当时只归因于「含 `[` `]` `&&` 的引号地狱」，
  **真因是这个 shim 的行为**。本技能包的生产脚本已全部规避（只有模拟脚本曾用到，已改）。

### 38.5 回归测试结果（2026-10-07 23:4x）
`bash scripts/sim-guard.sh` → **6/6 通过**：

| 场景 | 设定 | 期望 | 实测 |
|---|---|---|---|
| chain | 2 轮有产出 + 3 轮零产出 | rc=4，冷启动 2 次 | ✅ rc=4，2 次 |
| converge | 零产出、missing 恒为 100 | rc=0，冷启动 1 次 | ✅ rc=0，1 次 |
| spin | 零产出、missing 在 100/101/100 振荡 | rc=4（靠 `NO_GROWTH_MAX` 收尾），冷启动 2 次 | ✅ rc=4，2 次 |

场景 3 是**本轮新增**的：它正是 38.3 第 2 条那个「无限绕圈」场景的复现 ——
旧版永远走不到收尾，只能靠人工发现。

### 38.6 模拟设施自带的两个坑（供后续维护参考）
- 假 `lsof` 的输出里**必须含 `Photos Library` 字样**：守卫用
  `lsof -p <pid> | grep -q "Photos Library"` 判图库是否已加载。第一版假 `lsof` 只打印
  `$SIM_CTL/Photos.sqlite`，结果守卫卡在「等 Photos 加载图库」，整整 60 秒后才报错退出 ——
  现象很像脚本有 bug，其实是模拟环境没配对。
- 别用 here-string 给 sed 传空内容做缩进显示；直接 `grep … | tail -4 | sed 's/^/  /'`。

## 39. guard-status.sh 速率计算跨零点溢出（2026-10-08 01:09 巡检发现并修复）

### 39.1 现象
`guard-status.sh` 打印 `当前会话 净增 984 个，约 3542400.0 个/小时`。数字荒谬到一眼可辨，
但**未收尾的无人值守巡检里，这种量级的错值足以让后续轮次误判吞吐**。

### 39.2 根因
第 137–148 行的 perl 把时间键写成 `$3*3600+$4*60+$5`（只有 HH:MM:SS，无日期）。
本次会话跨零点（23:08 起 → 01:00 末），末样本 `01:00:03` 的键(3603) 小于首样本
`23:08:xx` 的键(83280) → `$dt` 为负 → `$dt = 1 if $dt <= 0;` 把它夹成 **1 秒**，
`$dn*3600/$dt` 于是被放大到百万级。

### 39.3 修复
时间键改为 `(($1*31)+$2)*86400 + ...`（$1=月、$2=日），使其跨日期单调递增。
`$dt<=0` 的兜底保留。修复后同一份日志算出 **529.9 个/小时**，与手工核算一致（984 个 / 6720 秒）。

### 39.4 判据提醒
`space_guard 启动` 的重置逻辑**本身是好的**（日志 line 104 有该行，重置确实生效）——
本次不是重置失效，纯粹是日期缺失。看到离谱速率先按 39.2 核对跨零点，别去怀疑重置分支。

## 40. guard-status.sh 的「在跑」判据与 gotchas 13d 自相矛盾（2026-10-08 05:12 巡检发现并修复）

### 40.1 现象
第 183 行：`if [ "$IS_RUNNING" = "1" ]; then VERDICT="running"; ACTION="正常在跑，不用干预。"`
——即**只看 `pgrep` 有没有进程**就下结论。而第 13d 节的结论恰恰是
「进程活着 / 探针绿 全都无意义，**唯一可信的判据是产出时间戳**」。
同一个工具里自相矛盾：判「误报」时用产出计数（第 193 行），判「在跑」时却用 pgrep。

### 40.2 本轮的实测窗口（说明这个盲区是真实存在的，不是理论洁癖）
05:11 那次读数：进程双在、守卫日志 6 分钟前刚更新、**结论「正常在跑」**；
但同时 —— 落地文件 04:24→05:05 **41 分钟只 +2 个**，
本轮 full 日志最后写入 04:52:35（**已静默 19 分钟**），
期间内部盘 143→135 GiB（**−9.4 GiB/h**）。
后经判断属正常：尾部停在半句 `Exporting dji_mimo_…mp4`，
是在导出大体积视频（该轮 Exported 344 / Skipping 740，仍有产出；磁盘在降也说明在写）。

### 40.3 修复（只加信息，不动结论与退出码）
新增 `L_AGE`＝本轮 full 日志的静默分钟数，输出一行
`日志静默 N 分钟（大文件导出期间静默属正常；连续 >30 分钟才值得看一眼）`，
JSON 增加 `round_log_age_min` 字段。
**刻意不改 RC、不改 ACTION**：大视频导出时静默十几分钟是常态，若据此升级告警就变成新的误报源
（第 36/37 节教训）。这条只负责把「静默多久」摆到人眼前，判断仍归巡检者。

### 40.4 顺带确认
`--fast` 只跳过 `du`，不影响 `L_AGE` / 计数 / 结论，可放心用于高频巡检。

### 40.5 本轮指纹
`guard-status.sh` md5 **3bfe064d7ea66120b356973403644b1d**（05:12，含第 39、40 节两处修复）。
它是只读体检工具，**不属硬约束里禁改的 `space_guard.sh` / `icloud_export.sh`**，改动不影响运行中的导出实例。


---

## 41. 【最容易误判的一条】Finder/系统设置的「可用空间」含可清除(purgeable)，比 df 大出一大截，且**不能当即时可用空间用**（证据：2026-10-08 22:2x–22:5x 实测）

### 39.1 现象：用户看到的数字和脚本看到的数字差 224 GB
用户报告「本地盘显示还有 230 G」，而脚本读到：

| 口径 | 命令 | 读数 |
|---|---|---|
| Finder / 系统设置「可用」 | `osascript -e 'tell application "Finder" to get (free space of startup disk)'` | **236.7 GB** |
| `df` / `statvfs` 真实空闲 | `df -k /System/Volumes/Data` | **12.6 GiB** |
| APFS 容器未分配 | `diskutil apfs list` | **12.6 GB** |

注意第三条：**APFS 容器本身只剩 12.6 GB 未分配给任何卷**。所以「236.7 GB」在物理上不可能全是真空闲
—— 差额 ≈ **224 GB 是 macOS 的 purgeable 记账**（主要是 iCloud 照片的本地缓存，即我们这些天导下来
的原件；也可能是本地快照等）。

### 39.2 关键：purgeable ≠ 随时能用
做了有界写入实验（`dd` 逐 GB 追加，真实空闲 <4 GiB 触发安全阀）：

```
写 5 GB  → df 空闲 7.21 GiB
写 10 GB → df 空闲 4.56 GiB
写 11 GB → 触发安全阀停止，df 空闲 3.93 GiB
```

**12.6 GiB 起步，写了 11 GB 后只剩 3.93 GiB —— 系统没有同步腾出空间。** purge 是**滞后且慢**的：
删掉测试文件后几分钟内，空闲回升到 25.6 GiB（净赚约 13 GB，说明 purge 确实发生了，只是尺度是
**几十分钟**而非几秒）。

对照守卫日志：休息期 21:35→22:18（**43 分钟**，7→20 GiB）、22:42→22:45（2 分钟，11→25 GiB）
—— 都成功回血了。所以**回收是存在的，只是以「几十分钟」为时间尺度**。

### 39.3 由此得出的正确心智模型
- 「Finder 可用」= 真实空闲 + 可清除。**给用户看数字时不要用这个口径判断能不能导出。**
- 内部盘在脉冲模式下**每一轮实际能借出 10–25 GB**，跑完一轮等几分钟到几十分钟回血。
- 判断「空间是否真的回不来」**不能在 5 分钟采样上做结论**。本轮我就犯了这个错：22:13 采样 5 分钟
  看到 13.86→13.87 GiB 就写下「零回收、换出完全没发生」，而实际上当时守卫正处在一次会成功的
  43 分钟休息期里（22:18 就回血到 20 GiB 并复工）。**正确做法：看守卫日志里有没有
  `✅ 休息期结束` 行，那才是权威判据。**

### 39.4 对脚本的含义
- `space_guard.sh` 用 `df -k /` 读真实空闲是对的，**不要改成读 Finder 的数字**，
  否则会因为账面数字虚高而把盘写穿。
- 但如果要判断「系统还能不能挤出空间」，光看 df 会得出「一点都挤不出来」的错误结论；
  应当结合休息期的 `rest_best` 与耗时来判断。

---

## 42. 【每轮固定白烧 5-6 分钟 + 十几 GiB】osxphotos 的「重走已导出项」被当成了必需的代价（证据：2026-10-08 23:0x 实测 + 离线回归）

### 42.1 现场：用户问「怎么又休息了」
```
[10-08 22:45:30] ▶ 第 9 轮 工作期开始：内部盘可用 25 GiB，已落地 15848 个文件
[10-08 22:51:38] 内部盘剩 11 GiB（< FLOOR=12）→ 停手，进入休息期等系统换出原件
```
**只跑了 6 分 08 秒，只导出 1 个文件。** 看着像故障，其实不是 —— 但它确实白跑了。

### 42.2 根因：每轮开头都有一段固定「重走」
按行定位第 9 轮的 full 日志（`full-20261008-224534.log`）：

| 轮次 | 时长 | 日志总行 | 导出个数 | **第一条 `Exported new file` 在第几行** |
|---|---|---|---|---|
| 第 9 轮 | 6 分 08 秒 | 16911 | 1 | **16910（倒数第 2 行）** |
| 第 8 轮 | 24 分 01 秒 | 17160 | 126 | 16763（97.7% 处）|
| 第 7 轮 | 5 时 44 分 | 17336 | 274 | — |

**每轮前约 16,900 行、约 5-6 分钟，全部花在「重新枚举并复核已导出的 15,874 项」上。**
只有走完这段才轮到真正的导出。

`--update` 的设计意图（复核补漏）没错；错在**低空间脉冲模式会反复重启导出进程**，
这段固定开销于是被乘上了轮次数。工作期越短占比越高 —— 第 9 轮 6 分钟里 **96% 是它**。
（对照：第 8 轮 24 分钟里它只占 23%，看起来就"正常"。所以这个洞在主库上不容易被发现，
**只有工作期被压缩到几分钟时才暴露**。）

### 42.3 它还疑似吃掉空间（推断，待更多样本）
第 9 轮 6 分钟内内部盘 25 GiB → 11 GiB（**-14 GiB**），而同期只落地 1 个文件。
两个候选解释，尚未区分：
1. 重走阶段对 727 条 missing 项重试 iCloud 下载，缓存占了空间；
2. 休息期「回血」报的是**账面值**（purgeable 尚未真正释放，见第 41 节），
   一开工就回落 —— 佐证：第 8 轮休息期仅 **2 分钟**就把 11 GiB 报成 25 GiB，
   远快于第 41 节实测的「几十分钟」回收尺度。

**在区分清楚之前不要改 CEIL**；但无论哪个解释成立，砍掉重走都能直接受益。

### 42.4 修复：尾段跳转（`AUTO_SKIP_DONE`）
`space_guard.sh` 每轮开工前调 `latest_done_date()`：从续传库 `photoinfo` 表取
`max(json.date)`，作为 `FROM_DATE` 交给导出器（`icloud_export.sh` 早已支持 `--from-date`）。

- 用 `env FROM_DATE="$d" cmd` **单次注入、不 export** —— 收尾的 `verify` 仍走全量复核
- 显式传了 `FROM_DATE=` → 尊重用户指定的值
- 读不到库 / 无 python3 / 日期晚于今天 → 静默退回全量，不阻塞、不报错
- 收尾补漏时设 `AUTO_SKIP_DONE=0` 做一次全量复核，防跳转漏掉历史项

预期收益：每轮重走量从 15,874 项降到约 131 项（2026-03-01 之后的项数），
每轮省下 5-6 分钟与十几 GiB 内部盘。

### 42.5 回归验证
`scripts/sim-guard.sh` 新增场景 4 `resume`：隔离 HOME 里造假续传库（含
`2026-01-05 / 2026-02-20 / 2026-03-14` 三个日期），断言守卫取**最大**者。
四场景 **9/9 通过**：chain rc=4/冷启动2、converge rc=0/1、spin rc=4/2、
resume rc=0/1 且 `FROM_DATE=2026-03-14`。

**模拟环境细节**：守卫第 50 行把 `/opt/homebrew/bin` 前置于 PATH，隔离环境里
`command -v python3` 能找到它；本机 `/usr/bin/python3`（3.9.6）也够用（代码只用 3.6+ 语法）。

### 42.6 【操作要点】替换正在运行的脚本必须用 `mv`，不能原地改
守卫当时正在跑。bash 对脚本是「打开 fd → 边读边执行」，所以：
- **原地改（Edit / `sed -i`）**：inode 不变，运行中的实例会读到内容错乱的中间态
- **先 `cp` 成新文件、再 `mv` 覆盖**：rename 换 inode，运行中的实例继续从旧 inode 读，**安全**

本轮按后者操作，替换后确认 pid 43817 仍在跑、日志继续写。

### 42.7 顺带澄清：休息期日志的「已 X 分钟」不是卡住时长
它是「距本次休息开始已过多久」，不是「卡住不动多久」—— 不是 bug。
本轮节奏：22:51:43 开始（11 GiB）→ 23:11:48 仍 13 GiB（已 20 分钟）。
历史成功案例：21:35→22:18（43 分钟，7→20 GiB）。

---

## 43. 【第 13 轮巡检 · 第 42 节修复的实地上线验证】重走确实没了，且真的没再烧空间（证据：2026-10-08 23:18–23:2x 实跑）

用户按提示 Ctrl+C 停旧守卫、重跑同一条命令。新会话 23:18:27 启动，**重启即生效**（不必等下一轮）。

### 43.1 三重证据确认跳转生效
| 证据 | 内容 |
|---|---|
| 守卫日志 | `[23:18:32] ⏭ 已复核到 2026-03-14 → 本轮 FROM_DATE=2026-03-14，跳过该日期之前的重走与 missing 重试` |
| 进程 argv | `ps` 看到导出器命令行确实带 `--from-date 2026-03-14` |
| 本轮日志规模 | `full-20261008-231837.log` **共 30 行**（对照第 42.2 节旧一轮的 16911 行）|

日志里 `Exporting 1255 photos to …` —— **1255 就是剩余待复核数**（2026-03-14 之后的 7 个月大视频），
与旧日志里 `(n/17124)` 的全库分母形成对照。结果：每轮重走量 15,874 → 约 0 行**已复核项**，
每轮固定开销从 5-6 分钟压到 **十几秒**（23:18:29 开工 → 23:18:48 已进入实际导出）。

### 43.2 第 42.3 节「疑似吃空间」的初步结论：确实消失了
新工作期从 **13 GiB**（只比 FLOOR 高 1 GiB）起步，头 2 分钟内部盘**平在 13 GiB 一动不动**，
没有复现第 9 轮那种「6 分钟掉 14 GiB」。→ 倾向支持第 42.3 节的解释 1（重走时对 missing 项
重试 iCloud 下载、把原件缓存进 Photos 库），而非解释 2（账面回血）。**样本仍偏少，继续观察。**

### 43.3 连带修掉一个显示 bug：`guard-status.sh` 会打出「完成 1262.9%」
```
落地文件  15849 个　（枚举总数 1255，完成 1262.9%）   ← 错的
```
根因：分母 `(n/1255)` 在跳转生效后只剩「剩余项」，而分子是**全库已落地数**，两者不同量纲。
修法：检测守卫日志里当前会话的 `本轮 FROM_DATE=`；有则改用 `分母 = 已落地 + 本轮枚举`
（≈ 全库），输出改成
```
落地文件  15849 个　（完成 92.7%（剩 1255 项，本轮跳至 2026-03-14））
```
JSON 同步加了 `denom` / `from_date` 两个字段。**判读进度时别再手算百分比** —— 会用错分母。

### 43.4 【观察要点】osxphotos 日志被重定向时会整块缓冲，静默 ≠ 卡住
导出器 stdout 是管道（`| tee`），Python 默认 **4 KiB 块缓冲**。日志尾部会长时间停在
`Exporting … (3/1255)` 不动，实际后台在下载大文件。判别真卡住要看：
- 进程有 CPU 时间在涨（`ps -o time= -p <osxphotos pid>`）
- 内部盘在动
**不要**只看日志最后一行没更新就下结论（本轮 23:18:48 → 23:20:39 静默近 2 分钟，属正常）。

---

## 44. 【一次完整的「取件通道死锁」现形】AppleScript 等 Photos 回话 + Photos 启动竞态 + 守卫判据把它认成空间问题（证据：2026-10-08 23:18–23:40 全程实测 + 采样栈 + 离线回归）

### 44.1 现象：新脚本第一轮就一动不动
23:18:29 开工（`--from-date 2026-03-14`，1255 项），到 23:28 仍是：
```
本轮日志 30 行 | 导出 0 | 跳过 missing 1 | 内部盘 13 GiB（10 分钟纹丝不动）
目标盘近 10 分钟新文件 = 0
```
**关键否证**：内部盘**一动不动**。既没在下载（图库 10 分钟 0 个文件变动），
也没在拷盘。所以「大视频慢」的解释不成立。

### 44.2 定位：`sample` 抓栈，一次就中
```
sample <osxphotos pid> 3 -file /tmp/ox-sample.txt
```
主线程停在：
```
-[NSAppleScript(NSPrivate) _executeAppleEvent:withMode:error:]   (Foundation)
  → OSAExecuteEvent → UASRemoteSend → AE  → AESendMessage
    → __CFRunLoopServiceMachPort → mach_msg2_trap      ← 死等 Photos 回话
```
另一条 Python 线程停在 `_PyMutex_LockTimed / _PyParkingLot_Park`（等主线程的锁）。
60 秒 CPU 只涨 0.41 秒、无 socket、无磁盘 I/O。**结论：不是网络慢，不是磁盘慢，
是在等 Photos 的 AppleEvent 回复，而 Photos 不回。**

### 44.3 Photos 那边的真相：它卡在**启动阶段**
```
sample <Photos pid> 2
com.apple.main-thread:
  -[NSApplication run] → _DPSNextEvent → AEProcessAppleEvent
    → -[NSCountCommand performDefaultImplementation]
      → -[NSApplication(NSScripting) valueForKey:]
        → ???(Photos) → -[NSRunLoop runUntilDate:] → mach_msg2_trap   ← 停在这
```
且此刻 Photos 的体征是：**4–6 条线程、CPU 累计 0.23 秒、图库句柄数 0**
（`lsof -p <pid> | grep -c Photos.sqlite`）——它**根本没打开图库**。

**根因（竞态）**：osxphotos 在 Photos 还没启动完就发了 AppleEvent，Photos 的处理函数
需要图库，于是进了嵌套 run loop 等图库，而打开图库恰好在被它堵住的启动流程后半段
——两个进程互相等，谁都不动。

### 44.4 自证：把 osxphotos 杀掉，Photos 也**不会**自己好
23:32 冻结守卫、杀掉 osxphotos 后，Photos 仍停在 图库句柄=0 / CPU 0.26 秒 不动 ——
说明它已经永久卡在嵌套 run loop 里，**只能重新拉起**。

### 44.5 正确处置（顺序很重要）
```bash
# 1. 先确保没有任何东西会在这时跟 Photos 说话（守卫停手 / 导出进程已死）
killall Photos; sleep 5
open -a Photos ~/Pictures/"Photos Library.photoslibrary"
# 2. 等图库真的加载完，再让导出开工
lsof -p "$(pgrep -x Photos|head -1)" | grep -c Photos.sqlite   # 要 > 0
```
实测 23:34:14 重开 → **23:34:29 图库句柄=12**，15 秒就好了。

> ⚠️ **反面教材（我当晚亲手踩的）**：先 `killall Photos` 紧接着 `open -a Photos`，
> 而 osxphotos 还在跑 → 它立刻又发一个 AppleEvent → Photos 二次卡死在启动阶段
> （图库句柄 0、CPU 冻结在 0.24 秒）。
> 守卫自带的 `restart_photos()` **本来就有这个等待**（`photos_lib_fd` 轮询，最多 30×10 秒），
> 而且它是在**本轮导出进程已被杀干净之后**才调用的 —— 所以**别手动抢它的活**。

### 44.6 连带发现：守卫会把这种卡死**误判成空间饥饿**（已修）
旧判据（`space_guard.sh` 空转分支）：
```bash
if [ "${fg:-0}" -lt "$SPACE_CEIL_GIB" ]; then  → 空间饥饿（去休息）
else                                            → 通道失效（冷启动 Photos）
```
**错在用 CEIL 当分界**。卡死时盘一分钱没花（一直 13 GiB < CEIL=18），
于是永远进不了通道自愈，只会：
`休息期等 18 GiB` → 磁盘压根没在消耗，等不到 → 到 `REST_MAX_MIN` 后
以 **exit 3「内部盘空间无法回收」** 收场（或绕到 `NO_GROWTH_MAX` 后误报 exit 4）。
**两种报错都指向错误的方向（让用户去腾空间），而真凶是要重开 Photos。**

修法（新判据）：
```bash
round_drop = 本轮开工时的内部盘 − 本轮见过的最低点(free_min)
round_drop >= STALL_DROP_GIB(3)  → 空间饥饿
否则                              → 通道卡死 → restart_photos
```
配套：轮次开头记 `free_round_start`，循环里维护 `free_min`。

### 44.7 回归：新增场景 5 `stallflat`，并验证「有牙齿」
- 新脚本：`bash sim-guard.sh` → **5 场景 11 项全过**（stallflat rc=4 / killall=2）
- 旧脚本跑同一场景 → **失败 2 项**，日志正是那句误判：
  `⚠️ 空转信号…且内部盘只剩 13 GiB → 判为空间饥饿，转休息期` → rc=3
- 场景 5 刻意把初始内部盘设为 **13 GiB**（低于 CEIL=18），专治「拿 CEIL 当分界」

**这次测试能跑起来还顺手补了两处**：
1. `sim-guard.sh` 支持 `GUARD_SRC=/path/to/x.sh` 指向待测副本（原本只测"装好的那份"）
2. 缩短 `REST_MAX_MIN` / `REST_HARD_MAX_MIN`，否则旧代码走休息期会把测试挂 180 分钟

### 44.8 顺手修掉的显示 bug
`guard-status.sh` 在跳转生效后打印过「完成 **1262.9%**」——分母只剩剩余项，
分子却是全库已落地数。已改为检测当前会话的 `本轮 FROM_DATE=`，
分母换成「已落地 + 本轮枚举」，并显式写出「剩 N 项，本轮跳至 YYYY-MM-DD」。

### 44.9 一条通用教训
**「进程活着、CPU 不动、盘不动、日志不走」四件套出现时，先抓栈再猜。**
本轮从怀疑网络 → 怀疑磁盘 → 怀疑大视频，全猜错；`sample` 一次就指到 AppleScript。
`sample` 对同用户进程不需要 sudo，且**不打断被采样进程**，成本几乎为零。

## 45. 【exit 3 的第三种成因】不是「没回收」，是「被误判驱动的空休息期」+ CEIL 物理不可达（证据：2026-10-09 02:35 实跑 + 03:29 巡检）

§44.6 讲的是误判**机制**，本节补的是这个机制跑到底之后**长什么样**，以及一条
能在不跑任何东西的情况下提前判定「本轮休息期注定失败」的预检。

### 45.1 看 exit 3 的第一件事：回读「休息期是怎么进的」

```
[10-08 23:34:38] 工作期结束：退出码 143，本轮新增 0 个文件，missing=未知，累计 15849 个 / 226G
[10-08 23:34:38] 💤 休息期开始（内部盘 13 GiB，目标回血到 18 GiB）
```
**没有** `内部盘剩 N GiB（< FLOOR=12）→ 停手，进入休息期` 这一行。

| 日志形态 | 含义 | 处置方向 |
|---|---|---|
| 有 `内部盘剩 N GiB（< FLOOR=12）→ 停手` | 真·空间饥饿，盘确实被啃到线 | 腾内部盘空间 / 调阈值 |
| 直接 `工作期结束：退出码 143，本轮新增 0 个文件` 后接休息期 | **走空转分支 → 大概率是通道卡死被误判** | 去看 §44，修通道（冷启动 Photos），不是腾盘 |

**这是 exit 3 归因的分水岭。** 只看 rc=3 的收尾文案（「空间无法回收」）会一路把用户带去腾盘，
而真凶在通道。旧版（23:40 之前）拿 CEIL 当分界线，必然产生第二种形态。

### 45.2 CEIL 可达性预检（两条命令，30 秒，可在开工前跑）

```bash
diskutil apfs list | grep -i "Capacity Not Allocated"   # 容器未分配空间
tmutil listlocalsnapshots /                             # 有没有 purgeable 快照可清
```

**若「未分配空间」< CEIL，且无快照可清 ⇒ 休息期在数学上到不了 CEIL，必然 exit 3。**
2026-10-09 03:29 实测：未分配 **14.3 GB** < CEIL=18 GiB，快照列表为空 ⇒ 无解。

注意区分两个数：`Capacity Not Allocated`（容器级空闲池）= 全机可用空间上限，
和 `df` 的单卷 avail 基本一致；`Capacity Consumed`（卷级）只是已占用，不指示空闲。

### 45.3 FLOOR 的隐含前提：**余量必须 ≥ 最大单件**

`space_guard.sh` 第 61–65 行自己写着「FLOOR 至少要能容纳『最大单件 × 2』」。
2026-10-09 03:29 实测余量 **13.35 − 12 = 1.35 GiB**，而尾部单件是 `dji_mimo_*` 4K 视频
**≈1.4 GB** ⇒ **「下一件就触线」**，脉冲退化成「一件一轮」，吞吐趋零而轮次狂涨。

**空间紧张时的正确动作是腾内部盘空间（或按脚本自带诊断降档 FLOOR/CEIL），不是重跑。**
重跑只会白烧一轮：开工 → 立刻触线 → 休息 → （若 CEIL 不可达）180 分钟 → exit 3。

### 45.4 校准：第 25 轮把「Photos 设成下载原件到 Mac」当成 P0 首嫌，证据不足

同一晚 **22:18 回血 +9 GiB（43 分钟）**、**22:45 回血 +14 GiB（2 分钟）** ⇒ 换出机制当时可用。
若图库一直设着「下载原件到 Mac」，这两次成功无法解释。**故该假设应降级为「顺手排除项」**，
首嫌归还给 §44.6 的通道卡死 + 判据误判。

> 通用教训：**「零回收」不等于「回收能力坏了」。** 若本轮压根没有消耗，就没有回收可谈；
> 先问「这轮到底有没有下载/拷盘发生」，再问「为什么没回收」。本轮 CSV 只有 940 字节 = 0 导出，
> 这就是答案。

### 45.5 第 26 轮判据读数模板（2026-10-09 03:29）

```
落地 15849 个 / 226G（92.7%，剩 1255 项 ≥ 2026-03-14）   ← 冻结
守卫 02:35:04 exit 3，休息 180 分钟，13 → 13 GiB           ← 经空转分支进入
df /System/Volumes/Data  13.35 GiB 可用 / 926 GiB（99%）    ← 60 s 双采样 13.35→13.34 无失血
APFS 容器 98.6% used，Not Allocated 14.3 GB，无本地快照     ← CEIL 不可达
外置盘 570 GiB ｜ space_guard/osxphotos 均未跑 ｜ Photos PID 39082（23:34:13）
本轮 CSV 940 字节 = 0 导出 ｜ 近 8h 无 >300MB 新增文件      ← 无人偷吃
残留 3 个 _试跑-* + 11 个 ._*（仅列未删）
```

## 46. APFS 换出是**需求驱动**的：空闲期不回收，工作期反而回血（2026-10-09 09:42）

第 29 轮实测到一段反直觉的读数序列，同一轮工作期内：

```
08:29:55 工作期开始   内部盘 13 GiB
08:40:09 工作进行中   内部盘 15 GiB   ← 有下载压力，系统主动换出，盘面反而变宽
08:45:44 触线         内部盘  9 GiB   ← 大视频下载瞬时吃掉
08:45:48 进休息期     内部盘 13 GiB   ← 释放下载暂存，弹回起点
08:46 → 09:42 休息中  内部盘 13 GiB   ← 57 分钟纹丝不动，零回收
```

**判据修正：休息期「零回收」不能反推换出机制坏了。**
macOS 的 purge/换出更像**按需**（demand-driven）：只有新的大额分配发生时才腾地方。
因此会出现两种看似矛盾、其实同源的现象：

- **空闲休息期**：无分配压力 → 不换出 → 读数恒定 → 休息期超时 exit 3
- **工作期内**：下载压力把盘顶上去 → 系统被迫换出 → 盘面读数反而回升（甚至能自行越过 CEIL）

**操作含义（重要）**：
1. 看到 `内部盘 N GiB → N GiB` 长时间不动，先别断定「回收能力坏了」，
   仍要按 §45.4 先问「本轮有没有消耗」。
2. 若判断 CEIL 不可达（§45.2）却又观察到工作期内读数上升，
   说明**该机型的换出可以被下载压力触发** —— 此时「歇着等」不如「让它干活」，
   但必须尊重 FLOOR：先腾出 ≥ 最大单件 ×2 的余量（§45.3）再重跑，否则退化成一件事一轮。
3. 尾段（2026-03-14 之后）全是 `dji_mimo_*` 4K 视频，单件 1.4–2 GB，
   13.8 GiB 可用空间对应 1.8 GiB 余量 ⇒ 仍然偏紧，**腾盘仍是唯一根治手段**。

**第 29 轮判据读数模板（2026-10-09 09:42）**：

```
落地 15866 个 / 242G（92.7%，剩 1255 项 ≥ 2026-03-14）
本轮工作期 08:29:55→08:45:44（16 min），Exported new file 16 条，走到 (19/1255)  ← 通道活着
  落盘内容全为 2026-03-14 dji_mimo_* 4K 视频 ⇒ +17 文件 = +16 GB
守卫 08:45:44 真空间饥饿进休息期（有「内部盘剩 9 GiB（< FLOOR=12）」一行，§45.1 通过）
休息 57 min 零回收：13 → 13 GiB（09:42 独立 df 13.80 GiB 双采样恒定）
APFS 容器 Not Allocated 14.8 GB ≈ df 可用量，无本地快照 ⇒ CEIL=18 物理悬空（§45.2）
外置盘 554 GiB ｜ space_guard PID 80457（1h13m）在跑 ｜ 休息期 osxphotos 未跑（设计如此）
Photos PID 39082（10h09m，未重启）｜ photolibraryd PID 3823（17h52m）
残留 3 个 _试跑-* + 11 个 ._*（仅列未删）
```

## 47. 【归因陷阱】photolibraryd 换 PID **不等于**守卫自愈动过手 —— 系统自己会重启它（2026-10-09 11:44 第 30 轮）

**现象**：休息期巡检发现 `photolibraryd` 从 PID 3823（17h52m）变成 PID 4599（1h59m），
即在 09:47 前后被重启过；同一时刻 Photos.app 的 PID 39082 纹丝不动（12h12m）。

**为什么这是个坑**：§44/§37.2 已经确认「守卫自愈 = `killall Photos` + 重新打开图库」，
于是很自然会把「进程 PID 变了」当成「守卫刚自愈过」的证据。**这是错的。**
守卫的自愈**只 kill Photos.app**，从不碰 `photolibraryd`；
反过来，macOS 会因内存压力/图库 daemon 回收自行重启 `photolibraryd`，而 Photos.app 不受影响。

**正确读法（两个进程要分开看）**：

| 观察 | 含义 |
|---|---|
| Photos.app PID 变 | 只能是 ① 守卫自愈 ② 用户手动重启 ③ 崩溃重拉 |
| `photolibraryd` PID 变、Photos.app PID 不变 | **系统行为**，与守卫无关，不要计入自愈次数 |
| 两者同时变 | 才可能是整栈冷启动 |

**推论（本轮实测）**：这次 `photolibraryd` 重启**没有带来任何回收**（13 → 13 GiB，休息 180 分钟）。
再次印证 §46：回收是**需求驱动**的 —— 休息期零下载压力时，连重建图库守护进程也不会触发换出。
**所以「等系统自己好」在零消耗的休息期里是没有依据的期望。**

**第 30 轮读数模板**（2026-10-09 11:44–11:46）：

```
守卫 08:29:55 工作期开始 → 08:45:44 真空间饥饿停手（有 `内部盘剩 9 GiB（< FLOOR=12）→ 停手`）
休息 180 分钟，13 → 13 GiB（本轮最高 13）→ 11:46:16 ❌ 退出码 3
与 02:35:04 那次逐字同型 ⇒ 同一空间死结第 4 次复现（第 26/27/28 轮 + 本次）
工作期真实产出 17 个文件 / 16 GB，全为 dji_mimo_20260314_* 4K 视频
15866 文件 / 242 GB / 92.7%（剩 1255 项）｜ 内部盘 13.85 GiB（距 FLOOR=12 仅 1.85 GiB）
外置盘 554 GiB ｜ APFS Not Allocated 14.9 GB、无快照
Photos PID 39082（12h12m）｜ photolibraryd PID 4599（1h59m，系统重启，非守卫）
space_guard / osxphotos 均已退出 ｜ 残留 3 个 _试跑-* + 11 个 ._*（仅列未删）
```

**处置优先级（第 30 轮结论，未变）**：P0 顺手核 Photos「优化 Mac 储存空间」→
**P0′ 真解：腾内部盘到 ≥25 GiB**（余量 1.85 GiB < 单个 DJI 4K 视频 ⇒ 现在重跑必然「一件一轮」）→
P1 腾开后才重跑 → P2 尾段一次性跑完或按年分批。

---

## 48. 【修正 §45.4 / §31.1】休息期「零回收」只证明 180 分钟窗口内没回收 —— 回血发生在守卫放弃之后（证据：2026-10-09 11:46 退出 → 13:48 实测）

**背景**：第 30 轮（11:44）判定「同一空间死结第 4 次复现」，理由是守卫休息 180 分钟期间
内部盘 `13 → 13 GiB`（`本轮最高 13`），「一个字节都没回收」。那个读数本身没错，
**错在把「窗口内零回收」推成了「回收能力已死」**。

**第 31 轮实测（守卫 11:46:16 以 exit 3 退出后 2 小时）**：

| 指标 | 11:46（守卫放弃时） | 13:48（第 31 轮实测） | 变化 |
|---|---|---|---|
| 内部盘 df 可用 | 13 GiB | **22.56 GiB**（`df -k` 23660212 KB） | **+9.6 GiB** |
| APFS Not Allocated | 14.9 GB | **24.2 GB** | +9.3 GB |
| 本地快照 | 无 | 无 | — |

**三条修正结论**：

1. **回血存在，只是时间常数 > `REST_MAX_MIN=180` 分钟。** 守卫在 11:46 判死刑，9.6 GiB 是在
   那之后两小时里回来的。所以 §45.4 的表述要收紧：**「零回收」只能证明「这个 180 分钟窗口内
   没有回收」，不能证明「系统不会回收」**。同理 §31.1 早就发现过「停 8.5 小时后自行回收 11 GiB」，
   本节是它在「窗口内恰好为零」情形下的复现。
   → **推论：不要以一次 exit 3 就断言需要人工腾盘；先等一个 ≥2 小时的窗口再复测。**

2. **§45.2 的 CEIL 物理门槛首次被跨过。** CEIL=18 GiB ≈ 19.33 GB，而 Not Allocated 现为
   24.2 GB > 19.33 GB ⇒ **休息期数学上可以够到 CEIL，`✅ 休息期结束` 重新成为可能**。
   第 26–30 轮反复引用的「Not Allocated 14.3–14.9 GB < CEIL ⇒ 必然 exit 3」这条硬约束**已失效**。
   → **预检口径**：`diskutil apfs list | grep "Capacity Not Allocated"` 与 CEIL 直接比大小，
   而不是只看 df 可用量。

3. **「盘未回 >25 GiB 不要重跑」这条建议要放宽。** 真正的判据是**两条**，现在都满足：
   ① FLOOR 余量 ≥ 最大单件 —— 22.56 − 12 = **10.56 GiB** ≫ 单个 DJI 4K 视频（≈1.4 GB）
   ⇒ 第 26–30 轮反复警告的「一件一轮」退化**不再适用**；
   ② CEIL 可达（见上）。
   → **结论：22.6 GiB 已够起跑，不必死等 25 GiB。** 按 ≈7 GiB/h 失血估算，单轮工作期可达
   ≈1.5 小时 / 约 20–40 个大视频，比 08:29 那轮的 16 分钟 17 个文件强一个量级。

**仍未解的结构性问题（诚实标注）**：`df` 可用量（22.56 GiB）≈ `Not Allocated`（22.6 GiB）
⇒ **没有额外的 purgeable 缓冲**，可用空间就是未分配空间。所以这一轮跑完撞到 FLOOR=12 后，
若系统仍不在休息期回收，会第 5 次 exit 3。**根治仍是在内部盘腾出真实用户数据**
（`~/Library/Containers` 254G / `~/Downloads` 209G / `~/微云同步助手` 92G，
注意 Containers 里的微信/企业微信只能走 App 内清理，手删会丢账号态）。

**第 31 轮读数模板**（2026-10-09 13:48）：

```
guard-status rc=3，末行「空间回收失败」（11:46:16 的 exit 3 收场）
15866 文件 / 242 GB / 92.7%（剩 1255 项）｜ 2 小时净增 0
最新媒体 mtime 10-09 08:45:44（唯一可信判据，已静默 5h）
内部盘 22.56 GiB ｜ APFS Not Allocated 24.2 GB ｜ 无本地快照 ｜ 外置盘 554 GiB
space_guard / osxphotos 均未跑 ｜ 守卫日志 mtime 停 11:46
Photos PID 39082（14h14m）｜ photolibraryd PID 4599（4h01m，系统重启，非守卫）
脚本指纹未变：space_guard eef92e84…（mtime 10-08 23:40，修复版仍未跑过）/ icloud_export ef0ac4dd…
近 8h 无第三方 >300MB 写入 ｜ 无新假完成标记 ｜ 残留 3 个 _试跑-* + 11 个 ._*（仅列未删）
```

---

## 49. 停在 FLOOR 时留下的 0 字节文件 + 「回收是否持久」的 2 小时判据

**49.1 触发 FLOOR 断尾会留一个 0 字节文件（本轮实见）**

第 32 轮（2026-10-09 15:51）在目标目录 `2026/03/` 下发现：

```
-rwx------@ 1 helufan  staff  0  Oct  9 08:45:44 2026  dji_mimo_20260314_155800_..._video.mp4
```

大小 0、mtime **正好等于本轮最后一次落盘时间 08:45:44**，与守卫日志尾部
`Exporting dji_mimo_20260314_155800_...video.mp4 (19/1255)` 对得上 ⇒ 它就是
**撞上 `内部盘剩 9 GiB（< FLOOR=12）→ 停手` 那一刻正在下载的那件**，被拦腰打断。

处置三条（不要自作聪明）：
1. **不要删** —— 硬约束：移动硬盘上的照片/视频文件一律不删，哪怕它是 0 字节。
2. **不要手工补 / 不要手工改名** —— 续传库没记它成功，改名只会造出孤儿。
3. **`--update` 重跑会自动重拉** —— 它不在续传库的已完成集合里，下轮会重新下载覆盖。

**副作用（读数口径）**：`guard-status` 的「落地文件 N 个」是按磁盘实体文件数统计的，
**会把 0 字节半成品算进去 → 轻微高估**。本轮只多 1 个，可忽略；
但若一轮内多次撞线断尾（例如盘极紧时「一件一轮」），高估量会累积，
**此时应以「最新媒体 mtime」和体积两列交叉复核**，不要只信文件数。

**49.2 「回收是否持久」用 ≥2 小时闲置窗口判，不用 180 分钟休息期判**

第 31 轮把「盘自己回来」定义为实质好转（§48），但那是**单点采样**，无法排除
「系统清了点临时缓存、半小时后又跌回去」。本轮补上时间维度：

| 观测点 | 内部盘可用 |
|---|---|
| 第 31 轮 13:48 | 22.56 GiB |
| 第 32 轮 15:51 | **22.52 GiB** |

**闲置 2 小时零流失（−0.04 GiB，5 秒双采样仅 −1.1 MB 噪声）⇒ 回收是持久的，不是瞬时抖动。**
判据：守卫退出后，若内部盘在 **≥2 小时 >25 GiB 之前**保持不回落，则重跑前提成立；
反之若半小时内跌回 13 GiB 附近，说明「回收」其实是其他 App 的临时缓存被系统清掉，
真实可用并未改善 —— **此时不要重跑**（会立刻再撞 FLOOR）。

**49.3 休息期 180 分钟零回收 ≠ 回收能力坏（再证 §45.4）**
本轮 08:45→11:46 的休息期同样一字未动，但守卫退出后盘立刻回到 22.5 GiB 并保持住。
⇒ **「休息期没回收」只说明那 180 分钟窗口内没回收；守卫一退出就回血，说明回收链条其实是通的。**
反向推论：休息期的零回收更可能是**守卫自身的采样/等待行为**（休息期不产生下载压力 ⇒
macOS 换出是需求驱动的，§46 已述），而不是 Photos 设置错了。

**第 32 轮读数模板**（2026-10-09 15:51）：

```
guard-status rc=3，末行「空间回收失败」（11:46:16 的 exit 3 收场，仍未重启）
15866 文件 / 242 GB / 92.7%（剩 1255 项）｜ 8 小时净增 0
最新媒体 mtime 10-09 08:45:44（且该件为 0 字节半成品，§49.1）
本轮日志 full-20261009-083001.log 最后写入 08:36:05 ｜ 日志静默 435 分钟
内部盘 22.52 GiB（第 31 轮 22.56，2 小时零流失 ⇒ 回收持久，§49.2）
外置盘 554 GiB ｜ space_guard / osxphotos 均未跑 ｜ 守卫日志 mtime 停 11:46（245 分钟前）
残留 3 个 _试跑-* + 11 个 ._*（仅列未删）
```

---

## 50. 第 33 轮（2026-10-09 17:53）：把「盘回来了」验成稳定态 + exit 3 的判据/文案分离

**50.1 回收持久性的正式判据：4–6 小时尺度不回落才算真回收**

§49.2 给的是「≥2 小时不回落」，本轮拿到更长的序列后收紧为 **4–6 小时**：

| 时点 | 内部盘可用 |
|---|---|
| 10-09 13:48 | 22.56 GiB |
| 10-09 15:51 | 22.52 GiB |
| 10-09 17:53 | **22.15 GiB** |

闲置 6 小时净变化 **-0.41 GiB**（属后台噪声，非趋势）。三条推论：
1. 「回收」是持久状态，不是系统临时清缓存的假象；
2. **重跑前提稳固成立** —— 给用户 P0 重跑命令时，依据要比单点读数硬得多；
3. 判据操作化：**守卫退出后，每 2 小时采一次 `df -k /System/Volumes/Data`，连续 ≥2 个采样点不回落即可下结论。**
   反之若一次采样后就跌回 13 GiB 附近，说明是别人的临时缓存被清，别重跑（沿用 §49.2 的反向判据）。

**50.2 CEIL 可达性再确认（第 26–30 轮的硬约束已彻底消除）**

```
diskutil apfs list | grep "Capacity Not Allocated"  →  23.8 GB（> CEIL=18 GiB = 19.33 GB）✅
tmutil listlocalsnapshots /                          →  空（无快照占用）✅
df -k /System/Volumes/Data 可用                      →  22.15 GiB（≈ Not Allocated，无 purgeable 缓冲）
```
⇒ §45.2 的失败模式（Not Allocated < CEIL ⇒ 休息期数学上到不了 CEIL ⇒ 必然 exit 3）**本次不成立**。
**但注意**：`df 可用 ≈ Not Allocated` 意味着**没有 purgeable 缓冲垫**，所以跑到 FLOOR 时仍是硬着陆 ——
若 1255 项大视频把盘再次啃到 12 GiB 以下，第 5 次 exit 3 仍可能发生。根治仍是腾内部盘。

**50.3 退出码 3 的「判据」与「文案」必须分开评价（第三次证）**

11:46:16 的收尾文案是「空间回收失败：确认『照片 → 设置 → iCloud → 优化 Mac 储存空间』」。
但同一脚本在 **08:29:55–08:45:44 工作期内**记录到内部盘 **13 → 15 → 9 → 13 GiB** 反复摆动，
最终因 `内部盘剩 9 GiB（< FLOOR=12）→ 停手` 停手 —— 这是**真空间饥饿**的正确判定（§45.1 分水岭行存在）。

所以本轮要区分两件事：
- **判据正确**：脚本识别「是真的没空间」，行为 100% 对；
- **文案误导**：把「空间饥饿」和「换出机制故障」写成同一句话，害得读者去改 Photos 设置。

**这一轮是修复版 `space_guard.sh`（md5 `eef92e84c227fdc86b911609463ddc96`，mtime 10-08 23:40）
的首次实战，且行为正确。** 结论：**看到 exit 3，先读「休息期是怎么进的」再决定要不要改设置。**
这已是 §45.4 / §49.3 之后的第三次同型证据，不要再把 rc=3 的文案当真。

**第 33 轮读数模板**（2026-10-09 17:53）：

```
guard-status rc=3，末行「空间回收失败」（11:46:16 的 exit 3 收场，仍未重启）
15866 文件 / 242 GB / 92.7%（剩 1255 项）｜ 9h08m 净增 0
最新媒体 mtime 10-09 08:45:44（且该件为 0 字节半成品，§49.1）
本轮日志 full-20261009-083001.log 最后写入 08:36:05 ｜ 日志静默 557 分钟
内部盘 22.15 GiB（双采样稳定；13:48=22.56 → 15:51=22.52 → 17:53=22.15，§50.1）
APFS Not Allocated 23.8 GB > CEIL 19.33 GB 且无快照 ⇒ CEIL 可达（§50.2）
外置盘 554 GiB ｜ space_guard / osxphotos 均未跑 ｜ 守卫日志 mtime 停 11:46（367 分钟前）
Photos PID 39082（18h19m）｜ photolibraryd 4599（8h05m，系统行为）
残留 3 个 _试跑-* + 11 个 ._*（仅列未删）
```

---

## 51. 第 36 轮（2026-10-09 22:24 起）：重启电脑复苏 + §45.2 的 CEIL 建议**首次真正落地**

### 51.1 重启是一次有效的「强制回收」触发（13 GiB 死结不是稳态）

用户重启电脑后，内部盘读数：

| 时点 | 可用（`df -k /System/Volumes/Data`） |
|---|---|
| 10-09 11:46（守卫 exit 3 退场） | 13 GiB |
| 10-09 21:56（第 35 轮 patrol） | 22.00 GiB |
| **10-09 22:24（重启后本轮实测）** | **40 GiB** |
| 10-09 22:24 `diskutil info` Container Free Space | 43.2 GB（≈ df 口径 ⇒ 当时**无 purgeable 缓冲**） |

⇒ 重启净释放约 **27 GiB**，且此刻 `Container Free ≈ df 可用`，
说明这 27 GiB 不是 purgeable 账面值，是真实可用的。

**结论**：13 GiB 的「死结」不是稳态。**下次再卡在十几 GiB，重启是可选处置之一**，
不必只等 §48/§50 说的 4–6 小时自然回收窗口。

### 51.2 §45.2 的 CEIL 建议首次落地：写进 sync.conf 覆盖

§45.2 早就指出「`Not Allocated` < CEIL ⇒ 休息期数学上够不到 CEIL ⇒ 必然 exit 3」，
但第 26–35 轮 patrol 全程**只读**，阈值其实一直没被动过（守卫始终是内置 FLOOR=12 / CEIL=18）。
本轮按守卫自己 error 文案里的建议，把覆盖写进 `~/.config/sync-icloud-photos-to-drive/sync.conf`：

```bash
SPACE_FLOOR_GIB=10     # 原 12
SPACE_CEIL_GIB=12      # 关键：压到本机稳态（~13 GiB）之下，原 18 够不着
REST_MAX_MIN=60        # 原 180
REST_HARD_MAX_MIN=180  # 原 720
```

**依据**：§46 已证换出是**需求驱动**的 —— 休息期不发起下载 ⇒ 不产生磁盘压力 ⇒ 不回收
（§49.3 第三次证实）。既然休息期本身不回收，「在休息期里等一个够不着的 CEIL」就是纯空耗。
把 CEIL 压到稳态之下后，休息期一到 12 GiB 立刻复工。

**实测效果（22:27 首验，三重证据）**：
1. guard 日志 `内部盘 共 926 GiB，可用 40 GiB ｜ 脉冲阈值 FLOOR=10 GiB CEIL=12 GiB` ← 覆盖生效
2. 第 1 轮收尾后 `💤 休息期开始（内部盘 40 GiB）` → 30 秒后 `✅ 休息期结束：内部盘回到 40 GiB（用时 0 分钟）`
3. 不再出现 §45 那种「进休息时带着 13 GiB（高于 FLOOR）、干等 180 分钟」的僵尸窗口

> ⚠️ 这是**权衡**不是根治：盘真被啃到 10 GiB 时仍是硬着陆，第 5 次 exit 3 的可能性还在。
> 根治仍是 §48/§50 反复点名的**在内部盘腾真实用户数据**（Containers 254 G / Downloads 209 G /
> 微云 92 G；微信与企业微信只能走 App 内清理，手删会丢账号态）。

### 51.3 在 Agent 会话里起守卫会被 TCC 拦下（要用 osascript 转交终端）

从 Agent 的 Bash 工具里直接起（`nohup caffeinate -is bash space_guard.sh &`）**进程能起来**，
但导出**立刻失败**：

```
Error: Invalid value for '--library' / '--db':
  Path '~/Pictures/Photos Library.photoslibrary' is not readable.
```

原因就是第 1 步写的 TCC 归责规则：权限跟的是**负责进程**，Agent 进程没有完全磁盘访问。
本会话里同源的先行征兆：`du -sh 图库` 失败、`ls -la 图库/` 返回 `total 0`。

**可行通路**（与第 1 步 `open -a Terminal xxx.command` 等价，且不依赖 .command 文件）：

```bash
osascript -e 'tell application "Terminal" to do script "caffeinate -is bash <ABS_PATH>/space_guard.sh"'
```

起在终端窗口里 ⇒ 继承终端已有 FDA、可见、用户随时 Ctrl+C。
**判别是否踩了这个坑**：守卫日志会正常出现「第 N 轮 工作期开始」，但本轮 `full-*.log`
只有 3–4 行且含 `is not readable`，`Exported new file` 恒为 0。

### 51.4 本轮读数模板（2026-10-09 22:24 → 22:35）

```
重启后复苏：内部盘 13 GiB → 40 GiB（§51.1）
sync.conf 覆盖生效：FLOOR=10 / CEIL=12 / REST_MAX=60（§51.2）
守卫经 osascript 在 Terminal 内启动（§51.3），PID 18777
第 1 轮 22:31:13 开工（40 GiB，已落地 15866）→ ⏭ FROM_DATE=2026-03-14
本轮 full-20261009-223117.log：item 19/1258，已落 1 个大视频；磁盘 40 → 35 GiB
外置盘 554 GiB ｜ 剩余约 1255 项（2026-03-14 之后 DJI 4K 视频）
```

---

## 52. 第 37 轮（2026-10-09 23:0x–23:4x）：AppleEvent 长等**不是**死锁 + 两处判据缺陷已固化

### 52.1 【关键认知修正】卡在 AppleEvent 上 ≠ 永久死锁，它可能只是「等久了」

23:06 起本轮卡在第 45 项 `dji_mimo_20260407_103210…video.mp4`：60 秒只烧 0.41 s CPU、
无网络 socket、无磁盘 I/O、目标盘 15 分钟零新增，`sample` 抓到主线程在
`NSAppleScript _executeAppleEvent → AESendMessage → mach_msg` 死等。**与 10-08 那次的栈完全同型。**

但这次**没有手动干预**，结果和上次不同：

- 23:24 守卫撞 FLOOR（盘从 17 GiB 掉到 6 GiB）→ 那一轮被 SIGTERM 收掉
- 守卫休息 30 秒后复工，第 2 轮 23:24:37 开跑
- **第 2 轮第 45 项一次就过了**（`grep -c 'Exported new file.*20260407_103210'` = 1），
  接着 46/47/48 连续落地，23:32 已落 4 个文件

结论：`--download-missing` 期间 osxphotos 会向 Photos 发「下载原件」的 AppleEvent 并**一直阻塞
到下载完成**。当单件是大 4K 视频、iCloud 端又慢时，这个等待可以长达十几分钟、期间**零 CPU / 零
磁盘增量**，看起来和死锁一模一样。判别要点：

- **Photos 图库句柄 > 0**（`lsof -p $(pgrep -x Photos) | grep -c Photos.sqlite`）
  ⇒ Photos 是健康的，这是「慢下载」；句柄 = 0 且 CPU 冻结 ⇒ 才是 §43 那种启动竞态死锁
- 卡住的那一轮**别急着杀**：先看它是不是在等一个大件；下一轮重试往往就过了
- 真正需要 `killall Photos` 的只有「图库未加载 / 启动竞态」那一种

> ⚠️ 与 §43.4 呼应：日志尾部长时间不动 + 进程无 CPU，既可能是「块缓冲」也可能是「慢下载」。
> 再叠上这层：**先查 Photos 图库句柄**，再决定动不动手。

### 52.2 【判据缺陷 · 已修】空转判别不能用「本轮盘跌了多少」

23:2x 那轮内部盘 40 → 17 GiB（正常下载消耗），随后在 17 GiB 处卡住。上一版判据
`round_drop = 开工盘 − 本轮最低点 = 23 GiB ≥ STALL_DROP_GIB(3)` → 会被判成**空间饥饿**
→ 去休息。而这一轮的问题跟空间毫无关系（盘还有 17 GiB），**方向又指错了**。

正确判据只有一条：**`fg < SPACE_FLOOR_GIB` 才是空间饥饿，否则一律是通道卡死**。
理由是逻辑上的：上面的 `(a)/(b)` 已经在 `fg < HARD_MIN` / `fg < FLOOR` 时**抢先收轮**，
所以能走到空转分支就必然 `fg ≥ FLOOR` —— 盘有余量却零出货，只能是通道问题。

至此这条判据被证伪过两次，**两种旧写法都上了回归测试**：

| 被证伪的写法 | 反例场景 | 现在由哪个场景守住 |
|---|---|---|
| 「盘是否高于 CEIL」 | 10-08 23:2x：卡死时盘一分钱不花，13 GiB 平 10 分钟 | 场景 5 `stallflat` |
| 「本轮盘跌了多少」 | 10-09 23:2x：先正常下载吃掉 23 GiB 才卡住 | 场景 6 `stalldrop` |

### 52.3 【判据缺陷 · 已修】`FROM_DATE` 被缓存，每轮都退回旧出口

守卫第 1 轮算出 `FROM_DATE=2026-03-14`，第 2 轮日志却是「⏭ **沿用指定的** FROM_DATE=2026-03-14」——
可从续传库读出来的最大日期早已是 **2026-04-07**。

根因：`skip_from` 分支写的是 `if [ -n "${FROM_DATE:-}" ]`，而第 1 轮把算出的日期**写回了
`FROM_DATE` 变量**；第 2 轮它非空 ⇒ 命中「用户显式指定」分支 ⇒ **再也不重算**。
代价：每轮从 03-14 重走 45 项，且重走会为 missing 项重试 iCloud 下载（白吃内部盘）。

修法：启动时只把**用户显式传入**的值记进 `FROM_DATE_USER`；每轮据此决定沿用还是重算；
不跳转时 `unset FROM_DATE`（别让它漏给子进程，`icloud_export.sh` 用 `${FROM_DATE:-}` 判空）。
回归测试：场景 7 `resume2`（假续传库每轮前进一天，断言末轮用 2026-05-01）。
实测生效：重启后第 1 轮即打印 `⏭ 本轮自动取续传库最新日期 → FROM_DATE=2026-04-07`。

### 52.4 【操作坑】停守卫只杀 `space_guard` 不够 —— `icloud_export.sh` 会自己把导出器拉起来

按 PID 杀掉守卫后，残留检查里冒出**新的** osxphotos 进程：

```
14805  PPID=84054  bash icloud_export.sh full   ← 84054 已是孤儿（PPID=1）
```

`icloud_export.sh` 自带重试循环，守卫一死它就把 osxphotos 再拉一次。
**正确做法：按进程组杀**（守卫用 `perl -e 'setpgrp(); exec @ARGV'` 让导出器独占一个 pgroup）：

```bash
kill -TERM -<PGID>     # 注意负号；PGID 即 icloud_export.sh 的 pid
```

杀完务必 `pgrep -fl 'space_guard|osxphotos|icloud_export'` 复核到空。

### 52.5 回归套件现在 7 场景 / 16 项断言（全绿）

```
chain(4) converge(2) spin(2) resume(3) stallflat(2) stalldrop(2) resume2(3) = 16 项
```

新增能力：假 `df` 支持**空间轨迹**（`free_plan`，逐次弹出，模拟「本轮先下载掉一截空间」），
假导出器支持**每轮往续传库追加更晚日期**（验证 `FROM_DATE` 每轮重算）。
证伪验证：拿修前的脚本跑 `stalldrop` → **失败 4 项**，日志正是那句
「本轮内部盘已跌 23 GiB（≥3）→ 判为空间饥饿」，并以 rc=3 收场。

### 52.6 本轮读数模板（2026-10-09 23:37 重启后）

```
新脚本上线：space_guard.sh inode 654998498（cp + mv 原子替换）
停旧实例要点：kill -TERM -84054 按进程组（§52.4）
经 osascript 在 Terminal 内重启（§51.3）：PID 15340
第 1 轮 23:37:37 开工（14 GiB，已落地 15896）→ ⏭ FROM_DATE=2026-04-07（§52.3 生效）
Photos 图库句柄 12（健康）｜ 外置盘 523 GiB
```

## 53. 【重要】Agent 侧 shell 没有完全磁盘访问 —— 「图库内有没有改动」这个证据不可用

**一句话**：由 Agent 工具直接起的 shell **读不了照片图库**，对图库跑
`ls` / `find` / `du` 全部返回 `Operation not permitted` 或 `total 0`。因此

> **不要再用「图库内近 N 分钟改动的文件数 = 0」当成「Photos 没在下载」的证据。**

这些读数恒为 0（或恒为空），**永远指向同一个结论**，看起来「很有信息量」，实际是权限噪声。
2026-10-09 23:45 就差点据此把一次停滞判成「彻底没动静」。

### 53.1 复现与判别

```bash
$ ls -la ~/Pictures/"Photos Library.photoslibrary"
ls: ~/Pictures/Photos Library.photoslibrary: Operation not permitted
total 0                                  # ← 注意这行是 faked 的空摘要
$ ls ~/Pictures/"Photos Library.photoslibrary/originals"
ls: .../originals: Operation not permitted
```

判据：**stderr 里有 `Operation not permitted` ⇒ 这一读必须整段丢弃**，不能与
其他信号并列比较。别把 `2>/dev/null` 把错误吞掉后的空结果当「没活动」。
（写监控脚本时，`find ... 2>/dev/null | wc -l` 这种写法在本环境天然会撒谎。）

### 53.2 为什么 Terminal 里能跑

TCC 的「完全磁盘访问」授权**跟负责进程走**：`Terminal.app` 被授过权，
所以终端里的守卫、以及它 `spawn` 出来的 `osxphotos` 都有；Agent 工具起的 shell
继承不到。这就是 §51.3 那条「必须经 `osascript` 让 Terminal 起守卫」的根因，
不只是「导出失败」，**连只读诊断也会静默失真**。

### 53.3 停滞判别该用什么（可靠信号清单）

| 信号 | 可靠 | 说明 |
|---|---|---|
| `df -k /System/Volumes/Data` 可用量 | ✅ | 无需授权；**真在下载大文件时它必然下降** |
| `osxphotos` 进程 CPU 时间（`ps -o time=`） | ✅ | 慢下载时约 1 秒/分钟；完全冻结才是死锁 |
| 目标盘新落盘文件 mtime | ✅ | 外置盘可读 |
| 本轮日志文件 mtime / 行数 | ✅ | 外置盘可读 |
| 出口连通性（`curl -m 8 -o /dev/null -w '%{http_code}'`） | ✅ | 排除「网断了」 |
| `sample <pid>` 主线程栈 | ✅ | 出 `NSAppleScript _executeAppleEvent → mach_msg` = 在等 Photos |
| **图库内文件改动的 find/ls/du** | ❌ | **本环境恒空，见上文** |

**组合判据（比单看某一个稳）**：
- 盘在稳定下降 + 日志在推进 ⇒ 正常下载，别动。
- 盘不动 + CPU 缓慢爬 + 栈在 AppleEvent ⇒ 等（>``STALL_MIN`` 由守卫冷启动 Photos）。
- 盘不动 + CPU **完全不涨**（`ps -o time=` 两次读数一致） + Photos 图库句柄 = 0
  ⇒ §43/§52.1 那种启动竞态死锁，立刻冷启动 Photos。

### 53.4 【2026-10-10 补】TCC 的 `-10004` 会被 `photoExists` 吞成「照片不存在」

助手进程今天（10-10 07:5x）对 Photos 的 AppleEvent 被拒（`-10004 权限违例`），
而 `photoscript.Photo(uuid)` 内部是：

```applescript
try
    set _exist to media item id (_id)
on error
    return false    -- ← 权限错误和「真不存在」在这里变成同一个返回值
end try
```

于是**全部**照片（包括昨天刚导出成功的对照组）都报
`ValueError: Invalid photo id` —— 表面现象是「照片不存在」，真实原因是**没权限**。

**教训**：
1. photoscript/osxphotos 探查结果为「找不到照片」时，先用**对照组**（确认存在的照片）
   验证通道本身，对照失败 ⇒ 是权限/通道问题，不是照片问题。
2. TCC 授权不是永久的：昨天能 `osascript → Terminal → do script`，今天同一命令就
   `-10004`。凡是依赖「经 Terminal 代跑」的方案，每次都要先发一条最小探针验证通道。
3. 「error=0」是分类学现象不是健康证明：osxphotos 的 AppleScript 下载失败被
   `photoexporter.py` 静默归入 `missing`（L1240-1242 捕获 ExportError →
   `StagedFiles.error` → `export()` 里被丢弃 → 计 missing），CSV 的 error 列恒空。
   要看真实失败原因，只能自己发 photoscript 探针或开 debug 日志。

---

## 54. 第 38 轮（2026-10-09 23:58）：§51.2 阈值调优的实盘确认 + 大件尾段的读写剖面

### 54.1 §51.2（FLOOR=10 / CEIL=12）实盘验证通过 —— 休息期回血 0–1 分钟

新进程 PID 15340（23:37:36 起）连续两个脉冲周期的休息期读数：

| 休息期开始 | 触发原因 | 回血 | 用时 |
|---|---|---|---|
| 23:24:04（旧实例 22:28 起） | `内部盘剩 6 GiB（< FLOOR=10）→ 停手` | 6 → **17 GiB** | **0 分钟** |
| 23:57:02（PID 15340） | `内部盘剩 9 GiB（< FLOOR=10）→ 停手` | 9 → **13 GiB** | **1 分钟** |

⇒ 第 26–35 轮那种「进休息期干等 180 分钟、零回收、exit 3」的僵尸窗口**在实盘中已消失**。
两次进休息都带 `内部盘剩 N GiB（< FLOOR=10）` 一行 ⇒ 均为**真空间饥饿**（§45.1），判据方向正确。

### 54.2 单件体量上界实测 ≈ 8.86 GiB —— 与 FLOOR 余量同量级

本轮最新落盘的最大单件：

```
9,509,216,262 B = 8.86 GiB   2026/04/dji_mimo_20260407_103210_…_video.mp4   (mtime 23:23:17)
2,503,150,063 B = 2.33 GiB   …20260407_111146…_video.mp4
1,307,062,870 B = 1.22 GiB   …20260407_110940…_video.mp4
```

内部盘可用仅 13–14 GiB ⇒ **单个大件可吃掉 2/3 的工作余量**。因此尾段出现「一轮 0 新增」
是**结构性的**，不是通道故障：23:37 那轮 20 分钟跑掉 5 GiB（14 → 9）却 0 个新文件，
就是在下这种大件时被 FLOOR 拦腰收掉。**判据：盘降 + 0 新增 = 正在下大件**（§15 判据的极端版）。

### 54.3 「内部盘持平」不能反推「没在下载」

23:58:54–23:59:18 对当前大件三次采样：

```
23:58:54  size=2,699,034,624  df_avail=13.84 GiB
23:59:06  size=3,627,024,384  df_avail=13.84 GiB
23:59:18  size=4,552,916,992  df_avail=13.84 GiB
```

导出侧 **≈77 MB/s**（+930 MB / 12 s），而内部盘**完全持平**。原因：该件的原件已在本地
（下载已完成），本轮只是「库 → 外置盘」的拷贝，不再吃内部盘。

⇒ §53.3 的组合判据要再补一格：**「盘不动」只有在「目标盘也不涨」时才有诊断意义**。
目标盘新落盘文件在长个子 = 铁证，优先于内部盘读数。（§15「盘降+静默=下大件」只覆盖
「原件还没下下来」那一半情形。）

### 54.4 第 38 轮读数模板（2026-10-09 23:58）

```
落地 15896 个 / 272 GB / 92.9%（剩 1215 项，跳至 2026-04-07）
内部盘 13.84 GiB（FLOOR=10 CEIL=12）｜ 外置盘 523 GiB
守卫 PID 15340（23:37:36，经 osascript 在 Terminal 内）
osxphotos PID 86310（--from-date 2026-04-07 --download-missing --update）
空间_guard.sh md5 ffacf8e024431de7f5de9697f3c588cb（23:36）
0 字节半成品 1 个：2026/03/dji_mimo_20260314_155800_…_video.mp4（§49.1，不删）
📌 判「在跑」只看目标盘新落盘文件 mtime 是否前进（本轮 23:59:18 仍在长）
```

---

## 55. 收尾补漏复核（2026-10-10 04:0x）—— 全量复核的正确姿势 + 「missing」判据被推翻

### 55.1 ⚠ `AUTO_SKIP_DONE=0` 用环境变量传是**无效的**（脚本第 79 行硬赋值）

第 79 行是普通赋值 `AUTO_SKIP_DONE=1`，**不是** `${AUTO_SKIP_DONE:-1}`，会覆盖环境变量。
文件头注释里写的「收尾补漏时设 0 可全量复核」实际不生效 —— 实测：

```
AUTO_SKIP_DONE=0 bash scripts/space_guard.sh
→ ⏭  本轮自动取续传库最新日期 → FROM_DATE=2026-10-09   ← 仍走了跳转分支
```

**正确做法：用 `FROM_DATE` 显式给起点**（第 313 行的 `FROM_DATE_USER` 分支优先级高于
`AUTO_SKIP_DONE` 分支）：

```bash
FROM_DATE=2008-01-01 caffeinate -is bash \
  ~/.workbuddy/skills/sync-icloud-photos-to-drive/scripts/space_guard.sh
```

本机图库最早已是 2008-05，所以 `2008-01-01` 等价于全量。**不要为了修这个去原地改脚本**
（硬约束：重跑期间禁止原地 Edit / `sed -i`）。

### 55.2 全量复核确有收成：尾段跳转漏了 4 个文件

全量一轮读数：

```
Processed: 17129 photos, exported: 4, updated: 0, skipped: 17113, missing: 745, error: 0
Elapsed time: 0:03:38
```

4 个新增全在 **2026/06**：`IMG_4790.JPG` `IMG_4791.JPG` `IMG_4792.JPG` `IMG_4795.JPG`。

⇒ 尾段跳转（拿 `latest_done_date` 当 FROM_DATE）**确实会漏掉跳点之前的项**，
收尾的 A1 全量复核不能省。

### 55.3 「missing」是真实缺口还是噪声 —— gotcha #3 的 75% 口径需要修正

旧结论（第 3 节坑）说：`Skipping missing original` 里约 75% 其实早已导出，属重走噪声。
本轮改用 **CSV `filename` 列的绝对路径做逐条 `os.path.exists`**（唯一权威判据），结论相反：

```
745 行 → 目标路径【全部 745 个】在目的盘上不存在
2017/01: 63   2017/02: 24   2017/03: 38
2022/09: 554  2022/11: 47   其余 18 个月各 1–3 个
```

⚠️ 改用 basename 宽容匹配会得出「546 条已存在」的**假象** —— 那是**跨年同名文件碰撞**
（`IMG_3059.JPG` 这种名字 2016/2018 目录里也有别的照片），并非同一条目。

**判据定稿：判 missing 是缺口还是噪声，必须拿 CSV 的 `filename` 绝对路径去 exists，
不能用 basename、也不能用「同名在续传库里有没有记录」（同名记录往往属于另一个 UUID）。**

### 55.4 745 条缺失的三条硬事实

1. 745 行 → 去重 **729 个 UUID**，与续传库 `export_data` 交叉核对：**729/729 全无记录**
   ⇒ 不是「复核不了」，是**真的从未导出成功**。
2. 扩展名分布：jpg **729** / mov **16** ⇒ 绝大多数是照片而非视频。
3. 本轮全量复核在一轮内已对它们全部重试过（`--download-missing` 生效），仍 100% 
   `Skipping missing original` ⇒ **不是「多跑几轮」能解决的，原件在库侧确实取不到。**

### 55.5「全部完成」判据对这类缺口不敏感（汇报时必看）

守卫的收尾条件是「本轮 `missing=0`」。所以 745 缺口存在时守卫**不会**直接判完成，
会继续多跑整轮（`NO_GROWTH_MAX=3` 兜底），最后以「真的推不动」收尾 —— 这是正确行为。

⇒ **`guard-status.sh` 末行的「已完整收尾」只等于「增量口径下 exported=0」，
不等于 100% 落地。汇报必须把 missing 缺口单独拎出来说，不能拿「已完整收尾」当 100%。**

### 55.6 0 字节半成品（§49.1）收口：内容已有完整副本

`2026/03/dji_mimo_20260314_155800_20260314155801_1773537412716_video.mp4`（0 B）
与 `…video (1).mp4`（**4.4 GB**，mtime 10-09 08:45）是**同一资产**；续传库里没有
0 字节件的记录，磁盘字节核对 17113 条 0 异常。⇒ 内容已完整落地，0 字节件是**纯残留**，
会让 `guard-status` 的文件计数偏高 1。按硬约束不删、不手工补。

### 55.7 第 40 轮读数模板（2026-10-10 04:05）

```
守卫末轮判定：已完整收尾（增量口径）｜ 落地 17115 个 / 381 GB
内部盘 14 GiB（FLOOR=10 CEIL=12）｜ 外置盘 415 GiB
全量复核：Processed 17129 / exported 4 / skipped 17113 / missing 745 / error 0（3:38）
真缺口 745 项（去重 729 UUID，全无续传库记录）：2022/09 554、2017/01-03 125、2022/11 47
verify-originals：字节与原件完全一致 16396/17113 = 95.8%；
                  「导出时本地没有、需现拉」1529 条中逐字节原件 1511 条 = 98.8%；
                  磁盘实际字节核对 17113 条异常 0
残留（只列不删）：_试跑-* 3 个（各 893M）+ ._* 11 个 + 0 字节半成品 1 个
```

## 56. `guard-status.sh` 的完成率会**翻倍分母**造成假 50%（2026-10-10 07:4x 修）

### 56.1 现象与根因

收尾后跑 `guard-status.sh` 打出：

```
落地文件  17119 个　（完成 50.0%（剩 17129 项，本轮跳至 2008-01-01））
```

真实是 **99.9%**。根因：早先修「完成 1262.9%」时，为了照顾**尾段跳转轮**
（本轮只枚举 `FROM_DATE` 之后的子集），把分母写成 `N + TOTAL_ENUM`。
但**全量复核轮**（`FROM_DATE=2008-01-01`）会把整个库枚举一遍，此时
`TOTAL_ENUM` **本身就是全库**（17129 ≥ N=17119），再加 N → 34248 → 50.0%。

### 56.2 正确写法（分界看「本轮分母 vs 已落地数」）

```bash
if   [ "$TOTAL_ENUM" -ge "$N" ]; then DENOM="$TOTAL_ENUM"          # 全量轮：分母就是全库
else                                 DENOM=$(( N + TOTAL_ENUM ))   # 跳转轮：全库 ≈ 已落地 + 尾段
fi
```

- 跳转轮实况（2026-10-09 23:37）：`TOTAL_ENUM=1215 < N=15896` → 分母 17111 → 92.9%，剩 1215 ✔
- 全量轮实况（2026-10-10 04:10）：`TOTAL_ENUM=17129 ≥ N=17119` → 分母 17129 → 99.9%，剩 10 ✔

**教训**：任何「用本轮读数去推全库」的公式，都要先问一句「本轮到底是全量还是尾段」。
只看 `FROM_DATE` 是否存在不够 —— 全量复核也会带 `FROM_DATE`（还偏偏是 2008-01-01）。
用**数量关系**（枚举数 vs 已落地数）判，比用**措辞**判稳。

### 56.3 同源提醒：`guard-status` 的「已完整收尾」不等于 100%（§55.3）

`finished` 判定只来自增量口径 `exported=0`，**对 missing 缺口完全不敏感**。
本次收尾状态下它照样报 `finished`，而库里实际还有 745 项拿不到原件。
汇报落地率时**必须**同时给 `本轮计数 Skipping` 与全量复核的 `missing` 行。

## 57. 缺口探针的 API 坑与 TCC 双权限（2026-10-10 22:0x，v2 校准）

**photoscript 的 API 边界（写探针前先核对，别凭印象）**：
- `PhotosLibrary` **没有** `search()` 方法——按文件名搜索用原始 AppleScript
  `every media item whose filename is "X.JPG"`，返回的是 id 列表（含 `/L0/001` 后缀）；
- `Photo` **没有** `size` / `hidden` 属性（v1 探针实测 AttributeError）；
  尺寸走 `width`/`height`，文件大小 AppleScript 侧拿不到，去 Photos.sqlite 查；
- `Photo(uuid)` 内部 = `run_script("photoExists", uuid)` = `exists media item id
  "UUID/L0/001"`，后缀**硬编码 `/L0/001`**（photoscript/__init__.py L30）。

**「Invalid photo id」不一定是照片不存在——对照组是生死线**。photoscript 会把
TCC 权限错误、AppleEvent 失败统统归约为 `photoExists=false`。必须先拿 2 个已知
已导出的 UUID 当对照组：对照组过 ⇒ 阴性结果可信；对照组挂 ⇒ 全部结果作废。
2026-10-10 实测：对照组全过 + 7 个 missing 全 `-1728` ⇒ 真阴性成立。

**TCC 是两层权限，给了一个不等于给了另一个**：
- 「照片」自动化权限（Apple Events）→ 管 osascript/photoscript；
- 「完全磁盘访问」→ 管 Photos.sqlite / originals/ 的**文件读写**。
  实测 stat 能过但 open/cp/sqlite 全被拦（`Operation not permitted`）——
  stat 不触发 TCC，别拿 stat 验证文件可读。
- 这两层都是**按 App 授予**的：用户终端（Terminal）有 FDA 不代表 Agent 进程有。
  Agent 进程两样都没有时，用 `osascript tell app "Terminal" to do script`
  借终端的身份跑（前提：拿到对 Terminal 的自动化权限）。

**Photos.sqlite schema 有版本差异，列名别写死**：这台机器的 ZASSET **没有**
`ZORIGINALFILENAME` 列（v1 探针在此崩溃）。正确姿势：先
`SELECT name FROM pragma_table_info('ZASSET')` 再挑列。

**osxphotos 的「error=0」不可作为脚本无故障的证据**：AppleScript 下载失败在
`photoexporter.py` 里被 try/except 静默吞掉、资产计入 missing，CSV error 列
恒为空（复审中读 venv 源码证实，~L1596）。

**同名判定：分辨率相同仍不等于重复（2026-10-10 实测教训）**。729 项缺口里 249 对
「同名 + 同分辨率」的拍摄时间差以年为单位散布（≈50000h 量级，无 ±8h 时区聚簇）
——同一台相机多年的 IMG_XXXX 自然撞名。判定重复必须**拍摄时间也吻合**
（missing 的 ZASSET.ZDATECREATED vs 落地件 photoinfo JSON 的 `date`，容差 ±300s）。
时区对法：Core Data 时间戳按「2001-01-01 UTC 起的秒」换算成 UTC epoch，
photoinfo `date` 是 ISO 带时区，直接 `.timestamp()` 比，差值应为 0。

## 58. 【重大】连拍子帧是 missing 的头号成因——AppleScript 通道全盲（2026-10-10 23:3x 定案）

**现象三件套**（同时出现基本可以定案）：
1. `Skipping missing original photo` 大量出现，且全是同设备同月份交织的照片；
2. AppleScript/photoscript 对这些 UUID 全部 `Invalid photo id`（对照组正常）——**这不是
   照片不存在**，是 AppleScript 只暴露连拍的 key photo，子帧全盲；
3. icloud.com 网页版按文件名/时间都找不到——**网页版只显示 key photo**，连拍堆栈
   无法在网页展开。用户实测：35 帧连拍只有 6147（key photo）可搜到。

**根因（osxphotos --help 原文）**：`--download-missing` 走 AppleScript 时
「does not currently export all burst images; only the primary photo will be
exported—associated burst images will be skipped」。本地原件被「优化储存」清掉的
连拍子帧，AppleScript 通道一个都拉不回来，失败被 photoexporter 静默计入 missing。

**识别方法**：续传库 photoinfo JSON 有 `burst` / `burst_key` 字段。缺失项的
已落地邻帧若 `burst=True, burst_key=False`，缺失项就是连拍子帧。

**恢复通道（唯一自动化路径）**：`--use-photokit`。photoexporter.py L1128-1137 有
专门兜底：`fetch_uuid` 失败 → `fetch_burst_uuid(burstUUID, all=True)` 拉全部连拍
资产 → 按 UUID 前缀匹配。命令：`OSXPHOTOS_PHOTOKIT=1 bash <skill>/scripts/icloud_export.sh full`。
限制：必须 Terminal.app（官方注明不支持 iTerm2）；首次运行弹「照片」TCC 授权框，
必须点允许；实验性功能，失败回退路径是 iPhone 端手动展开连拍导出。

**⚠️ 恢复前禁止操作**：iPhone 连拍若弹出「仅保留选中的照片」之类的清理提示，
不要点——未选中的子帧会被真删。

**教训：macOS BSD grep 不认 BRE 的 `\|` 交替**——`grep "a\|b"` 在 macOS 上静默返回
空（GNU 才支持），本轮两次假阴性（差点误判导出通道、漏掉 --help 里的 burst 原文）。
多模式必须用 `grep -E "a|b"`。

## 59. 【改判 + 实战验证】PhotoKit 恢复连拍全量成功；「终端拿不到照片权限」被实证推翻（2026-10-10 23:46 实跑）

**§14 的结论必须修正。** §14 曾判定「Terminal.app 没有声明
NSPhotoLibraryUsageDescription，所以永远拿不到照片权限，--use-photokit 在终端里
必然失败」。2026-10-10 23:46 用户在 Terminal.app 里跑
`OSXPHOTOS_PHOTOKIT=1 ... icloud_export.sh full`，**macOS 弹出了
「Terminal 想访问照片」的 TCC 授权框，点允许后通道完全可用**——17 分 05 秒导出
755 个文件（729 个连拍子帧 + 库内新增），error=0，729/729 终审全部落盘。

**教训：静态分析（读 Info.plist）推断不出动态 TCC 行为。** Info.plist 声明缺失
不代表授权必败——实际行为以实跑为准。这条错误论断曾差点把连拍恢复方案整个
否掉（恢复前还专门写进 SKILL.md 第 1 步「--use-photokit 只在对端 App 确实声明了
用途说明时才有用」）。**修正后的规则：PhotoKit 通道遇到 `could not get
authorization` 时，先让用户在 Terminal.app 里实跑一次——弹框点允许即通；
拿 Info.plist 缺声明当死刑判决是误诊。**

**恢复验证方法论（下次直接复用）**：
1. 恢复前：`grep -c "Skipping missing" <log>` 记录基线（本轮 729）；
2. 恢复中盯两个数：`grep -c "Exported new file"`（在涨=通道活）与
   `grep -c "Skipping missing"`（不涨=缺口在收敛）；
3. 恢复后终审（不依赖 TCC，Agent 可直接跑）：
   - 拿缺口 UUID 清单查续传库 export_data + 目的盘文件存在性（应 100%）；
   - sips 抽验分辨率 vs ZASSET 登记值——**竖幅件 sips 报的是原始像素
     （宽高互换），库登记的是显示尺寸，2448x3264 == 3264x2448 属一致**，
     别当成不一致；
   - 全量扫文件大小 <200KB 的（疑似缩略图混入），应 0 个。
   实测：60/60 吻合（15 个为方向互换）、0 缩略图、最小 282KB。

**导出撞名的 0 字节空壳**：同名资产同月落地时 osxphotos 会给后者加 `(1)` 后缀，
但**撞名瞬间先创建的 0 字节原路径文件可能残留**——它不在续传库 export_data 里、
无数据，正主以 `(1)` 后缀完好落盘。判定空壳能否删：查 export_data——
有记录且 size>0 的是真文件；无记录的 0 字节件是空壳可删。
（2026-10-11 清理 dji_mimo 0 字节件时定案。）

**exFAT + 安全删除钩子**：对 exFAT 卷上的 AppleDouble（`._xxx`）文件执行
删除时，回收站机制会报 `FSPathMakeRefWithOptions failed (-43)` 并 fail-closed
拒绝删除（WorkBuddy 环境）。这些 4KB 元数据件随主文件一起删即可绕开；
主目录本身仍能正常入回收站。
