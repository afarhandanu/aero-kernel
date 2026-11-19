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

# 5. Patch pkg_observer.c: handle_inode_event() only exists from 5.9, so
#    ZephyrSU (main) fails on 4.19 with "field designator
#    'handle_inode_event' does not name a field in struct fsnotify_ops".
#    On kernels below 5.9, translate the 5.0-era handle_event() callback
#    into ksu_handle_inode_event() instead.
if [ -f KernelSU/kernel/manager/pkg_observer.c ]; then
    echo "-- ZephyrSU: Patching pkg_observer.c for 4.19..."
    python3 - <<'PY'
import os

po_path = "KernelSU/kernel/manager/pkg_observer.c"
if os.path.exists(po_path):
    with open(po_path, "r") as f:
        code = f.read()
    orig = code

    # handle_inode_event() was only added to struct fsnotify_ops in 5.9.
    # Below 5.9, provide a handle_event() wrapper that builds the qstr
    # the handler expects from the plain file name string.
    # This file is indented with 4 spaces, not tabs.
    old_ops = """static const struct fsnotify_ops ksu_ops = {
    .handle_inode_event = ksu_handle_inode_event,
};"""
    if old_ops not in code:
        old_ops = """static const struct fsnotify_ops ksu_ops = {
\t.handle_inode_event = ksu_handle_inode_event,
};"""
    new_ops = """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)
/* 4.19 compat: handle_inode_event() only exists from 5.9. Translate the
 * 5.0-era handle_event() callback into ksu_handle_inode_event(). The
 * file name arrives as a plain string here, not a qstr. */
static int ksu_handle_event_419(struct fsnotify_group *group,
        struct inode *inode,
        u32 mask, const void *data, int data_type,
        const unsigned char *file_name, u32 cookie,
        struct fsnotify_iter_info *iter_info)
{
    struct qstr name;

    (void)group;
    (void)data;
    (void)data_type;
    (void)iter_info;
    name.name = file_name;
    name.len = file_name ? strlen(file_name) : 0;
    name.hash = 0;
    return ksu_handle_inode_event(NULL, mask, inode, NULL,
        file_name ? &name : NULL, cookie);
}
#endif

static const struct fsnotify_ops ksu_ops = {
#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)
    .handle_inode_event = ksu_handle_inode_event,
#else
    .handle_event = ksu_handle_event_419,
#endif
};"""
    if old_ops in code and new_ops not in code:
        code = code.replace(old_ops, new_ops, 1)
    elif "ksu_handle_event_419" not in code:
        print("   !! pkg_observer.c anchor not found, patch skipped")

    if code != orig:
        with open(po_path, "w") as f:
            f.write(code)
        print("   -> Patched pkg_observer.c for 4.19 (handle_event wrapper)")
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
# 6. Patch allowlist.c and supercall.c: TWA_RESUME only exists from 5.8,
#    so define it as true below 5.8 (task_work_add takes a boolean there).
#    allowlist.c also needs <linux/sched/task.h> for put_task_struct().
#    Runs after the main flow, so it re-enters the kernel directory first.
cd "$KERNEL_DIR"
if [ -f KernelSU/kernel/policy/allowlist.c ] || [ -f KernelSU/kernel/supercall/supercall.c ]; then
    echo "-- ZephyrSU: Patching allowlist.c and supercall.c for 4.19..."
    python3 - <<'PY'
import os

guard = ("// Older kernels use a boolean task_work notification argument.\n"
                "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 8, 0) &&!defined(TWA_RESUME)\n"
                "#define TWA_RESUME true\n"
                "#endif")

# put_task_struct() is declared in <linux/sched/task.h> on 4.19.
al_path = "KernelSU/kernel/policy/allowlist.c"
if os.path.exists(al_path):
    with open(al_path, "r") as f:
        code = f.read()
    orig = code
    anchor_tw = "#include <linux/task_work.h>"
    if "#include <linux/sched/task.h>" not in code and anchor_tw in code:
        code = code.replace(anchor_tw, anchor_tw + "\n#include <linux/sched/task.h>", 1)
    elif "#include <linux/sched/task.h>" not in code:
        print("   !! allowlist.c task_work.h anchor not found")
    if code != orig:
        with open(al_path, "w") as f:
            f.write(code)
        print("   -> Patched allowlist.c for 4.19 (sched/task.h)")

# TWA_RESUME is a boolean notify argument below 5.8.
for sp_path in ["KernelSU/kernel/policy/allowlist.c",
                "KernelSU/kernel/supercall/supercall.c"]:
    label = sp_path.rsplit("/", 1)[-1]
    if not os.path.exists(sp_path):
        continue
    with open(sp_path, "r") as f:
        code = f.read()
    orig = code
    anchor_ver = "#include <linux/version.h>"
    if "#define TWA_RESUME true" not in code and anchor_ver in code:
        code = code.replace(anchor_ver, anchor_ver + "\n" + guard, 1)
    elif "#define TWA_RESUME true" not in code:
        print("   !! " + label + " version.h anchor not found")
    if code != orig:
        with open(sp_path, "w") as f:
            f.write(code)
        print("   -> Patched " + label + " for 4.19 (TWA_RESUME)")
PY
fi
cd ..


# 7. Patch app_profile.c for kernels < 5.9: struct seccomp only gained
#    filter_count, and seccomp_filter_release() only appeared, in 5.9,
#    so guard the filter_count reset and use put_seccomp_filter() below 5.9.
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/policy/app_profile.c" ]; then
    echo "-- ZephyrSU: Patching app_profile.c for 4.19..."
    python3 - "KernelSU/kernel/policy/app_profile.c" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
orig = src

# filter_count only exists in struct seccomp from 5.9
anchor = "    atomic_set(&current->seccomp.filter_count, 0);\n"
replacement = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n"
    "    atomic_set(&current->seccomp.filter_count, 0);\n"
    "#endif\n"
)
if anchor in src:
    src = src.replace(anchor, replacement, 1)
    print(" -> Patched app_profile.c for 4.19 (filter_count guard)")
