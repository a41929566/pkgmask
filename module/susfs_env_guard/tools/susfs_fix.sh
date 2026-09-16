#!/system/bin/sh
# SUSFS Env Guard v3.0 - susfs_fix.sh（独立 SUSFS 修复脚本）
# 由 run.sh 和 daemon_loop.sh 共同调用
# 作用：把伪装内容注入内核 SUSFS，让 app 读 /proc/bootconfig 和 /proc/cmdline 时看到假值
#
# 用法: susfs_fix.sh [apply|check]

. "${0%/*}/lib_common.sh"

do_apply() {
    # 找到 ksu_susfs 工具
    local KS
    KS=$(command -v ksu_susfs 2>/dev/null || \
         for p in /data/adb/ksu/bin/ksu_susfs /data/adb/ksud/bin/ksu_susfs \
                  /data/adb/modules/susfs4ksu/bin/ksu_susfs; do
             [ -x "$p" ] && { echo "$p"; break; }
         done)

    if [ -z "$KS" ]; then
        log 0 "susfs_fix: ksu_susfs 未找到，SUSFS 用户态工具未安装"
        echo "SUSFS_FIX=NO_TOOL"
        return 1
    fi

    # 载入配置
    . "$CONF" 2>/dev/null
    : "${SPOOF_CMDLINE:=androidboot.verifiedbootstate=green androidboot.vbmeta.device_state=locked androidboot.selinux=enforcing}"

    # 准备伪装文件
    local spoof_txt="$MODDIR/config/cmdline_spoof.txt"
    local fake_txt="$MODDIR/config/cmdline_fake.txt"
    mkdir -p "$MODDIR/config"

    # 总是重建（因为 SPOOF_CMDLINE 可能改了）
    printf '%s\n' $SPOOF_CMDLINE > "$spoof_txt"
    echo "$SPOOF_CMDLINE" > "$fake_txt"
    chmod 644 "$spoof_txt" "$fake_txt" 2>/dev/null

    # 1) cmdline_or_bootconfig 重定向
    "$KS" config cmdline_or_bootconfig remove 2>/dev/null
    "$KS" config cmdline_or_bootconfig add "$spoof_txt" 2>/dev/null
    "$KS" set_cmdline_or_bootconfig "$spoof_txt" 2>/dev/null

    # 2) open_redirect 重定向
    "$KS" config open_redirect remove /proc/cmdline 2>/dev/null
    "$KS" config open_redirect add /proc/cmdline "$fake_txt" 3 2>/dev/null
    "$KS" add_open_redirect /proc/cmdline "$fake_txt" 3 2>/dev/null

    # 3) 如果配置里开了其他 SUSFS 能力，一并应用
    [ "$(get_config SPOOF_AVC_LOG 0)" = "1" ] && {
        "$KS" config avc_log_spoofing add 2>/dev/null
        "$KS" enable_avc_log_spoofing 1 2>/dev/null
    }
    [ "$(get_config SPOOF_HIDE_SUS_MNTS 0)" = "1" ] && {
        "$KS" config hide_sus_mnts_for_non_su_procs add 2>/dev/null
        "$KS" hide_sus_mnts_for_non_su_procs 1 2>/dev/null
    }

    log 2 "susfs_fix: applied spoof='$SPOOF_CMDLINE'"
    echo "SUSFS_FIX=OK"
    return 0
}

do_check() {
    echo "--- ksu_susfs 工具 ---"
    command -v ksu_susfs || echo "(未找到)"
    echo "--- .susfs.json ---"
    head -20 /data/adb/ksu/.susfs.json 2>/dev/null || echo "(空)"
    echo "--- /proc/bootconfig ---"
    cat /proc/bootconfig 2>/dev/null | grep -iE "verified|device_state"
    echo "--- /proc/cmdline ---"
    cat /proc/cmdline 2>/dev/null | tr ' ' '\n' | grep -iE "verified|device_state"
}

case "$1" in
    apply) do_apply ;;
    check) do_check ;;
    *) do_apply ;;
esac
