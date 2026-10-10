# osxphotos CLI 参考

> 本文件内容于 2026-10-05 从已安装的 `osxphotos 0.77.2` 源码
> (`osxphotos/cli/export.py`、`osxphotos/cli/cli_params.py`、`osxphotos/cli/cli_commands.py`)
> 逐项核对得出，不是凭记忆写的。升级版本后应重新核对。

## 安装

```bash
pipx install osxphotos        # 入口 ~/.local/bin/osxphotos
```

**Homebrew core 没有这个 formula**，`brew install osxphotos` 会报
`No available formula`。不要试图走 brew。

若 pipx 不可用，退回隔离 venv：

```bash
python3 -m venv ~/.local/share/osxphotos-venv
~/.local/share/osxphotos-venv/bin/pip install osxphotos
```

## 必需的 macOS 权限

| 权限 | 位置 | 用途 |
|---|---|---|
| 完全磁盘访问 | 系统设置 → 隐私与安全性 → 完全磁盘访问 | 读取 `.photoslibrary` 内容 |
| 自动化 → 照片 | 系统设置 → 隐私与安全性 → 自动化 | `--download-missing` 通过 AppleScript 指挥照片 App |

授予后**必须退出并重开终端**，否则不生效。

## `--library PHOTOS_LIBRARY_PATH`（别名 `--db`）

指定要操作的 Photos 图库。

```bash
osxphotos info --library "$HOME/Pictures/Photos Library.photoslibrary"
osxphotos export --library "$HOME/Pictures/Photos Library.photoslibrary" /Volumes/X/out
```

**⚠️ 位置必须在子命令之后。** 它虽然定义在 `osxphotos/cli/cli_commands.py:242`
（`param_decls=["--library", "--db"]`），但那个类是**每个子命令自己的参数组装器**，
所以 `--library` 会被注册到 `info` / `export` 等**各子命令上**，而不是顶层 group。

```
osxphotos --library X info     # ❌ Error: No such option '--library'.
osxphotos info --library X     # ✅
```

（2026-10-06 实测：错误写法直接报 `No such option`，两种子命令都验证过。
`osxphotos info --help` 与 `osxphotos export --help` 里都能看到 `--library, --db`。）

**类型是 `click.Path(exists=True)`** —— 路径不存在时立即报错退出，不会静默回退到别的库。
这是好事：配错了能立刻发现，而不是导了半天导错库。

不指定时的查找顺序（源码 help 原文）：
1. 最近打开的图库 → 2. 系统图库 → 3. `~/Pictures/Photos Library.photoslibrary`

出于这个歧义，**建议始终显式指定**。工具链里对应配置项 `SRC_LIBRARY`。

## 子命令

| 命令 | 用途 |
|---|---|
| `osxphotos info` | 打印图库统计与路径。**先跑这个** |
| `osxphotos export <dir>` | 导出 |
| `osxphotos query` | 按条件查询，返回 UUID 列表，可用于生成待导出清单 |
| `osxphotos albums` | 列出相册 |
| `osxphotos dump` | 导出原始 JSON 元数据 |

## export 参数（按用途分组）

### 必用
| 参数 | 说明 |
|---|---|
| `--download-missing` | 本地缺原图时（「优化 Mac 存储」），让照片 App 去 iCloud 拉。**不加这个会导出缩略图** |
| `--directory "<模板>"` | 落盘目录结构，见下方模板字段 |
| `--update` | 只导新的/变化的。配合 `--exportdb` 实现断点续传 |
| `--exportdb <路径>` | 续传数据库位置。默认在用户目录，显式指定更可移植。**勿删** |
| `--report <路径>` | 输出 CSV 报告（文件名、UUID、日期、大小、错误）。校验用 |
| `--verbose` | 详细输出 |

> **`--no-version-check` 不可用**（2026-10-06 实测）：它在 `cli_params.py:121` 有定义，
> 但**没注册到 `export` / `info`**，用它会报 `Error: No such option '--no-version-check'`。
> 官方替代是环境变量（`cli/common.py:131`）：
>
> ```bash
> export OSXPHOTOS_NO_VERSION_CHECK=1
> ```
>
> 工具链已在脚本头部 export 该变量，不必再传参数。

