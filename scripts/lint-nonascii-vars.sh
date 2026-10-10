#!/bin/bash
# ============================================================================
# bash 静态检查：查出「变量名被非 ASCII 字节粘连」这个坑
#
# 背景（gotchas.md 第 5e 节）：
#   macOS 自带的是 bash 3.2。它按字节解析变量名，遇到先导字节 >= 0x80 的
#   UTF-8 字符时会**把它并进变量名**。于是中文提示里写
#       echo "已启动（pid=$NEWPID）"
#   会被解析成变量 `NEWPID）`，配合 `set -u` 直接报 unbound variable 并中止脚本。
#
# 正确写法：**中文里插变量一律加花括号** —— ${NEWPID}
#
# 另一条同类坑（规则 2）：
#   把含花括号的默认值塞进参数展开，花括号会提前闭合展开式，默认值被截断。
#       : "${DIR_TEMPLATE:={created.year}/{created.mm}}"   # ❌ 结果是 {created.year}
#   正确写法：
#       [ -n "${DIR_TEMPLATE:-}" ] || DIR_TEMPLATE='{created.year}/{created.mm}'
#   危害比规则 1 更隐蔽：不报错，只是目录结构静默变错。
#
# 用法：
#   bash scripts/lint-nonascii-vars.sh                      # 查默认范围
#   bash scripts/lint-nonascii-vars.sh 文件1 文件2 ...       # 查指定文件
# ============================================================================

set -u
PY="${PY:-/usr/bin/python3}"

if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  FILES=("$SELF_DIR"/*.sh
         "$HOME/WorkBuddy/2026-10-05-21-20-32"/*.command
         "$HOME/WorkBuddy/2026-10-05-21-20-32"/*.sh)
fi

"$PY" - "${FILES[@]}" <<'PYEOF'
import re, sys, pathlib

# 规则 1：$VAR 后面紧跟非 ASCII 字符 → 高位字节被并进变量名（gotchas 第 5e 节）
PAT1 = re.compile(r'\$([A-Za-z_][A-Za-z0-9_]*)([^\x00-\x7F])')

# 规则 2：`${VAR:=默认值}` / `${VAR:-默认值}` 的默认值里含【裸】花括号 → 花括号提前
#         闭合参数展开，默认值被截断。实测 `: "${T:={a}/{b}}"` 后 T 只等于 `{a}`。
#         ⚠️ 必须排除 `${a:-${b:-c}}` 这种嵌套展开 —— 它在 bash 3.2 下完全合法
#         （实测确认），用 `(?<!\$)` 把「$ 后面跟的 {」排除掉。
PAT2 = re.compile(r'\$\{[A-Za-z_][A-Za-z0-9_]*:[-=?+][^}]*?(?<!\$)\{')

total1 = total2 = 0
for f in sys.argv[1:]:
    p = pathlib.Path(f)
    if not p.exists() or not p.is_file():
        continue
    text = p.read_text(errors="replace")
    hits1, hits2 = [], []
    for i, line in enumerate(text.splitlines(), 1):
        stripped = line.lstrip()
        # 纯注释行不影响执行，只提示
        comment = stripped.startswith("#")
        for m in PAT1.finditer(line):
            hits1.append((i, m.group(1), m.group(2), comment, line.strip()[:100]))
        for m in PAT2.finditer(line):
            hits2.append((i, m.group(0), comment, line.strip()[:100]))

    if not hits1 and not hits2:
        print(f"✅ {p.name}")
        continue

    real1 = [h for h in hits1 if not h[3]]
    real2 = [h for h in hits2 if not h[2]]
    print(f"\n{'❌' if (real1 or real2) else 'ℹ️ '} {p}")

    for i, var, ch, comment, line in hits1:
        tag = "注释(无害)" if comment else "★ 会导致 set -u 报 unbound variable"
        print(f"   [非ASCII粘连] L{i}: ${var} 紧跟 {ch!r}  {tag}")
        print(f"        {line}")
        if not comment:
            print(f"        改成：${{{var}}}")
    for i, frag, comment, line in hits2:
        tag = "注释(无害)" if comment else "★ 默认值会被花括号截断"
        print(f"   [花括号截断] L{i}: {frag}…  {tag}")
        print(f"        {line}")
        if not comment:
            print(f"        改成：先判空再兜底，例如")
            print(f"              [ -n \"${{VAR:-}}\" ] || VAR='含{{}}的默认值'")
    total1 += len(real1); total2 += len(real2)

total = total1 + total2
print()
print(f"非 ASCII 粘连：{total1} 处    花括号截断：{total2} 处")
sys.exit(1 if total else 0)
PYEOF
