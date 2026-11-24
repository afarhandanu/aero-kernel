#!/bin/bash

# ZephyrSU for non-GKI kernels (4.19): builtin branch + SUSFS.
# The main branch hooks with kprobes and syscall tracepoints, which is the
# GKI path. The builtin branch has no kprobes: the kernel source calls its
# hook entry points (manual hooks), and those are added by the SUSFS patch
# and the inline hook script below.

# Export ZephyrSU variables
SUSFS_PATCH="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/Patch/susfs_patch_to_${KERNEL_VERSION}.patch"
KSU_SETUP_URI="https://raw.githubusercontent.com/afarhandanu/ZephyrSU/refs/heads/main/kernel/setup.sh"
KSU_SETUP_BRANCH="builtin"
KSU_HOOK="https://raw.githubusercontent.com/JackA1ltman/NonGKI_Kernel_Build_2nd/refs/heads/mainline/Patches/susfs_inline_hook_patches.sh"
ZEPHYR_PACKAGE="com.kucingbalap1644.zephyrsu"
ZEPHYR_SIGN_SIZE="0x02f5"
ZEPHYR_SIGN_HASH="7136496b8696964b8ddd8e581bca8b7be3591a19da7a53934bc9263bc4616933"

# Run ZephyrSU setup script (builtin branch)
cd "$KERNEL_DIR"
echo "-- ZephyrSU: Running setup script (builtin branch)..."
curl -LSs --fail --retry 3 -H "Authorization: Bearer $GITHUB_TOKEN" "$KSU_SETUP_URI" | bash -s "$KSU_SETUP_BRANCH" &> /dev/null || {
    echo "-- Fatal: ZephyrSU setup script failed to download or run!"
    exit 1
}
[ -f KernelSU/kernel/ksu_main.c ] || { echo "-- Fatal: ZephyrSU builtin branch was not checked out!"; exit 1; }

# The builtin branch still carries the upstream identity. Point it at the
# ZephyrSU manager, or the manager app is never recognised.
echo "-- ZephyrSU: Applying ZephyrSU identity to builtin branch..."
sed -i "s|^KSU_PACKAGE_NAME ?= .*|KSU_PACKAGE_NAME ?= $ZEPHYR_PACKAGE|" KernelSU/kernel/Makefile
sed -i "s|^REPO_OWNER  := .*|REPO_OWNER  := afarhandanu|" KernelSU/kernel/Makefile
sed -i "s|^REPO_NAME   := .*|REPO_NAME   := ZephyrSU|" KernelSU/kernel/Makefile
sed -i "s|^} apk_sign_keys\[\] = {|&\n    { $ZEPHYR_SIGN_SIZE, \"$ZEPHYR_SIGN_HASH\" }, // ZephyrSU|" KernelSU/kernel/manager/apk_sign.c
grep -q "^KSU_PACKAGE_NAME ?= $ZEPHYR_PACKAGE" KernelSU/kernel/Makefile || { echo "-- Fatal: could not set ZephyrSU package name!"; exit 1; }
grep -q "$ZEPHYR_SIGN_HASH" KernelSU/kernel/manager/apk_sign.c || { echo "-- Fatal: could not add ZephyrSU manager signature!"; exit 1; }

# Enable ZephyrSU configs
echo "-- ZephyrSU: Enabling configs..."
echo "CONFIG_KSU=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_HAVE_SYSCALL_TRACEPOINTS=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_THREAD_INFO_IN_TASK=y" >> "$FINAL_DEFCONFIG"

# Apply SUSFS patch
echo "-- ZephyrSU: Applying SUSFS patch..."
wget -qO susfs.patch "$SUSFS_PATCH" || { echo "-- Fatal: could not download SUSFS patch!"; exit 1; }
patch -p1 -s --fuzz=5 < susfs.patch || echo "-- WARNING: SUSFS patch reported rejects"
rm -f susfs.patch
[ -f fs/susfs.c ] || { echo "-- Fatal: SUSFS patch did not create fs/susfs.c!"; exit 1; }

echo "-- ZephyrSU: Enabling SUSFS configs..."
echo "CONFIG_KSU_SUSFS=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KSU_SUSFS_SUS_KSTAT=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KSU_SUSFS_SPOOF_UNAME=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KSU_SUSFS_ENABLE_LOG=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KSU_SUSFS_OPEN_REDIRECT=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_KSU_SUSFS_SUS_MAP=y" >> "$FINAL_DEFCONFIG"

# Duct tape SUSFS for 4.19
if [[ "$KERNEL_VERSION" == "4.19" ]]; then
    echo "-- ZephyrSU: Patching fs/namespace.c for susfs_sus_mount..."
    sed -i 's|^[[:space:]]*mnt = alloc_vfsmnt(fc->source ?: "none");|#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n\t// - We will just stop checking for ksu process if /sdcard/Android is accessible,\n\t//   for the sake of performance\n\tif (static_branch_unlikely(\&susfs_is_sdcard_android_data_not_decrypted)) {\n\t\tif (susfs_is_current_ksu_domain()) {\n\t\t\tmnt = susfs_alloc_non_unshare_ksu_vfsmnt(fc->source ?:"none");\n\t\t\tgoto bypass_orig_flow;\n\t\t}\n\t}\n#endif\n\tmnt = alloc_vfsmnt(fc->source ?: "none");\n#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nbypass_orig_flow:\n#endif|' fs/namespace.c
fi

# 4.19 compat (runs after setup above, before build.sh compiles):
# linux/static_call.h does not exist before kernel 5.5. The builtin
# branch includes it unconditionally in kernel_includes.h, while every
# real static_call use is guarded to >= 6.12, so guard the include.
for _ksu_inc in KernelSU/kernel/kernel_includes.h drivers/kernelsu/kernel_includes.h; do
  if [ -f "$_ksu_inc" ] && grep -q '#include <linux/static_call.h>' "$_ksu_inc"; then
    sed -i 's|#include <linux/static_call.h>|#include <linux/version.h>\n#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 12, 0)\n#include <linux/static_call.h>\n#endif|' "$_ksu_inc"
    echo "-- ZephyrSU: Guarded static_call.h include in $_ksu_inc for 4.19..."
  fi
done


# Apply manual (inline) hooks
echo "-- ZephyrSU: Applying inline hooks..."
curl -LSs --fail --retry 3 "$KSU_HOOK" | bash &> /dev/null || { echo "-- Fatal: inline hook script failed to download or run!"; exit 1; }

if [[ "$KERNEL_VERSION" == "4.19" ]]; then
    echo "-- ZephyrSU: Fixing typos on fs/stat.c hooks..."
    sed -i 's/ksu_handle_stat(&dfd, &fname, &flag);/ksu_handle_stat(\&dfd, \&fname, \&flags);/g' fs/stat.c
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

# 4.19 compat: access_ok() takes (type, addr, size) before kernel 5.0.
# kpm.c uses the modern 2-arg form; it writes the result back to
# userspace, so use VERIFY_WRITE. Only one access_ok call in ZephyrSU.
for _kpm in KernelSU/kernel/extension/kpm/kpm.c drivers/kernelsu/extension/kpm/kpm.c; do
  if [ -f "$_kpm" ] && grep -q 'access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result))' "$_kpm"; then
    sed -i 's|access_ok(u64_to_user_ptr(cmd.result_code), sizeof(result))|access_ok(VERIFY_WRITE, u64_to_user_ptr(cmd.result_code), sizeof(result))|' "$_kpm"
    echo "-- ZephyrSU: Fixed access_ok call in $_kpm for 4.19..."
  fi
done
