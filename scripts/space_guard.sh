#!/bin/bash
# ============================================================================
# space_guard.sh —— 「内部盘空间有限」模式下的 iCloud 导出监管器
#
# 【为什么需要它】
# 原件必须先由 Photos 从 iCloud 落到内部盘，osxphotos 才能读出来写到外置盘。
# 图库留在内部盘是硬约束：.photoslibrary 是 SQLite 密集的包，**exFAT 装不了**
# （A5 节），而用户的外置盘是 exFAT。所以整条链路的临时空间只能来自内部盘。
#
# 好消息是：这不需要「与图库等大的空闲空间」，只需要一个**有界的工作集**。
# 坏消息是：macOS 回收图库原件是【磁盘压力驱动 + 小时级】的，见 A1 节。
#
# 因此本脚本不追求「一口气跑完」，而是把导出切成脉冲：
#
#     工作期：跑 icloud_export.sh full，直到内部盘可用空间跌到 FLOOR
#     休息期：彻底停掉导出（不再请求任何新下载），等系统把原件换出，
#             可用空间回到 CEIL 再开工
#     判定  ：休息期若长时间一个字节都不回收 → 原件根本没被换出
#             → 干净中止 + 给出确切处置（不是含糊的「空间不足」）
#
# 速度是牺牲品，但它有两个硬保证：
#   1) 绝不把内部盘啃到系统危险区（HARD_MIN 以下立刻停）
#   2) 绝不在没跑完时写「完成」标记 / 报成功
#
# 【前置条件】
#   - 由「终端」运行（TCC 权限归责到负责进程，见 A3 节）
#   - 照片 → 设置 → iCloud → 选【优化 Mac 储存空间】
#     选「下载原件到 Mac」时原件永不换出，本脚本会在第 1 个休息期后如实报告
#
# 【用法】
#   bash scripts/space_guard.sh              # 参数全部从 sync.conf 读
#   SYNC_CONF=/path/other.conf bash scripts/space_guard.sh
#   bash scripts/space_guard.sh --dry-run    # 只体检 + 打印脉冲计划，不跑导出
#
# 【退出码】
#   0 全部导完（或有 N 项原件在 iCloud 上确实取不到，已如实标注）
#   3 空间无法回收 —— 需要人工改 Photos 设置 / 腾空间
#   4 取件通道持续失效 —— 连续 CHANNEL_FIX_MAX 轮冷启动后仍零产出。
#     ⚠️ 见到 4 先做误报核对，别急着重启 Mac：数一数那一轮的
#        `grep -c "Exported new file" <该轮 full-*.log>`。
#        只要还出文件就是误报，直接重跑（gotchas 第 36、37 节，
#        2026-10-07 22:28 那次误报白丢了一轮 20 分钟的产出）。
#   5 达到轮次上限（进度已进续传库，重跑即可接着来）
#   6 前置条件不满足（盘没挂 / 图库路径不对 / 工具缺失）
# ============================================================================
set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORT_SH="${SKILL_DIR}/scripts/icloud_export.sh"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export OSXPHOTOS_NO_VERSION_CHECK=1

# --- 配置（先给默认值，再被 sync.conf 覆盖）---------------------------------
SRC_LIBRARY=""
DEST_VOLUME=""
DEST_SUBDIR="iCloud导出"
DIR_TEMPLATE='{created.year}/{created.mm}'
DOWNLOAD_MISSING=1
FS_TIMEOUT=8

# 脉冲参数（GiB）。FLOOR 是工作期的下限，CEIL 是休息期的回血目标。
# 经验值：单个大视频在内部盘上要占 2 份（图库原件 + osxphotos 的暂存副本），
# 所以 FLOOR 至少要能容纳「最大单件 × 2」。实测库里有 1.4 GB 的 MOV，
# 2×1.4≈2.8 GiB，再留一倍余量 → 12 GiB 起步是够的。
SPACE_FLOOR_GIB=12      # 工作期跌到这个值 → 停手进休息期
SPACE_CEIL_GIB=18       # 休息期回到这个值 → 恢复工作（不必等很久，够下一轮用即可）
SPACE_HARD_MIN_GIB=6    # 无论何时跌破这个值 → 立刻停止（系统危险区）
REST_MAX_MIN=180        # 休息期上限（分钟）；期间有回收则可延长一次
REST_HARD_MAX_MIN=720   # 休息期硬上限（分钟）
POLL_SEC=30             # 巡检间隔（秒）
STALL_MIN=30            # 连续多少分钟零新增文件 → 判空转
MISS_WINDOW_MIN=10      # missing 观测窗口（分钟）
MISS_MAX=50             # 窗口内新增多少条 missing → 判取件失败（仅当窗口内零产出时才成立）
CHANNEL_FIX_MAX=5       # 收到通道信号时最多冷启动 Photos 几次
CHANNEL_MIN_PROGRESS=20 # 冷启动一轮后至少新增这么多文件，才认为通道还活着
COLD_MAX=8              # 全局冷启动总上限（两个分支共用），防自愈打死循环
NO_GROWTH_MAX=3         # 连续多少轮零新增文件就判「真的推不动」并收尾
                        # （空转判据不再看「本轮跌了多少 GiB」—— 见下方 (c) 注释）
