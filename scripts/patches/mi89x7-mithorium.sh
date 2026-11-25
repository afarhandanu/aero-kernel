#!/bin/bash
cd "$KERNEL_DIR"

# Export kernel patches
echo "-- Exporting device patches..."
KSU_REVERT="https://github.com/Mi-Thorium/kernel_msm-4.19/commit/624875e8edc36ae280b1f8efc1d3c48a28da64ea.patch"

# Apply device specific patches
echo "-- Reverting in-tree static KSU commit..."
revert_commit "$KSU_REVERT"

echo "-- Fixing HW key for riva..."
sed -i 's/#define FTS_POINT_REPORT_CHECK_EN[[:space:]]*0/#define FTS_POINT_REPORT_CHECK_EN               1/g' techpack/xiaomi-msm8937/touchscreen/focaltech_touch/focaltech_common.h
sed -i '/input_report_key(input_dev, BTN_TOUCH, 0);/a \
                if (ts_data->key_state) {\
                    struct fts_ts_platform_data *pdata = ts_data->pdata;\
                    int key_idx;\
                    int num_keys = 0;\
                    u32 *keycodes = NULL;\
            \
                if (pdata->key_is_vkeys && pdata->vkeys_pdata) {\
                        num_keys = pdata->vkeys_pdata->num_keys;\
                        keycodes = pdata->vkeys_pdata->keycodes;\
                } else if (!pdata->key_is_vkeys) {\
                        num_keys = pdata->key_number;\
                        keycodes = pdata->keys;\
                }\
            \
                if (keycodes) {\
                        for (key_idx = 0; key_idx < num_keys; key_idx++) {\
                                if (ts_data->key_state & (1 << key_idx))\
                                        input_report_key(input_dev, keycodes[key_idx], 0);\
                        }\
                }\
                ts_data->key_state = 0;\
            }' techpack/xiaomi-msm8937/touchscreen/focaltech_touch/focaltech_point_report_check.c

echo "-- Setting custom kernel release name to Aero-Mi8937v2..."
# 1. Remove localversion files (such as localversion-cip and localversion-st)
rm -f localversion*
# 2. Touch empty .scmversion to prevent git hash / commitish suffix
touch .scmversion
# 3. Strip dirty flag check from scripts/setlocalversion
sed -i "s/printf '%s' -dirty/:/g" scripts/setlocalversion
# 4. Set CONFIG_LOCALVERSION to -Aero-Mi8937v2 so uname -r shows <version>-Aero-Mi8937v2
sed -i 's/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-Aero-Mi8937v2"/g' "$FINAL_DEFCONFIG"
if ! grep -q '^CONFIG_LOCALVERSION=' "$FINAL_DEFCONFIG"; then
    echo 'CONFIG_LOCALVERSION="-Aero-Mi8937v2"' >> "$FINAL_DEFCONFIG"
fi

echo "-- Disabling IKHeaders..."
sed -i 's/CONFIG_IKHEADERS=y/# CONFIG_IKHEADERS is not set/g' "$FINAL_DEFCONFIG"

# tune default configs
echo "-- Tuning default configs..."
echo "CONFIG_LTO_CLANG=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_THINLTO=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_MODULE_REL_CRCS=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_SECURITY_SELINUX_DEVELOP=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_DM_CRYPT=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_DM_DEFAULT_KEY=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_DM_SNAPSHOT=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_DM_UEVENT=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_DM_VERITY=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_DM_VERITY_FEC=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_DM_BOW=y" >> "$FINAL_DEFCONFIG"

# Aero extras. Already on in the Mi-Thorium base, so not repeated here:
# BBR (built, not default), TTL target (IPv4), zram lz4 default, pstore/ramoops.
echo "-- Enabling Aero extras (BBR, fq_codel, HL target, zstd, KSM, HZ 250)..."
# BBR as default TCP congestion control, fq_codel as default qdisc
echo "CONFIG_TCP_CONG_BBR=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_DEFAULT_BBR=y" >> "$FINAL_DEFCONFIG"
echo 'CONFIG_DEFAULT_TCP_CONG="bbr"' >> "$FINAL_DEFCONFIG"
echo "CONFIG_NET_SCH_FQ=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_NET_SCH_FQ_CODEL=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_NET_SCH_DEFAULT=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_DEFAULT_FQ_CODEL=y" >> "$FINAL_DEFCONFIG"
echo 'CONFIG_DEFAULT_NET_SCH="fq_codel"' >> "$FINAL_DEFCONFIG"
# TTL (IPv4) / HL (IPv6) targets for tethering
echo "CONFIG_IP_NF_MANGLE=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_IP_NF_TARGET_TTL=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_IP6_NF_MANGLE=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_IP6_NF_TARGET_HL=y" >> "$FINAL_DEFCONFIG"
echo "CONFIG_NETFILTER_XT_TARGET_HL=y" >> "$FINAL_DEFCONFIG"
# zstd as an extra zram algorithm (lz4 stays the default)
echo "CONFIG_CRYPTO_ZSTD=y" >> "$FINAL_DEFCONFIG"
# KSM
echo "CONFIG_KSM=y" >> "$FINAL_DEFCONFIG"
# Timer frequency 100 -> 250
sed -i '/^CONFIG_HZ_100=y/d;/^CONFIG_HZ=100/d' "$FINAL_DEFCONFIG"
echo "# CONFIG_HZ_100 is not set" >> "$FINAL_DEFCONFIG"
echo "CONFIG_HZ_250=y" >> "$FINAL_DEFCONFIG"

cd ..
