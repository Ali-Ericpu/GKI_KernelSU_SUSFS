#!/usr/bin/env bash
#
# backport_epoll_pwait2.sh
#
# 把 Linux 5.11 的 epoll_pwait2(2) 回移到 ACK android12-5.10 内核。
#
# 背景
# ----
# Android 13+ 的 bionic Looper 会调用 epoll_pwait2。如果内核没有实现这个
# 系统调用，调用方拿到的是 ENOSYS，SystemUI 的 RenderThread 随即以
#     Abort message: 'RenderThread Looper POLL_ERROR!'
# 反复 abort，表现为锁屏界面黑屏/亮屏闪烁、系统无法正常使用。
#
# ACK 的 android12-5.10 分支（含 HEAD 5.10.269）至今都没有这个 syscall，
# 所以这里手工补齐。实测中，带该 syscall 的原厂/移植 ROM 内核与本内核的
# 系统调用全集差异**仅此一项**。
#
# 用法
# ----
# 在内核源码根目录执行（本 workflow 里即 <KERNEL_ROOT>/common）：
#     bash /path/to/backport_epoll_pwait2.sh
#
# 脚本是幂等的：重复执行不会重复插入。
#
set -euo pipefail

if [ ! -f fs/eventpoll.c ] || [ ! -f include/uapi/asm-generic/unistd.h ]; then
  echo "错误：当前目录不是内核源码根目录（缺少 fs/eventpoll.c）" >&2
  exit 1
fi

python3 - <<'PYEOF'
import io, re, sys

def read(p):
    with io.open(p, 'r', encoding='utf-8', errors='surrogateescape') as f:
        return f.read()

def write(p, s):
    with io.open(p, 'w', encoding='utf-8', errors='surrogateescape') as f:
        f.write(s)

changed = False

# ---------------------------------------------------------------- 1) 系统调用号
p = 'include/uapi/asm-generic/unistd.h'
s = read(p)
if '__NR_epoll_pwait2' in s:
    print('[1/4] unistd.h: 已存在 epoll_pwait2，跳过')
else:
    entry = ('#define __NR_epoll_pwait2 441\n'
             '__SYSCALL(__NR_epoll_pwait2, sys_epoll_pwait2)\n')
    m = re.search(r'^__SYSCALL\(__NR_process_madvise, sys_process_madvise\)\n', s, re.M)
    if m:
        s = s[:m.end()] + entry + s[m.end():]
        print('[1/4] unistd.h: 已在 process_madvise(440) 之后插入 epoll_pwait2(441)')
    else:
        m = re.search(r'^#undef __NR_syscalls\n', s, re.M)
        if not m:
            sys.exit('unistd.h: 找不到插入锚点，中止')
        s = s[:m.start()] + entry + s[m.start():]
        print('[1/4] unistd.h: 已在 __NR_syscalls 之前插入 epoll_pwait2(441)')
    m = re.search(r'^#define __NR_syscalls (\d+)$', s, re.M)
    if m and int(m.group(1)) < 442:
        s = s[:m.start()] + '#define __NR_syscalls 442' + s[m.end():]
        print('      __NR_syscalls 提升为 442')
    write(p, s)
    changed = True

# ---------------------------------------------------------------- 2) 系统调用声明
p = 'include/linux/syscalls.h'
s = read(p)
if 'sys_epoll_pwait2' in s:
    print('[2/4] syscalls.h: 已存在声明，跳过')
else:
    decl = ('asmlinkage long sys_epoll_pwait2(int epfd, struct epoll_event __user *events,\n'
            '\t\t\t\tint maxevents, const void __user *timeout,\n'
            '\t\t\t\tconst sigset_t __user *sigmask,\n'
            '\t\t\t\tsize_t sigsetsize);\n')
    m = re.search(r'^/\* fs/eventpoll\.c \*/\n', s, re.M)
    if not m:
        sys.exit('syscalls.h: 找不到 /* fs/eventpoll.c */ 锚点，中止')
    s = s[:m.end()] + decl + s[m.end():]
    write(p, s)
    print('[2/4] syscalls.h: 已添加 sys_epoll_pwait2 声明')
    changed = True