AUTO_SKIP_DONE=1        # 1 = 每轮用续传库里的最新日期做 FROM_DATE，跳过「重走已导出项」
                        # 这段是每轮 5-6 分钟的固定开销，还会为 missing 项重试 iCloud
                        # 下载、白吃十几 GiB 内部盘。收尾补漏时设 0 可全量复核。
MAX_ROUNDS=0            # 导出轮次上限，0 = 不限（跑到真的完成为止）
PHOTOS_WAIT_MIN=180     # 等 Photos 加载图库的上限（分钟）
DRIVE_WAIT_SEC=600      # 等外置盘挂载的上限（秒）

CONF="${SYNC_CONF:-$HOME/.config/sync-icloud-photos-to-drive/sync.conf}"
CONF_LOADED=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
  CONF_LOADED="$CONF"
fi

VOL="${DEST_VOLUME}"
DEST="${VOL}/${DEST_SUBDIR}"
REPORT_DIR="${DEST}/_导出报告"
LOG_DIR="${REPORT_DIR}/日志"
GUARD_LOG="${LOG_DIR}/space-guard.log"
DBDIR="${EXPORT_DB_DIR:-$HOME/.cache/osxphotos}"
EXPORT_DB="${DBDIR}/${DEST_SUBDIR}-export.db"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# ⚠️ 只记「启动时你显式传进来的」FROM_DATE。每轮自动算出的跳转日期**不能**写回这里，
#    否则第 2 轮起会走「沿用指定的」分支、再也不重算 —— 2026-10-09 实测：第 1 轮算出
#    2026-03-14，之后每轮都从 03-14 重走 45 项，哪怕续传库早已推进到 2026-04-07。
FROM_DATE_USER="${FROM_DATE:-}"

# 配置错误早失败
[ -n "$VOL" ] || { echo "❌ 未配置 DEST_VOLUME。检查 ${CONF}" >&2; exit 6; }
[ -n "$SRC_LIBRARY" ] || echo "⚠️  未配置 SRC_LIBRARY，osxphotos 会自行判断图库，有导错库风险" >&2

mkdir -p "$LOG_DIR" 2>/dev/null
# 双写：屏幕上一份（用户看得见进度），监管日志里一份（事后可查）。
# 不用 exec + process substitution：那样末尾几行常常来不及刷进文件。
say() {
  local m; m="$(printf '[%s] %s' "$(date '+%m-%d %H:%M:%S')" "$*")"
  printf '%s\n' "$m"
  [ -d "$LOG_DIR" ] && printf '%s\n' "$m" >>"$GUARD_LOG"
}
rule() {
  printf '%s\n' "============================================================"
  [ -d "$LOG_DIR" ] && printf '%s\n' "============================================================" >>"$GUARD_LOG"
}
# ⚠️ bash 3.2 会把紧跟变量名的非 ASCII 字节并进变量名，中文提示里一律写 ${VAR}
free_gib()      { df -k / | awk 'NR==2{printf "%d", $4/1024/1024}'; }
internal_gib()  { df -k / | awk 'NR==2{printf "%d", $2/1024/1024}'; }
vol_free_gib()  { df -k "$VOL" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}'; }
photos_pid()    { pgrep -f "Photos.app/Contents/MacOS/Photos" | head -1; }
photos_lib_fd() {
  local p; p="$(photos_pid)"
  [ -n "$p" ] || return 1
  lsof -p "$p" 2>/dev/null | grep -q "Photos Library"
}
dest_files() { find "$DEST" -type f ! -name '.*' ! -path '*/_导出报告/*' 2>/dev/null | wc -l | tr -d ' '; }

