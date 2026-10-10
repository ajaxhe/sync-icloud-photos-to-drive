# 症状速查表：按现象找答案

用法：按工作阶段定位症状 → 执行处置 → 需要完整证据链与复盘时，按 `§n` 编号去读
`gotchas.md` 对应节。本表是全项目（2026-10-05 至 10-11，38 轮巡检 + 一次 729 张
连拍恢复实战）的教训蒸馏，每条都付出过真实代价。

## A. 开工前（环境与权限）

| 症状 | 根因 | 处置 | 深读 |
|---|---|---|---|
| `probe` 报 `PermissionError: [Errno 1]`（退出码 3） | 调用方 App 没有完全磁盘访问 | 系统设置 → 隐私与安全性 → 完全磁盘访问 → 给**调用脚本的 App**（终端里跑就给终端）授权 → **完全退出重开该 App** | §5、§5b |
| `could not get authorization to access Photos library` | 「照片」权限未授 | 在 Terminal.app 里实跑一次 `--use-photokit`，弹 TCC 框点允许即通。**不要**拿 `Info.plist` 缺 `NSPhotoLibraryUsageDescription` 当死刑判决——该静态判定已被实证推翻 | §59 |
| AppleEvent `-1712` 超时 / 整段挂死 | 自动化 → 控制「照片」权限缺失 | 给调用方 App 授「自动化 → 照片」权限 | §5b、§13 |
| `stat` 能过但 `open`/`cp`/`sqlite3` 报 `Operation not permitted` | TCC 文件权限（FDA）缺失——**stat 不触发 TCC，会假通过** | 换用真实读操作验证可读性；给 FDA | §57 |
| osascript 对 Photos 报 `-10004` | 当前后台进程的自动化权限被系统重置（会话中途可能发生） | 换用户终端跑，或重新授权 | §57 |
| photoscript 报 `Invalid photo id` 但照片明明在 | photoscript 把权限错误/连拍盲区统统吞成这个报错 | **必须设对照组**（拿 2 个已导出 UUID 验证链路），对照组挂了结果全部作废 | §57、§58 |

## B. 安装与工具

| 症状 | 根因 | 处置 | 深读 |
|---|---|---|---|
| `brew install osxphotos` 失败 | Homebrew core 无此 formula | `pipx install osxphotos` | — |
| 想用 icloudpd | 已被 Homebrew 标记 deprecated，上游疑似被入侵 | 不用，只用 osxphotos | §1 |
| `osxphotos --library X info` 报 `No such option` | `--library` 是子命令级选项 | 写在子命令之后：`osxphotos info --library X` | §5c |
| `--no-version-check` 报错 | 0.77.2 里未注册到 export/info | 用环境变量 `OSXPHOTOS_NO_VERSION_CHECK=1` | §5c |
| `pipx upgrade osxphotos` 之后行为回退（killall Photos / 超时 120s 复现） | 升级覆盖了 4 个本地补丁 | 升级后必须重跑 `apply-patches.sh`，并重启正在跑的进程 | §23、§25 |
| 大视频（>300MB）导出必失败 | AppleScript `with timeout` 默认 120s 且**把 iCloud 下载耗时算在内** | 补丁④已把下限抬到 14400s；确认补丁在位 | §25 |

## C. 导出过程中

