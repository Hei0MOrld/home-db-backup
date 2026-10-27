#!/bin/bash
# 夜は電源を切っているメインPCを、Wake-on-LAN で起こして SSH が通るまで待つ。cron から朝に動かす。
#
# 2026-10 の障害(POSTMORTEM.md)を受けて、メインPCの IP を固定値だけに頼らないようにした。
# マジックパケットは MAC 宛なので IP が変わっても届くが、起動の確認を固定 IP でしていたため、
# DHCP で IP が変わったあと 44 日間「起きなかった」と誤判定し続けた。
# いまは近隣テーブル(ARP)から MAC で今の IP を引き、見つからなければ MAIN_PC_IP を使う。
set -euo pipefail

MAIN_PC_MAC="${MAIN_PC_MAC:-AA:BB:CC:DD:EE:FF}"
MAIN_PC_IP="${MAIN_PC_IP:-192.168.1.10}"
MAIN_PC_SSH_PORT="${MAIN_PC_SSH_PORT:-22}"
BROADCAST_IP="${BROADCAST_IP:-192.168.1.255}"
MAX_WAIT="${MAX_WAIT:-60}"

echo "[wake_main_pc] Sending WoL magic packet to ${MAIN_PC_MAC} via ${BROADCAST_IP}..."
wakeonlan -i "${BROADCAST_IP}" "${MAIN_PC_MAC}"

# Windows は既定で ping(ICMP)に応答しないので、SSH のポートが開くかで起動を確かめる
current_ip() {
    ip neigh show | awk -v m="$(echo "${MAIN_PC_MAC}" | tr 'A-F' 'a-f')" '$5 == m {print $1; exit}'
}
elapsed=0
until { ip_now="$(current_ip)"; [ -n "${ip_now}" ] && MAIN_PC_IP="${ip_now}"; (exec 3<>"/dev/tcp/${MAIN_PC_IP}/${MAIN_PC_SSH_PORT}") 2>/dev/null; }; do
    elapsed=$((elapsed + 2))
    if [ "${elapsed}" -ge "${MAX_WAIT}" ]; then
        echo "[wake_main_pc] Timed out after ${MAX_WAIT}s. Main PC did not come up."
        exit 1
    fi
    sleep 2
done

echo "[wake_main_pc] Main PC is up (${MAIN_PC_IP}, SSH reachable)."
