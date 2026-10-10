#!/bin/bash
# ============================================================================
# icloud_export.sh —— 用 osxphotos 把 iCloud 照片/视频导出到外置盘
#
# 用法（参数全部可省，默认从配置文件读）:
#   bash icloud_export.sh conf      # 打印生效配置
#   bash icloud_export.sh doctor    # 目标盘诊断（卷卡住时用这个）
#   bash icloud_export.sh probe     # 读图库统计（只读）
#   bash icloud_export.sh test  [挂载点] [目录] [数量]
#   bash icloud_export.sh full  [挂载点] [目录]     # 全量，可反复跑、自动续传
#   bash icloud_export.sh verify [挂载点] [目录]
#
# 配置来源（优先级 低 → 高）:
#   1. 本文件内置默认值
#   2. 配置文件  $SYNC_CONF 或 ~/.config/sync-icloud-photos-to-drive/sync.conf
#   3. 命令行参数 / 环境变量
#
# 配置文件里可设: SRC_LIBRARY / DEST_VOLUME / DEST_SUBDIR / DIR_TEMPLATE /
#                 DOWNLOAD_MISSING / FS_TIMEOUT / EXPORT_DB_DIR
# 分批/切片（低空间模式）: ONLY_PHOTOS / ONLY_MOVIES / FROM_DATE / TO_DATE /
#                          MAX_ITEMS / EXTRA_ARGS
#
# 行为约定:
#   - 只读取照片图库，绝不写入或删除图库内容
#   - 只往目标盘的导出目录里写，不碰盘上其他文件
#   - full 可反复运行，已导出的自动跳过（依赖 --exportdb 续传数据库，勿删）
#   - 所有触碰文件系统的调用都带超时，卷无响应时快速失败并给出处置步骤
#
# 前置条件（必须由用户在「系统设置 → 隐私与安全性」里授予）:
#   1. 完全磁盘访问 → 加入【调用本脚本的那个 App】
#        - 在「终端」里跑        → 给「终端」授权
#        - 在 WorkBuddy 等 GUI 里跑 → 给那个 App 授权（TCC 按「负责进程」归责）
#      缺少它会在读 Photos.sqlite 时报：
#        PermissionError: [Errno 1] Operation not permitted
#   2. 自动化 → 控制「照片」（仅 --download-missing 走 AppleScript 时需要）
#   改完要退出并重开该 App。
# ============================================================================
set -uo pipefail

# 关闭 osxphotos 启动时的版本检查（它会联网查 PyPI，慢且不必要）。
# ⚠️ 不要用 `--no-version-check` 参数：0.77.2 里它虽有定义（cli_params.py:121），
#    但没注册到 export/info 子命令，运行时会被拒（Error: No such option）。
#    官方在 cli/common.py:131 推荐的关闭方式是下面这个环境变量。
export OSXPHOTOS_NO_VERSION_CHECK=1

ACTION="${1:-probe}"
ARG_VOL="${2:-}"
ARG_SUBDIR="${3:-}"
LIMIT="50"
[ "$ACTION" = "test" ] && [ -n "${4:-}" ] && LIMIT="$4"

# --- 内置默认值（会被配置文件与命令行覆盖）----------------------------------
# ⚠️ 一律用「先判空再兜底」，而不是 `VAR=默认`。
#    普通赋值会把【调用时传进来的同名环境变量】冲掉，于是
#    `ONLY_PHOTOS=1 bash icloud_export.sh full` 这种写法会静默失效。
#
# ⚠️⚠️ 也不要写成 `: "${VAR:={a}/{b}}"` —— 花括号模板会提前闭合参数展开！
#    实测 `: "${T:={created.year}/{created.mm}}"` 之后 T = `{created.year}`，
#    后半截被吃掉 → 目录结构静默变错（比原写法更危险）。含 {} 的默认值
#    必须走「中间变量」或「先判空」两条路。
: "${SRC_LIBRARY:=}"
: "${DEST_VOLUME:=}"
: "${DEST_SUBDIR:=iCloud导出}"
[ -n "${DIR_TEMPLATE:-}" ] || DIR_TEMPLATE='{created.year}/{created.mm}'
: "${DOWNLOAD_MISSING:=1}"
: "${FS_TIMEOUT:=8}"          # 单次文件系统调用的超时秒数

