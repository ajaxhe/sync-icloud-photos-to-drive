# sync-icloud-photos-to-drive

把 iCloud 照片图库（几十到几百 GB）**完整、可验证地**导出到外置硬盘的全套工具链。
纯 bash + Python，macOS 原生依赖，唯一核心工具是开源的 [osxphotos](https://github.com/RhetTbul/osxphotos)。

## 为什么需要它

直接「照片 App 全选 → 拖到移动硬盘」在以下场景会翻车：

- 图库开了「优化 Mac 储存空间」，本地只剩缩略图——拖出来的是小图
- 内部盘只有十几 GB 空闲，装不下整库原件
- 导出日志里出现几百条 `Skipping missing original photo`，分不清是丢了还是通道问题
- **连拍（Burst）照片的子帧**：AppleScript 下载通道和 icloud.com 网页都只暴露封面照，
  子帧既不下也不显示——本项目实战 17,846 项导出中 729 项 missing 全部是连拍子帧，
  最终用 PhotoKit 通道 100% 找回

本项目把这些问题全部工程化解决，流程六阶段：

```
盘体检 → TCC 权限 → 安装+补丁 → 导出(含低空间脉冲模式) → 缺口核查 → 连拍恢复 → 终审清点
```

**成功的定义不是「命令跑完」，而是「账平」**：图库登记资产数 == 落地文件数 + 逐项定性的缺口清单。

## 快速开始

```bash
git clone https://github.com/ajaxhe/sync-icloud-photos-to-drive.git
cd sync-icloud-photos-to-drive

# 1. 配置（源图库、目标盘等）
mkdir -p ~/.config/sync-icloud-photos-to-drive
cat > ~/.config/sync-icloud-photos-to-drive/sync.conf <<'EOF'
SRC_LIBRARY="$HOME/Pictures/Photos Library.photoslibrary"
DEST_VOLUME="/Volumes/你的移动硬盘"
DEST_SUBDIR="iCloud导出"
DOWNLOAD_MISSING=1
EOF

# 2. 安装工具 + 打 4 个必需补丁（别跳，跳了会静默丢大文件）
pipx install osxphotos
bash scripts/apply-patches.sh

# 3. 四段式导出（在已授权「完全磁盘访问」的终端里跑）
bash scripts/icloud_export.sh probe   # 图库统计
bash scripts/icloud_export.sh test    # 试跑 50 项，人工确认
bash scripts/icloud_export.sh full    # 全量，可中断续传
bash scripts/icloud_export.sh verify  # 核验

# 内部盘装不下整库时，用脉冲模式（跑一段→等系统回收原件→再跑）
bash scripts/space_guard.sh
bash scripts/guard-status.sh          # 随时查进度（只读）

# 导出后日志里有 missing？先跑探针定性，九成是连拍子帧（照片在 iCloud 里是安全的）
bash scripts/run_probe.sh
# 确认是连拍后，用 PhotoKit 通道一轮找回（必须 Terminal.app）
OSXPHOTOS_PHOTOKIT=1 bash scripts/icloud_export.sh full
```

## 前置要求

| 依赖 | 说明 |
|---|---|
| macOS（Apple Silicon / Intel） | 依赖 TCC、AppleScript、PhotoKit |
| Python 3.9+ | `pipx install osxphotos` 自动带 |
| 外置硬盘 | exFAT/APFS 均可；exFAT 只能导散文件（不能拷 `.photoslibrary` 整包） |
| 三项 TCC 权限 | 完全磁盘访问、照片、自动化→照片——**授给跑脚本的那个 App** |

## 目录结构

| 路径 | 内容 |
|---|---|
| `SKILL.md` | 完整操作手册（六阶段流程、判据、约束）——**主文档** |
| `scripts/icloud_export.sh` | 驱动器：`conf/doctor/probe/test/full/verify` + 切片过滤 |
| `scripts/space_guard.sh` | 低空间脉冲监管器（工作/休息交替，永不写假完成标记） |
| `scripts/probe_missing.py` | 缺口探针：三路独立验证 + 对照组 + 同名双判据 |
| `scripts/apply-patches.sh` | osxphotos 4 个必需补丁（幂等；`pipx upgrade` 后必重跑） |
| `scripts/verify-originals.sh` | 离线核验导出的是不是原件（续传库字节 vs 实际字节） |
| `references/troubleshooting.md` | 症状速查表：40+ 条「症状→根因→处置→深读」 |
| `references/gotchas.md` | 59 节陷阱战史（每条含实测证据，编年体） |

## 核心设计决策（踩坑换来的）

1. **导出历史库（续传库）放内部盘**：exFAT 不支持 SQLite 文件锁，放外置盘必崩
   `readonly database`
2. **AppleScript 通道必须打超时补丁**：原版 120s 超时把 iCloud 下载耗时算在内，
   >300MB 视频必失败
3. **脉冲模式的前提是「优化储存」**：选「下载原件到 Mac」则原件永不换出，脉冲死锁
4. **missing ≠ 丢失**：先排除连拍子帧（AppleScript/网页双盲区），再谈数据找回
5. **同名 ≠ 同照片**：相机 IMG_XXXX 跨年撞名；判定重复需分辨率 + 拍摄时间双吻合
6. **每个否定性结论都要对照组**：photoscript 会把权限错误吞成「照片不存在」

## WorkBuddy 用户

本仓库同时是一个 [WorkBuddy](https://www.workbuddy.cn) skill。克隆到
`~/.workbuddy/skills/` 即可被自动发现，对话中说「导出 iCloud 照片到移动硬盘」即触发。

## 已验证规模

17,846 项 / 381 GB 图库：17,117 项逐字节校验原件一致 + 729 项连拍子帧经
PhotoKit 通道全量找回，终审 100% 落盘、0 缩略图混入。

## License

[MIT](LICENSE)