else:
    print("!! app_profile.c filter_count anchor not found, patch skipped")

# seccomp_filter_release() only exists from 5.9; below that, the same
# filter reference is dropped with put_seccomp_filter().
anchor2 = "    seccomp_filter_release(fake);\n"
replacement2 = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n"
    "    seccomp_filter_release(fake);\n"
    "#else\n"
    "    put_seccomp_filter(fake);\n"
    "#endif\n"
)
if anchor2 in src:
    src = src.replace(anchor2, replacement2, 1)
    print(" -> Patched app_profile.c for 4.19 (put_seccomp_filter)")
else:
    print("!! app_profile.c seccomp_filter_release anchor not found, patch skipped")

if src != orig:
    open(path, "w").write(src)
PYEOF
fi
cd ..


# 8. Patch cpu_spoof.c for kernels < 5.7: struct clocksource only gained
#    vdso_clock_mode in 5.7, so the curr_clocksource write fails on 4.19
#    with "no member named 'vdso_clock_mode' in 'struct clocksource'".
#    Guard the whole curr_clocksource block: on kernels below 5.7 the
#    vDSO clock mode is already set through vdso_data[].clock_mode and
#    vdso_default, so skipping this write loses nothing and avoids a
#    spurious "missing" count if the symbol is unresolvable.
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/extension/cpu_spoof.c" ]; then
  echo "-- ZephyrSU: Patching cpu_spoof.c for 4.19..."
  python3 - "KernelSU/kernel/extension/cpu_spoof.c" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
orig = src
# vdso_clock_mode only exists in struct clocksource from 5.7.
# Find the curr_clocksource block and wrap it in a version guard.
# The file is indented with 4 spaces, but match on content so the
# patch does not depend on the exact indentation.
lines = src.split("\n")
start = None
for i, line in enumerate(lines):
    if "struct clocksource **curr_cs_ptr =" in line:
        start = i - 1
        break
if start is None or lines[start].strip() != "{":
    print("!! cpu_spoof.c curr_cs block anchor not found, patch skipped")
else:
    depth = 0
    end = None
    for j in range(start, len(lines)):
        depth += lines[j].count("{") - lines[j].count("}")
        if depth == 0:
            end = j
            break
    if end is None:
        print("!! cpu_spoof.c curr_cs block end not found, patch skipped")
    else:
        block = lines[start:end + 1]
        guarded = ["#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)"] + block + ["#endif"]
        lines[start:end + 1] = guarded
        src = "\n".join(lines)
        print(" -> Patched cpu_spoof.c for 4.19 (curr_clocksource vdso_clock_mode guard)")
if src != orig:
    open(path, "w").write(src)
PYEOF
fi
cd ..


# 9. Patch selinux_policy / selinux_state.policy for kernels < 5.10 (such as 4.19).
#    Before 5.10 the live SELinux policy lives in struct selinux_ss
#    (selinux_state.ss, guarded by policy_rwlock) instead of struct selinux_policy
#    (selinux_state.policy, guarded by policy_mutex). Alias the type in sepolicy.h
#    and install the duplicated policy by content in rules.c, as security_load_policy does.
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/selinux/sepolicy.h" ]; then
python3 - "KernelSU/kernel/selinux/sepolicy.h" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
anchor = '#include "ss/policydb.h"'
alias = anchor + '\n\n#include <linux/version.h>\n\n/* Kernels before 5.10 keep the live SELinux policy in struct selinux_ss\n * (selinux_state.ss, guarded by policy_rwlock) instead of\n * struct selinux_policy (selinux_state.policy, guarded by policy_mutex).\n * Alias the type so the code below works with both layouts. */\n#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)\n#define selinux_policy selinux_ss\n#endif'
if anchor in src:
    if 'selinux_policy selinux_ss' not in src:
        src = src.replace(anchor, alias, 1)
        open(path, 'w').write(src)
        print(" -> Patched sepolicy.h for 4.19 (selinux_policy -> selinux_ss alias)")
    else:
        print(" -> sepolicy.h already has the selinux_ss alias, skipping")
else:
    print("!! sepolicy.h anchor not found, patch skipped")
PYEOF
fi
if [ -f "KernelSU/kernel/selinux/rules.c" ]; then
python3 - "KernelSU/kernel/selinux/rules.c" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()

# spinlock.h for write_lock_irq() used by the 4.19 install helper
anchor = '#include <linux/slab.h>'
if anchor in src and '#include <linux/spinlock.h>' not in src:
    src = src.replace(anchor, anchor + '\n#include <linux/spinlock.h>', 1)
elif '#include <linux/spinlock.h>' not in src:
    print("!! rules.c slab.h anchor not found, spinlock include skipped")

# 4.19 install helper, inserted before apply_kernelsu_rules()
helper = '''#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 10, 0)
/* Install a duplicated policy on kernels before 5.10, where the live
 * policy lives in selinux_state.ss (struct selinux_ss) instead of
 * selinux_state.policy. Mirrors security_load_policy(): the new
 * policydb/sidtab/latest_granting are swapped in under the ss write
 * lock, then the old policydb is destroyed. The duplicated container
 * itself is freed; its policydb was moved into the live policy. */
static bool ksu_install_selinux_policy_419(struct selinux_policy *pol)
{
\tstruct policydb *old_db;
\tu32 seqno;

\told_db = kzalloc(sizeof(*old_db), GFP_KERNEL);
\tif (!old_db) {
\t\tpr_err("failed to alloc old policydb for policy install");
\t\tksu_destroy_sepolicy(pol);
\t\treturn false;
\t}
\tmemcpy(old_db, &selinux_state.ss->policydb, sizeof(*old_db));
\twrite_lock_irq(&selinux_state.ss->policy_rwlock);
\tmemcpy(&selinux_state.ss->policydb, &pol->policydb, sizeof(struct policydb));
\tselinux_state.ss->sidtab = pol->sidtab;
\tselinux_state.ss->latest_granting = pol->latest_granting;
\twrite_unlock_irq(&selinux_state.ss->policy_rwlock);
\tpolicydb_destroy(old_db);
\tkfree(old_db);
\tseqno = pol->latest_granting;
\tkfree(pol);
\treset_avc_cache(seqno);
\treturn true;
}
#endif

'''
if 'ksu_install_selinux_policy_419' not in src:
    if src.count('void apply_kernelsu_rules()') == 1:
        src = src.replace('void apply_kernelsu_rules()', helper + 'void apply_kernelsu_rules()', 1)
    else:
        print("!! rules.c apply_kernelsu_rules anchor not found, helper skipped")

