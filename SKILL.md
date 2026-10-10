---
name: sync-icloud-photos-to-drive
description: 把 iCloud 照片/视频库（几十到几百 GB）完整导出到外置硬盘，含全流程六阶段：目标盘体检、macOS 权限配置、osxphotos 导出与续传、低空间脉冲模式、三层完整性校验、缺口核查与连拍(Burst)子帧恢复。当用户说「导出 iCloud 照片到移动硬盘」「备份 iCloud 相册到外接盘」「把照片和视频从 iCloud 拷出来」「导出报 missing 怎么办」「这块硬盘够不够装我的照片」时使用。关键词：iCloud 照片导出、照片备份到硬盘、osxphotos、连拍导出、missing 恢复、移动硬盘存照片。
agent_created: true
---

# iCloud 照片/视频 → 外置硬盘

## 用途

将 iCloud 照片图库中的原始照片与视频导出到外置硬盘，用于本地归档或迁移。
产出是**散文件**（保留原始格式与 EXIF），不是 `.photoslibrary` 整包。

**成功的定义不是「跑完命令」，而是「账平」**：
`图库登记资产数 == 目的盘落地文件数 + 逐项定性的缺口清单`。
导出结束只是上半场；缺口核查与终审（第 4-6 步）是流程的一部分，不要跳过。

## 配置（一次性，之后所有命令都不用带参数）

配置文件：`~/.config/sync-icloud-photos-to-drive/sync.conf`

| 变量 | 含义 |
|---|---|
| `SRC_LIBRARY` | **源端**。要同步的 `.photoslibrary` 路径，必须显式指定（防导错库） |
| `DEST_VOLUME` | **目的端**。外置盘挂载点，如 `/Volumes/Expansion` |
| `DEST_SUBDIR` | 导出根目录名。**必须保持稳定**：续传库以它为名（放内部盘 `~/.cache/osxphotos/`），改名等于重导 |
| `DIR_TEMPLATE` | 落盘结构，默认 `{created.year}/{created.mm}` |
| `DOWNLOAD_MISSING` | `1` = 本地缺原图时去 iCloud 拉；图库为「优化 Mac 存储」必须为 1 |
| `FS_TIMEOUT` | 单次文件系统调用超时秒数，默认 `8` |

`--library` 对应的 `SRC_LIBRARY` **必须写在子命令之后**（它是子命令级选项，
`osxphotos --library X info` 会报 `No such option`）。改完配置直接重跑命令即可，
`SYNC_CONF=<路径>` 可指向别的配置。

## 命令入口（一次性）

```bash
ln -sf ~/.workbuddy/skills/sync-icloud-photos-to-drive/scripts/icloud_export.sh \
       ~/.local/bin/sync-icloud-photos
```

用符号链接而不是拷贝，保证实现只有 skill 里这一份。不装入口就用
`bash scripts/icloud_export.sh`。**不要在工作区另建转发封装。**

## 执行顺序（六阶段，按此顺序，不要跳步）

### 第 0 步：核对配置 + 体检目标盘

```bash
sync-icloud-photos conf                             # 打印生效配置
bash scripts/drive_check.sh /Volumes/xxx --speed    # 盘体检
```

判读：`read-only` → 停止解决可写性；可用 < 300 GiB → 换盘；exFAT → 只能导散文件
（不能拷 `.photoslibrary` 整包）；NTFS → macOS 原生只读。

### 第 1 步：确认权限（三套互相独立的 TCC，缺一半路失败）

| 权限 | 位置（系统设置 → 隐私与安全性） | 谁需要 |
|---|---|---|
| 完全磁盘访问 | 完全磁盘访问 | 调用脚本的 App |
| 照片 | 照片 | PhotoKit 通道（连拍恢复） |
| 自动化 → 控制「照片」 | 自动化 | 默认 AppleScript 下载通道 |

三条铁律：
1. **TCC 按「负责进程」归责**：终端里跑就给「终端」授权；在 WorkBuddy / iTerm /
   VS Code 里跑就给那个 App。搞错对象等于没授权。改完**完全退出并重开该 App**。
2. **TCC 是两层权限**：「照片」自动化权限（Apple Events，管 osascript/photoscript）
   和完全磁盘访问（管 Photos.sqlite / originals/ 的文件读写）互相独立，
   给了一个不等于给了另一个。验证文件可读**别用 stat**（stat 不触发 TCC 会假通过），
   用真实 open/sqlite 读验证。
3. **PhotoKit 通道的「照片」权限以实跑为准**：在 Terminal.app 里跑
   `--use-photokit` 时 macOS 会弹「Terminal 想访问照片」授权框，点允许即通。
   不要拿 `Info.plist` 缺 `NSPhotoLibraryUsageDescription` 当死刑判决——该静态
   判定已被实战推翻（2026-10-10 连拍恢复 729/729 全量成功）。

