#!/bin/bash
# ============================================================================
# sim-guard.sh —— space_guard.sh 的**离线回归测试**
#
# 【它解决什么】
# space_guard 的「通道是否还活着」是一套启发式判据，改一次就可能引入新的误判
# （2026-10-07 那次误报白丢一轮 20 分钟产出，见 gotchas 第 36、37 节）。
# 而它平时只能对着真实图库跑 —— 验证代价是「几十分钟 + 可能误杀一轮导出」。
# 这里造一个**完全隔离**的沙箱：假 df / pgrep / lsof / killall / open /
# caffeinate + 假 icloud_export.sh，不碰真实 Photos、外置盘、续传库。
#
# 【用法】
#   bash scripts/sim-guard.sh            # 跑全部场景
#   bash scripts/sim-guard.sh chain      # 只跑场景 1
#
# 【七个场景与期望】
#   1 chain  2 轮有产出 + 3 轮零产出 → 前 2 轮判「通道活着、不重启 Photos」，
#            后 2 轮各冷启动一次，第 5 轮 exit 4        期望 rc=4, killall=2
#   2 converge  零产出且 missing 连续两轮相同 → exit 0   期望 rc=0, killall=1
#   3 spin    零产出且 missing 来回跳（100/101/100）→ 靠 NO_GROWTH_MAX 收敛
#            并 exit 4，**不能无限绕圈**                  期望 rc=4, killall=2
#   4 resume  有续传库（含三个日期）→ 取最大日期做 FROM_DATE，
#            跳过「重走已导出项」那段固定开销            期望 rc=0, FROM_DATE=2026-03-14
#   5 stallflat 零产出 + **内部盘贴在 13 GiB 一动不动** → 不能判成空间饥饿
#            （那样只会去休息，而磁盘压根没在消耗），必须走冷启动 Photos
#            期望 rc=4, killall=2
#   6 stalldrop 零产出，但**本轮先正常下载吃掉 23 GiB**（40→17 GiB）后才卡住
#            → 同样不能判成空间饥饿：跌幅大只说明「早先下载过」，与「此刻为什么
#            停」无关。必须只看「盘是否已跌破 FLOOR」→ 17 ≥ 12 → 通道卡死
#            期望 rc=4, killall=2
#   7 resume2 假续传库每轮往前进一天 → 验证 FROM_DATE **每轮重算**，
#            不是第 1 轮算完就缓存住（否则每轮都退回旧出口、白重走一段）
#            期望 rc=0, 末轮 FROM_DATE=2026-05-01
#
# 场景 3 是专门补的：旧版没有零增长护栏，missing 一振荡就永远收敛不了。
# 场景 4 验证尾段跳转：没有它，每轮都要白走 5-6 分钟、白吃十几 GiB。
# 场景 5/6 验证空转判别：判据**只能**看「盘是否已跌破 FLOOR」，不能看
# 「盘是否高于 CEIL」（场景 5 证伪），也不能看「本轮跌了多少」（场景 6 证伪）。
# ============================================================================
set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 允许指向待测副本：GUARD_SRC=/tmp/x.sh bash sim-guard.sh
GUARD_SRC="${GUARD_SRC:-${SKILL_DIR}/scripts/space_guard.sh}"
ONLY="${1:-all}"

