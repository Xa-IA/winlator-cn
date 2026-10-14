#!/usr/bin/env bash
# ============================================================================
# fix-prefix-paths.sh - 改写上游二进制资产中写死的包名前缀
#
# 背景 (UPSTREAM.md 已知风险 #1):
#   上游 Winlator 的 box64 / rootfs 等资产按官方包名 com.winlator 构建,
#   其中 box64 的 PT_INTERP 写死为
#     /data/data/com.winlator/files/rootfs/lib/ld-linux-aarch64.so.1
#   本应用包名是 com.winlator.cn, rootfs 位于 /data/data/com.winlator.cn/...
#   应用对 box64 是直接 exec (无显式加载器), 内核解析 PT_INTERP 时会在
#   其他应用的私有目录中找解释器, 必然失败 -> 容器无法启动。
#
# 修复 (对应 UPSTREAM.md 方案 a):
#   1. 所有 ELF 的 PT_INTERP / RPATH 中旧前缀 -> 新前缀 (patchelf, 与长度无关)
#   2. 所有符号链接目标中旧前缀 -> 新前缀 (ln -sfn 重建, sed/patchelf 均不处理链接)
#   3. 所有文本配置 (fonts.conf / alsa.conf / vulkan icd.json / X11 Compose 等)
#      中旧前缀 -> 新前缀 (sed)
#   3. rootfs 的 etc/ld.so.cache 若含旧前缀则删除: 该缓存按官方包名路径
#      生成, 在本包名下全部失效; 删除后加载器回退到 LD_LIBRARY_PATH
#      (应用启动时已设置指向本应用 rootfs lib 目录) + 默认目录,
#      与上游 rootfs 在 Android 上的实际运行方式一致
#   4. ELF rodata 中内嵌的旧前缀字符串 (gladio/virgl libGL 等) 无法用
#      patchelf/sed 修复 (新旧前缀长度不同), 这些 .so 由应用按显式路径加载,
#      内嵌路径只是兜底, 保留为已知限制 (见 UPSTREAM.md)
#
# 用法: fix-prefix-paths.sh <android-assets目录> [appid]
# ============================================================================
set -euo pipefail

ASSETS="$(realpath "${1:?缺少 assets 目录参数}")"
APPID="${2:-com.winlator.cn}"
OLD_PREFIX="/data/data/com.winlator"
NEW_PREFIX="/data/data/${APPID}"
ZSTD_LEVEL="${ZSTD_LEVEL:-19}"

SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
echo "==> 安装所需工具 (patchelf / zstd)"
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    patchelf zstd binutils >/dev/null 2>&1 || true
command -v patchelf >/dev/null || { echo "!!! 缺少 patchelf"; exit 1; }
command -v zstd >/dev/null || { echo "!!! 缺少 zstd"; exit 1; }

TOTAL=0

# ---- 单个 ELF: 解释器 / rpath 旧前缀改写 (只动含旧前缀的) ----
fix_elf() {
    local elf="$1" interp rpath newval
    interp="$(patchelf --print-interpreter "$elf" 2>/dev/null || true)"
    if [ -n "$interp" ] && [[ "$interp" == "$OLD_PREFIX"* ]]; then
        newval="$NEW_PREFIX${interp#"$OLD_PREFIX"}"
        patchelf --set-interpreter "$newval" "$elf"
        echo "    INTERP ${elf#*work/}: $interp"
        echo "        -> $newval"
        TOTAL=$((TOTAL+1))
    fi
    rpath="$(patchelf --print-rpath "$elf" 2>/dev/null || true)"
    if [ -n "$rpath" ] && [[ "$rpath" == *"$OLD_PREFIX"* ]]; then
        newval="${rpath//"$OLD_PREFIX"/"$NEW_PREFIX"}"
        patchelf --set-rpath "$newval" "$elf"
        echo "    RPATH  ${elf#*work/} -> $newval"
        TOTAL=$((TOTAL+1))
    fi
}

# ---- 目录级扫描: 文本 sed + ELF patchelf ----
fix_dir() {
    local dir="$1"
    # 符号链接: 目标含旧前缀时重建为新前缀
    # (sed 不能动链接, 会把链接替换成实体文件; 必须用 ln -sfn 重建)
    while IFS= read -r f; do
        local target newtarget
        target="$(readlink "$f")"
        if [[ "$target" == *"$OLD_PREFIX"* ]]; then
            newtarget="${target//"$OLD_PREFIX"/"$NEW_PREFIX"}"
            ln -sfn "$newtarget" "$f"
            echo "    LINK   ${f#"$dir"/} -> $newtarget"
            TOTAL=$((TOTAL+1))
        fi
    done < <(find "$dir" -type l 2>/dev/null || true)
    # 文本文件: grep 先过滤出含旧前缀的文本文件, sed 逐文件替换
    # (--binary-files=without-match 跳过 ld.so.cache 等二进制)
    while IFS= read -r f; do
        [ -L "$f" ] && continue   # 跳过符号链接: sed -i 会把链接替换成实体文件
        sed -i "s#${OLD_PREFIX}/#${NEW_PREFIX}/#g" "$f"
        echo "    TEXT   ${f#"$dir"/}"
        TOTAL=$((TOTAL+1))
    done < <(grep -rl --binary-files=without-match "$OLD_PREFIX/" "$dir" 2>/dev/null || true)
    # ELF: magic 匹配的文件才跑 patchelf
    while IFS= read -r f; do
        fix_elf "$f"
    done < <(find "$dir" -type f -print0 | while IFS= read -r -d '' f; do
        [ "$(head -c 4 "$f")" = "$(printf '\177ELF')" ] && printf '%s\n' "$f"
    done)
}