| 症状 | 根因 | 处置 | 深读 |
|---|---|---|---|
| 一跑就崩 `attempt to write a readonly database` | exFAT（FSKit 托管）不支持 SQLite 文件锁，**不是权限问题** | 导出历史库放内部盘（`EXPORT_DB_DIR="$HOME/.cache/osxphotos"`），osxphotos 的 different-directory 警告无害 | §21 |
| 逐项 `Skipping missing original photo`，一个字节都下不来 | Photos.app「进程活着但图库未打开」假死 | `lsof -p <pid> \| grep -c Photos.sqlite` 为 0 即确诊 → `killall -9 Photos photolibraryd photoanalysisd mediaanalysisd` → `open -a Photos <图库路径>` → 等 lsof 计数 >0 | §19 |
| 日志尾部十几分钟不动 | **不一定是卡死**：stdout 管道 4KiB 块缓冲，下载大视频时整块憋着 | 看进程 CPU 时间在不在涨、内部盘在不在动，别只看最后一行 | §43.4 |
| `Skipping missing` 洪水（数百条） | ~75% 是「已导出但原件不在本地、复核不了」的重走噪声 | 唯一可靠指标：`grep -c "Exported new file" <该轮log>`。在涨=通道活，等着 | §22、§36 |
| 退出码 4「通道死锁」 | 一半是误报（判据口径旧） | 先数本轮 `Exported new file`：成百上千 → 直接重跑守卫，**别动 Photos、别重启 Mac**；确实 ≈0 → 按重开照片 → 重启 → 换 PhotoKit 顺序 | §36、§37 |
| Photos 被神秘 killall、下载通道永久死亡 | osxphotos 原版自毁行为（超时/连续错 → killall Photos） | 补丁①②已摘除；确认补丁在位 | §23 |
| 命令永久挂死不报错 | 卷文件系统无响应（USB 桥接休眠/掉线残留） | 分层测试：`mount`/`diskutil list` 秒回但 `df -k <卷>` 阻塞 = FS 卡死 → 强制卸载 → 拔插 → `diskutil verifyVolume` | §10 |
| Finder 显示可用空间比 df 大一截 | Finder 数字含 purgeable，不能当即时可用 | 以 `df` 为准 | §41 |

## D. 空间与脉冲模式

| 症状 | 根因 | 处置 | 深读 |
|---|---|---|---|
| 休息期一个字节都不回收 | 图库设了「下载原件到 Mac」，原件永不换出 | 改为「优化 Mac 储存空间」 | §17 |
| 休息期干等到上限、exit 3 | `SPACE_CEIL_GIB` 高于内部盘稳态可用，物理不可达 | 把 FLOOR/CEIL 压到稳态之下（本机 10/12） | §45、§51 |
| 空转时该判「空间饥饿」还是「通道卡死」 | 两种旧判据（对 CEIL / 看盘跌幅）都被证伪过 | 唯一正确口径：`fg < SPACE_FLOOR_GIB → 空间饥饿；否则 → 通道卡死（冷启动 Photos）` | §44、§46 |
| 每轮开头白烧 5-6 分钟、十几 GiB | osxphotos 每轮从第 1 项重新枚举复核 | `AUTO_SKIP_DONE=1`（每轮重算 FROM_DATE）；**收尾补漏时置 0** 做一次全量复核 | §42、§55 |
| 守卫写了「完成」但实际没导完 | 旧版低盘中止分支写假完成标记 | 新版 space_guard 三条硬保证之一就是永不写假完成；旧 autopilot 已作废 | §26、§27 |

## E. 导出完成后（核验）

| 症状 | 根因 | 处置 | 深读 |
|---|---|---|---|
| verify-originals 报出「导出小于原件」的异常条目 | 多为 Live Photo 口径错配（拿 .mov 字节比 JPG 原件尺寸） | 逐条看配对：Live Photo 的 HEIC+MOV 都在且原件一致 = 无损 | §35 |
| `exported: N` 数字虚高 | 收尾校验把历史累计当本轮产出 | 看本轮 log 的 `Exported new file` 计数，不看跨轮累加 | §27 |
| 完成率显示 50% 但文件都在 | guard-status 全量枚举轮把分母算成「已落地+本轮枚举」翻倍 | 已修；对不上时先查 `guard-status.sh` 分母口径 | §56 |
| 目的盘上发现 0 字节文件 | 导出撞名（`(1)` 后缀重命名）残留的空壳 | 查续传库 export_data：**无记录 = 空壳可删；有记录 = 源头就坏，另案处理** | §59 |
| 统计文件数偏多 | exFAT 每个文件都有 `._` AppleDouble 伴生件 | 统计时排除 `._*`；删除它们会触发回收站 -43 fail-closed，随主文件一起删 | §59 |

## F. 缺口定性（missing 探针与连拍）⚠️ 本项目最大教训区