PASS=0; FAIL=0
say_ok()   { printf '  ✅ %s\n' "$*"; PASS=$((PASS+1)); }
say_bad()  { printf '  ❌ %s\n' "$*"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# run_scenario <名字> <导出模式> <每轮新建文件数(空格分隔)> <每轮 missing 值> \
#              <期望 rc> <期望 killall 次数>
# ---------------------------------------------------------------------------
run_scenario() {
  local NAME="$1" MODE="$2" FPLAN="$3" MPLAN="$4" EXP_RC="$5" EXP_KA="$6"
  local SEED_DB="${7:-}" EXP_FROM="${8:-}" SIM_FREE="${9:-200}" SIM_FREEPLAN="${10:-}" SIM_DBPLAN="${11:-}"
  local ROOT; ROOT="$(mktemp -d "/tmp/sim-guard-${NAME}.XXXXXX")"

  mkdir -p "$ROOT"/home/.local/bin "$ROOT/ctl" "$ROOT/conf" "$ROOT/skill/scripts" "$ROOT/log"
  mkdir -p "$ROOT/vol/iCloud导出-2026/_导出报告/日志"

  # ---------- 假命令 --------------------------------------------------------
  # df：第一行是表头，第二行是数据（space_guard 用 `df -k / | awk NR==2`）。
  cat > "$ROOT/home/.local/bin/df" <<'FAKE'
#!/bin/bash
# 若给了轨迹文件 free_plan：每次调用弹出一行（模拟「本轮先正常下载吃掉一截
# 空间、随后才卡死」）。弹空后回落到 free 的定值。
P="$SIM_CTL/free_plan"; F=""
if [ -s "$P" ]; then
  F="$(head -1 "$P")"
  tail -n +2 "$P" > "$P.t" && mv "$P.t" "$P"
fi
[ -n "$F" ] || F="$(cat "$SIM_CTL/free" 2>/dev/null || echo 200)"
echo "Filesystem 1024-blocks Used Available Capacity iused ifree %iused Mounted on"
printf '/dev/fake %d %d %d 1%% 0 0 0%% /\n' \
  $((926*1024*1024)) $(((926-F)*1024*1024)) $((F*1024*1024))
FAKE
  cat > "$ROOT/home/.local/bin/pgrep" <<'FAKE'
#!/bin/bash
for a in "$@"; do case "$a" in *MacOS/Photos*) echo 4242; exit 0;; esac; done
exit 1
FAKE
  # ⚠️ 输出里必须出现 `Photos Library` 字样：守卫用
  #    `lsof -p <pid> | grep -q "Photos Library"` 判图库是否已加载。
  cat > "$ROOT/home/.local/bin/lsof" <<'FAKE'
#!/bin/bash
echo "Photos 4242 helufan 12r REG /Users/x/Pictures/Photos Library.photoslibrary/database/Photos.sqlite"
FAKE
  # killall 记账，用来数「冷启动 Photos 被调了几次」
  cat > "$ROOT/home/.local/bin/killall" <<'FAKE'
#!/bin/bash
echo "killall $*" >> "$SIM_CTL/killall_calls"
exit 0
FAKE
  for c in open osascript caffeinate; do
    printf '#!/bin/bash\nexit 0\n' > "$ROOT/home/.local/bin/$c"
  done
  chmod +x "$ROOT"/home/.local/bin/*

  # ---------- 假导出器 ------------------------------------------------------
  # hang 模式：建完文件后一直挂着刷 `Skipping missing`（模拟被杀）
  # exit 模式：建完文件、打一行 Processed 汇总后自己退出（模拟自然跑完）
  cat > "$ROOT/skill/scripts/icloud_export.sh" <<'FAKE'
#!/bin/bash
DEST="$SIM_DEST"; LGD="$SIM_LOG"
mkdir -p "$DEST" "$LGD"
L="$LGD/full-$(date +%H%M%S)-$$.log"; : > "$L"
printf '%s\n' "${FROM_DATE:-<unset>}" >> "$SIM_CTL/fromdate"
pop() { local f="$1" v; v="$(head -1 "$f" 2>/dev/null)"; [ -n "$v" ] || v=0
        printf '%s\n' "$(tail -n +2 "$f" 2>/dev/null)" > "$f.t" && mv "$f.t" "$f"; echo "$v"; }
# 每轮往续传库里追加一条更晚的日期，模拟「库在推进」。
# 用来验证守卫**每轮重算** FROM_DATE，而不是第 1 轮算完就把它缓存住。
BD="$(pop "$SIM_PLAN_DB")"
if [ -n "$BD" ] && [ "$BD" != "0" ] && [ -f "${SIM_DB:-/nonexistent}" ]; then
  python3 - "$SIM_DB" "$BD" <<'PY' >/dev/null 2>&1
import sys, sqlite3
con = sqlite3.connect(sys.argv[1])
con.execute("insert into photoinfo values (?, ?)",
            ("added-" + sys.argv[2], '{"date": "%sT10:00:00+08:00"}' % sys.argv[2]))
con.commit()
PY
fi
N="$(pop "$SIM_PLAN_F")"; M="$(pop "$SIM_PLAN_M")"
echo "[模拟导出] 本轮计划新建 ${N} 个文件，missing=${M}" >> "$L"
i=0; while [ "$i" -lt "$N" ]; do i=$((i+1)); : > "$DEST/f${i}-$$.jpg"; done
if [ "$SIM_MODE" = "exit" ]; then
  echo "Processed: 100 photos, exported: ${N}, skipped: 0, missing: ${M}, error: 0" >> "$L"
  exit 0
fi
t=0
while : ; do
  t=$((t+1))
  echo "Skipping missing original photo SIM_$(printf '%04d' "$t").JPG (U$t)" >> "$L"
  sleep 1
done
FAKE
  chmod +x "$ROOT/skill/scripts/icloud_export.sh"

  # ---------- 复制守卫并只缩短时间常数（判定逻辑原样）-----------------------
  # ⚠️ 只改「多久」，不改「怎么判」—— 改了处置逻辑这测试就没有意义了。
  cp "$GUARD_SRC" "$ROOT/skill/scripts/space_guard.sh"
  local S="$ROOT/skill/scripts/space_guard.sh"
  # ⚠️ 不要写 `sed -i ''`：本机的 sed 是 toybox shim，它会**边改文件边报**
  #    `sed: : No such file or directory` 并返回 1（文件其实改对了，但 rc 是坏的，
  #    在 `set -e` 或 `|| die` 的脚本里会直接崩）。用重定向 + mv 最稳。
  sed -e 's|^POLL_SEC=30|POLL_SEC=2|' \
      -e 's|^MISS_MAX=50|MISS_MAX=1|' \
      -e 's|^CHANNEL_FIX_MAX=5|CHANNEL_FIX_MAX=2|' \
      -e 's|^COLD_MAX=8|COLD_MAX=99|' \
      -e 's|^STALL_MIN=30|STALL_MIN=999|' \
      -e 's|^REST_MAX_MIN=180|REST_MAX_MIN=1|' \
      -e 's|^REST_HARD_MAX_MIN=720|REST_HARD_MAX_MIN=2|' \
      -e 's|^PHOTOS_WAIT_MIN=180|PHOTOS_WAIT_MIN=1|' \
      -e 's|^DRIVE_WAIT_SEC=600|DRIVE_WAIT_SEC=5|' \
      -e 's|MISS_WINDOW_MIN\*60/POLL_SEC|SIM_WINDOW_POLLS|g' \
      "$S" > "$S.tmp" && mv "$S.tmp" "$S"
  if ! grep -q SIM_WINDOW_POLLS "$S"; then
    echo "  ❌ 窗口替换失败（守卫里的窗口表达式改了？测试需要同步）"; FAIL=$((FAIL+1)); return
  fi
  # 冷启动里的 `sleep 3` / 图库等待的 `sleep 10` 换成 0，省时间
  perl -pi -e 's/sleep 3$/sleep 0/; s/^(\s*)sleep 10$/$1sleep 0/' "$S"

  cat > "$ROOT/conf/sync.conf" <<CONF
SRC_LIBRARY="$ROOT/fakelib.photoslibrary"
DEST_VOLUME="$ROOT/vol"
DEST_SUBDIR="iCloud导出-2026"
DOWNLOAD_MISSING=1
SIM_WINDOW_POLLS=3
CONF

  printf '%s\n' $FPLAN | tr ' ' '\n' > "$ROOT/ctl/plan_f"
  printf '%s\n' $MPLAN | tr ' ' '\n' > "$ROOT/ctl/plan_m"
  echo "$SIM_FREE" > "$ROOT/ctl/free"
  if [ -n "$SIM_FREEPLAN" ]; then printf '%s\n' $SIM_FREEPLAN > "$ROOT/ctl/free_plan"; else : > "$ROOT/ctl/free_plan"; fi
  if [ -n "$SIM_DBPLAN" ]; then printf '%s\n' $SIM_DBPLAN > "$ROOT/ctl/plan_db"; else : > "$ROOT/ctl/plan_db"; fi
  : > "$ROOT/ctl/killall_calls"
  : > "$ROOT/ctl/fromdate"

  # 可选：造一个假续传库，验证「尾段跳转」—— 守卫从 photoinfo.date 推出 FROM_DATE。
  # 每个元素可以写多个日期，逗号分隔；守卫应取其中最大的那个。
  if [ -n "$SEED_DB" ]; then
    mkdir -p "$ROOT/home/.cache/osxphotos"
    local PY; PY="$(command -v python3 2>/dev/null)"
    if [ -n "$PY" ]; then
      "$PY" - "$ROOT/home/.cache/osxphotos/iCloud导出-2026-export.db" "$SEED_DB" <<'PYEOF'
import sys, sqlite3
con = sqlite3.connect(sys.argv[1])
con.execute("create table photoinfo (uuid text primary key, photoinfo text)")
for i, d in enumerate(sys.argv[2].split(",")):
    con.execute("insert into photoinfo values (?, ?)",
                ("u%d" % i,
                 '{"date": "%sT10:00:00+08:00", "original_filename": "f.jpg"}' % d))
con.commit()
PYEOF
    else
      echo "  ⚠️ 隔离 PATH 下找不到 python3 —— 本场景的 FROM_DATE 断言会失败"
    fi
  fi

  echo "▶ 场景 ${NAME}（模式 ${MODE}｜文件计划 [${FPLAN}]｜missing 计划 [${MPLAN}]｜内部盘 ${SIM_FREE} GiB${SIM_FREEPLAN:+，轨迹 [${SIM_FREEPLAN}]}）"
  env -i HOME="$ROOT/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      SIM_CTL="$ROOT/ctl" SIM_LOG="$ROOT/vol/iCloud导出-2026/_导出报告/日志" \
      SIM_DEST="$ROOT/vol/iCloud导出-2026" \
      SIM_PLAN_F="$ROOT/ctl/plan_f" SIM_PLAN_M="$ROOT/ctl/plan_m" \
      SIM_PLAN_DB="$ROOT/ctl/plan_db" SIM_DB="$ROOT/home/.cache/osxphotos/iCloud导出-2026-export.db" \
      SIM_MODE="$MODE" SYNC_CONF="$ROOT/conf/sync.conf" \
      /bin/bash "$S" > "$ROOT/guard.out" 2>&1
  local RC=$?

  local KA; KA="$(wc -l < "$ROOT/ctl/killall_calls" | tr -d ' ')"
  [ "$RC" = "$EXP_RC" ] && say_ok "退出码 ${RC}（期望 ${EXP_RC}）" \
                        || say_bad "退出码 ${RC}（期望 ${EXP_RC}）"
  [ "$KA" = "$EXP_KA" ] && say_ok "冷启动 Photos ${KA} 次（期望 ${EXP_KA}）" \
                        || say_bad "冷启动 Photos ${KA} 次（期望 ${EXP_KA}）"

  if [ -n "$EXP_FROM" ]; then
    local GF; GF="$(tail -1 "$ROOT/ctl/fromdate" 2>/dev/null)"
    [ "$GF" = "$EXP_FROM" ] && say_ok "传给导出器的 FROM_DATE=${GF}（期望 ${EXP_FROM}）" \
                            || say_bad "传给导出器的 FROM_DATE=[${GF}]（期望 ${EXP_FROM}）"
  fi

  # 结论行取最后几条，方便人眼看懂这轮判了什么
  grep -E '结论|通道|missing|零新增|完成' "$ROOT/guard.out" 2>/dev/null | tail -4 | sed 's/^/      /'
  echo "  （完整输出留在 ${ROOT}/guard.out）"
  echo
}

echo "=========== space_guard 离线回归测试 ==========="
echo

if [ "$ONLY" = "all" ] || [ "$ONLY" = "chain" ]; then
  run_scenario chain hang "100 100 0 0 0" "0 0 0 0 0" 4 2
fi
if [ "$ONLY" = "all" ] || [ "$ONLY" = "converge" ]; then
  run_scenario converge exit "0 0" "100 100" 0 1
fi
if [ "$ONLY" = "all" ] || [ "$ONLY" = "spin" ]; then
  run_scenario spin exit "0 0 0" "100 101 100" 4 2
fi

# 场景 4：尾段跳转。假续传库里混着三个日期，守卫应取最大者做 FROM_DATE，
# 从而跳过「重走已导出项」这段每轮 5-6 分钟、十几 GiB 的固定开销。
if [ "$ONLY" = "all" ] || [ "$ONLY" = "resume" ]; then
  run_scenario resume exit "0 0" "100 100" 0 1 \
    "2026-01-05,2026-03-14,2026-02-20" "2026-03-14"
fi

# 场景 5：卡死但**不消耗空间**。这是 2026-10-08 23:2x 实测踩到的坑：
# osxphotos 卡在 AppleScript 等 Photos 回话，内部盘一分钱没花，一直贴在 13 GiB。
# 旧判据「内部盘 < CEIL(18) → 空间饥饿」会把它识别成空间问题，于是只会去休息，
# 而磁盘本来就没在消耗 → 休息也等不到回血 → 绕圈到零增长护栏后误报 exit 4。
# 初始 13 GiB 是刻意的：它低于 CEIL，正好卡住旧判据。
if [ "$ONLY" = "all" ] || [ "$ONLY" = "stallflat" ]; then
  run_scenario stallflat hang "0 0 0 0" "0 0 0 0" 4 2 "" "" 13
fi

# 场景 6：卡死**之前先正常下载吃掉一大截空间**（40 → 17 GiB），随后在 17 GiB
# 处卡住不动。这是 2026-10-09 23:2x 的实测形态：
#   - 旧判据「本轮跌 ≥3 GiB 就算空间饥饿」会看到跌了 23 GiB → 误判成空间问题
#     → 去休息 → 而休息回收不了任何东西 → 死循环到 exit 3，方向完全指错。
#   - 新判据只看「盘是否已跌破 FLOOR」：17 GiB ≥ FLOOR=12 → 通道卡死 → 冷启动 Photos。
# 40/17 是刻意的：40 让「本轮跌幅」很大（23），17 又稳稳高于 FLOOR。
if [ "$ONLY" = "all" ] || [ "$ONLY" = "stalldrop" ]; then
  run_scenario stalldrop hang "0 0 0 0" "0 0 0 0" 4 2 "" "" 17 \
    "40 40 40 40 40 40 40 40 17 17 17 17 17 17 17 17 17 17 17 17"
fi

# 场景 7：验证 FROM_DATE **每轮重算**，而不是第 1 轮算完就缓存住。
# 这是 2026-10-09 23:2x 实测：第 1 轮算出 2026-03-14，之后每轮都从 03-14 重走 45 项，
# 哪怕续传库早已推进到 2026-04-07 —— 因为算出的值被写回了 FROM_DATE 变量，
# 下一轮误判成「用户显式指定的」。
# 这里让假导出器每轮往假续传库追加一条更晚的日期：
#   第 1 轮 → 2026-03-14；第 2 轮 → 库已推进到 2026-05-01，应改用 2026-05-01。
if [ "$ONLY" = "all" ] || [ "$ONLY" = "resume2" ]; then
  run_scenario resume2 exit "0 0" "100 100" 0 1 \
    "2026-03-14" "2026-05-01" 200 "" "2026-05-01 2026-06-01"
fi

echo "=========== 结果：通过 ${PASS} 项 / 失败 ${FAIL} 项 ==========="
[ "$FAIL" = "0" ] || exit 1
exit 0
