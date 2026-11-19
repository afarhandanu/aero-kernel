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
