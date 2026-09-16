#!/system/bin/sh
# SUSFS环境守护 v3.0 - 守护进程
# 职责：
#   1) 消费 action.txt 动作
#   2) 聚合 status.json 供 WebUI 实时反馈
#   3) 全程容错，单点失败绝不退出
# 由 service.sh 以 setsid 后台启动，开机自启。

. "${0%/*}/lib_common.sh"

PKG="$PKG_SYSFS"
HWID="$HWID_SYSFS"
STATUS_FILE="$MODDIR/webroot/status.json"
PID_FILE="$RUN_DIR/daemon.pid"
mkdir -p "$MODDIR/webroot"
echo "$$" > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

gprop() { getprop "$1" 2>/dev/null; }
catf() { cat "$1" 2>/dev/null; }

# ---------- JSON 转义 ----------
jq_s() { echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\r\n'; }

# ---------- SUSFS 检测（供 WebUI「SUSFS修复」Tab 显示） ----------
# 返回值会写入 status.json 的 susfs_check 字段
# 每项格式：名称|状态|当前值|期望值|原因
detect_susfs() {
    local out=""
    # 1) bootconfig 伪装
    local bc; bc=$(catf /proc/bootconfig | tr '\n' ' ')
    local bc_ok=0
    case "$bc" in *verifiedbootstate=green*) bc_ok=$((bc_ok+1));; esac
    case "$bc" in *vbmeta.device_state=locked*) bc_ok=$((bc_ok+1));; esac
    if [ "$bc_ok" -ge 2 ]; then
        out="${out}bootconfig伪装|ok|green/locked|green/locked|/proc/bootconfig 已重定向到伪装值\n"
    else
        out="${out}bootconfig伪装|fail|${bc:-空}|green/locked|SUSFS cmdline_or_bootconfig 未生效，检查内核是否支持 CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG\n"
    fi

    # 2) cmdline 重定向
    local cl; cl=$(catf /proc/cmdline | tr '\n' ' ')
    case "$cl" in
        *verifiedbootstate=green*) out="${out}cmdline重定向|ok|green|green|/proc/cmdline 对普通进程已重定向\n";;
        *) out="${out}cmdline重定向|warn|${cl:0:80}|green|open_redirect 未生效或尚未写入伪装文件\n";;
    esac

    # 3) prop 三连（安全版：只做兜底检查，不做修改）
    local p1 p2 p3
    p1=$(gprop ro.boot.verifiedbootstate)
    p2=$(gprop ro.boot.vbmeta.device_state)
    p3=$(gprop ro.boot.flash.locked)
    if [ "$p1" = "green" ] && [ "$p2" = "locked" ] && [ "$p3" = "1" ]; then
        out="${out}prop三连|ok|$p1/$p2/$p3|green/locked/1|内核重定向已覆盖属性读取\n"
    else
        out="${out}prop三连|warn|${p1:-空}/${p2:-空}/${p3:-空}|green/locked/1|属性层未伪装（正常：引导状态由内核重定向伪装，属性层不改）\n"
    fi

    # 4) AVC 日志伪装
    if grep -q '"avc_log_spoofing": true' "$SUSFS_JSON" 2>/dev/null; then
        out="${out}AVC日志伪装|ok|已启用|已启用|免疫 AVC 日志审计类检测\n"
    else
        out="${out}AVC日志伪装|warn|未启用|已启用|内核可能不支持 avc_log_spoofing\n"
    fi

    # 5) 非root进程挂载隐藏
    if grep -q '"hide_sus_mnts_for_non_su_procs": true' "$SUSFS_JSON" 2>/dev/null; then
        out="${out}挂载隐藏|ok|已启用|已启用|非root进程看不到 sus 挂载\n"
    else
        out="${out}挂载隐藏|warn|未启用|已启用|内核可能不支持 hide_sus_mnts\n"
    fi

    # 6) ksu_susfs 工具存在性
    local KS
    KS=$(command -v ksu_susfs 2>/dev/null || \
         for p in /data/adb/ksu/bin/ksu_susfs /data/adb/ksud/bin/ksu_susfs; do
             [ -x "$p" ] && { echo "$p"; break; }
         done)
    if [ -n "$KS" ]; then
        out="${out}ksu_susfs工具|ok|$KS|存在|内核 SUSFS 管理工具就绪\n"
    else
        out="${out}ksu_susfs工具|fail|未找到|存在|内核未编译 SUSFS 或非 KSU 系\n"
    fi

    printf '%b' "$out"
}