# ---- rootfs 专属: 清理含旧前缀的 stale ld.so.cache ----
fix_ldconfig_cache() {
    local dir="$1"
    [ -f "$dir/etc/ld.so.cache" ] || return 0
    grep -q "$OLD_PREFIX/" "$dir/etc/ld.so.cache" 2>/dev/null || return 0
    rm -f "$dir/etc/ld.so.cache"
    echo "    LDCONF etc/ld.so.cache 含旧包名路径, 已删除 (回退到 LD_LIBRARY_PATH 解析)"
    TOTAL=$((TOTAL+1))
}

# ---- 主流程: 逐个 tzst 解包 -> 改写 -> (有改动才)重打包 ----
count_tzst=0
while IFS= read -r -d '' tz; do
    tmp="$(mktemp -d /tmp/tzst-work.XXXXXX)"
    tar -I zstd -xf "$tz" -C "$tmp"
    chmod -R u+w "$tmp"   # 防止打包内只读权限导致 sed -i / patchelf 失败
    before="$TOTAL"
    echo "--> ${tz#"$ASSETS"/}"
    fix_dir "$tmp"
    if [ "$(basename "$tz")" = "rootfs.tzst" ]; then
        fix_ldconfig_cache "$tmp"
    fi
    if [ "$TOTAL" -gt "$before" ]; then
        ( cd "$tmp" && tar --numeric-owner --owner=0 --group=0 --sort=name \
            -cf "$tz.new" --use-compress-program="zstd -q -$ZSTD_LEVEL -T0" . )
        mv "$tz.new" "$tz"
        count_tzst=$((count_tzst+1))
        echo "    已重打包 ($(( TOTAL - before )) 处改动)"
    else
        echo "    无旧前缀内容, 跳过"
    fi
    rm -rf "$tmp"
done < <(find "$ASSETS" -name '*.tzst' -print0)

# ---- 最终断言: box64 的解释器必须等于本应用路径, 否则容器必挂 ----
box64_tz="$(find "$ASSETS" -path '*/box64/box64-*.tzst' | sort -V | tail -1)"
[ -n "$box64_tz" ] || { echo "!!! 找不到 box64 资产"; exit 1; }
verify_tmp="$(mktemp -d /tmp/box64-verify.XXXXXX)"
tar -I zstd -xf "$box64_tz" -C "$verify_tmp"
box64_bin="$(find "$verify_tmp" -type f -name box64 | head -1)"
want_interp="$NEW_PREFIX/files/rootfs/lib/ld-linux-aarch64.so.1"
got_interp="$(patchelf --print-interpreter "$box64_bin" 2>/dev/null || true)"
rm -rf "$verify_tmp"
if [ "$got_interp" != "$want_interp" ]; then
    echo "!!! box64 解释器仍为 '$got_interp', 期望 '$want_interp': 修复未生效"
    exit 1
fi

echo "==> 完成: $count_tzst 个资产重打包, 共 $TOTAL 处改写"
echo "    box64 解释器 = $got_interp ✓"

# ---- 最终断言2: 任何资产中不得再有指向旧前缀的符号链接 ----
# (v1.0.0 的 container_pattern 里 .wine/dosdevices/z: 是指向旧包名的绝对链接,
#  sed/patchelf 都管不到符号链接, 必须显式重建, 否则 wine 的 Z: 盘断裂)
while IFS= read -r -d '' tz; do
    if tar -I zstd -tvf "$tz" 2>/dev/null | grep '^l' | grep -q -- "$OLD_PREFIX"; then
        echo "!!! ${tz#"$ASSETS"/} 仍含指向旧前缀的符号链接:"
        tar -I zstd -tvf "$tz" 2>/dev/null | grep '^l' | grep -- "$OLD_PREFIX" | head -3
        exit 1
    fi
done < <(find "$ASSETS" -name '*.tzst' -print0)
echo "    符号链接检查 ✓"
echo "FIX_PREFIX_PATHS_OK"