def guarded(src, old, new):
    if old not in src:
        print("!! rules.c anchor not found, patch skipped: " + old[:60])
        return src
    return src.replace(old, new)

# mutex_lock (both functions; on 4.19 the prep work runs unlocked, as in security_load_policy)
old = '\tmutex_lock(&selinux_state.policy_mutex);'
new = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n' + old + '\n#endif'
src = guarded(src, old, new)

# old policy pointer (both functions)
old = '\told_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));'
new = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n' + old + '\n#else\n\told_pol = selinux_state.ss;\n#endif'
src = guarded(src, old, new)

# mutex_unlock (both functions; the empty statement keeps the out_unlock label valid on 4.19)
old = '\tmutex_unlock(&selinux_state.policy_mutex);'
new = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n' + old + '\n#else\n\t;\n#endif'
src = guarded(src, old, new)

# install block in apply_kernelsu_rules (followed by out_unlock:)
old = '\trcu_assign_pointer(selinux_state.policy, pol);\n\tsynchronize_rcu();\n\tksu_destroy_sepolicy(old_pol);\n\treset_avc_cache(pol->latest_granting);\nout_unlock:'
new = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n\trcu_assign_pointer(selinux_state.policy, pol);\n\tsynchronize_rcu();\n\tksu_destroy_sepolicy(old_pol);\n\treset_avc_cache(pol->latest_granting);\n#else\n\tif (!ksu_install_selinux_policy_419(pol))\n\t\tgoto out_unlock;\n#endif\nout_unlock:'
src = guarded(src, old, new)

# install block in handle_sepolicy (followed by ret = success_cmd_count;)
old = '\trcu_assign_pointer(selinux_state.policy, pol);\n\tsynchronize_rcu();\n\tksu_destroy_sepolicy(old_pol);\n\treset_avc_cache(pol->latest_granting);\n\tret = success_cmd_count;'
new = '#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n\trcu_assign_pointer(selinux_state.policy, pol);\n\tsynchronize_rcu();\n\tksu_destroy_sepolicy(old_pol);\n\treset_avc_cache(pol->latest_granting);\n#else\n\tif (!ksu_install_selinux_policy_419(pol)) {\n\t\tret = -ENOMEM;\n\t\tgoto out_unlock;\n\t}\n#endif\n\tret = success_cmd_count;'
src = guarded(src, old, new)

open(path, 'w').write(src)
print(" -> Patched rules.c for 4.19 (selinux_ss policy install)")
PYEOF
fi
cd ..

# 9 (continued). Patch selinux_hide.c for kernels < 5.10 / < 5.7:
#    the live policy is selinux_state.ss (not selinux_state.policy) below 5.10,
#    and the status page and its lock live in selinux_ss below 5.7.
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/feature/selinux_hide.c" ]; then
python3 - "KernelSU/kernel/feature/selinux_hide.c" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
lines = src.split('\n')
out = []
patched = 0
# (stripped line, 4.19 replacement line, kernel version the new layout needs)
guard = [
    ('orig_policy = rcu_dereference(selinux_state.policy);', 'orig_policy = selinux_state.ss;', '5, 10, 0'),
    ('policy = rcu_dereference(selinux_state.policy);', 'policy = selinux_state.ss;', '5, 10, 0'),
    ('mutex_lock(&selinux_state.status_lock);', 'mutex_lock(&selinux_state.ss->status_lock);', '5, 7, 0'),
    ('mutex_unlock(&selinux_state.status_lock);', 'mutex_unlock(&selinux_state.ss->status_lock);', '5, 7, 0'),
    ('if (!selinux_state.status_page) {', 'if (!selinux_state.ss->status_page) {', '5, 7, 0'),
    ('struct selinux_kernel_status *status = page_address(selinux_state.status_page);', 'struct selinux_kernel_status *status = page_address(selinux_state.ss->status_page);', '5, 7, 0'),
]
for ln in lines:
    stripped = ln.strip()
    hit = None
    for old, new, ver in guard:
        if stripped == old:
            hit = (new, ver)
            break
    if hit:
        new, ver = hit
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append('#if LINUX_VERSION_CODE >= KERNEL_VERSION(' + ver + ')')
        out.append(ln)
        out.append('#else')
        out.append(indent + new)
        out.append('#endif')
        patched += 1
    else:
        out.append(ln)
if patched == 0:
    print("!! selinux_hide.c anchors not found, patch skipped")
else:
    open(path, 'w').write('\n'.join(out))
    print(" -> Patched selinux_hide.c for 4.19 (selinux_ss policy/status, %d line(s))" % patched)
PYEOF
fi
cd ..


# 10. Fix rules.c patch anchors for 4.19 (4-space indent, not tab)
# Patch #9's rules.c replacements used tab-indented anchors, but rules.c
# uses 4-space indentation, so none of them matched (the build log shows
# "!! rules.c anchor not found, patch skipped" for all four). Redo the
# same four replacements matching on stripped content, which does not
# depend on indentation. The sepolicy.h alias, the
# ksu_install_selinux_policy_419() helper and the selinux_hide.c lines
# from patch #9 already apply, so this block only repeats the four
# rules.c replacements (8 replacements in total: 2 each).
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/selinux/rules.c" ]; then
    echo "-- ZephyrSU: Patching rules.c anchors for 4.19 (indent-independent)..."
    python3 - "KernelSU/kernel/selinux/rules.c" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.read().splitlines(keepends=True)

