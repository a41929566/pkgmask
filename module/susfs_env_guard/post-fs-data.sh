#!/system/bin/sh
# SUSFS Env Guard v3.0 - post-fs-data.sh（zygote 前执行）
# 【安全区】只做文件准备，绝不修改任何系统属性
#
# 核心原则：
#   1) 此阶段只做文件准备，不碰任何 ro.* 属性
#   2) 引导状态伪装由 SUSFS 的 cmdline_or_bootconfig 在内核层完成
#   3) 属性三连延后到 service.sh（开机 10 秒后）
#   4) 历史教训：在 zygote 前修改 ro.boot.verifiedbootstate 会导致一加
#      设备 Bootloader 完整性校验失败，无限重启（卡黄字）

. "${0%/*}/tools/lib_common.sh"

# 应用本模块 SELinux 规则
if [ -f "$MODDIR/sepolicy.rule" ]; then
    "$MAGISKPOLICY" --apply "$MODDIR/sepolicy.rule" 2>/dev/null
fi

# 重建伪装文件（SUSFS 内核重定向的目标文件）
SPOOF_TXT="$MODDIR/config/cmdline_spoof.txt"
FAKE_TXT="$MODDIR/config/cmdline_fake.txt"
. "$CONF" 2>/dev/null
: "${SPOOF_CMDLINE:=androidboot.verifiedbootstate=green androidboot.vbmeta.device_state=locked androidboot.selinux=enforcing}"

if [ ! -s "$SPOOF_TXT" ] || [ ! -s "$FAKE_TXT" ]; then
    if [ -n "$SPOOF_CMDLINE" ]; then
        printf '%s\n' $SPOOF_CMDLINE > "$SPOOF_TXT"
        echo "$SPOOF_CMDLINE" > "$FAKE_TXT"
        chmod 644 "$SPOOF_TXT" "$FAKE_TXT" 2>/dev/null
    fi
fi

# 所有属性伪装、硬件 ID、pkgmask、进程隐藏全部延后到 service.sh
# 原因：zygote 启动前修改 ro.* 属性或挂 vfs_read kretprobe 都可能导致系统级重启

exit 0