# ---------------------------------------------------------------- 3) 占位实现
p = 'kernel/sys_ni.c'
s = read(p)
if 'epoll_pwait2' in s:
    print('[3/4] sys_ni.c: 已存在占位，跳过')
else:
    m = re.search(r'^COND_SYSCALL\(epoll_pwait\);\n', s, re.M)
    if not m:
        sys.exit('sys_ni.c: 找不到 COND_SYSCALL(epoll_pwait) 锚点，中止')
    s = s[:m.end()] + 'COND_SYSCALL(epoll_pwait2);\n' + s[m.end():]
    write(p, s)
    print('[3/4] sys_ni.c: 已添加 COND_SYSCALL(epoll_pwait2)')
    changed = True

# ---------------------------------------------------------------- 4) 正式实现
p = 'fs/eventpoll.c'
s = read(p)
if 'epoll_pwait2' in s:
    print('[4/4] eventpoll.c: 已存在实现，跳过')
else:
    impl = '''
/*
 * Backport of epoll_pwait2() from Linux 5.11 (upstream commit b2540210c9a5).
 *
 * ACK android12-5.10 does not provide this syscall. Android 13+ userspace
 * (bionic's Looper) issues it, and a missing implementation returns ENOSYS,
 * which makes RenderThread abort with "RenderThread Looper POLL_ERROR!".
 *
 * The nanosecond timeout is converted to the millisecond granularity
 * understood by do_epoll_wait(), rounding up so we never return early.
 * A NULL timeout keeps the original "wait indefinitely" semantics.
 */
SYSCALL_DEFINE6(epoll_pwait2, int, epfd, struct epoll_event __user *, events,
\t\tint, maxevents, const void __user *, timeout,
\t\tconst sigset_t __user *, sigmask, size_t, sigsetsize)
{
\tstruct { long long tv_sec; long long tv_nsec; } kts;
\tint timeout_ms = -1;
\tint error;

\tif (timeout) {
\t\tif (copy_from_user(&kts, timeout, sizeof(kts)))
\t\t\treturn -EFAULT;

\t\tif (kts.tv_sec < 0 || kts.tv_nsec < 0 ||
\t\t    kts.tv_nsec >= 1000000000LL)
\t\t\treturn -EINVAL;

\t\tif (kts.tv_sec > 2147483LL) {
\t\t\ttimeout_ms = 2147483647;
\t\t} else {
\t\t\ttimeout_ms = (int)(kts.tv_sec * 1000LL +
\t\t\t\t\t   (kts.tv_nsec + 999999LL) / 1000000LL);
\t\t}
\t}

\terror = set_user_sigmask(sigmask, sigsetsize);
\tif (error)
\t\treturn error;

\terror = do_epoll_wait(epfd, events, maxevents, timeout_ms);
\trestore_saved_sigmask_unless(error == -EINTR);

\treturn error;
}

'''
    m = re.search(r'^static int __init eventpoll_init\(void\)\n', s, re.M)
    if not m:
        sys.exit('eventpoll.c: 找不到 eventpoll_init 锚点，中止')
    s = s[:m.start()] + impl + s[m.start():]
    write(p, s)
    print('[4/4] eventpoll.c: 已插入 epoll_pwait2 实现')
    changed = True

print('完成。' if changed else '四处均已存在，无需改动。')
PYEOF

echo "==> 校验插入结果"
echo "--- unistd.h ---";    grep -n '__NR_epoll_pwait2'             include/uapi/asm-generic/unistd.h || true
echo "--- syscalls.h ---";  grep -n 'sys_epoll_pwait2'               include/linux/syscalls.h           || true
echo "--- sys_ni.c ---";    grep -n 'epoll_pwait2'                   kernel/sys_ni.c                    || true
echo "--- eventpoll.c ---"; grep -n 'SYSCALL_DEFINE6(epoll_pwait2'   fs/eventpoll.c                     || true