# --- 过滤/切片（默认全部为「不限」，低空间分批时才需要设）--------------------
: "${ONLY_PHOTOS:=0}"         # 1 = 只导图片（占地小、条数多，适合先啃年份）
: "${ONLY_MOVIES:=0}"         # 1 = 只导视频（占地大，建议等腾出空间后单独跑）
: "${FROM_DATE:=}"            # 只导此日期之后创建的，如 2018-01-01
: "${TO_DATE:=}"              # 只导此日期之前创建的（不含），如 2019-01-01
: "${MAX_ITEMS:=}"            # 本次最多导多少条（0/空 = 不限）
: "${EXTRA_ARGS:=}"           # 追加任意 osxphotos export 选项，空格分隔

# --- 加载配置文件 -----------------------------------------------------------
CONF="${SYNC_CONF:-$HOME/.config/sync-icloud-photos-to-drive/sync.conf}"
CONF_LOADED=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
  CONF_LOADED="$CONF"
fi

# --- 命令行参数优先级最高 ---------------------------------------------------
[ -n "$ARG_VOL" ]    && DEST_VOLUME="$ARG_VOL"
[ -n "$ARG_SUBDIR" ] && DEST_SUBDIR="$ARG_SUBDIR"

VOL="$DEST_VOLUME"
SUBDIR="$DEST_SUBDIR"

# 三个着色输出助手。第二个参数可选，传缩进前缀用（保持列对齐）
c_ok()   { printf "\033[32m%s✅ %s\033[0m\n" "${2:-}" "$1"; }
c_warn() { printf "\033[33m%s⚠️  %s\033[0m\n" "${2:-}" "$1"; }
c_err()  { printf "\033[31m%s❌ %s\033[0m\n" "${2:-}" "$1"; }
hr()     { printf '%s\n' "============================================================"; }

usage() {
  cat <<EOF
用法: bash $0 {conf|doctor|probe|test|full|verify} [挂载点] [导出目录名] [test 数量]

  不带参数时，挂载点与目录名从配置文件读取:
    $CONF

例:
  bash $0 conf      # 先看配置对不对
  bash $0 doctor    # 盘卡住时诊断
  bash $0 full      # 全量导出
EOF
  exit 1
}

# ============================================================================
# 带超时的执行 —— macOS 没有 GNU timeout
#
# 用 perl 的 alarm：exec 之后定时器依然有效，被调用的命令会真的收到 SIGALRM。
# 目的：卷无响应时**不要永久挂死**，而是超时后给出可操作的报错。
# 进程被 SIGALRM 杀掉时退出码是 128+14=142。
# ============================================================================
TIMEOUT_RC=142

t_run() {   # t_run <秒> <命令...>  → 原样执行，返回真实退出码
  local t="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$t" "$@"
}

fs_probe() {  # fs_probe <秒> <命令...> → 成功回显输出；超时 return 124
  local t="$1"; shift
  local out rc
  out="$(perl -e 'alarm shift; exec @ARGV' "$t" "$@" 2>&1)"
  rc=$?
  [ "$rc" -eq "$TIMEOUT_RC" ] && return 124
  printf '%s\n' "$out"
  return "$rc"
}

dir_state() {  # 0=存在 1=不存在或不可访问 124=无响应
  local out rc
  out="$(perl -e 'alarm shift; exec @ARGV' "$FS_TIMEOUT" test -d "$1" 2>&1)"
  rc=$?
  [ "$rc" -eq "$TIMEOUT_RC" ] && return 124
  [ "$rc" -eq 0 ] && return 0
  return 1
}