out = []
counts = {"mutex_lock": 0, "old_pol": 0, "mutex_unlock": 0, "install": 0}
warned = []

i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()
    ind = line[:len(line) - len(line.lstrip())]

    if stripped == "mutex_lock(&selinux_state.policy_mutex);":
        out.append("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n")
        out.append(ind + "mutex_lock(&selinux_state.policy_mutex);\n")
        out.append("#endif\n")
        counts["mutex_lock"] += 1
        i += 1
        continue

    if stripped == "old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));":
        out.append("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n")
        out.append(ind + "old_pol = rcu_dereference_protected(selinux_state.policy, lockdep_is_held(&selinux_state.policy_mutex));\n")
        out.append("#else\n")
        out.append(ind + "old_pol = selinux_state.ss;\n")
        out.append("#endif\n")
        counts["old_pol"] += 1
        i += 1
        continue

    if stripped == "mutex_unlock(&selinux_state.policy_mutex);":
        out.append("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n")
        out.append(ind + "mutex_unlock(&selinux_state.policy_mutex);\n")
        out.append("#else\n")
        out.append(ind + ";\n")
        out.append("#endif\n")
        counts["mutex_unlock"] += 1
        i += 1
        continue

    if stripped == "rcu_assign_pointer(selinux_state.policy, pol);":
        block = [lines[j].strip() for j in range(i, min(i + 4, len(lines)))]
        expected = [
            "rcu_assign_pointer(selinux_state.policy, pol);",
            "synchronize_rcu();",
            "ksu_destroy_sepolicy(old_pol);",
            "reset_avc_cache(pol->latest_granting);",
        ]
        after = lines[i + 4].strip() if i + 4 < len(lines) else ""
        if block == expected and after in ("out_unlock:", "ret = success_cmd_count;"):
            out.append("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n")
            out.append(ind + "rcu_assign_pointer(selinux_state.policy, pol);\n")
            out.append(ind + "synchronize_rcu();\n")
            out.append(ind + "ksu_destroy_sepolicy(old_pol);\n")
            out.append(ind + "reset_avc_cache(pol->latest_granting);\n")
            out.append("#else\n")
            if after == "out_unlock:":
                out.append(ind + "if (!ksu_install_selinux_policy_419(pol)) goto out_unlock;\n")
            else:
                out.append(ind + "if (!ksu_install_selinux_policy_419(pol)) {\n")
                out.append(ind + "    ret = -ENOMEM;\n")
                out.append(ind + "    goto out_unlock;\n")
                out.append(ind + "}\n")
            out.append("#endif\n")
            counts["install"] += 1
            i += 4
            continue
        warned.append("install block at line %d not replaced (after: %s)" % (i + 1, after))
        out.append(line)
        i += 1
        continue

    out.append(line)
    i += 1

with open(path, "w") as f:
    f.writelines(out)

for w in warned:
    print("!! rules.c (patch #10): " + w)
for name, n in counts.items():
    if n == 0:
        print("!! rules.c (patch #10): no match for " + name)
print(" -> Patched rules.c anchors for 4.19 (indent-independent, %d replacement(s))" % sum(counts.values()))
PYEOF
    cd ..
fi


# 11. Fix rules.c install blocks for 4.19 (blank line in the block)
# Patch #10's install-block match expected the four statements to be
# consecutive, but rules.c has a blank line between
# ksu_destroy_sepolicy(old_pol); and reset_avc_cache(...), so neither
# block matched (the build log shows "install block at line ... not
# replaced (after: reset_avc_cache(...)"). Redo only the two install
# blocks, collecting the next four non-blank lines so a blank line
# anywhere in the block does not matter. The other six replacements
# from patch #10 already apply and are not repeated.
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/selinux/rules.c" ]; then
    echo "-- ZephyrSU: Patching rules.c install blocks for 4.19 (blank-tolerant)..."
    python3 - "KernelSU/kernel/selinux/rules.c" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.read().splitlines(keepends=True)

out = []
patched = 0
warned = []

i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()
    ind = line[:len(line) - len(line.lstrip())]

    if stripped == "rcu_assign_pointer(selinux_state.policy, pol);":
        idx = []
        j = i
        while j < len(lines) and len(idx) < 4:
            if lines[j].strip() != "":
                idx.append(j)
            j += 1
        block = [lines[k].strip() for k in idx]
        expected = [
            "rcu_assign_pointer(selinux_state.policy, pol);",
            "synchronize_rcu();",
            "ksu_destroy_sepolicy(old_pol);",
            "reset_avc_cache(pol->latest_granting);",
        ]
        after = ""
        k = j
        while k < len(lines):
            if lines[k].strip() != "":
                after = lines[k].strip()
                break
            k += 1
        if block == expected and after in ("out_unlock:", "ret = success_cmd_count;"):
            out.append("#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 10, 0)\n")
            out.append(ind + "rcu_assign_pointer(selinux_state.policy, pol);\n")
            out.append(ind + "synchronize_rcu();\n")
            out.append(ind + "ksu_destroy_sepolicy(old_pol);\n")
            out.append(ind + "reset_avc_cache(pol->latest_granting);\n")
            out.append("#else\n")
            if after == "out_unlock:":
                out.append(ind + "if (!ksu_install_selinux_policy_419(pol)) goto out_unlock;\n")
            else:
                out.append(ind + "if (!ksu_install_selinux_policy_419(pol)) {\n")
                out.append(ind + "    ret = -ENOMEM;\n")
                out.append(ind + "    goto out_unlock;\n")
                out.append(ind + "}\n")
            out.append("#endif\n")
            patched += 1
            i = idx[-1] + 1
            continue
        warned.append("install block at line %d not replaced (after: %s)" % (i + 1, after))
        out.append(line)
        i += 1
        continue

    out.append(line)
    i += 1