### 空跑 / 试跑
| 参数 | 说明 |
|---|---|
| `--limit N` | 最多导出 N 项，试跑用 |
| `--dry-run` | 不实际写文件，只列出会导出什么。**校验完整性时用它再跑一遍** |
| `--retry` | 重试上次失败的项 |

### 范围筛选
`--album <名>` `--in-album <名>` `--not-in-album <名>` `--folder <名>`
`--from-date YYYY-MM-DD` `--to-date YYYY-MM-DD` `--year YYYY`
`--added-in-last 7d` `--added-before <日期>` `--added-after <日期>`
`--only-photos` `--only-movies` `--favorite` `--not-favorite`
`--selected` `--hidden` `--screenshot` `--selfie` `--live` `--not-live`
`--missing` `--not-missing` `--incloud` `--not-incloud`
`--uuid <UUID>` `--uuid-from-file <文件>` `--skip-uuid <UUID>`

### 原件 vs 编辑版
- 默认导出**未修改的原件**
- `--edited` 额外导出编辑后的版本（`--edited-suffix` 控制后缀）
- `--skip-original-if-edited` 有编辑版时就不导原件
- `--skip-edited` / `--skip-raw` / `--skip-raw-jpeg` / `--skip-live` / `--skip-bursts`

### 元数据
| 参数 | 说明 |
|---|---|
| `--sidecar xmp` / `json` / `exiftool` | 写附属文件，保留关键词/人物/位置 |
| `--exiftool` | 用 exiftool 写回元数据。**需另装 `brew install exiftool`** |
| `--keyword-template "<模板>"` | 按模板生成关键词，如 `"{folder_album(>)}"` |
| `--title` `--description` `--location` `--person` | 是否写入对应元数据 |
| `--export-aae` | 导出 Apple 的编辑调整文件（adjustments） |
| `--touch-file` | 把文件时间戳设为拍摄时间（方便按时间浏览） |

### 其他
`--use-photokit`（实验性，须与 `--download-missing` 同用，AppleScript 出问题时的备选通道）
`--tmpdir <路径>` `--overwrite` `--force-update` `--ignore-signature`
`--no-progress` `--watch` `--checkpoint` `--load-config` `--save-config`

### 已废弃，不要用
`--threads-num` —— 社区反馈新版已弃用、固定为 1。速度瓶颈在网络，靠并发提速的思路不成立。

## 目录模板字段（`--directory`）

日期时间（来自拍摄时间）：
```
{created}  {created.year}  {created.yy}  {created.mm}(月)  {created.month}  {created.dd}
{created.hour}  {created.min}  {created.sec}  {created.dow}  {created.doy}
{created.date}  {created.strftime,%Y-%m-%d}
```

其余：
```
{folder_album}            所属文件夹/相册路径；未归入任何相册时展开为 "_"
{folder_album(>)}         用 > 作分隔符（配 keyword-template 用）
{folder_album|lower}      转小写
{folder_album|filter(startswith Events)}   按前缀筛选
{original_name} {title} {name} {place} {keyword} {keywords} {uuid}
```

常用配方：
```bash
--directory "{created.year}/{created.mm}"        # 2024/08/
--directory "{created.strftime,%Y/%m/%d}"        # 2024/08/15/
--directory "{folder_album}"                     # 保留相册结构（一张照片属多个相册会被导出多份）
```

## 速度与稳定性事实

- 瓶颈是**网络带宽**，不是磁盘或并发。实测外置 USB3 机械盘写入 105 MB/s，
  500 GB 约 1.3 小时；从 iCloud 拉则受带宽限制，通常 5–15 小时
- `--download-missing` 依赖照片 App 的 AppleScript 接口，**官方文档自承该接口有 bug、
  可能导致照片 App 崩溃**；osxphotos 会尝试重启它继续。撞上了重跑即可
- 若反复出问题，改用 `--use-photokit`（实验性）替代 AppleScript 通道
- 会话建立后凭证可复用；反复运行同一条命令就是增量同步

## 完整性校验的三层做法

1. `--dry-run --update` 再跑一遍 → 输出 `0 exported` 即视为拉全（最省事，推荐下限）
2. 文件数 + 总体积，与 `osxphotos info` 的数字逐项比对
3. `--report` 的 CSV 逐行核对，重点看有没有 error 列非空的行