volume_hung_msg() {
  echo
  c_err "目标卷的文件系统无响应：${FS_TIMEOUT} 秒内没有返回"
  echo
  echo "  这不是脚本的问题。挂载表读得到、diskutil 也正常，说明盘和 USB 层都还在；"
  echo "  但任何文件系统调用（df / stat / ls）都会一直阻塞 —— 卷的 I/O 挂起了。"
  echo
  echo "  常见原因：外置盘或 USB 桥接休眠后唤不醒 / 盘掉线但挂载项还在 /"
  echo "            exFAT 走 FSKit 用户态服务，该服务卡死"
  echo
  echo "  处置顺序（每步做完重跑本命令验证）："
  echo "    [命令行手段 —— 若下面的 unmount force 已经卡过一次，直接跳到 3)]"
  echo "    1) 先试正常推出：访达里点该盘旁的 ⏏"
  echo "       不行则强制卸载：sudo diskutil unmount force \"${VOL:-/Volumes/xxx}\""
  echo "       注意：force 只跳过「文件被占用」检查，跳不过「FS 驱动应答」。"
  echo "             这条也卡死 = 用户态文件系统服务已死，命令行手段到头了。"
  echo "    2) 在新终端窗口（⌘N）看卡住的进程，决定还能不能救："
  echo "         ps -Ao pid,stat,etime,command | grep -iE \"diskutil|umount\""
  echo "       STAT 带 U → 不可中断等待，kill -9 也无效 → 直接跳到 3)"
  echo "       STAT 为 S → 可试 sudo kill -9 <PID>，再 sudo umount -f \"${VOL:-}\""
  echo "    3) 物理断连 —— 成功率最高的一招：拔掉 USB 线 / 关掉盘上电源开关"
  echo "       预期：挂住的命令立刻报错退出，访达里的盘变灰或消失"
  echo "    4) 拔线后访达仍显示该盘 → 重启 Mac（最终解）"
  echo "    5) 重插 / 重启后，先急救再读写，别直接开始导出："
  echo "         sudo diskutil verifyVolume <设备节点。编号重启后会变，用 diskutil list 现查>"
  echo "    6) 单独诊断：bash scripts/icloud_export.sh doctor"
  echo
  c_warn "如果重插后仍然无响应、或反复出现，别把它当作照片的唯一落点。"
}

# ============================================================================
do_conf() {
  hr; echo "生效配置"; hr
  echo "  配置文件    : ${CONF_LOADED:-（未找到，使用内置默认值）}"
  echo "  预期位置    : $CONF"
  echo "  探测超时    : ${FS_TIMEOUT}s"
  echo
  echo "  [源端]"
  echo "    图库      : ${SRC_LIBRARY:-（未指定 → 交给 osxphotos 自行判断，有歧义风险）}"
  if [ -n "$SRC_LIBRARY" ]; then
    local s=0; dir_state "$SRC_LIBRARY" || s=$?
    case $s in
      0)   c_ok  "源端图库路径可用" "    " ;;
      124) c_err "源端图库无响应" "    " ;;
      *)   c_err "源端图库路径不存在" "    " ;;
    esac
  fi
  echo
  echo "  [目的端]"
  echo "    挂载点    : ${VOL:-（未指定）}"
  echo "    导出目录  : ${VOL:-?}/${SUBDIR}"
  if [ -n "${VOL:-}" ]; then
    check_volume; local vrc=$?
    case $vrc in
      0)   echo "    状态      : 已挂载"
           echo "    挂载参数  : $MOUNT_OPTS"
           echo "    可用空间  : $(( $(printf '%s' "$DF_OUT" | awk 'NR==2{print $4}') / 1024 / 1024 )) GiB" ;;
      1)   c_err "挂载点不在挂载表里 —— 盘没插好？" "    " ;;
      2)   c_err "只读挂载，写不进去" "    " ;;
      3)   c_err "文件系统无响应 —— 卷卡住了（跑 doctor 看详情）" "    " ;;
    esac
  fi
  echo
  echo "  [导出选项]"
  echo "    目录模板  : $DIR_TEMPLATE"
  echo "    缺原图时拉取(--download-missing): $([ "$DOWNLOAD_MISSING" = "1" ] && echo 开 || echo 关)"
  echo "    续传库    : ${EXPORT_DB_DIR:-$HOME/.cache/osxphotos}/${SUBDIR}-export.db"
  echo
  echo "  [过滤/切片]（全默认 = 导整个图库）"
  echo "    只导图片  : $([ "$ONLY_PHOTOS" = "1" ] && echo 开 || echo 关)"
  echo "    只导视频  : $([ "$ONLY_MOVIES" = "1" ] && echo 开 || echo 关)"
  echo "    起始日期  : ${FROM_DATE:-（不限）}"
  echo "    结束日期  : ${TO_DATE:-（不限）}"
  echo "    条数上限  : ${MAX_ITEMS:-（不限）}"
  [ -n "$EXTRA_ARGS" ] && echo "    追加参数  : $EXTRA_ARGS"
  [ "$ONLY_PHOTOS" = "1" ] && [ "$ONLY_MOVIES" = "1" ] && \
    c_warn "同时开了「只导图片」和「只导视频」→ 两个选项互斥，osxphotos 会报错" "    "
  echo
  hr
}