Agent 自身无权限时的自治通路：`open -a Terminal /path/to/x.command` 或
`osascript 'tell application "Terminal" to do script "…"'` 把活儿转交给终端
（继承终端权限、脱离会话、能弹 GUI 授权框）。注意 Terminal 自动化权限可能被
系统中途重置（osascript 报 -10004），届时需用户重新授权。

### 第 2 步：安装工具 + 打补丁（跳了会静默丢大文件）

```bash
pipx install osxphotos        # Homebrew core 没有此 formula，别走 brew
bash scripts/apply-patches.sh # 幂等，含语法自检
```

4 个必需补丁（原版行为 → 后果）：
① `script_loader.py` 超时 killall Photos → Photos 重开不带图库、通道永久死亡；
② `photoexporter.py` 连续 10 错重启 Photos → 同上；③④ AppleScript 超时 120s
且**把 iCloud 下载耗时算在内** → >300MB 视频必然失败（补丁抬到 14400s）。

⚠️ `pipx upgrade osxphotos` 覆盖全部补丁，升级后必须重跑 `apply-patches.sh`，
且补丁只对新启动的进程生效。

### 第 3 步：跑四段式导出

```bash
sync-icloud-photos probe     # 读图库统计：总量 / 缺原件数 / 是否系统图库
sync-icloud-photos test      # 试跑 50 项，人工确认：年/月分层、原件非缩略图、
                             # Live Photo 的 HEIC+MOV 成对、预览能打开
sync-icloud-photos full      # 全量，可反复运行，自动续传（--update + 续传库）
sync-icloud-photos verify    # 完整性核对
```

内部盘装不下整库时用**脉冲模式**（见下节）。长任务不要挂在 Agent 会话里。

### 第 4 步：缺口核查（导出后必做，missing 的定性）

导出日志里出现 `Skipping missing original photo` ≠ 照片丢失。**九成是连拍子帧**——
`--download-missing` 的 AppleScript 通道对连拍子帧结构性失明（官方帮助原文：
「only the primary photo will be exported—associated burst images will be
skipped」），icloud.com 网页版同样只显示 key photo。

**定性流程**（先查最常见的那一种，别一上来就下「丢失」结论）：

1. 跑探针：`bash scripts/run_probe.sh`（需 TCC 权限，在终端跑；输出
   `/tmp/probe_out.txt` + `/tmp/missing_uuids.tsv`）
2. 按下表定性，**对照组（2 个已成功导出 UUID）必须全过，结果才可信**——
   photoscript 会把权限错误吞成 `Invalid photo id`：

| 定性 | 证据 | 处置 |
|---|---|---|
| **连拍子帧（最常见）** | 缺失项邻帧 `burst=True, burst_key=False`；icloud.com 只能搜到该连拍 key photo；AppleScript 对子帧 `Invalid photo id`（但对照组正常） | **照片在 iCloud 里是安全的** → 第 5 步 PhotoKit 恢复 |
| Photos 应用还找得到 | AppleScript `exists media item id` 返回 true | photoscript 补导出，一轮归零 |
| 真丢失 | 连拍排除 + PhotoKit 也导不出 + 设备端连拍里也没有 | 去别的设备/时间机器备份找 |

**三条判定纪律**（每条都是用误判换来的）：
- AppleScript「Invalid photo id」≠ 照片不存在（连拍盲区伪装成不存在）；
- icloud.com 搜不到连拍子帧是正常行为，不能当「云端没有」的证据；
- 同名判定双判据缺一不可：分辨率一致 **且** 拍摄时间吻合（±300s）。
  实测 249 对「同名同分辨率」全是同相机跨年撞名，不是重复。

### 第 5 步：连拍恢复（PhotoKit 通道）

```bash
# 必须在 Terminal.app 里跑（--use-photokit 不支持 iTerm2）；
# 首次运行弹「Terminal 想访问照片」授权框，必须点允许
OSXPHOTOS_PHOTOKIT=1 caffeinate -is bash \
  ~/.workbuddy/skills/sync-icloud-photos-to-drive/scripts/icloud_export.sh full
```

已导出的自动跳过（`--update`），只补缺口。恢复中盯两个数：
`grep -c "Exported new file" <该轮log>`（在涨 = 通道活）、
`grep -c "Skipping missing" <该轮log>`（不涨 = 缺口在收敛）。

⚠️ 恢复前提醒用户：iPhone 上若弹出「仅保留选中的照片」类清理提示，**不要点**
（会真删未选中子帧）。

### 第 6 步：终审清点（不依赖 TCC，Agent 可直接跑）

三件套，全部通过才算结案：

1. **落盘核对**：缺口 UUID 清单逐一查续传库 `export_data` + 目的盘文件存在性，
   应 100%（参考实现：本轮终审用 sqlite 读 `~/.cache/osxphotos/<DEST_SUBDIR>-export.db`）
