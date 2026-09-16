#!/system/bin/sh
# SUSFS Env Guard v3.0 - susfs_fix.sh
# 独立 SUSFS 修复脚本，由 run.sh 和 daemon_loop.sh 共同调用
#
# 核心思路：
#   cmdline：读当前真值 → sed 替换敏感字段 → 写伪装文件
#   bootconfig：用固定模板 config/bootconfig_spoof.txt
#              （不能读 /proc/bootconfig 动态生成，因为一旦被重定向
#               就会自我循环污染，越改越少）

. "${0%/*}/lib_common.sh"

# 定位 ksu_susfs 工具
KS=""
for p in /data/adb/ksu/bin/ksu_susfs /data/adb/ksud/bin/ksu_susfs /data/adb/modules/susfs4ksu/bin/ksu_susfs; do
    [ -x "$p" ] && KS="$p" && break
done
[ -z "$KS" ] && { echo "SUSFS_FIX=NO_TOOL"; exit 1; }

D="$MODDIR/config"
F="$D/cmdline_fake.txt"
B="$D/bootconfig_spoof.txt"

# ---------- 1) cmdline 伪装 ----------
# root 视角读 /proc/cmdline 是真值（open_redirect 只对普通 app 生效）
# 所以可以安全地动态生成，不会被自我污染
cat /proc/cmdline | tr '\n' ' ' | sed '
    s/oplusboot\.verifiedbootstate=[a-z]*/oplusboot.verifiedbootstate=green/g
    s/androidboot\.verifiedbootstate=[a-z]*/androidboot.verifiedbootstate=green/g
    s/androidboot\.vbmeta\.device_state=[a-z]*/androidboot.vbmeta.device_state=locked/g
    s/androidboot\.selinux=[a-z]*/androidboot.selinux=enforcing/g
    s/oplusboot\.mode=[a-z]*/oplusboot.mode=normal/g
' > "$F"
echo >> "$F"
cp "$F" "$D/cmdline_spoof.txt"

# ---------- 2) bootconfig 伪装 ----------
# 用固定模板，避免自我循环污染
[ -s "$B" ] || { echo "SUSFS_FIX=NO_BOOTCONFIG_TEMPLATE"; exit 1; }

# ---------- 3) 注册到内核 ----------
# bootconfig 重定向
"$KS" config cmdline_or_bootconfig remove 2>/dev/null
"$KS" config cmdline_or_bootconfig add "$B" 2>/dev/null
"$KS" set_cmdline_or_bootconfig "$B" 2>/dev/null

# cmdline open_redirect（scheme 3 = 普通 app 进程）
"$KS" config open_redirect remove /proc/cmdline 2>/dev/null
"$KS" config open_redirect add /proc/cmdline "$F" 3 2>/dev/null
"$KS" add_open_redirect /proc/cmdline "$F" 3 2>/dev/null

# ---------- 4) 可选：SUSFS 高级隐藏能力 ----------
[ "$(get_config SPOOF_AVC_LOG 0)" = "1" ] && {
    "$KS" config avc_log_spoofing add 2>/dev/null
    "$KS" enable_avc_log_spoofing 1 2>/dev/null
}
[ "$(get_config SPOOF_HIDE_SUS_MNTS 0)" = "1" ] && {
    "$KS" config hide_sus_mnts_for_non_su_procs add 2>/dev/null
    "$KS" hide_sus_mnts_for_non_su_procs 1 2>/dev/null
}

log 2 "susfs_fix: applied cmdline+$B"
echo "SUSFS_FIX=OK"
exit 0