# ============================================================================
# 卷检查：0=正常  1=未挂载  2=只读  3=无响应
# 成功后 MOUNT_LINE / DF_OUT 可用
# ============================================================================
check_volume() {
  MOUNT_LINE="$(mount | grep " on ${VOL} " || true)"
  [ -n "$MOUNT_LINE" ] || return 1
  printf '%s' "$MOUNT_LINE" | grep -q 'read-only' && return 2
  # 取括号内的挂载选项，去掉两端括号
  MOUNT_OPTS="${MOUNT_LINE#*\(}"; MOUNT_OPTS="${MOUNT_OPTS%\)}"
  DF_OUT="$(fs_probe "$FS_TIMEOUT" df -k "${VOL}")" || return 3
  return 0
}

do_doctor() {
  hr; echo "目标盘诊断"; hr
  echo "目标: ${VOL:-（未配置）}   （探测超时 ${FS_TIMEOUT}s）"
  echo

  echo "[1] 挂载表 —— 纯读内核表，不碰文件系统，必然秒回"
  if [ -n "${VOL:-}" ]; then
    mount | grep " on ${VOL} " | sed 's/^/    /' || echo "    挂载表里没有 $VOL"
  else
    mount | grep -i "/Volumes" | sed 's/^/    /'
  fi
  echo

  echo "[2] 物理盘与分区 —— kernel 层，也不碰文件系统"
  if fs_probe 10 diskutil list >/tmp/.wb_diskutil.out 2>&1; then
    grep -E "^/dev/disk|external" /tmp/.wb_diskutil.out | sed 's/^/    /'
  else
    c_err "diskutil list 超时 —— 连磁盘层都无响应，优先怀疑盘/线/口"
  fi
  rm -f /tmp/.wb_diskutil.out
  echo

  echo "[2b] 分区详情（DiskArbitration）—— 交叉验证：区分「盘没了」和「文件系统驱动卡死」"
  DEV="$(mount | grep " on ${VOL} " 2>/dev/null | awk '{print $1}' | head -1)"
  if [ -z "$DEV" ]; then
    echo "    挂载表里没有该卷，拿不到设备节点 —— 跳过"
  elif fs_probe "$FS_TIMEOUT" diskutil info "$DEV" >/tmp/.wb_di.out 2>&1; then
    c_ok "分区元数据可读 ($DEV)"
    grep -E "File System Personality|Volume Free Space|Read-Only Volume|Mounted" \
      /tmp/.wb_di.out | sed 's/^ */    /' | head -6
    echo "    → 盘与分区都在。若下一步 df 超时，即可锁定为文件系统驱动无响应"
  else
    c_err "diskutil info 也超时 —— 问题比文件系统更深，怀疑盘/USB 桥接/线材"
  fi
  rm -f /tmp/.wb_di.out
  echo

  echo "[3] 文件系统响应 —— 子命令会卡住，根因就在这一步"
  if [ -n "${VOL:-}" ]; then
    if fs_probe "$FS_TIMEOUT" df -k "$VOL" >/tmp/.wb_df.out 2>&1; then
      c_ok "文件系统有响应"
      awk 'NR==2{printf "    容量: %.1f GiB   可用: %.1f GiB\n", $2/1048576, $4/1048576}' /tmp/.wb_df.out
    else
      c_err "文件系统无响应 —— 卷已卡住，这就是命令挂起的原因"
      volume_hung_msg
      rm -f /tmp/.wb_df.out
      return 1
    fi
  fi
  rm -f /tmp/.wb_df.out
  echo

  echo "[4] 可写性 —— 只创建一个空文件再删掉"
  if [ -n "${VOL:-}" ]; then
    local T="$VOL/.wb_doctor_$$"
    if fs_probe "$FS_TIMEOUT" touch "$T" >/dev/null 2>&1; then
      c_ok "可写"
      fs_probe "$FS_TIMEOUT" rm -f "$T" >/dev/null 2>&1
      if fs_probe "$FS_TIMEOUT" test -e "$T" >/dev/null 2>&1; then
        c_warn "临时文件没删掉，请手动删除: $T"
      else
        echo "    临时文件已清理"
      fi
    else
      c_err "写入超时或失败 —— 卷可能已损坏或只读"
    fi
  fi
  echo

  hr; c_ok "诊断结束：文件系统正常，可以继续 probe"
}

