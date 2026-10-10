#!/bin/bash
# ============================================================================
# 给 osxphotos / photoscript 打上本机运行所必需的 4 个补丁
#
# 为什么需要：osxphotos（含 photoscript）有两条会毁掉整轮 iCloud 导出的行为：
#   ① AppleScript 超时后 killall Photos —— 而 Photos 被自动拉起时不重新打开图库，
#      下载通道就此永久失效（gotchas.md 第 23 节）
#   ② AppleScript 的 `with timeout` 把 iCloud 下载耗时也算在内 —— 默认 120 秒
#      只够下约 130 MB，大视频必然失败（gotchas.md 第 25 节）
#
# 本脚本幂等，可反复运行。pipx upgrade osxphotos 之后必须重跑。
#   bash ~/.workbuddy/skills/sync-icloud-photos-to-drive/scripts/apply-patches.sh
# ============================================================================

set -u

VENV="$HOME/.local/share/pipx/venvs/osxphotos"
V="$(ls -d "$VENV"/lib/python*/site-packages 2>/dev/null | head -1)"

if [ -z "$V" ]; then
  echo "❌ 找不到 osxphotos 的 site-packages（$VENV/lib/python*/site-packages）"
  echo "   先安装：pipx install osxphotos"
  exit 1
fi

echo "site-packages: $V"
echo "备份目录建议: ~/WorkBuddy/2026-10-05-21-20-32/backup/"
echo

/usr/bin/python3 - "$V" <<'PYEOF'
import pathlib, re, sys

V = pathlib.Path(sys.argv[1])
results = []

def report(tag, ok, note=""):
    results.append((tag, ok, note))
    print(f"{'✅' if ok else '⚠️ '} {tag}{(' — ' + note) if note else ''}")

ALREADY = "LOCAL PATCH 2026-10-06"

# ---------------------------------------------------------------- ① killall 补丁
p = V / "photoscript" / "script_loader.py"
s = p.read_text()
if ALREADY in s:
    report("① 禁用 killall Photos", True, "已在位")
else:
    anchor = (
        '    try:\n'
        '        logger.warning(\n'
        '            "⚠️  run_script: AppleScript timed out: retrying killall + run_script"\n'
        '        )\n'
    )
    if anchor not in s:
        report("① 禁用 killall Photos", False, "锚点没找到，需人工处理")
    else:
        patch = (
            '    # ==== LOCAL PATCH 2026-10-06 (helufan) ==================================\n'
            '    # 禁用「AppleScript 超时 → killall Photos」这条破坏性自愈路径。\n'
            '    # Photos 被 kill 后由 AppleScript/open 重新拉起时不会重新打开图库，\n'
            '    # 下载通道会永久失效，之后每一项都 "Skipping missing original photo"。\n'
            '    # 详见 skill: sync-icloud-photos-to-drive / references/gotchas.md 第 23 节\n'
            '    return None\n'
            '    # ======================================================================\n'
        )
        p.write_text(s.replace(anchor, patch + anchor, 1))
        report("① 禁用 killall Photos", True, "已打")

# ------------------------------------------------------- ② 错误阈值（等同于禁用）
p = V / "osxphotos" / "photoexporter.py"
s = p.read_text()
m = re.search(r'^APPLESCRIPT_ERROR_THRESHOLD = .*$', s, re.M)
if not m:
    report("② 关掉「连续错误→重启 Photos」阈值", False, "没找到该常量")
elif m.group(0).strip() == "APPLESCRIPT_ERROR_THRESHOLD = 10**9":
    report("② 关掉「连续错误→重启 Photos」阈值", True, "已在位")
else:
    s = s[:m.start()] + "APPLESCRIPT_ERROR_THRESHOLD = 10**9" + s[m.end():]
    p.write_text(s)
    report("② 关掉「连续错误→重启 Photos」阈值", True, f"已打（原：{m.group(0).strip()}）")

# ------------------------------------------------------------- ③ 导出超时 4 小时
p = V / "osxphotos" / "exportoptions.py"
s = p.read_text()
m = re.search(r'^    timeout: int = (\d+)\s*$', s, re.M)
if not m:
    report("③ 导出超时 → 14400 秒", False, "没找到 timeout 字段")
elif m.group(1) == "14400":
    report("③ 导出超时 → 14400 秒", True, "已在位")
else:
    s = s[:m.start()] + "    timeout: int = 14400" + s[m.end():]
    p.write_text(s)
    report("③ 导出超时 → 14400 秒", True, f"已打（原：{m.group(1)} 秒）")

# --------------------------------------------- ④ AppleScript with timeout 下限
p = V / "photoscript" / "photoscript.applescript"
s = p.read_text()
if "if theTimeOut < 14400 then set theTimeOut to 14400" in s:
    report("④ AppleScript 超时下限 4 小时", True, "已在位")
else:
    anchor = (
        '\tphotosLibraryWaitForPhotos(WAIT_FOR_PHOTOS)\n'
        '\ttell application "Photos"\n'
        '\t\tset thePath to thePath\n'
    )
    if s.count(anchor) != 1:
        report("④ AppleScript 超时下限 4 小时", False,
               f"锚点命中 {s.count(anchor)} 次（应为 1），需人工处理")
    else:
        patch = (
            '\t-- ==== LOCAL PATCH 2026-10-06 (helufan) ==============================\n'
            '\t-- 下方 with timeout 把「Photos 从 iCloud 下载原图」的耗时也算进去，\n'
            '\t-- 默认 120 秒只够下约 130 MB，大视频必然超时失败。强制下限 4 小时。\n'
            '\tif theTimeOut < 14400 then set theTimeOut to 14400\n'
            '\t-- =====================================================================\n'
        )
        p.write_text(s.replace(anchor, patch + anchor, 1))
        report("④ AppleScript 超时下限 4 小时", True, "已打")

print()
bad = [r for r in results if not r[1]]
print(f"结果：{len(results) - len(bad)}/{len(results)} 项就绪")
sys.exit(1 if bad else 0)
PYEOF
RC=$?

echo
echo "--- 语法自检 ---"
if osacompile -o /tmp/_ps_check.scpt "$V/photoscript/photoscript.applescript" 2>/dev/null; then
  echo "✅ AppleScript 编译通过"; rm -f /tmp/_ps_check.scpt
else
  echo "❌ AppleScript 编译失败 —— 补丁有问题，立刻从 backup/ 还原"; RC=1
fi
if "$VENV/bin/python" -m py_compile "$V/osxphotos/exportoptions.py" "$V/osxphotos/photoexporter.py" "$V/photoscript/script_loader.py" 2>/dev/null; then
  echo "✅ Python 语法通过"
else
  echo "❌ Python 语法失败 —— 立刻从 backup/ 还原"; RC=1
fi

echo
if [ "$RC" = "0" ]; then
  echo "全部就绪。注意：补丁只对【新启动】的 osxphotos 进程生效。"
  echo "若此刻有导出在跑，它仍用旧超时；需重启该轮才能生效。"
else
  echo "有项目未就绪，请看上面的 ⚠️ 行。"
fi
exit "$RC"