# ============================================================================
# A1. 为什么不能靠「腾空间」解决 —— 换出原件的真实触发条件
#
#   Photos 的「优化 Mac 储存空间」≠ 立即换出。macOS 只在【磁盘压力】下才回收，
#   经验阈值是空闲空间低于卷容量的 10% 左右；高于它，系统不着急，原件就一直躺着。
#   本机 926 GiB 的盘，21 GiB 可用（2.3%）——远在阈值之下，所以系统确实会回收，
#   但实测速率是【小时级】：8.5 小时停工期自行回收了 11 GiB（≈1.3 GiB/h）。
#   若选「下载原件到 Mac」，则是【永不回收】，本脚本会在休息期识别出来。
#
# A2. 为什么是脉冲而不是「慢速限流」
#   osxphotos 没有「每 N MB 停一下」的开关，限流只能靠停整个进程组。
#   脉冲的额外好处：休息期 Photos 不再收到新的下载请求，系统才有干净的回收窗口。
#
# A3. 为什么必须由终端跑
#   TCC 把「完全磁盘访问」归责到【负责进程】。agent 自己的进程读不到图库
#   （实测 osxphotos info 报 Path ... is not readable），终端可以。
#
# A4. 为什么用 SIGTERM 而不是 SIGSTOP
#   SIGSTOP 的进程仍持有 AppleScript 与 Photos 的下载状态，休息期回收不干净。
#   SIGTERM 让它正常收尾（续传库落盘），重跑时靠 --update 秒过已导出的部分。
#
# A5. 为什么图库不能挪到外置盘
#   .photoslibrary 内部是大量 SQLite；exFAT（macOS 15.4+ 由 FSKit 托管）
#   不支持 SQLite 需要的文件锁语义，装上去必崩。换 APFS 又得重格式化。
#   → 本方案默认不动图库位置。
# ============================================================================

restart_photos() {
  say "【自愈】冷启动照片栈（killall + 重新打开图库）"
  killall -9 Photos photolibraryd photoanalysisd 2>/dev/null
  sleep 3
  open -a Photos "$SRC_LIBRARY" 2>/dev/null
  local n=0
  while [ "$n" -lt 30 ]; do
    n=$((n+1))
    photos_lib_fd && { say "图库已重新加载（等 ${n}0 秒）"; return 0; }
    sleep 10
  done
  say "冷启动后图库仍未加载"
  return 1
}

# 一行解析：把某轮 run 日志里的最终统计抓出来
#   Processed: 16958 photos, exported: 3303, ..., missing: 14096, error: 0
# 从续传库里读出「已复核到的最新日期」（YYYY-MM-DD）。用途见轮次开始处的「尾段跳转」。
# 读不到（库不存在 / 无 python3 / 字段缺失）就返回非零，调用方静默退回全量。
latest_done_date() {
  local db="${1:-}" py
  if [ -z "$db" ] || [ ! -f "$db" ]; then return 1; fi
  py="$(command -v python3 2>/dev/null)" || return 1
  if [ -z "$py" ]; then return 1; fi
  "$py" - "$db" 2>/dev/null <<'PYEOF'
import sys, sqlite3, json
try:
    con = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
    mx = ""
    for (pi,) in con.execute("select photoinfo from photoinfo"):
        try:
            d = json.loads(pi).get("date") or ""
        except Exception:
            continue
        if d > mx:
            mx = d
    if not mx:
        sys.exit(1)
    print(mx[:10])
except Exception:
    sys.exit(1)
PYEOF
}

parse_stat() {   # parse_stat <日志文件> <字段名>  → 数字
  local f="$1" k="$2" line val
  [ -f "$f" ] || { echo ""; return; }
  line="$(grep -h 'Processed:' "$f" 2>/dev/null | tail -1)"
  [ -n "$line" ] || { echo ""; return; }
  val="$(printf '%s' "$line" | sed -n "s/.*${k}: *\([0-9][0-9]*\).*/\1/p")"
  echo "${val:-}"
}

# ============================================================================
# 主流程
# ============================================================================
rule
say "space_guard 启动（有限内部盘空间模式）"
say "配置文件   : ${CONF_LOADED:-（未找到，用内置默认值）}"
say "源端图库   : ${SRC_LIBRARY:-（未指定，交给 osxphotos 判断）}"
say "目标盘     : ${VOL}"
say "内部盘     : 共 $(internal_gib) GiB，可用 $(free_gib) GiB"
say "脉冲阈值   : FLOOR=${SPACE_FLOOR_GIB} GiB  CEIL=${SPACE_CEIL_GIB} GiB  HARD_MIN=${SPACE_HARD_MIN_GIB} GiB"
say "续传库     : ${EXPORT_DB}"
say "监管日志   : ${GUARD_LOG}"
rule

if [ "$DOWNLOAD_MISSING" != "1" ]; then
  say "⚠️  DOWNLOAD_MISSING=0：只导本地已有原件，iCloud 上的取不回来。若图库是「优化」模式，导出的是残缺集。"
fi
if [ "$(free_gib)" -lt "$SPACE_FLOOR_GIB" ]; then
  say "注意：启动时可用空间 $(free_gib) GiB 已低于 FLOOR=${SPACE_FLOOR_GIB} GiB"
  say "      → 会先进入休息期等系统回收；若长时间不回收，本脚本会如实报出原因。"
fi
if [ "$DRY_RUN" = "1" ]; then
  say "（--dry-run：只体检，不启动导出）"
  rule; exit 0
fi

# 全程防睡眠（休息期睡过去的话，回收也会停）
caffeinate -is -w $$ &