with open(path, "w") as f:
    f.writelines(out)

for w in warned:
    print("!! rules.c (patch #11): " + w)
if patched != 2:
    print("!! rules.c (patch #11): expected 2 install block(s), got %d" % patched)
print(" -> Patched rules.c install blocks for 4.19 (blank-tolerant, %d replacement(s))" % patched)
PYEOF
    cd ..
fi


# 12. Patch sepolicy.c avtab / type_attr_map_array for 4.19 flex_array layout (< 5.7)
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/selinux/sepolicy.c" ]; then
python3 - "KernelSU/kernel/selinux/sepolicy.c" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

count = 0

def replace_guarded(anchor, old_text, new_text, ver):
    global count
    hits = [i for i, line in enumerate(lines) if line.strip() == anchor]
    if not hits:
        print("!! sepolicy.c anchor not found, patch skipped: %s" % anchor)
        return 0
    for idx in reversed(hits):
        ind = lines[idx][:len(lines[idx]) - len(lines[idx].lstrip())]
        lines[idx:idx + 1] = [
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(%s)\n" % ver,
            ind + old_text + "\n",
            "#else\n",
            ind + new_text + "\n",
            "#endif\n",
        ]
    count += len(hits)
    return len(hits)

# (A) remove_avtab_node: 4.19 keeps avtab buckets in a flex_array, not a
# plain array of struct avtab_node pointers (plain array from 5.7).
replace_guarded("for (n = db->te_avtab.htable[i]; n; prev = n, n = n->next) {",
                "for (n = db->te_avtab.htable[i]; n; prev = n, n = n->next) {",
                "for (n = flex_array_get_ptr(db->te_avtab.htable, i); n; prev = n, n = n->next) {",
                "5, 7, 0")
replace_guarded("db->te_avtab.htable[i] = n->next;",
                "db->te_avtab.htable[i] = n->next;",
                "flex_array_put_ptr(db->te_avtab.htable, i, n->next, GFP_KERNEL);",
                "5, 7, 0")
replace_guarded("removed.htable[0] = n;",
                "removed.htable[0] = n;",
                "flex_array_put_ptr(removed.htable, 0, n, GFP_KERNEL);",
                "5, 7, 0")

# (D) add_typeattribute_raw: the type_attr_map_array entry is reached
# through the flex_array on 4.19.
replace_guarded("struct ebitmap *sattr = &db->type_attr_map_array[type->value - 1];",
                "struct ebitmap *sattr = &db->type_attr_map_array[type->value - 1];",
                "struct ebitmap *sattr = flex_array_get(db->type_attr_map_array, type->value - 1);",
                "5, 7, 0")

with open(path, "w") as f:
    f.writelines(lines)
print(" -> Patched sepolicy.c avtab / type_attr_map for 4.19 (%d replacement(s))" % count)
PYEOF
fi
cd ..

# 13. Patch sepolicy.c add_type for 4.19 flex_array type maps (< 5.7)
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/selinux/sepolicy.c" ]; then
python3 - "KernelSU/kernel/selinux/sepolicy.c" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

count = 0

def insert_before(anchor, block):
    global count
    hits = [i for i, line in enumerate(lines) if line.strip() == anchor]
    if not hits:
        print("!! sepolicy.c anchor not found, patch skipped: %s" % anchor)
        return 0
    for idx in reversed(hits):
        lines[idx:idx] = block
    count += len(hits)
    return len(hits)

# Helper: grow a flex_array by one element, copying the old elements.
helper = """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 7, 0)
/* 4.19: the policydb type maps are flex_arrays, not plain arrays.
 * Grow one by a single element, copying the existing elements. */
static struct flex_array *ksu_flex_array_grow(struct flex_array *old,
                                                unsigned int new_n,
                                                size_t elem_size,
                                                gfp_t flags)
{
    struct flex_array *new;
    unsigned int i;

    new = flex_array_alloc(elem_size, new_n, flags | __GFP_ZERO);
    if (!new)
        return NULL;
    if (flex_array_prealloc(new, 0, new_n, flags | __GFP_ZERO)) {
        flex_array_free(new);
        return NULL;
    }
    for (i = 0; i < new_n - 1; i++) {
        void *elem = flex_array_get(old, i);

        if (elem && flex_array_put(new, i, elem, flags)) {
            flex_array_free(new);
            return NULL;
        }
    }
    flex_array_free(old);
    return new;
}
#endif

"""
insert_before("static bool add_type(struct policydb *db, const char *type_name, bool attr)", helper.splitlines(keepends=True))

# 4.19: grow the three type maps as flex_arrays, then return early so the
# plain-array kvrealloc block below is skipped.
flex_block = """#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 7, 0)
    /* 4.19: the type maps are flex_arrays; grow each by one entry. */
    {
        struct flex_array *new_attr_map;
        struct flex_array *new_type_struct;
        struct flex_array *new_sym_names;
        struct ebitmap *new_ebitmap;
        int j;

        new_attr_map = ksu_flex_array_grow(db->type_attr_map_array, value,
                                           sizeof(struct ebitmap), GFP_KERNEL);
        new_type_struct =
            ksu_flex_array_grow(db->type_val_to_struct_array, value,
                                sizeof(struct type_datum *), GFP_KERNEL);
        new_sym_names = ksu_flex_array_grow(db->sym_val_to_name[SYM_TYPES], value,
                                            sizeof(char *), GFP_KERNEL);
        if (!new_attr_map || !new_type_struct || !new_sym_names) {
            if (new_attr_map)
                flex_array_free(new_attr_map);
            if (new_type_struct)
                flex_array_free(new_type_struct);
            if (new_sym_names)
                flex_array_free(new_sym_names);
            return false;
        }
        db->type_attr_map_array = new_attr_map;
        db->type_val_to_struct_array = new_type_struct;
        db->sym_val_to_name[SYM_TYPES] = new_sym_names;

        new_ebitmap = flex_array_get(db->type_attr_map_array, value - 1);
        ebitmap_init(new_ebitmap);
        ebitmap_set_bit(new_ebitmap, value - 1, 1);

        flex_array_put_ptr(db->type_val_to_struct_array, value - 1, type,
                           GFP_KERNEL);
        flex_array_put_ptr(db->sym_val_to_name[SYM_TYPES], value - 1, key,
                           GFP_KERNEL);

        for (j = 0; j < db->p_roles.nprim; ++j)
            ebitmap_set_bit(&db->role_val_to_struct[j]->types, value - 1, 1);
        return true;
    }
#endif

"""
insert_before("struct ebitmap *new_type_attr_map_array =", flex_block.splitlines(keepends=True))