# ============================================================================
# 定位 osxphotos
find_osxphotos() {
  local c
  for c in "$HOME/.local/bin/osxphotos" \
           "/opt/homebrew/bin/osxphotos" \
           "/usr/local/bin/osxphotos" \
           "$HOME/.workbuddy/binaries/python/envs/default/bin/osxphotos"; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  c="$(command -v osxphotos 2>/dev/null)" && [ -n "$c" ] && { echo "$c"; return 0; }
  return 1
}

preflight() {
  hr; echo "[1/4] 工具检查"
  OX="$(find_osxphotos)" || {
    c_err "找不到 osxphotos。安装方式: pipx install osxphotos"
    echo "  注意: Homebrew core 没有这个 formula，别用 brew install osxphotos"
    exit 1
  }
  echo "  路径: $OX"
  # 注意：不要写成 `"$OX" --version | head -1`。本脚本开了 pipefail，
  # head 读完一行就退出会让 osxphotos 收到 SIGPIPE(141)，整条管道被判失败，
  # 于是 --version 时好时坏（竞态）。改成先落到临时文件再取首行。
  local ver_out ver_rc
  ver_out="$( "$OX" --version 2>&1 )"; ver_rc=$?
  if [ "$ver_rc" -ne 0 ]; then
    c_err "osxphotos 无法启动（退出码 ${ver_rc}）。常见原因："
    echo "    - 缺少「完全磁盘访问」权限"
    echo "    - 在受限/无图形会话的环境里运行（必须用真实终端）"
    printf '%s\n' "$ver_out" | sed 's/^/    报错: /'
    exit 1
  fi
  printf '%s\n' "$ver_out" | head -1
  c_ok "osxphotos 可用"

  hr; echo "[2/4] 源端检查"
  if [ -n "$SRC_LIBRARY" ]; then
    local s=0; dir_state "$SRC_LIBRARY" || s=$?
    case $s in
      0)   echo "  图库: $SRC_LIBRARY"; c_ok "路径可用" "  " ;;
      124) c_err "源端图库无响应（所在卷可能也卡住了）: $SRC_LIBRARY" "  "
           echo "  源端在内置盘却无响应，通常是系统层面卡住，建议重启后再试"
           exit 2 ;;
      *)   c_err "源端图库不存在: $SRC_LIBRARY" "  "; exit 1 ;;
    esac
  else
    c_warn "未指定 SRC_LIBRARY —— osxphotos 将自行判断用哪个图库"
    echo "  建议在 $CONF 里显式指定，避免导错库"
  fi

  hr; echo "[3/4] 目标盘检查"
  [ -n "${VOL:-}" ] || { c_err "未指定挂载点。在配置文件里设 DEST_VOLUME，或作为第 2 个参数传入"; exit 1; }

  check_volume; local vrc=$?
  case $vrc in
    1) c_err "$VOL 未挂载（挂载表里没有）" "  "
       echo "  当前已挂载:"; ls -1 /Volumes/ | sed 's/^/    /'
       exit 1 ;;
    2) c_err "$VOL 是只读挂载，写不进去。先跑: bash scripts/drive_check.sh $VOL" "  "
       exit 1 ;;
    3) volume_hung_msg; exit 2 ;;
  esac
  echo "  挂载参数: $MOUNT_OPTS"
  AVAIL_GB=$(( $(printf '%s' "$DF_OUT" | awk 'NR==2{print $4}') / 1024 / 1024 ))
  echo "  可用空间: ${AVAIL_GB} GiB"
  [ "$AVAIL_GB" -lt 400 ] && c_warn "可用空间不足 400 GiB，图库较大时会写满"

  hr; echo "[4/4] 准备目录"
  DEST="$VOL/$SUBDIR"
  REPORT_DIR="$DEST/_导出报告"
  LOG_DIR="$REPORT_DIR/日志"

  # ⚠️ 导出历史库【绝不能】放在 exFAT 卷上。
  #    macOS 15.4+ 起 exFAT 由 FSKit（用户态文件系统）托管，不支持 SQLite
  #    建立写事务所需的文件锁语义。表现是：卷可写、文件也能建（touch/mkdir
  #    都成功），但 SQLite 一执行建表就报
  #        sqlite3.OperationalError: attempt to write a readonly database
  #    （osxphotos 只会自动检测「网络卷」并转 --ramdb，覆盖不到这种本地的
  #      FSKit 卷。）详见 references/gotchas.md 第 21 节。
  #    因此：这个库固定放内部盘。照片本身是普通文件写入，仍写目标盘，不受影响。
  EXPORT_DB_DIR="${EXPORT_DB_DIR:-$HOME/.cache/osxphotos}"
  EXPORT_DB="$EXPORT_DB_DIR/${SUBDIR}-export.db"   # full / verify 用
  TEST_DB="$EXPORT_DB_DIR/${SUBDIR}-试跑.db"        # 试跑专用，每次清空

  if ! fs_probe "$FS_TIMEOUT" mkdir -p "$DEST" "$REPORT_DIR" "$LOG_DIR" >/dev/null 2>&1; then
    c_err "在目标盘创建目录失败或超时"
    volume_hung_msg; exit 2
  fi
  if ! fs_probe "$FS_TIMEOUT" mkdir -p "$EXPORT_DB_DIR" >/dev/null 2>&1; then
    c_err "创建导出历史库目录失败: $EXPORT_DB_DIR"
    exit 2
  fi
  echo "  $DEST"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  echo

  # 传给 osxphotos 的公共选项
  # ⚠️ --library 是【子命令级】选项，必须写在子命令之后。
  #    写成 `osxphotos --library X info` 会报 Error: No such option '--library'.
  #    正确：`osxphotos info --library X` / `osxphotos export --library X <dir>`
  LIB_ARGS=()
  [ -n "$SRC_LIBRARY" ] && LIB_ARGS=(--library "$SRC_LIBRARY")
  DL_ARGS=()
  [ "$DOWNLOAD_MISSING" = "1" ] && DL_ARGS=(--download-missing)
  # 下载通道二选一（详见 references/gotchas.md 第 12 节）：
  #   默认        = AppleScript 驱动 Photos。不需要额外授权，但在部分机器上
  #                 会整段死锁（Photos 的集合查询永久不返回）。
  #   OSXPHOTOS_PHOTOKIT=1 = 走 PhotoKit。更快更稳，但 macOS 会要求给
  #                 「负责进程」授「照片」权限，首次运行会弹窗，必须点允许。
  # 两者都要「完全磁盘访问」（osxphotos 要读图库数据库做枚举）。
  [ "${OSXPHOTOS_PHOTOKIT:-0}" = "1" ] && DL_ARGS+=(--use-photokit)

  # 过滤/切片选项 —— 低空间模式下「分批导」用（见 SKILL.md「低空间模式」一节）。
  # 安全性：osxphotos 的续传库按 UUID/文件路径记账，不校验过滤条件，
  #        所以同一续传库换过滤条件是安全的，不会报「导出集冲突」。
  FILTER_ARGS=()
  [ "${ONLY_PHOTOS:-0}" = "1" ] && FILTER_ARGS+=(--only-photos)
  [ "${ONLY_MOVIES:-0}" = "1" ] && FILTER_ARGS+=(--only-movies)
  [ -n "${FROM_DATE:-}" ]       && FILTER_ARGS+=(--from-date "$FROM_DATE")
  [ -n "${TO_DATE:-}" ]         && FILTER_ARGS+=(--to-date "$TO_DATE")
  if [ -n "${EXTRA_ARGS:-}" ]; then
    # 故意不加引号：允许 EXTRA_ARGS 里写多个空格分隔的选项
    # shellcheck disable=SC2206
    FILTER_ARGS+=($EXTRA_ARGS)
  fi
  # --limit 单独放：do_test 自带 --limit，两个同时出现会让 osxphotos 只取最后一个
  LIMIT_ARGS=()
  [ -n "${MAX_ITEMS:-}" ] && [ "${MAX_ITEMS:-0}" != "0" ] && LIMIT_ARGS=(--limit "$MAX_ITEMS")
}

