#!/bin/bash

# Export ZephyrSU variables
KSU_SETUP_URI="https://raw.githubusercontent.com/afarhandanu/ZephyrSU/refs/heads/main/kernel/setup.sh"
KSU_SETUP_BRANCH="main"

# Run ZephyrSU setup script
cd "$KERNEL_DIR"
echo "-- ZephyrSU: Running setup script..."
curl -LSs --fail --retry 3 -H "Authorization: Bearer $GITHUB_TOKEN" "$KSU_SETUP_URI" | bash -s "$KSU_SETUP_BRANCH" &> /dev/null || {
    echo "-- Fatal: ZephyrSU setup script failed to download or run!"
    exit 1
}

# Fix ZephyrSU compatibility for kernels < 5.4 (such as 4.19)
if [ -d KernelSU/kernel ]; then
    echo "-- ZephyrSU: Patching 4.19 compatibility..."
    python3 - <<'PY'
import os

# 1. Patch MODULE_IMPORT_NS in core/init.c (< 5.4)
init_path = "KernelSU/kernel/core/init.c"
if os.path.exists(init_path):
    with open(init_path, "r") as f:
        code = f.read()
    target = "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)"
    replacement = "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)"
    if target in code and "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)" not in code:
        code = code.replace(target, replacement, 1) + "\n#endif\n"
        with open(init_path, "w") as f:
            f.write(code)
        print("   -> Wrapped MODULE_IMPORT_NS in LINUX_VERSION_CODE >= 5.4.0")

# 2. Patch iopoll (< 5.1) and remap_file_range (< 5.0) in infra/file_wrapper.c
fw_path = "KernelSU/kernel/infra/file_wrapper.c"
if os.path.exists(fw_path):
    with open(fw_path, "r") as f:
        code = f.read()

    # Wrap ksu_wrapper_iopoll definition in >= 5.1.0
    target_iopoll = "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)\nstatic int ksu_wrapper_iopoll"
    anchor_iopoll = "\n#endif\n\n#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)\nstatic int ksu_wrapper_iterate"
    if target_iopoll in code and anchor_iopoll in code:
        code = code.replace(target_iopoll, "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n" + target_iopoll, 1)
        code = code.replace(anchor_iopoll, "\n#endif\n#endif // 5.1.0\n\n#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)\nstatic int ksu_wrapper_iterate", 1)

    # Wrap iopoll assignment in >= 5.1.0
    assign_iopoll = "    p->ops.iopoll = fp->f_op->iopoll ? ksu_wrapper_iopoll : NULL;"
    if assign_iopoll in code:
        code = code.replace(assign_iopoll, "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 1, 0)\n" + assign_iopoll + "\n#endif", 1)

    # Wrap ksu_wrapper_remap_file_range definition in >= 5.0.0
    target_remap = "static loff_t ksu_wrapper_remap_file_range("
    anchor_remap = "static int ksu_wrapper_fadvise("
    if target_remap in code and anchor_remap in code:
        code = code.replace(target_remap, "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n" + target_remap, 1)
        code = code.replace(anchor_remap, "#endif // 5.0.0\n\n" + anchor_remap, 1)

    # Wrap remap_file_range assignment in >= 5.0.0
    assign_remap = "    p->ops.remap_file_range = fp->f_op->remap_file_range ? ksu_wrapper_remap_file_range : NULL;"
    if assign_remap in code:
        code = code.replace(assign_remap, "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n" + assign_remap + "\n#endif", 1)

    with open(fw_path, "w") as f:
        f.write(code)
    print("   -> Injected file_wrapper.c compat guards for kernel < 5.1")
PY
fi

# 3. Patch seccomp_cache.c: SECCOMP_ARCH_NATIVE_NR / SECCOMP_ARCH_COMPAT_NR
#    were only added to the kernel after 4.19, so ZephyrSU (main) fails to
#    compile on 4.19 with "use of undeclared identifier
#    'SECCOMP_ARCH_NATIVE_NR'". Backport the newer arm64 definitions,
#    using the 4.19 names NR_syscalls and __NR_compat_syscalls.
if [ -f KernelSU/kernel/infra/seccomp_cache.c ]; then
    echo "-- ZephyrSU: Patching seccomp_cache.c for 4.19..."
    python3 - <<'PY'
import os

sc_path = "KernelSU/kernel/infra/seccomp_cache.c"
if os.path.exists(sc_path):
    with open(sc_path, "r") as f:
        code = f.read()
    if "SECCOMP_ARCH_NATIVE_NR" in code and "#ifndef SECCOMP_ARCH_NATIVE_NR" not in code:
        anchor = '#include "infra/seccomp_cache.h"'
        compat = anchor + """


/* 4.19 compat: SECCOMP_ARCH_*_NR do not exist before 5.x. */
#include <linux/audit.h>
#include <asm/unistd.h>
#ifndef SECCOMP_ARCH_NATIVE
#define SECCOMP_ARCH_NATIVE AUDIT_ARCH_AARCH64
#endif
#ifndef SECCOMP_ARCH_NATIVE_NR
#define SECCOMP_ARCH_NATIVE_NR NR_syscalls
#endif
#ifdef CONFIG_COMPAT
#ifndef SECCOMP_ARCH_COMPAT
#define SECCOMP_ARCH_COMPAT AUDIT_ARCH_ARM
#endif
#ifndef SECCOMP_ARCH_COMPAT_NR
#define SECCOMP_ARCH_COMPAT_NR __NR_compat_syscalls
#endif
#endif
"""
        code = code.replace(anchor, compat, 1)
        with open(sc_path, "w") as f:
            f.write(code)
        print("   -> Defined SECCOMP_ARCH_NATIVE_NR / SECCOMP_ARCH_COMPAT_NR for 4.19")