with open(path, "w") as f:
    f.writelines(lines)
print(" -> Patched sepolicy.c add_type for 4.19 (%d insertion(s))" % count)
PYEOF
fi
cd ..

# 14. Patch sepolicy.c add_filename_trans for the 4.19 filename_trans layout (< 5.9)
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/selinux/sepolicy.c" ]; then
python3 - "KernelSU/kernel/selinux/sepolicy.c" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

count = 0

def find_all(anchor):
    return [i for i, line in enumerate(lines) if line.strip() == anchor]

def replace_guarded(anchor, old_text, new_text, ver):
    global count
    hits = find_all(anchor)
    if not hits:
        print("!! sepolicy.c anchor not found, patch skipped: %s" % anchor)
        return 0
    for idx in reversed(hits):
        ind = lines[idx][:len(lines[idx]) - len(lines[idx].lstrip())]
        lines[idx:idx + 1] = [
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(%s)\n" % ver,
            ind + old_text + "\n",
            "#else\n",
            ind + new_text + "\n",
            "#endif\n",
        ]
    count += len(hits)
    return len(hits)

def replace_lines(anchor, new_lines):
    global count
    hits = find_all(anchor)
    if not hits:
        print("!! sepolicy.c anchor not found, patch skipped: %s" % anchor)
        return 0
    for idx in reversed(hits):
        lines[idx:idx + 1] = new_lines
    count += len(hits)
    return len(hits)

def insert_after(anchor, block):
    global count
    hits = find_all(anchor)
    if not hits:
        print("!! sepolicy.c anchor not found, patch skipped: %s" % anchor)
        return 0
    for idx in reversed(hits):
        lines[idx + 1:idx + 1] = block
    count += len(hits)
    return len(hits)

def replace_block(start_anchor, new_lines):
    global count
    hits = find_all(start_anchor)
    if not hits:
        print("!! sepolicy.c anchor not found, patch skipped: %s" % start_anchor)
        return 0
    n = 0
    for idx in reversed(hits):
        j = idx
        depth = 0
        started = False
        while j < len(lines):
            depth += lines[j].count("{") - lines[j].count("}")
            if "{" in lines[j]:
                started = True
            if started and depth == 0:
                break
            j += 1
        if not started or depth != 0:
            print("!! sepolicy.c block end not found, patch skipped: %s" % start_anchor)
            continue
        lines[idx:j + 1] = new_lines
        count += 1
        n += 1
    return n

# (B1) On 4.19 the filename transition key is struct filename_trans
# (which carries stype); struct filename_trans_key only exists from 5.7.
insert_after("#define symtab_insert(s, name, datum) hashtab_insert((s)->table, name, datum)",
             ["/* 4.19: filename transitions use the old struct filename_trans key\n",
              " * (which carries stype) instead of struct filename_trans_key. */\n",
              "#define filename_trans_key filename_trans\n"])

# (B2) The 4.19 key also carries the source type.
replace_lines("key.name = (char *)o;",
              ["    key.name = (char *)o;\n",
               "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n",
               "    key.stype = src->value;\n",
               "#endif\n"])

# (B3) The chain-walk cursor only exists in the new-format code.
replace_lines("struct filename_trans_datum *last = NULL;",
              ["#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n",
               "    struct filename_trans_datum *last = NULL;\n",
               "#endif\n"])

# (B4) 4.19 has no policydb_filenametr_search; the hashtab is a plain
# pointer, searched with the 2-arg hashtab_search.
replace_guarded("struct filename_trans_datum *trans = policydb_filenametr_search(db, &key);",
                "struct filename_trans_datum *trans = policydb_filenametr_search(db, &key);",
                "struct filename_trans_datum *trans = hashtab_search(db->filename_trans, &key);",
                "5, 9, 0")

# (B5) 4.19 has one datum per key, so a hit is a duplicate; there is no
# stypes bitmap and no next chain to walk.
replace_block("while (trans) {",
              ["#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n",
               "    while (trans) {\n",
               "        if (ebitmap_get_bit(&trans->stypes, src->value - 1)) {\n",
               "            // Duplicate, overwrite existing data and return\n",
               "            trans->otype = def->value;\n",
               "            return true;\n",
               "        }\n",
               "        if (trans->otype == def->value)\n",
               "            break;\n",
               "        last = trans;\n",
               "        trans = trans->next;\n",
               "    }\n",
               "#else\n",
               "    /* 4.19: the key already includes the source type, so a hit\n",
               "     * is a duplicate; overwrite the default type and return. */\n",
               "    if (trans) {\n",
               "        trans->otype = def->value;\n",
               "        return true;\n",
               "    }\n",
               "#endif\n"])

# (B6) No next chain on 4.19.
replace_lines("trans->next = last;",
              ["#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n",
               "        trans->next = last;\n",
               "#endif\n"])

# (B7) 4.19 hashtab_insert takes (hashtab, key, datum) with a pointer hashtab.
replace_guarded("rc = hashtab_insert(&db->filename_trans, new_key, trans, filenametr_key_params);",
                "rc = hashtab_insert(&db->filename_trans, new_key, trans, filenametr_key_params);",
                "rc = hashtab_insert(db->filename_trans, new_key, trans);",
                "5, 9, 0")