do_probe() {
  hr; echo "读取照片图库"
  [ -n "$SRC_LIBRARY" ] && echo "图库: $SRC_LIBRARY"
  hr
  local out rc
  out="$( "$OX" info ${LIB_ARGS[@]+"${LIB_ARGS[@]}"} 2>&1 )"; rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    echo; hr
    # 判读失败原因：osxphotos 的 stdout 只有摘要，详细堆栈在 crash log 里。
    # 权限问题只写进 crash log，所以必须读它才能定性。
    local perm=0 clog="$PWD/osxphotos_crash.log"
    printf '%s' "$out" | grep -q -e "Operation not permitted" -e "PermissionError" && perm=1
    if [ -f "$clog" ] && grep -q -e "Operation not permitted" -e "PermissionError" "$clog" 2>/dev/null; then
      perm=1
    fi
    if [ "$perm" -eq 1 ]; then
      c_err "读不到图库数据库 —— 缺「完全磁盘访问」权限"
      echo
      echo "  macOS 把它归责到【调用脚本的那个 App】，而不是 osxphotos："
      echo "    在「终端」里跑     → 给「终端」授权"
      echo "    在 WorkBuddy 里跑  → 给「WorkBuddy」授权"
      echo
      echo "  操作: 系统设置 → 隐私与安全性 → 完全磁盘访问 → 添加该 App 并打开开关"
      echo "        授权后【完全退出并重开该 App】，再重跑本命令。"
      echo
      echo "  报错原文:"
      echo "    PermissionError: [Errno 1] Operation not permitted:"
      echo "      .../Photos Library.photoslibrary/database/Photos.sqlite"
    else
      c_err "osxphotos info 失败（退出码 ${rc}），报错原文见上"
      if printf '%s' "$out" | grep -q "Error copying"; then
        c_warn "疑似读不到图库数据库（权限或文件占用）—— 查崩溃日志里的 PermissionError 可确认"
      fi
    fi
    echo
    echo "  崩溃日志（osxphotos 自动生成，排查完可删）:"
    echo "    $(pwd)/osxphotos_crash.log"
    exit 3
  fi
  echo
  hr
  echo "重点看三项:"
  echo "  1) 照片/视频总数与总体积 —— 对照预期体量"
  echo "  2) 是否有 missing / in-cloud 标记 —— 有则说明图库是「优化 Mac 存储」，"
  echo "     必须保持 DOWNLOAD_MISSING=1，否则导出的都是缩略图"
  echo "  3) 图库路径是否为「系统照片图库」—— iCloud 只同步系统图库"
}