# --- 1. 等外置盘 -------------------------------------------------------------
say "等待 ${VOL} 挂载（最多 $((DRIVE_WAIT_SEC/60)) 分钟）…"
n=0
while [ "$n" -lt "$DRIVE_WAIT_SEC" ]; do
  [ -d "$VOL" ] && break
  n=$((n+5)); sleep 5
done
if [ ! -d "$VOL" ]; then say "❌ 外置盘未挂载。插好盘后重跑本脚本。"; exit 6; fi
say "外置盘已挂载，可用 $(vol_free_gib) GiB"
mkdir -p "$REPORT_DIR" "$LOG_DIR" "$DEST" 2>/dev/null

# --- 2. 等 Photos 就绪 -------------------------------------------------------
say "等待 Photos 加载图库（最多 ${PHOTOS_WAIT_MIN} 分钟）…"
n=0
while [ "$n" -lt "$PHOTOS_WAIT_MIN" ]; do
  photos_lib_fd && break
  if [ -z "$(photos_pid)" ]; then
    say "Photos 未运行 → 拉起它"; open -a Photos "$SRC_LIBRARY" 2>/dev/null; sleep 20
  fi
  if [ $(( n % 30 )) -eq 0 ] && [ "$n" -gt 0 ]; then
    say "已等 ${n} 分钟仍未加载，做一次冷启动自愈"; restart_photos
  fi
  n=$((n+1)); sleep 60
done
if ! photos_lib_fd; then
  say "❌ 等了 ${PHOTOS_WAIT_MIN} 分钟，Photos 始终没打开图库 → 需人工介入（重启 Mac）"
  exit 4
fi
say "Photos 已加载图库 ✔"

# --- 3. 脉冲循环 -------------------------------------------------------------
# 三个独立计数器，职责不要混用（2026-10-07 混用埋过一个隐性死循环）：
#   cold_channel —— 收到通道信号时的冷启动次数，预算 CHANNEL_FIX_MAX
#   cold_missing —— missing>0 且空间充裕时的冷启动次数，预算 2
#   cold_total   —— 两者之和，全局上限 COLD_MAX
# 早先两个分支共用一个 `photo_fixes`：通道分支把它推到 5 之后，
# missing 分支的 `photo_fixes < 2` 永远为假 → 那条路径再没有自愈机会。
round=0; miss_prev=""; cold_channel=0; cold_missing=0; cold_total=0; no_growth=0
# 通道判死看「距上次处置又出了多少文件」，所以要在循环前钉一个基准。
files_at_fix="$(dest_files)"
final_missing=""