# ---------- 进程列表（供 WebUI「进程隐藏」Tab 搜索） ----------
# 输出 JSON 数组，每项 {pid, uid, comm}
list_procs() {
    local first=1
    echo -n "["
    if command -v ps >/dev/null 2>&1; then
        # 兼容 busybox/toybox 两种输出
        ps -A -o PID,UID,NAME 2>/dev/null | tail -n +2 | \
        while read -r pid uid name; do
            case "$pid" in ''|*[!0-9]*) continue ;; esac
            [ -z "$name" ] && continue
            [ "$first" = 1 ] && first=0 || echo -n ","
            printf '{"pid":"%s","uid":"%s","comm":"%s"}' \
                "$pid" "$uid" "$(jq_s "$name")"
        done
    else
        # /proc 遍历兜底
        for d in /proc/[0-9]*; do
            [ -d "$d" ] || continue
            local pid=${d#/proc/}
            local comm; comm=$(catf "$d/comm")
            [ -z "$comm" ] && continue
            local uid; uid=$(stat -c %u "$d" 2>/dev/null)
            [ "$first" = 1 ] && first=0 || echo -n ","
            printf '{"pid":"%s","uid":"%s","comm":"%s"}' \
                "$pid" "$uid" "$(jq_s "$comm")"
        done
    fi
    echo -n "]"
}

# ---------- 应用隐藏验证：以 A 的 UID 尝试读 B 的数据目录 ----------
# 参数：$1 = A 包名，$2 = B 包名（逗号分隔）
# 返回：JSON 数组 {b_pkg, a_pkg, hidden, detail}
verify_hide() {
    local a_pkg="$1" b_list="$2"
    local a_uid; a_uid=$(pkg_uid "$a_pkg")
    local first=1
    echo -n "["
    for b in $(echo "$b_list" | tr ',' ' '); do
        [ -z "$b" ] && continue
        local detail hidden=0
        if [ -z "$a_uid" ]; then
            detail="A 未安装或取不到 UID"
        else
            # 尝试以 A 身份读 B 的目录
            # su <uid> -c 在 KernelSU 下是允许的（如果 manager 开了 su_for_all）
            detail=$(su "$a_uid" -c "ls -d /data/data/$b 2>&1" 2>&1 | head -1)
            case "$detail" in
                *"No such file"*|*"Permission denied"*|*"not found"*)
                    hidden=1;;
                *) hidden=0;;
            esac
        fi
        [ "$first" = 1 ] && first=0 || echo -n ","
        printf '{"a":"%s","b":"%s","hidden":"%s","detail":"%s"}' \
            "$(jq_s "$a_pkg")" "$(jq_s "$b")" "$hidden" "$(jq_s "$detail")"
    done
    echo -n "]"
}