do_test() {
  # 用带时间戳的独立目录，绝不删除任何已存在的内容
  local tdir="$VOL/_试跑-$SUBDIR-$STAMP"
  fs_probe "$FS_TIMEOUT" mkdir -p "$tdir" >/dev/null 2>&1 || { c_err "创建试跑目录失败或超时"; volume_hung_msg; exit 2; }
  # 试跑用独立的导出历史库，避免把试跑目录的记录混进正式库
  # （续传库按 UUID 记账，不记目标路径；混用会让正式 full 误判这些项「已导出」而跳过）
  rm -f "$TEST_DB" 2>/dev/null
  hr; echo "试跑: 最近 $LIMIT 项 -> $tdir"
  echo "开始: $(date '+%F %T')"; hr
  caffeinate -is "$OX" export ${LIB_ARGS[@]+"${LIB_ARGS[@]}"} "$tdir" \
    ${DL_ARGS[@]+"${DL_ARGS[@]}"} \
    ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"} \
    --limit "$LIMIT" \
    --directory "$DIR_TEMPLATE" \
    --exportdb "$TEST_DB" \
    --verbose 2>&1 | tee "$LOG_DIR/test-$STAMP.log"
  echo; hr; echo "试跑结果"; hr
  echo "  文件数: $(find "$tdir" -type f ! -name '.*' | wc -l | tr -d ' ')"
  du -sh "$tdir" 2>/dev/null | sed 's/^/  体积: /'
  echo
  echo "人工确认以下四点后，再跑 full:"
  echo "  [ ] 目录按 年/月 分层"
  echo "  [ ] 图片是 HEIC/JPG 原件，视频是 MOV/MP4 原件（不是缩略图）"
  echo "  [ ] Live Photo 的 HEIC 与同名 MOV 成对出现"
  echo "  [ ] 文件能用「预览」正常打开"
  echo
  echo "确认无误后清理试跑目录（在访达里把它拖进废纸篓）:"
  echo "  $tdir"
}