2. **分辨率抽验**：sips 抽验 vs ZASSET 登记值——**竖幅件 sips 报原始像素
   （宽高互换），库登记显示尺寸，`2448x3264 == 3264x2448` 属一致**，别误报
3. **缩略图扫描**：全量扫 < 200KB 的恢复件，应 0 个

结案报告给三个数：落地文件总数、缺口找回数（如 729/729）、遗留项及定性。

## 低空间模式：脉冲式导出（内部盘腾不出整库空间时）

**背景**：取原件链路是 iCloud → 内部盘（图库）→ 外置盘。图库必须留内部盘
（exFAT 装不了 `.photoslibrary`），但不需要整库等大的空闲——只需要有界工作集。
原件换出由磁盘压力驱动、小时级回收（≈1.3 GiB/h），所以把导出切成脉冲：
跑一段 → 停手等系统回收 → 再跑。

```bash
# 在用户终端里跑（要完全磁盘访问）
bash scripts/space_guard.sh            # 等盘 → 等 Photos → 脉冲循环 → 最终核对
bash scripts/space_guard.sh --dry-run  # 只体检 + 打印阈值
bash scripts/guard-status.sh           # 查进度（只读，随时可跑）；--json 供定时任务
```

**前置设置**：照片 App → 设置 → iCloud → 勾选「iCloud 照片」+ **优化 Mac 储存空间**。
选「下载原件到 Mac」则原件永不换出，脉冲卡死在第一个休息期。
「优化」不会拿到压缩件——iCloud 侧永远存全分辨率原件，`--download-missing`
保证导的是原件（已实证 4922 条中 1489 条 iCloud 现拉件 99.8% 逐字节一致，
复核跑 `scripts/verify-originals.sh`）。

**更划算的顺序**：能从微信/企业微信/微云的存储管理里腾出几十 GB 就优先腾
——一次性动作，导出几乎不间断；腾不出再退到脉冲（保底而非优选）。

**阈值**（`sync.conf` 可覆盖，**先 grep 一遍 sync.conf 再按默认值推导**——本机已覆盖）：

```bash
SPACE_FLOOR_GIB=12      # 工作期跌到这里停手；至少要装下「最大单件 × 2」
SPACE_CEIL_GIB=18       # 休息期回血到这里复工；不得高于内部盘稳态可用（否则永不可达）
SPACE_HARD_MIN_GIB=6    # 绝对下限，跌破立即无条件停
REST_MAX_MIN=180        # 休息期上限（分钟）
STALL_MIN=30            # 连续零产出判空转
AUTO_SKIP_DONE=1        # 每轮重算 FROM_DATE 跳过重走；收尾补漏时置 0 做全量复核
```

**空转判据（唯一正确口径，旧写法已被证伪两次）**：
`可用 < FLOOR → 空间饥饿（休息）；否则 → 通道卡死（冷启动 Photos）`。
不要用「盘是否高于 CEIL」或「本轮盘跌了多少」判断。

**退出码先核对再动手**：
- 4「通道死锁」一半是误报——先数本轮 `Exported new file`：成百上千 = 误报，
  直接重跑守卫，**别动 Photos、别重启 Mac**；确实 ≈0 才按重开照片 → 重启 →
  换 PhotoKit 顺序处置
- 3「空间无法回收」先看休息期是否其实有回收（只是没到 CEIL）→ 调低阈值即可

**腾不出 8 GiB 时退到分批**（不删续传库，按 UUID 记账，各批互不干扰）：

```bash
ONLY_PHOTOS=1 sync-icloud-photos full                 # 先导图片
ONLY_MOVIES=1 sync-icloud-photos full                 # 再导视频
FROM_DATE=2018-01-01 TO_DATE=2019-01-01 sync-icloud-photos full  # 按年切片
MAX_ITEMS=200 sync-icloud-photos full                 # 小口试水
```

## 排障

**按症状查 `references/troubleshooting.md`（症状 → 根因 → 处置 → gotchas 深读）**，
覆盖七类共 40+ 条。最高频的四条：

| 症状 | 一句话处置 |
|---|---|
| 一跑就崩 `attempt to write a readonly database` | exFAT 不支持 SQLite 锁（非权限问题）——历史库放内部盘即解 |
| 逐项 Skipping missing、一个字节都下不来 | Photos 假死：`lsof -p <pid> \| grep -c Photos.sqlite` 为 0 确诊 → killall 全家 → `open -a Photos <图库>` |
| 命令永久挂死 | `df -k <卷>` 阻塞而 `mount` 秒回 = 卷 FS 卡死 → 强制卸载 → 拔插 |
| 日志尾部十几分钟不动 | 不一定是卡死（管道块缓冲）——看进程 CPU 时间和内部盘动静 |