while : ; do
  round=$((round+1))
  if [ "$MAX_ROUNDS" -gt 0 ] && [ "$round" -gt "$MAX_ROUNDS" ]; then
    rule; say "达到轮次上限 ${MAX_ROUNDS}，退出（进度已进续传库，重跑接着来）"; rule
    exit 5
  fi

  rule
  say "▶ 第 ${round} 轮 工作期开始：内部盘可用 $(free_gib) GiB，已落地 $(dest_files) 个文件"
  rule
  # 本轮增量 = 结束时文件数 - 这个基准。它同时是「通道是否活着」和
  # 「是否真的推不动了」两个判据的唯一输入。
  files_round_start="$(dest_files)"

  # --- 尾段跳转：跳过「重走已导出项」这段固定开销 ---------------------------
  # 每轮 osxphotos 都从第 1 项重新枚举（--update 逐个复核）。大库上这段要 5-6 分钟，
  # 且会为 missing 项重试 iCloud 下载、白白吃掉十几 GiB 内部盘。工作期越短，
  # 这段固定开销占比越高（实测第 9 轮：6 分钟里 96% 花在这儿，只导出 1 个文件）。
  # 用续传库里「已复核到哪天」当 FROM_DATE，直接跳到出口。
  #   显式传了 FROM_DATE → 尊重你指定的值；读不到库 / 日期异常 → 静默退回全量。
  # ⚠️ 每轮都要重算：续传库在推进，第 2 轮的出口比第 1 轮更靠后。别把算出的值
  #    留在 FROM_DATE 里让下一轮误认成「你指定的」（见文件顶部 FROM_DATE_USER 说明）。
  skip_from=0
  FROM_DATE=""
  if [ -n "${FROM_DATE_USER:-}" ]; then
    FROM_DATE="$FROM_DATE_USER"; skip_from=1
    say "⏭  沿用你指定的 FROM_DATE=${FROM_DATE}"
  elif [ "${AUTO_SKIP_DONE:-1}" = "1" ]; then
    _d="$(latest_done_date "$EXPORT_DB" 2>/dev/null || true)"
    _today="$(date +%Y-%m-%d)"
    if [ -n "${_d:-}" ] && { [ "$_d" \< "$_today" ] || [ "$_d" = "$_today" ]; }; then
      FROM_DATE="$_d"; skip_from=1
      say "⏭  本轮自动取续传库最新日期 → FROM_DATE=${_d}（跳过该日之前的重走与 missing 重试）"
    else
      say "⏭  续传库里没有可用日期 → 本轮全量复核"
    fi
  fi
  [ "$skip_from" = "1" ] || unset FROM_DATE

  # 独立进程组，便于整组停止（macOS 没有 setsid 命令）
  best_log=""
  if [ "$skip_from" = "1" ]; then
    env FROM_DATE="$FROM_DATE" perl -e 'setpgrp(); exec @ARGV' bash "$EXPORT_SH" full &
  else
    perl -e 'setpgrp(); exec @ARGV' bash "$EXPORT_SH" full &
  fi
  EXP_PID=$!
  sleep 5

  stop_for_space=0; stop_for_channel=0
  # ⚠️ 空转计时按【秒】累加，不要按巡检次数累加 —— POLL_SEC 不一定是 60，
  #    按次数算会让 STALL_MIN=30 实际在 15 分钟（POLL_SEC=30 时）就误触发。
  stall_sec=0; last_files="$(dest_files)"; mcount=0; miss_base=""
  files_base="$(dest_files)"; win_new=0
  # 记录本轮「开工时的内部盘」与「本轮见过的最低点」，供空转判别用。
  free_round_start="$(free_gib)"; free_min="$free_round_start"
  while kill -0 "$EXP_PID" 2>/dev/null; do
    sleep "$POLL_SEC"
    fg="$(free_gib)"
    [ "${fg:-0}" -lt "${free_min:-$fg}" ] && free_min="$fg"

    # (a) 系统危险区 —— 无条件立即停
    if [ "${fg:-0}" -lt "$SPACE_HARD_MIN_GIB" ]; then
      say "⛔ 内部盘仅剩 ${fg} GiB（< HARD_MIN=${SPACE_HARD_MIN_GIB}）→ 立即停止导出"
      stop_for_space=1; break
    fi
    # (b) 工作期下限 —— 正常脉冲切换点
    if [ "${fg:-0}" -lt "$SPACE_FLOOR_GIB" ]; then
      say "内部盘剩 ${fg} GiB（< FLOOR=${SPACE_FLOOR_GIB}）→ 停手，进入休息期等系统换出原件"
      stop_for_space=1; break
    fi
    # (c) 零产出 / missing 洪水 —— 先判别是空间问题还是通道问题
    files_now="$(dest_files)"
    if [ "${files_now:-0}" -gt "${last_files:-0}" ]; then
      last_files="$files_now"; stall_sec=0
    else
      stall_sec=$((stall_sec + POLL_SEC))
    fi
    stall_min=$(( stall_sec / 60 ))
    mcount=$((mcount + 1))
    RUNLOG="$(ls -t "${LOG_DIR}"/full-*.log 2>/dev/null | head -1)"
    miss_now=""; [ -n "$RUNLOG" ] && miss_now="$(grep -c 'Skipping missing' "$RUNLOG" 2>/dev/null | tr -d ' ')"
    flood=0
    # ⚠️ 洪水判定必须同时满足【窗口内零新增文件】。
    #    2026-10-07 实测：一轮日志 902 条 "Skipping missing original" 里，679 条其实
    #    早已在导出目录里（原件不在本地、osxphotos 复核不了 → 记成 skip），
    #    属重走噪声。只要还有文件落盘，通道就是活的，skip 多不能判死。
    if [ $(( mcount % (MISS_WINDOW_MIN*60/POLL_SEC) )) -eq 0 ]; then
      win_new=$(( ${files_now:-0} - ${files_base:-0} ))
      if [ -n "${miss_base:-}" ] && [ -n "${miss_now:-}" ] && \
         [ $(( ${miss_now:-0} - ${miss_base:-0} )) -gt "$MISS_MAX" ] && \
         [ "$win_new" -le 0 ]; then
        flood=1
      fi
      miss_base="${miss_now:-${miss_base:-0}}"
      files_base="${files_now:-${files_base:-0}}"
    fi

    if [ "$stall_sec" -ge "$(( STALL_MIN * 60 ))" ] || [ "$flood" = "1" ]; then
      # ⚠️⚠️ 分界只能看【盘是不是已经被吃到 FLOOR 以下】，不能用另外两种写法：
      #   ① 不能用「内部盘是否高于 CEIL」—— 2026-10-08 23:2x 实测反例：
      #      osxphotos 卡在 AppleScript 等 Photos 回话，内部盘**一分钱没花**
      #      （13 GiB 平了 10 分钟），于是永远低于 CEIL=18 → 永远被判成
      #      「空间饥饿」→ 只会去休息，而那根本不解决问题。
      #   ② 也不能用「本轮跌了多少 GiB」—— 2026-10-09 23:2x 实测反例：
      #      本轮正常下载先吃掉 23 GiB（40→17 GiB），随后在 17 GiB 处卡死；
      #      跌幅很大，却与「此刻为什么停」毫无关系，于是又误判成空间饥饿。
      #    正确逻辑：上面 (a)/(b) 已经在 fg < HARD_MIN / < FLOOR 时抢先收轮，
      #    所以**走到这里必然 fg >= FLOOR** —— 盘还有余量却一件都不出货，
      #    那就只能是取件通道卡死，跟空间无关。
      if [ "${fg:-0}" -lt "$SPACE_FLOOR_GIB" ]; then
        say "⚠️  空转信号（零产出 ${stall_min} 分钟 / missing 洪水=${flood}），内部盘仅 ${fg} GiB（< FLOOR=${SPACE_FLOOR_GIB}）→ 判为空间饥饿，转休息期"
        stop_for_space=1; break
      else
        say "⚠️  空转信号（零产出 ${stall_min} 分钟 / missing 洪水=${flood}），内部盘还有 ${fg} GiB（≥ FLOOR=${SPACE_FLOOR_GIB}，本轮最低 ${free_min:-$fg} GiB）却零出货 → 判为取件通道卡死（Photos/AppleEvent），冷启动 Photos"
        stop_for_channel=1; break
      fi
    fi
    if [ $(( mcount % 20 )) -eq 0 ]; then
      say "  …工作进行中：已落地 $(dest_files) 个文件，内部盘 ${fg} GiB"
    fi
  done

  # 停导出（优雅优先）
  kill -CONT -"$EXP_PID" 2>/dev/null
  kill -TERM -"$EXP_PID" 2>/dev/null
  # ⚠️ 不能用 `kill -0 "$EXP_PID"` 判「还没退出」：子进程被系统收成僵尸后
  #    `kill -0` 依然返回 0，于是每轮固定白等满 60 秒（2026-10-07 实测，
  #    见 gotchas 第 36.5 节）。改看进程状态：进程消失、或进入 Z（僵尸，
  #    等 wait 收割）都算已退出。
  n=0
  while [ "$n" -lt 12 ]; do
    st="$(ps -o stat= -p "$EXP_PID" 2>/dev/null | tr -d ' ')"
    [ -z "$st" ] && break
    case "$st" in Z*) break ;; esac
    sleep 5; n=$((n+1))
  done
  st="$(ps -o stat= -p "$EXP_PID" 2>/dev/null | tr -d ' ')"
  if [ -n "$st" ]; then
    case "$st" in
      Z*) : ;;
      *)  say "导出进程未在 60 秒内退出，强制结束"; kill -KILL -"$EXP_PID" 2>/dev/null ;;
    esac
  fi
  wait "$EXP_PID" 2>/dev/null; exp_rc=$?
  RUNLOG="$(ls -t "${LOG_DIR}"/full-*.log 2>/dev/null | head -1)"
  exp_missing="$(parse_stat "$RUNLOG" missing)"
  round_gain=$(( $(dest_files) - ${files_round_start:-0} ))
  say "工作期结束：退出码 ${exp_rc}，本轮新增 ${round_gain} 个文件，missing=${exp_missing:-未知}，累计 $(dest_files) 个 / $(du -sh "$DEST" 2>/dev/null | cut -f1 | tr -d ' ')"

  # --- 通道失效：先自愈，再决定是否退出 -----------------------------------
  # ⚠️ 判据是【冷启动之后还有没有新产出】，不是【有没有再次收到通道信号】。
  #    2026-10-07 实测反例：第 1 次冷启动后的下一轮照样产出 2973 个文件，
  #    通道明明是活的；旧逻辑却因为「第二次收到信号」就宣布系统级死锁、
  #    建议重启 Mac —— 属于误报，白丢了一轮 20 分钟的产出。
  if [ "$stop_for_channel" = "1" ]; then
    now_files="$(dest_files)"
    new_since_fix=$(( now_files - ${files_at_fix:-0} ))
    if [ "$new_since_fix" -gt "$CHANNEL_MIN_PROGRESS" ]; then
      # 上一轮还在出货 → 通道活着，不必动 Photos（杀掉重开最扰民，留到最后手段）。
      # 单是把导出进程重起一轮，就足以清掉卡住的 AppleScript 会话。
      rule
      say "⚠️  收到通道信号，但上一轮仍新增了 ${new_since_fix} 个文件 —— 通道是活的。"
      say "    skip 多只是这库的常态：多数是「已导出、但原件不在本地、osxphotos"
      say "    复核不了」造成的重走噪声，不是取件失败。"
      say "    → 不重启 Photos，直接重开一轮（第 ${round} 轮已落地 ${now_files} 个文件）"
      rule
      files_at_fix="$now_files"
      continue
    fi
    if [ "$cold_channel" -lt "$CHANNEL_FIX_MAX" ] && [ "$cold_total" -lt "$COLD_MAX" ]; then
      cold_channel=$(( cold_channel + 1 )); cold_total=$(( cold_total + 1 ))
      files_at_fix="$now_files"
      say "⚠️  上一轮只新增 ${new_since_fix} 个文件（不超过 ${CHANNEL_MIN_PROGRESS} 个）—— 疑似真的取不到原件"
      say "    → 冷启动照片栈后重试（第 ${cold_channel}/${CHANNEL_FIX_MAX} 次，全局第 ${cold_total}/${COLD_MAX} 次）"
      restart_photos || { say "冷启动失败"; }
      continue
    fi
    rule
    say "❌ 取件通道持续失效：连续 ${CHANNEL_FIX_MAX} 次冷启动，每轮新增文件都不超过 ${CHANNEL_MIN_PROGRESS} 个，"
    say "   且内部盘空间充裕（$(free_gib) GiB）—— 卡在系统层，不是空间问题，也不是没导完。"
    # 给出误报核对所需的那一个数，免得用户凭「建议重启 Mac」就照做。
    say "   【误报核对】本轮日志 $(basename "${RUNLOG:-（无）}") 里 Exported new file = $(grep -c 'Exported new file' "${RUNLOG:-/dev/null}" 2>/dev/null | tr -d ' ') 条。"
    say "   这个数不小 → 是误报，直接重跑本脚本，别动 Photos、别重启 Mac。"
    say "   这个数确实为 0 → 判据可信，按下面顺序试，由轻到重："
    say "     ① 手动退出「照片」再重开，然后重跑本脚本"
    say "     ② 重启 Mac，再重跑本脚本"
    say "     ③ 换取件通道：OSXPHOTOS_PHOTOKIT=1 重跑本脚本（走 PhotoKit 而非"
    say "        AppleScript；首次会弹窗要「照片」权限，点允许。大库上 AppleScript"
    say "        通道反复卡死是已知问题，换通道往往比重启管用）"
    say "   已落地 $(dest_files) 个文件，进度在续传库里，不会丢。"
    rule
    exit 4
  fi

  # --- 空间饥饿：若导出其实已自然跑完，先做完成判定 -----------------------
  if [ "$stop_for_space" = "0" ]; then
    if [ "${exp_missing:-1}" = "0" ]; then
      rule; say "✅ 本轮导出自然结束且 missing=0 → 做最终核对"; rule
      bash "$EXPORT_SH" verify
      say "全部完成。已落地 $(dest_files) 个文件 / $(du -sh "$DEST" 2>/dev/null | cut -f1 | tr -d ' ')"
      exit 0
    fi
    # missing>0 且空间充裕：要么是通道问题的另一种长相（osxphotos 静默跳过），
    # 要么是这批原件在 iCloud 侧真的取不到。用「missing 是否收敛」区分两者。
    if [ "${exp_missing:-0}" -gt 0 ]; then
      prev_missing="${miss_prev}"

      # (i) 累计零增长轮数。⚠️ 这条护栏不可省：missing 若在两个值之间来回跳
      #     （100→101→100→101…），下面的收敛判定永远不成立，早先的版本会无限绕圈。
      if [ "${round_gain:-0}" -le 0 ]; then
        no_growth=$(( no_growth + 1 ))
      else
        no_growth=0
      fi

      # (ii) 收敛：连续两轮 missing 相同 → 这批在 iCloud 侧确实取不到
      if [ "${prev_missing:-x}" = "${exp_missing}" ]; then
        rule
        say "ℹ️  连续两轮 missing 都是 ${exp_missing}，冷启动 Photos 也没让它变小 ——"
        say "    这批原件在 iCloud 侧取不到（不是本机问题）。导出已做到当前能做到的最全。"
        say "    已落地 $(dest_files) 个文件 / $(du -sh "$DEST" 2>/dev/null | cut -f1 | tr -d ' ')"
        rule
        exit 0
      fi
      miss_prev="$exp_missing"

      # (iii) 连续多轮零新增 → 推不动了，如实收尾（不再无限重开）
      if [ "$no_growth" -ge "$NO_GROWTH_MAX" ]; then
        rule
        say "❌ 连续 ${no_growth} 轮零新增文件，missing 还在变（${prev_missing:-初值} → ${exp_missing}）——"
        say "   通道推不动但也没崩。已落地 $(dest_files) 个文件，进度在续传库里，不会丢。"
        say "   【误报核对】本轮 Exported new file = $(grep -c 'Exported new file' "${RUNLOG:-/dev/null}" 2>/dev/null | tr -d ' ') 条；"
        say "   这个数不小 → 是误报，直接重跑。确认零产出再按序试："
        say "     ① 重开「照片」并重跑  ② 重启 Mac  ③ OSXPHOTOKIT=1 重跑"
        rule
        exit 4
      fi

      # (iv) 还有自愈预算 → 冷启动一次再看。
      #      预算用独立计数器：早先与通道分支共用 photo_fixes，通道分支把它
      #      推到上限后，这条路径的 `photo_fixes < 2` 永远为假 → 再没机会自愈。
      if [ "$cold_missing" -lt 2 ] && [ "$cold_total" -lt "$COLD_MAX" ]; then
        cold_missing=$(( cold_missing + 1 )); cold_total=$(( cold_total + 1 ))
        say "本轮 missing=${exp_missing}（上轮 ${prev_missing:-初值}）且空间充裕 → 冷启动 Photos 后重试（第 ${cold_missing}/2 次，全局第 ${cold_total}/${COLD_MAX} 次）"
        restart_photos
        continue
      fi
      say "本轮 missing=${exp_missing}（上轮 ${prev_missing:-初值}），自愈预算已用尽，重开一轮再看"
      continue
    fi
  fi

  # --- 休息期：等系统换出原件 ---------------------------------------------
  rest_start=$(date +%s); rest_f0="$(free_gib)"; rest_best="$rest_f0"; extended=0
  say "💤 休息期开始（内部盘 ${rest_f0} GiB，目标回血到 ${SPACE_CEIL_GIB} GiB）"
  say "   期间不发起任何新下载，让 macOS 有机会回收图库原件"
  while : ; do
    sleep "$POLL_SEC"
    fg="$(free_gib)"
    [ "${fg:-0}" -gt "${rest_best:-0}" ] && rest_best="$fg"
    el=$(( ($(date +%s) - rest_start) / 60 ))
    if [ "${fg:-0}" -ge "$SPACE_CEIL_GIB" ]; then
      say "✅ 休息期结束：内部盘回到 ${fg} GiB（用时 ${el} 分钟）"
      break
    fi
    [ $(( el % 10 )) -eq 0 ] && say "  …休息中：内部盘 ${fg} GiB（已 ${el} 分钟，本轮最高 ${rest_best}）"
    if [ "$el" -ge "$REST_MAX_MIN" ] && [ "$extended" = "0" ] && [ "$rest_best" -gt "$(( rest_f0 + 1 ))" ]; then
      extended=1
      say "   休息期已到 ${REST_MAX_MIN} 分钟，但期间有回收（${rest_f0}→${rest_best} GiB）→ 再给 ${REST_MAX_MIN} 分钟"
    fi
    hard=$REST_MAX_MIN
    [ "$extended" = "1" ] && hard=$REST_HARD_MAX_MIN
    [ "$el" -ge "$hard" ] && break
  done

  if [ "$(free_gib)" -lt "$SPACE_CEIL_GIB" ]; then
    rule
    rl=$(( ( $(date +%s) - rest_start ) / 60 ))
    say "❌ 内部盘空间无法回收：休息 ${rl} 分钟，可用空间 ${rest_f0} → $(free_gib) GiB（最高 ${rest_best}）"
    say
    if [ "$rest_best" -le "$(( rest_f0 + 1 ))" ]; then
      say "   一个字节都没回收。最可能的原因："
      say "   → 照片 App 的图库设成了【下载原件到 Mac】。该模式下原件永不换出，"
      say "     光靠等是等不来的。请改成："
      say
      say "        打开「照片」→ 菜单栏「照片 → 设置」→ iCloud 标签 →"
      say "        勾选「iCloud 照片」后选【优化 Mac 储存空间】"
      say
      say "     改完不用重启，重跑本脚本即可（进度在续传库里，会秒过已导出的部分）。"
      say "   其次的可能：内部盘上其他 App 正在持续写入（微信/微云/浏览器缓存等），"
      say "     把回收出来的空间立刻吃掉。"
    else
      say "   有回收但太慢（最高到 ${rest_best} GiB）。当前阈值 FLOOR=${SPACE_FLOOR_GIB} / CEIL=${SPACE_CEIL_GIB} 对你这台盘偏高。"
      say "   可选处置（任选其一，都不影响已导出的成果）："
      say "     ① 把阈值调低后在 ${CONF} 里改小，例如："
      say "          SPACE_FLOOR_GIB=8"; say "          SPACE_CEIL_GIB=13"
      say "        （代价：留给大视频的余量变少，超大视频可能失败一次后重试）"
      say "     ② 从「系统设置 → 通用 → 储存空间」里清掉几十 GB 长期不用的数据"
      say "     ③ 分批导：先只导图片（内置开关见 SKILL.md「低空间模式」一节）"
    fi
    say
    say "   已落地 $(dest_files) 个文件 / $(du -sh "$DEST" 2>/dev/null | cut -f1 | tr -d ' ')，进度未丢。"
    rule
    exit 3
  fi

  say "▶ 重新开工（本轮已落地 $(dest_files) 个文件）"
done