# (B8) 4.19 has no compat_filename_trans_count and no stypes bitmap;
# record the transition in the policydb-wide ttypes bitmap instead.
hits = find_all("db->compat_filename_trans_count++;")
if not hits:
    print("!! sepolicy.c anchor not found, patch skipped: db->compat_filename_trans_count++;")
else:
    for idx in reversed(hits):
        if lines[idx + 1].strip() != "return ebitmap_set_bit(&trans->stypes, src->value - 1, 1) == 0;":
            print("!! sepolicy.c: expected stypes return after compat_filename_trans_count, patch skipped")
            continue
        lines[idx:idx + 2] = [
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 9, 0)\n",
            "    db->compat_filename_trans_count++;\n",
            "    return ebitmap_set_bit(&trans->stypes, src->value - 1, 1) == 0;\n",
            "#else\n",
            "    /* 4.19: record that this target type has filename transitions. */\n",
            "    return ebitmap_set_bit(&db->filename_trans_ttypes, tgt->value, 1) == 0;\n",
            "#endif\n",
        ]
        count += 1

with open(path, "w") as f:
    f.writelines(lines)
print(" -> Patched sepolicy.c add_filename_trans for 4.19 (%d replacement(s))" % count)
PYEOF
fi
cd ..


# 15. Guard the add_type plain-array block to kernels >= 5.7
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/selinux/sepolicy.c" ]; then
python3 - "KernelSU/kernel/selinux/sepolicy.c" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

count = 0

def insert_before(anchor, block):
    global count
    hits = [i for i, line in enumerate(lines) if line.strip() == anchor]
    if not hits:
        print("!! sepolicy.c anchor not found, patch skipped: %s" % anchor)
        return 0
    for idx in reversed(hits):
        lines[idx:idx] = block
    count += len(hits)
    return len(hits)

def insert_after(anchor, block):
    global count
    hits = [i for i, line in enumerate(lines) if line.strip() == anchor]
    if not hits:
        print("!! sepolicy.c anchor not found, patch skipped: %s" % anchor)
        return 0
    for idx in reversed(hits):
        lines[idx + 1:idx + 1] = block
    count += len(hits)
    return len(hits)

# The plain-array kvrealloc block only compiles on 5.7+; on 4.19 the
# flex_array block above returns early, but the compiler still parses
# this block, so it must be excluded from compilation.
insert_before("struct ebitmap *new_type_attr_map_array =",
              ["#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)\n"])
insert_after("db->sym_val_to_name[SYM_TYPES][value - 1] = key;",
             ["#endif\n"])

with open(path, "w") as f:
    f.writelines(lines)
print(" -> Patched sepolicy.c add_type plain-array guard for 4.19 (%d insertion(s))" % count)
PYEOF
fi
cd ..


# 16. Patch sulog/event.c for 4.19: linux/minmax.h is a 6.3 header (< 6.3: use linux/kernel.h)
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/sulog/event.c" ]; then
python3 - "KernelSU/kernel/sulog/event.c" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()

count = 0
hits = [i for i, line in enumerate(lines) if line.strip() == "#include <linux/minmax.h>"]
if not hits:
    print("!! sulog/event.c anchor not found, patch skipped: #include <linux/minmax.h>")
else:
    for idx in reversed(hits):
        lines[idx:idx + 1] = [
            "#include <linux/version.h>\n",
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)\n",
            "#include <linux/minmax.h>\n",
            "#else\n",
            "#include <linux/kernel.h>\n",
            "#endif\n",
        ]
        count += 1

with open(path, "w") as f:
    f.writelines(lines)
print(" -> Patched sulog/event.c for 4.19 (minmax.h -> kernel.h, %d replacement(s))" % count)
PYEOF
fi
cd ..


# 17. Patch supercall/dispatch.c missing sched includes on 4.19
echo "-- ZephyrSU: Patching supercall/dispatch.c for 4.19..."
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/supercall/dispatch.c" ]; then
python3 - "KernelSU/kernel/supercall/dispatch.c" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
anchor = "#include <linux/capability.h>"
addition = anchor + "\n// 4.19: linux/sched.h does not pull in sched/signal.h or sched/task.h,\n// so task_pgrp()/task_session() (signal.h) and tasklist_lock/init_task\n// (task.h) are undeclared without these explicit includes.\n#include <linux/sched.h>\n#include <linux/sched/signal.h>\n#include <linux/sched/task.h>"
if anchor in src:
    src = src.replace(anchor, addition, 1)
    open(path, "w").write(src)
    print(" -> Patched supercall/dispatch.c for 4.19 (sched/signal.h + sched/task.h, 1 replacement(s))")
else:
    print("!! supercall/dispatch.c anchor not found, patch skipped")
PYEOF
fi
cd..


# 18. Patch feature/selinux_hide.c for 4.19: the SELinux sidtab/policydb
#    rework (5.7/5.9) means symtab_search(), struct sidtab_entry and the
#    sid2str cache do not exist on 4.19, and the policydb type maps are
#    flex_arrays (type_val_to_struct_array / type_attr_map_array) instead
#    of plain arrays. Provide a 4.19 symtab_search() over the hashtab, a
#    context-based sidtab_entry_to_string(), and flex_array accessors.
echo "-- ZephyrSU: Patching feature/selinux_hide.c for 4.19..."
cd "$KERNEL_DIR"
if [ -f "KernelSU/kernel/feature/selinux_hide.c" ]; then
python3 - "KernelSU/kernel/feature/selinux_hide.c" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
count = 0

def find_all(anchor):
    return [i for i, line in enumerate(lines) if line.strip() == anchor]

def replace_guarded(anchor, old_text, new_text, ver):
    global count
    hits = find_all(anchor)
    if not hits:
        print("!! selinux_hide.c anchor not found, patch skipped: %s" % anchor)
        return 0
    for idx in reversed(hits):
        ind = lines[idx][:len(lines[idx]) - len(lines[idx].lstrip())]
        lines[idx:idx + 1] = [
            "#if LINUX_VERSION_CODE >= KERNEL_VERSION(%s)\n" % ver,
            ind + old_text + "\n",
            "#else\n",
            ind + new_text + "\n",
            "#endif\n",
        ]
    count += len(hits)
    return len(hits)