注意 `probe` 成功不代表通道可用（它直读 SQLite 绕过 Photos.app）。

## 关键约束

**只读图库。** 全程不得写入或删除照片图库内容，导出只往目标盘写。

**不要用 icloudpd。** 已被 Homebrew 标记 deprecated 且上游疑似被入侵（§1）。

**不要在导出运行中改 `space_guard.sh` / `icloud_export.sh`。** 运行中的实例用
启动时载入的旧版，且截断重写会让它读到半截内容；改完必须重启守卫。

**macOS BSD grep 不认 `\|` 交替**——`grep "a\|b"` 静默返回空（GNU 才支持），
多模式必须 `grep -E "a|b"`。曾两次假阴性带偏结论。

**`set -o pipefail` 下不要 `cmd | head -1`**（SIGPIPE 竞态）；**改脚本不要
`sed -i ''`**（本机 sed 是 toybox shim，报错但改对了）；bash 变量引用一律
`"${VAR}"`（bash 3.2 会把 UTF-8 高位字节并进变量名，跑 `lint-nonascii-vars.sh` 检查）。

**不做唯一备份。** USB 桥接盘读不到 SMART。完成后提醒用户关键内容再存一份（3-2-1）。

## 常用变体

| 需求 | 做法 |
|---|---|
| 只导视频 / 图片 | `ONLY_MOVIES=1` / `ONLY_PHOTOS=1`（勿同开） |
| 只导某时间段 | `FROM_DATE=… TO_DATE=…` |
| 保留相册结构 | `DIR_TEMPLATE` 改 `{folder_album}`（多相册归属导多份） |
| 留元数据 | 加 `--sidecar xmp` |
| AppleScript 通道不稳 / 恢复连拍 | `OSXPHOTOS_PHOTOKIT=1`（Terminal.app + 照片权限） |
| 临时换盘 / 换配置 | 位置参数 / `SYNC_CONF=<路径>` |

参数全量清单见 `references/osxphotos-cli.md`。

## 完整性校验（四层，由省事到严格）

1. `scripts/verify-originals.sh`：续传库 `original_filesize` vs 导出字节逐条比对
   （注意 Live Photo 口径：别拿 .mov 字节比 JPG 原件尺寸）
2. `sync-icloud-photos verify`：`--dry-run --update` 输出 `0 exported` 即拉全
3. 文件数 + 总体积对照 `probe` 报告（**文件数 ≠ 资产数**：Live Photo 一个资产两个文件）
4. `_导出报告/export-*.csv` 逐行核对——但 **error 列恒为空不能当「无故障」证据**
   （AppleScript 下载失败被静默吞进 missing）

## 交付话术

向用户交代结果时，必须说清四件事：

1. **导到哪里**：路径与目录结构
2. **账平不平**：落地数 vs 图库登记数，缺口几项、定性是什么（连拍已恢复 / 真丢失 / 其他）
3. **怎么续**：中断后重跑同一条命令即可；续传库在 `~/.cache/osxphotos/`（放内部盘），**不要删**
4. **风险边界**：这块盘不做唯一备份；拔盘先 eject；exFAT 断电易损

## 资源索引

| 文件 | 内容 |
|---|---|
| `scripts/icloud_export.sh` | 配置加载 + 六段式驱动 `conf/doctor/probe/test/full/verify` + 切片过滤 |
| `scripts/space_guard.sh` | 低空间脉冲监管器（工作/休息交替，永不写假完成标记） |
| `scripts/guard-status.sh` | 只读进度体检：进度 + 本轮计数 + 速率 + 误报判别 |
| `scripts/sim-guard.sh` | 脉冲监管器离线回归测试（七场景，不碰真实图库） |
| `scripts/drive_check.sh` | 目标盘体检（只读，`--speed` 才写盘） |
| `scripts/apply-patches.sh` | osxphotos 4 个必需补丁（幂等；`pipx upgrade` 后必跑） |
| `scripts/probe_missing.py` + `run_probe.sh` | 缺口探针（v2）：三路验证 + 对照组 + 同名双判据；`LOG=… DB=…` 可覆盖路径 |
| `scripts/verify-originals.sh` | 离线原件性核验（续传库 vs 导出字节） |
| `scripts/lint-nonascii-vars.sh` | bash 3.2 UTF-8 变量陷阱静态检查 |
| `references/troubleshooting.md` | **症状速查表**：七类 40+ 条「症状 → 根因 → 处置 → gotchas § 深读」 |
| `references/gotchas.md` | 59 节陷阱战史（编年，含证据）；检索模式见 troubleshooting.md 末尾 |
| `references/osxphotos-cli.md` | 参数全清单、目录模板字段、权限要求 |

机外配置文件（不进本目录、不进分发包）：
`~/.config/sync-icloud-photos-to-drive/sync.conf`