| 症状 | 根因 | 处置 | 深读 |
|---|---|---|---|
| 大量 missing + AppleScript 全部寻址失败 + icloud.com 也搜不到 | **九成是连拍子帧**：AppleScript 与网页版都只暴露 key photo | **先查连拍再下「丢失」结论**：续传库邻帧 `burst=True, burst_key=False` 即证实。恢复：`OSXPHOTOS_PHOTOKIT=1` 重跑（Terminal.app，首次弹照片权限框点允许） | §58、§59 |
| 同名文件已导出，能否判定缺失项「其实拿到了」 | 同名 ≠ 同照片：相机 IMG_XXXX 跨年/跨设备撞名 | 双判据缺一不可：分辨率一致 **且** 拍摄时间吻合（±300s）。实测 249 对「同名同分辨率」全是跨年撞名 | §57 |
| ZASSET 有记录但文件找不到，想判「幽灵记录/真丢失」 | 单通道证据不足以定案——通道盲区会伪装成「不存在」 | 三路独立验证（originals/ 磁盘、AppleScript 寻址、ZASSET 状态）+ 对照组；仍不能下「丢失」结论前先排除连拍 | §58 |
| photoscript 想按文件名搜 / 取照片大小 | **API 不存在**：无 `PhotosLibrary.search()`、无 `Photo.size/hidden` | 文件名搜索用原始 AppleScript `every media item whose filename is "X"`；尺寸用 `width/height`；文件大小查 Photos.sqlite | §57 |
| 查 Photos.sqlite 报列不存在 | schema 有版本差异（本机无 `ZORIGINALFILENAME`） | 先 `SELECT name FROM pragma_table_info('ZASSET')` 再挑列 | §57 |
| 拍摄时间比对全差 8 小时 / 全不一致 | 时区换算错误（Core Data 时间戳 = 2001-01-01 UTC 起秒） | 两边都换算成 UTC epoch 再比；差值应为 0。**比对前先看时间差分布**：聚在 ±8h = 时区 bug，按年散布 = 真撞名 | §57 |
| PhotoKit 恢复后想确认成功 | — | 终审三件套：UUID 清单查落盘（应 100%）+ sips 抽验分辨率（**竖幅件宽高互换属一致**）+ 全量扫 <200KB（应 0） | §59 |

## G. 写脚本时的通用坑（macOS + bash 3.2）

| 症状 | 根因 | 处置 | 深读 |
|---|---|---|---|
| `grep "a\|b"` 静默无结果（应有多条） | macOS BSD grep 不认 BRE `\|` 交替（GNU 才支持） | 必须用 `grep -E "a|b"`。**本轮两次假阴性差点带偏结论** | §58 |
| `sed -i ''` 报错但文件其实改对了 | 本机 sed 是 toybox shim | `sed -e … "$f" > "$f.tmp" && mv` 或 `perl -pi -e` | §18 |
| `cmd | head -1` 在 pipefail 下时好时坏 | head 提前退出触发 SIGPIPE(141) | 先落临时文件/变量再取行 | §5d |
| bash 变量莫名拼接中文 / 默认值被截断 | bash 3.2 UTF-8 高位字节并进变量名；`${VAR:={…}}` 花括号截断 | 跑 `lint-nonascii-vars.sh`；变量引用一律 `"${VAR}"` | §5e、§32 |
| 运行中的脚本改了没生效 | bash 启动时载入全文，运行中用旧版 | 改完必须重启该脚本/守卫 | §20 |
| `du` 显示的目录大小删完不还空间 | APFS 快照/purgeable 幻象 | 别按 du 推导可用空间，以 df 为准 | §29 |

## 检索 gotchas.md 的 grep 模式

```bash
G=~/.workbuddy/skills/sync-icloud-photos-to-drive/references/gotchas.md
grep -n "TCC\|权限" $G          # 权限类（§5、5b、13、14、15、53、57）
grep -n "连拍\|burst" $G        # 连拍类（§58、59）
grep -n "误报\|假" $G           # 误判类（§26、27、36、41、56）
grep -n "空间\|回收\|FLOOR\|CEIL" $G  # 空间脉冲类（§9、17、31、44-48、51）
grep -n "AppleScript\|photokit" $G    # 下载通道类（§12、13、23、25）
```