def insert_before(anchor, block):
    global count
    hits = find_all(anchor)
    if not hits:
        print("!! selinux_hide.c anchor not found, patch skipped: %s" % anchor)
        return 0
    for idx in reversed(hits):
        lines[idx:idx] = block
    count += len(hits)
    return len(hits)

def replace_block(start_anchor, new_lines):
    global count
    hits = find_all(start_anchor)
    if not hits:
        print("!! selinux_hide.c anchor not found, patch skipped: %s" % start_anchor)
        return 0
    n = 0
    for idx in reversed(hits):
        j = idx
        depth = 0
        started = False
        while j < len(lines):
            depth += lines[j].count("{") - lines[j].count("}")
            if "{" in lines[j]:
                started = True
            if started and depth == 0:
                break
            j += 1
        if not started or depth != 0:
            print("!! selinux_hide.c block end not found, patch skipped: %s" % start_anchor)
            continue
        lines[idx:j + 1] = new_lines
        count += 1
        n += 1
    return n

# (A) 4.19 symtab_search(): added in 5.9, and struct symtab still holds its
# hashtab by pointer here. Look the name up in the underlying hashtab
# directly, so the existing symtab_search() call sites keep working.
compat = [
    "#if LINUX_VERSION_CODE < KERNEL_VERSION(5, 9, 0)\n",
    "/* 4.19: symtab_search() was only added in 5.9, and struct symtab still\n",
    " * holds its hashtab by pointer here. Look the name up in the underlying\n",
    " * hashtab directly, so the existing symtab_search() call sites keep\n",
    " * working unchanged. */\n",
    '#include "ss/hashtab.h"\n',
    "\n",
    "static inline void *ksu_symtab_search(struct symtab *s, const char *name)\n",
    "{\n",
    "    return hashtab_search(s->table, name);\n",
    "}\n",
    "#define symtab_search ksu_symtab_search\n",
    "#endif\n",
    "\n",
]
insert_before("static ssize_t my_write_context(struct file *file, char *buf, size_t size)", compat)

# (B) sidtab_entry_to_string(): struct sidtab_entry, sidtab_sid2str_get()
# and sidtab_sid2str_put() only exist from 5.7. On 4.19 the sidtab stores
# struct context directly, so convert it straight away.
new_func = [
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(5, 7, 0)\n",
    "static int sidtab_entry_to_string(struct policydb *p, struct sidtab *sidtab, struct sidtab_entry *entry,\n",
    "                                  char **scontext, u32 *scontext_len)\n",
    "{\n",
    "    int rc = sidtab_sid2str_get(sidtab, entry, scontext, scontext_len);\n",
    "\n",
    "    if (rc != -ENOENT)\n",
    "        return rc;\n",
    "\n",
    "    rc = context_struct_to_string(p, &entry->context, scontext, scontext_len);\n",
    "    if (!rc && scontext)\n",
    "        sidtab_sid2str_put(sidtab, entry, *scontext, *scontext_len);\n",
    "    return rc;\n",
    "}\n",
    "#else\n",
    "/* 4.19: there is no struct sidtab_entry and no sid2str cache; the sidtab\n",
    " * stores struct context directly, so convert it straight away. */\n",
    "static int sidtab_entry_to_string(struct policydb *p, struct sidtab *sidtab, struct context *entry,\n",
    "                                  char **scontext, u32 *scontext_len)\n",
    "{\n",
    "    return context_struct_to_string(p, entry, scontext, scontext_len);\n",
    "}\n",
    "#endif\n",
]
replace_block("static int sidtab_entry_to_string(struct policydb *p, struct sidtab *sidtab, struct sidtab_entry *entry,", new_func)

# (C) security_sid_to_context_with_policy(): sidtab_search_entry() only
# exists from 5.7; on 4.19 sidtab_search() returns the struct context.
replace_guarded("struct sidtab_entry *entry;",
                "struct sidtab_entry *entry;",
                "struct context *entry;",
                "5, 7, 0")
replace_guarded("entry = sidtab_search_entry(sidtab, sid);",
                "entry = sidtab_search_entry(sidtab, sid);",
                "entry = sidtab_search(sidtab, sid);",
                "5, 7, 0")

# (D) type_attribute_bounds_av(): on 4.19 the type map is a flex_array.
replace_guarded("source = policydb->type_val_to_struct[scontext->type - 1];",
                "source = policydb->type_val_to_struct[scontext->type - 1];",
                "source = flex_array_get_ptr(policydb->type_val_to_struct_array, scontext->type - 1);",
                "5, 7, 0")
replace_guarded("target = policydb->type_val_to_struct[tcontext->type - 1];",
                "target = policydb->type_val_to_struct[tcontext->type - 1];",
                "target = flex_array_get_ptr(policydb->type_val_to_struct_array, tcontext->type - 1);",
                "5, 7, 0")

# (E) context_struct_compute_av(): on 4.19 the attr map is a flex_array.
replace_guarded("sattr = &policydb->type_attr_map_array[scontext->type - 1];",
                "sattr = &policydb->type_attr_map_array[scontext->type - 1];",
                "sattr = flex_array_get(policydb->type_attr_map_array, scontext->type - 1);",
                "5, 7, 0")
replace_guarded("tattr = &policydb->type_attr_map_array[tcontext->type - 1];",
                "tattr = &policydb->type_attr_map_array[tcontext->type - 1];",
                "tattr = flex_array_get(policydb->type_attr_map_array, tcontext->type - 1);",
                "5, 7, 0")

with open(path, "w") as f:
    f.writelines(lines)
print(" -> Patched feature/selinux_hide.c for 4.19 (%d replacement(s))" % count)
PYEOF
fi
cd ..