# ---------- 聚合状态 ----------
write_status() {
    local G aid fake_inc
    init_feature_flags
    G=0
    [ "$(get_config spoof_props_enabled 0)" = 1 ] && G=1
    [ "$(get_config spoof_hwid_enabled 0)" = 1 ] && G=1
    [ "$(get_config spoof_android_id 0)" = 1 ] && G=1
    . "$DATA_DIR/fake_profile.conf" 2>/dev/null

    # 属性
    local serial inc fp vb dbg tags oem model
    serial=$(gprop ro.serialno); inc=$(gprop ro.build.version.incremental)
    fp=$(gprop ro.build.fingerprint); vb=$(gprop ro.boot.verifiedbootstate)
    dbg=$(gprop ro.debuggable); tags=$(gprop ro.build.tags); oem=$(gprop sys.oem_unlock_allowed)
    model=$(gprop ro.product.model)

    # 硬件 ID（内核）
    local hwsup=0 hwen=0 hwactive=0 hsoc hwcid hcpu hwmac hbmac
    if [ -f "$HWID/hwid_enabled" ]; then
        hwsup=1; hwen=$(catf "$HWID/hwid_enabled")
        local ks; ks=$(catf "$HWID/hwid_status")
        hwactive=$(printf '%s\n' "$ks" | sed -n 's/.*hook_active=\([01]\).*/\1/p')
        hwactive=${hwactive:-0}
        hsoc=$(echo "$ks" | sed -n 's/^soc_serial=//p')
        hwcid=$(echo "$ks" | sed -n 's/^cid=//p')
        hcpu=$(echo "$ks" | sed -n 's/^cpu_serial=//p')
        hwmac=$(echo "$ks" | sed -n 's/^wlan_mac=//p')
        hbmac=$(echo "$ks" | sed -n 's/^bt_mac=//p')
    fi
    local aidcur; aidcur=$(settings --user 0 get secure android_id 2>/dev/null)
    local hwid_uids; hwid_uids=$(catf "$HWID/hwid_uids")

    # pkgmask
    local pmsup=0 pmdeny pmpaths pmscope pmhproc pmhname pmstat
    if [ -d "$PKG" ] && [ -f "$PKG/reload" ]; then
        pmsup=1
        pmdeny=$(catf "$PKG/deny_uids"); pmpaths=$(catf "$PKG/target_paths")
        pmscope=$(catf "$PKG/scope_mode"); pmhproc=$(catf "$PKG/hide_proc_enabled")
        pmhname=$(catf "$PKG/hide_proc_names"); pmstat=$(catf "$PKG/status" | tr '\n' ';')
    fi

    # SUSFS / kernel
    local susver susstate
    susver=$(catf /sys/module/susfs/version)
    if [ -n "$susver" ]; then
        susstate="ready"
    elif [ -d /sys/module/susfs ] || [ -d /sys/module/ksu_susfs ]; then
        susstate="present"
        susver="present"
    else
        susstate="built_in_or_hidden"
        susver="built-in/hidden"
    fi
    local kver karch; kver=$(uname -r 2>/dev/null); karch=$(uname -m 2>/dev/null)

    # 自检结果
    local scp=0 scw=0 scf=0
    if [ -f "$DATA_DIR/selfcheck_result.json" ]; then
        scp=$(sed -n 's/.*"pass": *\([0-9]*\).*/\1/p' "$DATA_DIR/selfcheck_result.json" | head -1)
        scw=$(sed -n 's/.*"warn": *\([0-9]*\).*/\1/p' "$DATA_DIR/selfcheck_result.json" | head -1)
        scf=$(sed -n 's/.*"fail": *\([0-9]*\).*/\1/p' "$DATA_DIR/selfcheck_result.json" | head -1)
    fi

    # 目标/隐藏列表
    local tgts hides; tgts=$(get_config pkgmask_targets ""); hides=$(get_config pkgmask_hide_pkgs "")
    local identity_state; identity_state=$(catf "$DATA_DIR/identity_state")

    # SUSFS 检测项（每次刷新都跑，较快）
    local susfs_check; susfs_check=$(detect_susfs)

    # 应用隐藏验证结果（只在 WebUI 请求时计算，避免每次刷爆 CPU）
    # 结果缓存在 $RUN_DIR/verify_cache.json
    local verify; verify=$(catf "$RUN_DIR/verify_cache.json")
    [ -z "$verify" ] && verify="[]"

    # 进程列表（只在需要时刷新；结果缓存在 $RUN_DIR/procs_cache.json）
    local procs; procs=$(catf "$RUN_DIR/procs_cache.json")
    [ -z "$procs" ] && procs="[]"

    local tmp="$STATUS_FILE.tmp"
    {
      echo "{"
      echo "  \"ts\": $(date +%s),"
      echo "  \"global\": \"$G\","
      echo "  \"features\": {\"props\":\"$(get_config spoof_props_enabled 0)\",\"android_id\":\"$(get_config spoof_android_id 0)\",\"hwid\":\"$(get_config spoof_hwid_enabled 0)\",\"pkgmask\":\"$(get_config spoof_pkgmask_enabled 0)\",\"prochide\":\"$(get_config spoof_process_hide_enabled 0)\"},"
      echo "  \"identity_transaction\": \"$(jq_s "$identity_state")\","
      echo "  \"props\": {\"serial\":\"$(jq_s "$serial")\",\"fake_serial\":\"$(jq_s "$fake_serial")\",\"incremental\":\"$(jq_s "$inc")\",\"fake_inc\":\"$(jq_s "$fake_inc")\",\"fingerprint\":\"$(jq_s "$fp")\",\"vbstate\":\"$vb\",\"debuggable\":\"$dbg\",\"tags\":\"$tags\",\"oem\":\"$oem\",\"model\":\"$(jq_s "$model")\"},"
      echo "  \"hwid\": {\"supported\":\"$hwsup\",\"enabled\":\"$hwen\",\"hook_active\":\"$hwactive\",\"uids\":\"$(jq_s "$hwid_uids")\",\"cur_aid\":\"$(jq_s "$aidcur")\",\"fake_aid\":\"$(jq_s "$fake_aid")\",\"soc\":\"$(jq_s "$hsoc")\",\"fake_soc\":\"$(jq_s "$fake_soc")\",\"cid\":\"$(jq_s "$hwcid")\",\"fake_cid\":\"$(jq_s "$fake_cid")\",\"cpu\":\"$(jq_s "$hcpu")\",\"fake_cpu\":\"$(jq_s "$fake_cpu")\",\"wmac\":\"$(jq_s "$hwmac")\",\"fake_wmac\":\"$(jq_s "$fake_wmac")\",\"bmac\":\"$(jq_s "$hbmac")\",\"fake_bmac\":\"$(jq_s "$fake_bmac")\"},"
      echo "  \"pkgmask\": {\"supported\":\"$pmsup\",\"scope\":\"$(jq_s "$pmscope")\",\"deny_uids\":\"$(jq_s "$pmdeny")\",\"target_paths\":\"$(jq_s "$pmpaths")\",\"hide_proc\":\"$pmhproc\",\"hide_proc_names\":\"$(jq_s "$pmhname")\",\"status\":\"$(jq_s "$pmstat")\",\"targets\":\"$(jq_s "$tgts")\",\"hide_pkgs\":\"$(jq_s "$hides")\"},"
      echo "  \"susfs\": {\"version\":\"$(jq_s "$susver")\",\"state\":\"$susstate\",\"check\":\"$(jq_s "$susfs_check")\"},"
      echo "  \"kernel\": {\"version\":\"$(jq_s "$kver")\",\"arch\":\"$karch\"},"
      echo "  \"selfcheck\": {\"pass\":\"${scp:-0}\",\"warn\":\"${scw:-0}\",\"fail\":\"${scf:-0}\"},"
      echo "  \"verify\": $verify,"
      echo "  \"procs\": $procs"
      echo "}"
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATUS_FILE"
}

# ---------- 动作消费 ----------
handle_action() {
    local a; a=$(cat "$ACTION_FILE" 2>/dev/null); rm -f "$ACTION_FILE"
    [ -z "$a" ] && return
    log 2 "action: $a"
    case "$a" in
        # ---- 属性 / 硬件 ID ----
        props_on) set_config spoof_props_enabled 1; sh "$MODDIR/tools/props_spoof.sh" apply ;;
        props_off) set_config spoof_props_enabled 0; sh "$MODDIR/tools/props_spoof.sh" restore ;;
        android_on) set_config spoof_android_id 1; sh "$MODDIR/tools/randomize.sh" apply ;;
        android_off) set_config spoof_android_id 0; sh "$MODDIR/tools/randomize.sh" restore_aid; sh "$MODDIR/tools/randomize.sh" apply ;;
        hwid_on) set_config spoof_hwid_enabled 1; sh "$MODDIR/tools/randomize.sh" apply ;;
        hwid_off) set_config spoof_hwid_enabled 0; sh "$MODDIR/tools/randomize.sh" apply ;;
        id_apps_set:*)
            # 参数：逗号分隔的包名列表 -> 转 UID 写入 hwid_uids
            local pkgs="${a#id_apps_set:}" uids="" p u
            for p in $(echo "$pkgs" | tr ',' ' '); do
                [ -z "$p" ] && continue
                u=$(pkg_uid "$p")
                [ -n "$u" ] && uids="${uids:+$uids,}$u"
            done
            echo "$uids" > "$HWID/hwid_uids" 2>/dev/null
            echo 1 > "$HWID/hwid_reload" 2>/dev/null
            log 2 "hwid_uids set to [$uids]"
            ;;
        # ---- SUSFS ----
        susfs_fix)
            local KS
            KS=$(command -v ksu_susfs 2>/dev/null || \
                 for p in /data/adb/ksu/bin/ksu_susfs /data/adb/ksud/bin/ksu_susfs; do
                     [ -x "$p" ] && { echo "$p"; break; }
                 done)
            if [ -n "$KS" ]; then
                local spoof_txt="$MODDIR/config/cmdline_spoof.txt"
                local fake_txt="$MODDIR/config/cmdline_fake.txt"
                [ -s "$spoof_txt" ] || printf '%s\n' "$SPOOF_CMDLINE" > "$spoof_txt"
                [ -s "$fake_txt" ] || echo "$SPOOF_CMDLINE" > "$fake_txt"
                "$KS" config cmdline_or_bootconfig remove 2>/dev/null
                "$KS" config cmdline_or_bootconfig add "$spoof_txt" 2>/dev/null
                "$KS" set_cmdline_or_bootconfig "$spoof_txt" 2>/dev/null
                "$KS" config open_redirect add /proc/cmdline "$fake_txt" 3 2>/dev/null
                "$KS" add_open_redirect /proc/cmdline "$fake_txt" 3 2>/dev/null
                log 2 "susfs_fix executed"
            else
                log 1 "susfs_fix: ksu_susfs not found"
            fi
            ;;
        susfs_check)
            log 2 "susfs_check requested (will be embedded in status.json)"
            ;;
        # ---- pkgmask ----
        pkgmask_apply) sh "$MODDIR/tools/pkgmask_setup.sh" apply ;;
        pkgmask_restore) sh "$MODDIR/tools/pkgmask_setup.sh" restore ;;
        appops_apply) sh "$MODDIR/tools/appops_setup.sh" apply ;;
        targets_set:*)
            local list="${a#targets_set:}"
            set_config pkgmask_targets "$list"
            sh "$MODDIR/tools/pkgmask_setup.sh" apply
            sh "$MODDIR/tools/appops_setup.sh" apply
            # 触发验证
            sh "$MODDIR/tools/run_verify.sh" "$list" >/dev/null 2>&1
            ;;
        hidepkgs_set:*)
            local list="${a#hidepkgs_set:}"
            set_config pkgmask_hide_pkgs "$list"
            sh "$MODDIR/tools/pkgmask_setup.sh" apply
            # 触发验证
            local tgts; tgts=$(get_config pkgmask_targets "")
            sh "$MODDIR/tools/run_verify.sh" "$tgts" >/dev/null 2>&1
            ;;
        # ---- 进程隐藏 ----
        prochide_list)
            # 生成进程列表缓存
            list_procs > "$RUN_DIR/procs_cache.json" 2>/dev/null
            log 2 "prochide_list refreshed"
            ;;
        hide_proc_add:*|prochide_add:*)
            local comm cur found="" item
            comm=$(echo "${a#*:}" | cut -c1-15)
            cur=$(catf "$PKG/hide_proc_names")
            for item in $(echo "$cur" | tr ',' ' '); do
                [ "$item" = "$comm" ] && found=1
            done
            [ -z "$found" ] && echo "${cur:+$cur,}$comm" > "$PKG/hide_proc_names" 2>/dev/null
            echo 1 > "$PKG/hide_proc_enabled" 2>/dev/null
            echo 1 > "$PKG/reload" 2>/dev/null
            log 2 "proc hide added: $comm"
            ;;
        prochide_del:*)
            local comm cur new item
            comm=$(echo "${a#prochide_del:}" | cut -c1-15)
            cur=$(catf "$PKG/hide_proc_names")
            new=""
            for item in $(echo "$cur" | tr ',' ' '); do
                [ "$item" = "$comm" ] && continue
                new="${new:+$new,}$item"
            done
            echo "$new" > "$PKG/hide_proc_names" 2>/dev/null
            echo 1 > "$PKG/reload" 2>/dev/null
            log 2 "proc hide removed: $comm"
            ;;
        # ---- 自检 / 清理 ----
        selfcheck) sh "$MODDIR/tools/selfcheck.sh" > "$RUN_DIR/last_selfcheck.txt" 2>&1 ;;
        cleanup) sh "$MODDIR/tools/cleanup.sh" ;;
        *) log 1 "unknown action: $a" ;;
    esac
    write_status
}

# ---------- 主循环（绝不退出） ----------
echo "=== daemon start $(date) ===" >> "$RUN_DIR/daemon.log"
LOOP=0
ACTIVE_LOOPS=0
IDLE=$(get_config daemon_interval_idle 15)
case "$IDLE" in ''|*[!0-9]*) IDLE=15;; [1-9]*) ;; *) IDLE=15;; esac
ACTIVE=$(get_config daemon_interval_active 1)
case "$ACTIVE" in ''|*[!0-9]*) ACTIVE=1;; [1-9]*) ;; *) ACTIVE=1;; esac
while true; do
    LOOP=$((LOOP+1))
    if [ -f "$ACTION_FILE" ]; then
        handle_action || true
        ACTIVE_LOOPS=15
    fi
    [ $((LOOP % 40)) -eq 0 ] && sh "$MODDIR/tools/log_rotate.sh" >/dev/null 2>&1 || true
    if [ "$ACTIVE_LOOPS" -gt 0 ]; then
        write_status || true
        ACTIVE_LOOPS=$((ACTIVE_LOOPS-1))
        sleep "$ACTIVE"
    else
        [ $((LOOP % 4)) -eq 0 ] && write_status || true
        sleep "$IDLE"
    fi
done