do_full() {
  hr; echo "全量导出（可反复运行，已导出的自动跳过）"
  echo "  源端  : ${SRC_LIBRARY:-（osxphotos 自动判断）}"
  echo "  目标  : $DEST"
  echo "  结构  : $DIR_TEMPLATE"
  echo "  续传库: $EXPORT_DB"
  echo "  开始  : $(date '+%F %T')"
  hr
  c_warn "全程勿拔盘、勿合盖。中断了直接重跑本命令即可续传。"
  echo
  caffeinate -is "$OX" export ${LIB_ARGS[@]+"${LIB_ARGS[@]}"} "$DEST" \
    ${DL_ARGS[@]+"${DL_ARGS[@]}"} \
    ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"} \
    ${LIMIT_ARGS[@]+"${LIMIT_ARGS[@]}"} \
    --directory "$DIR_TEMPLATE" \
    --update \
    --exportdb "$EXPORT_DB" \
    --report "$REPORT_DIR/export-$STAMP.csv" \
    --verbose 2>&1 | tee "$LOG_DIR/full-$STAMP.log"
  local rc=${PIPESTATUS[0]}
  echo; hr
  echo "结束: $(date '+%F %T')   退出码: $rc"
  echo "报告: $REPORT_DIR/export-$STAMP.csv"
  echo "日志: $LOG_DIR/full-$STAMP.log"
  hr
  [ "$rc" -eq 0 ] || c_warn "退出码非 0，看日志尾部；通常直接重跑就能续上"
  do_verify
}

do_verify() {
  hr; echo "完整性核对"; hr
  echo "  已导出文件数: $(find "$DEST" -type f ! -name '.*' | wc -l | tr -d ' ')"
  echo "  磁盘占用    : $(du -sh "$DEST" 2>/dev/null | cut -f1)"
  echo
  echo "  按扩展名分布:"
  find "$DEST" -type f ! -name '.*' | sed 's/.*\.//' | tr 'A-Z' 'a-z' \
    | sort | uniq -c | sort -rn | head -12 | sed 's/^/    /'
  echo
  hr; echo "再跑一次导出校验: 若「0 exported」即为拉全"; hr
  caffeinate -is "$OX" export ${LIB_ARGS[@]+"${LIB_ARGS[@]}"} "$DEST" \
    ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"} \
    --update --exportdb "$EXPORT_DB" --dry-run 2>&1 | tail -20
  echo
  echo "更严格的做法: 把上面的总数/总体积，与 probe 阶段 osxphotos info 报出的数字逐项对照。"
}

case "$ACTION" in
  conf)   do_conf   ;;
  doctor) do_doctor ;;
  probe)  preflight; do_probe  ;;
  test)   preflight; do_test   ;;
  full)   preflight; do_full   ;;
  verify) preflight; do_verify ;;
  *)      usage ;;
esac
