#!/usr/bin/env python3
"""在已解包的资产目录中原位替换硬编码的包名路径。

为什么需要它
------------
上游 Winlator 的二进制资产 (rootfs / box64 / 各驱动) 是按官方包名
com.winlator 构建的, 路径被硬编码进 ELF 的 rodata / .dynstr 以及文本配置里。
sed 只处理文本文件, patchelf 只处理 PT_INTERP / RPATH, 两者都管不到
libxcb.so.1 里那条决定 X 套接字位置的字符串:

    /data/data/com.winlator/files/rootfs/tmp/.X11-unix/X

而应用的 X Server 把套接字建在 <本应用>/files/rootfs/tmp/.X11-unix/X0,
两者对不上 -> XOpenDisplay 失败 -> winex11.so 初始化失败 -> Wine 退回
nodrv -> explorer 建不了窗口 -> 容器永远停在"正在启动…"。

为什么必须等长
--------------
这些字符串后面还跟着子路径 (/tmp/.X11-unix/X、/usr/share/locale ...)。
若新前缀比旧前缀长, 就地替换必然越界; 若比旧前缀短, 补 NUL 会把子路径
截断成孤儿字节。因此新旧字符串必须等长, 才能保证"只换包名, 其余不变"。

    /data/data/com.winlator   (23)
    /data/data/com.wlator.cn  (23)   <- applicationId 取 12 字符, 与官方等长

用法
----
    patch-binary-prefix.py <old> <new> <dir>          # 替换, stdout 输出处数
    patch-binary-prefix.py --check <old> <dir>        # 校验, 有残留则 exit 1
"""
import os
import sys


def walk_files(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            if os.path.islink(p):
                continue  # 符号链接由 fix-prefix-paths.sh 用 ln -sfn 重建
            yield p


def replace(root, old: bytes, new: bytes) -> int:
    total = 0
    for p in walk_files(root):
        try:
            with open(p, "rb") as f:
                data = f.read()
        except OSError:
            continue
        cnt = data.count(old)
        if not cnt:
            continue
        with open(p, "wb") as f:  # 覆盖写, 保留原文件权限
            f.write(data.replace(old, new))
        total += cnt
        print("    BIN    %s (%d)" % (os.path.relpath(p, root).replace(os.sep, "/"), cnt),
              file=sys.stderr)
    return total


def check(root, old: bytes) -> int:
    total = 0
    for p in walk_files(root):
        try:
            with open(p, "rb") as f:
                data = f.read()
        except OSError:
            continue
        cnt = data.count(old)
        if cnt:
            total += cnt
            print("    残留 %s (%d)" % (os.path.relpath(p, root).replace(os.sep, "/"), cnt),
                  file=sys.stderr)
    return total


def main() -> int:
    args = sys.argv[1:]
    if args and args[0] == "--check":
        if len(args) != 3:
            print("usage: patch-binary-prefix.py --check <old> <dir>", file=sys.stderr)
            return 2
        old, root = args[1].encode(), args[2]
        left = check(root, old)
        if left:
            print("!!! %s 中仍有 %d 处旧前缀 %s" % (root, left, args[1]), file=sys.stderr)
            return 1
        return 0

    if len(args) != 3:
        print("usage: patch-binary-prefix.py <old> <new> <dir>", file=sys.stderr)
        return 2
    old, new, root = args[0].encode(), args[1].encode(), args[2]
    if len(old) != len(new):
        print("!!! 新旧前缀长度不等 (%d != %d): 就地替换会截断子路径"
              % (len(old), len(new)), file=sys.stderr)
        return 2
    print(replace(root, old, new))
    return 0


if __name__ == "__main__":
    sys.exit(main())