PY
fi

# 4. Patch su_mount_ns.c: <uapi/linux/mount.h> and path_mount() only exist
#    from 5.0, so ZephyrSU (main) fails on 4.19 with "fatal error:
#    'uapi/linux/mount.h' file not found". Guard the include and provide
#    path_mount() for 4.19 via do_mount() run under KERNEL_DS.
if [ -f KernelSU/kernel/infra/su_mount_ns.c ]; then
    echo "-- ZephyrSU: Patching su_mount_ns.c for 4.19..."
    python3 - <<'PY'
import os

mn_path = "KernelSU/kernel/infra/su_mount_ns.c"
if os.path.exists(mn_path):
    with open(mn_path, "r") as f:
        code = f.read()
    orig = code

    # (a) The uapi mount header only exists from 5.0.
    old_inc = "#include <uapi/linux/mount.h>"
    new_inc = ("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 0, 0)\n"
               "#include <uapi/linux/mount.h>\n"
               "#endif")
    if old_inc in code and new_inc not in code:
        code = code.replace(old_inc, new_inc, 1)

    # (b) path_mount() does not exist before 5.0. Provide a 4.19
    #     equivalent that makes the root mount private via do_mount(),
    #     which takes a user-space path string, so it runs under
    #     KERNEL_DS. The only caller passes the filesystem root, so
    #     "/" is the same mountpoint path_mount() would have used.
    #     The call site is left untouched: the macro below redirects
    #     path_mount() to the helper on kernels below 5.0.
    anchor = "// global mode , need CAP_SYS_ADMIN and CAP_SYS_CHROOT to perform setns"
    helper = """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 0, 0)
#include <linux/uaccess.h>
/* 4.19 compat: path_mount() only exists from 5.0. do_mount() takes a
 * user-space path string, so run it with KERNEL_DS to pass "/". */
static int ksu_path_mount_419(const char *dev_name, struct path *path,
\t\t\t      const char *type_page, unsigned long flags,
\t\t\t      void *data_page)
{
\tmm_segment_t old_fs = get_fs();
\tint ret;

\t(void)path;
\tset_fs(KERNEL_DS);
\tret = (int)do_mount(dev_name, "/", type_page, flags, data_page);
\tset_fs(old_fs);
\treturn ret;
}
#define path_mount ksu_path_mount_419
#endif

"""
    if anchor in code and "ksu_path_mount_419" not in code:
        code = code.replace(anchor, helper + anchor, 1)

    if code != orig:
        with open(mn_path, "w") as f:
            f.write(code)
        print("   -> Patched su_mount_ns.c for 4.19 (path_mount via do_mount)")
PY
fi

# Enable ZephyrSU & Kprobes Configs (Non-GKI Requirements)
echo "-- ZephyrSU: Enabling Non-GKI configs..."
echo "CONFIG_KSU=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KPROBES=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_HAVE_KPROBES=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KPROBE_EVENTS=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KRETPROBES=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_HAVE_SYSCALL_TRACEPOINTS=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_THREAD_INFO_IN_TASK=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KALLSYMS=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KALLSYMS_ALL=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_EXT4_FS=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KSU_MANUAL_SU=y" >> "$FINAL_DEFCONFIG"

# Pre-install UAPI headers for preinit_runner if needed
if [ -f KernelSU/kernel/tools/code_generation/preinit_runner/preinit_runner.mk ] &&
   grep -q '^CONFIG_HEADERS_INSTALL=y' "$FINAL_DEFCONFIG"; then
    echo "-- ZephyrSU: Pre-installing UAPI headers for preinit..."
    if ! make -j"$(nproc --all)" O=out "${MAKE_ARGS[@]}" headers > headers.log 2>&1; then
        echo "-- ZephyrSU: UAPI header pre-install failed"
        tail -n 40 headers.log
        exit 1
    fi
    rm -f headers.log
fi

# Export static SELinux symbols for hooks if present
echo "-- ZephyrSU: Checking and exporting static SELinux symbols..."
unstatic() {
    local file="$1" regex="$2"
    if [ -f "$file" ] && grep -q "static $regex" "$file" 2>/dev/null; then
        sed -i "s/static $regex/$regex/" "$file"
        echo "   -> Exported: $regex"
    fi
}
unstatic "security/selinux/selinuxfs.c" "ssize_t (\*write_op\[\])"
unstatic "security/selinux/selinuxfs.c" "ssize_t (\*const write_op\[\])"
unstatic "security/selinux/selinuxfs.c" "const struct file_operations sel_handle_status_ops"
unstatic "security/selinux/selinuxfs.c" "DEFINE_MUTEX(sel_mutex);"
unstatic "security/selinux/ss/status.c" "struct page \*selinux_status_page;"
unstatic "security/selinux/ss/status.c" "DEFINE_MUTEX(selinux_status_lock);"
unstatic "security/selinux/ss/services.c" "DEFINE_RWLOCK(policy_rwlock);"
unstatic "security/selinux/hooks.c" "struct security_operations selinux_ops"
unstatic "security/selinux/hooks.c" "int inode_doinit_with_dentry"
unstatic "security/selinux/ss/services.c" "void security_dump_masked_av"
unstatic "security/selinux/ss/services.c" "void context_struct_compute_av"

cd ..
