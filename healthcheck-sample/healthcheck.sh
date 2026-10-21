#!/usr/bin/env bash
# Read-only Linux health check.
# The only write is the file path passed with -o (use /dev/stdout to print).
# Missing tools are reported as N/A. Nothing is installed or restarted.
set -u
set -o pipefail

OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      shift
      OUT="${1-}"
      ;;
    -h|--help)
      printf '%s\n' "usage: healthcheck.sh -o OUTPUT_FILE"
      exit 0
      ;;
    *)
      printf '%s\n' "unknown argument: $1" >&2
      exit 2
      ;;
  esac
  if [ $# -gt 0 ]; then
    shift
  fi
done

if [ -z "${OUT}" ]; then
  printf '%s\n' "usage: healthcheck.sh -o OUTPUT_FILE" >&2
  exit 2
fi

case "${OUT}" in
  /dev/stdout|/dev/stderr|/dev/fd/*)
    ;;
  *)
    : > "${OUT}"
    ;;
esac

have() {
  local found
  found=$(command -v "$1" 2>&1) || return 1
  [ -n "${found}" ]
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "${s}" | tr -d '\000-\010\013\014\016-\037'
}

clip_text() {
  printf '%s\n' "$1" | awk 'NR<=24 { print } NR==25 { print "... truncated ..."; exit }'
}

emit() {
  local id="$1"
  local title="$2"
  local command="$3"
  local evidence="$4"
  local risk="$5"
  local rec_en="$6"
  local rec_zh="$7"
  case "${risk}" in
    OK|Low|Medium|High|N/A) ;;
    *) risk="N/A" ;;
  esac
  evidence=$(clip_text "${evidence}")
  printf '{"id":"%s","title":"%s","command":"%s","evidence":"%s","risk":"%s","recommendation_en":"%s","recommendation_zh":"%s"}\n' \
    "$(json_escape "${id}")" \
    "$(json_escape "${title}")" \
    "$(json_escape "${command}")" \
    "$(json_escape "${evidence}")" \
    "$(json_escape "${risk}")" \
    "$(json_escape "${rec_en}")" \
    "$(json_escape "${rec_zh}")" >> "${OUT}"
}

capture() {
  local secs="$1"
  shift
  CAP_RC=0
  CAP_OUT=""
  if have timeout; then
    CAP_OUT=$(timeout "${secs}" "$@" 2>&1) || CAP_RC=$?
  else
    CAP_OUT=$("$@" 2>&1) || CAP_RC=$?
  fi
}

worst_rank() {
  case "$1" in
    High) printf '4' ;;
    Medium) printf '3' ;;
    Low) printf '2' ;;
    OK) printf '1' ;;
    *) printf '0' ;;
  esac
}

rank_name() {
  case "$1" in
    4) printf 'High' ;;
    3) printf 'Medium' ;;
    2) printf 'Low' ;;
    1) printf 'OK' ;;
    *) printf 'N/A' ;;
  esac
}

bump() {
  local cur="$1"
  local add="$2"
  local rc ac
  rc=$(worst_rank "${cur}")
  ac=$(worst_rank "${add}")
  if [ "${ac}" -gt "${rc}" ]; then
    printf '%s' "${add}"
  else
    printf '%s' "${cur}"
  fi
}

skip_fstype() {
  case "$1" in
    tmpfs|devtmpfs|devfs|squashfs|iso9660|proc|sysfs|cgroup|cgroup2|autofs|bpf|tracefs|securityfs|pstore|mqueue|hugetlbfs|debugfs|fusectl|configfs|nsfs|ramfs|efivarfs|rpc_pipefs|binfmt_misc|none)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

check_os() {
  local evidence="" risk="OK" parts=""
  if [ -r /etc/os-release ]; then
    parts=$(awk -F= '/^(NAME|VERSION|PRETTY_NAME)=/{print}' /etc/os-release 2>&1 || true)
  else
    parts="os-release not readable"
    risk="N/A"
  fi
  local uname_out load_out up_out
  if have uname; then
    uname_out=$(uname -srmv 2>&1 || true)
  else
    uname_out="uname not present"
    risk="N/A"
  fi
  if have uptime; then
    up_out=$(uptime 2>&1 || true)
  elif [ -r /proc/uptime ]; then
    up_out=$(awk '{printf "uptime_seconds %.0f\n", $1}' /proc/uptime 2>&1 || true)
  else
    up_out="uptime not present"
    risk="N/A"
  fi
  if [ -r /proc/loadavg ]; then
    load_out=$(cat /proc/loadavg 2>&1 || true)
    local load1 cpus
    load1=$(awk '{print $1}' /proc/loadavg 2>&1 || echo 0)
    if have nproc; then
      cpus=$(nproc 2>&1 || echo 1)
    else
      cpus=$(awk '/^processor/{n++} END{print n+0}' /proc/cpuinfo 2>&1 || echo 1)
    fi
    [ -z "${cpus}" ] && cpus=1
    local load_x10 cpu_x10
    load_x10=$(awk -v v="${load1}" 'BEGIN{printf "%d", v*10}')
    cpu_x10=$((cpus * 10))
    if [ "${load_x10}" -gt $((cpu_x10 * 4)) ]; then
      risk=$(bump "${risk}" High)
    elif [ "${load_x10}" -gt $((cpu_x10 * 2)) ]; then
      risk=$(bump "${risk}" Medium)
    fi
  else
    load_out="loadavg not readable"
    risk="N/A"
  fi
  evidence=$(printf 'os-release:\n%s\nuname: %s\nuptime: %s\nloadavg: %s\n' "${parts}" "${uname_out}" "${up_out}" "${load_out}")
  local rec_en rec_zh
  case "${risk}" in
    High|Medium)
      rec_en="Load is high for the visible CPU count. Inspect runaway processes before the next change window."
      rec_zh="相对可见 CPU 数量，负载偏高。在下一次变更窗口前先查看异常进程。"
      ;;
    N/A)
      rec_en="OS, kernel, uptime, or load could not be read. Re-run from an account that can read /proc and /etc/os-release."
      rec_zh="未能读取操作系统、内核、运行时间或负载。请用可以读取 /proc 与 /etc/os-release 的账户重试。"
      ;;
    *)
      rec_en="OS, kernel, uptime, and load were readable. Keep this snapshot with the rest of the report."
      rec_zh="已读到操作系统、内核、运行时间与负载。请把这份快照和报告其余部分一起留存。"
      ;;
  esac
  emit "os" "OS, kernel, uptime, and load" "uname -srmv; uptime; cat /proc/loadavg; awk /etc/os-release" "${evidence}" "${risk}" "${rec_en}" "${rec_zh}"
}

usage_scan() {
  local mode="$1"
  local cmd evidence line fstype pct rest rank=0 risk="N/A" seen=0
  if [ "${mode}" = "disk" ]; then
    cmd="df -PT"
  else
    cmd="df -PiT"
  fi
  if ! have df; then
    emit "${mode}" "$( [ "${mode}" = "disk" ] && printf 'Disk usage' || printf 'Inode usage' )" "${cmd}" "df not present" "N/A" \
      "Do not add packages during a read-only review. Provide df output from the agreed account if this host hides it." \
      "只读检查期间不添加软件包。如果该主机隐藏了 df，请由约定账户提供 df 输出。"
    return
  fi
  if [ "${mode}" = "disk" ]; then
    capture 15 df -PT
  else
    capture 15 df -PiT
  fi
  evidence="${CAP_OUT}"
  if [ "${CAP_RC}" -ne 0 ] && [ -z "${CAP_OUT}" ]; then
    emit "${mode}" "$( [ "${mode}" = "disk" ] && printf 'Disk usage' || printf 'Inode usage' )" "${cmd}" "df failed (exit ${CAP_RC})" "N/A" \
      "df did not return usage. Confirm the account can run df." \
      "df 没有返回用量。请确认该账户可以运行 df。"
    return
  fi
  while IFS= read -r line; do
    case "${line}" in
      Filesystem*) continue ;;
      "") continue ;;
    esac
    fstype=$(printf '%s\n' "${line}" | awk '{print $2}')
    pct=$(printf '%s\n' "${line}" | awk '{
      for (i = 1; i <= NF; i++) if ($i ~ /%$/) { gsub(/%/, "", $i); print $i; exit }
    }')
    case "${pct}" in
      ''|*[!0-9]*) continue ;;
    esac
    if skip_fstype "${fstype}"; then
      continue
    fi
    seen=1
    if [ "${pct}" -gt 85 ]; then
      rank=$(bump "$(rank_name "${rank}")" High)
      rank=$(worst_rank "${rank}")
    elif [ "${pct}" -gt 70 ]; then
      rank=$(bump "$(rank_name "${rank}")" Medium)
      rank=$(worst_rank "${rank}")
    else
      if [ "${rank}" -eq 0 ]; then
        rank=1
      fi
    fi
  done <<EOF
${CAP_OUT}
EOF
  if [ "${seen}" -eq 0 ]; then
    risk="N/A"
  else
    risk=$(rank_name "${rank}")
  fi
  local title rec_en rec_zh
  if [ "${mode}" = "disk" ]; then
    title="Disk usage"
    rec_en="Flag filesystems above 85 percent as High and above 70 percent as Medium. Plan cleanup or growth before either band is reached. Pseudo filesystems are skipped."
    rec_zh="文件系统用量高于 85% 记为高，高于 70% 记为中。在进入这两个区间前安排清理或扩容。已跳过虚拟文件系统。"
  else
    title="Inode usage"
    rec_en="Inode pressure uses the same bands: above 85 percent High, above 70 percent Medium. A full inode table blocks new files even when bytes remain."
    rec_zh="inode 压力使用同一档位：高于 85% 为高，高于 70% 为中。inode 用尽时，即使还有剩余字节也无法新建文件。"
  fi
  if [ "${risk}" = "N/A" ]; then
    rec_en="No eligible filesystem was parsed from df. Review the evidence and repeat with the agreed account."
    rec_zh="没有从 df 解析出符合条件的文件系统。请查看证据，并用约定账户重试。"
  elif [ "${risk}" = "OK" ]; then
    rec_en="Eligible filesystems are at or below 70 percent. ${rec_en}"
    rec_zh="符合条件的文件系统均在 70% 及以下。${rec_zh}"
  fi
  emit "${mode}" "${title}" "${cmd}" "${evidence}" "${risk}" "${rec_en}" "${rec_zh}"
}

check_memory() {
  local evidence risk="OK" rec_en rec_zh
  if [ ! -r /proc/meminfo ]; then
    emit "memory" "Memory and swap" "awk /proc/meminfo" "meminfo not readable" "N/A" \
      "Memory figures were not readable. Re-run where /proc/meminfo is allowed." \
      "未能读取内存数据。请在允许读取 /proc/meminfo 的环境重试。"
    return
  fi
  evidence=$(awk '
    /^MemTotal:/ {t=$2}
    /^MemAvailable:/ {a=$2}
    /^SwapTotal:/ {st=$2}
    /^SwapFree:/ {sf=$2}
    END {
      printf "MemTotal_kB %d\nMemAvailable_kB %d\nSwapTotal_kB %d\nSwapFree_kB %d\n", t, a, st, sf
      if (t > 0) printf "mem_used_pct %d\n", (t-a)*100/t
      if (st > 0) printf "swap_used_pct %d\n", (st-sf)*100/st
      else print "swap_used_pct none"
    }
  ' /proc/meminfo)
  local mem_pct swap_pct swap_total
  mem_pct=$(printf '%s\n' "${evidence}" | awk '/^mem_used_pct/{print $2}')
  swap_pct=$(printf '%s\n' "${evidence}" | awk '/^swap_used_pct/{print $2}')
  swap_total=$(printf '%s\n' "${evidence}" | awk '/^SwapTotal_kB/{print $2}')
  mem_pct=${mem_pct:-0}
  if [ "${mem_pct}" -gt 90 ]; then
    risk="High"
  elif [ "${mem_pct}" -gt 80 ]; then
    risk="Medium"
  fi
  if [ "${swap_pct}" != "none" ]; then
    if [ "${swap_pct}" -gt 80 ]; then
      risk=$(bump "${risk}" High)
    elif [ "${swap_pct}" -gt 50 ]; then
      risk=$(bump "${risk}" Medium)
    fi
  elif [ "${swap_total}" = "0" ]; then
    if [ "${risk}" = "OK" ]; then
      risk="Low"
    fi
  fi
  rec_en="Memory used above 90 percent is High and above 80 percent is Medium. Swap used above 80 percent is High and above 50 percent is Medium. No swap is Low when memory itself is fine, because a spike has nowhere to go."
  rec_zh="内存占用高于 90% 为高，高于 80% 为中。交换区占用高于 80% 为高，高于 50% 为中。内存本身正常但没有交换区时记为低，因为突发占用没有缓冲。"
  emit "memory" "Memory and swap" "awk /proc/meminfo" "${evidence}" "${risk}" "${rec_en}" "${rec_zh}"
}

check_failed_units() {
  local evidence risk rec_en rec_zh
  if ! have systemctl; then
    emit "failed-units" "Failed systemd units" "systemctl list-units --state=failed --no-legend --plain --no-pager" "systemctl not present" "N/A" \
      "This host did not provide systemctl. Skip the unit check or collect it from a host that runs systemd." \
      "该主机没有 systemctl。请跳过单元检查，或在运行 systemd 的主机上收集。"
    return
  fi
  capture 15 systemctl list-units --state=failed --no-legend --plain --no-pager
  evidence="${CAP_OUT}"
  if printf '%s\n' "${CAP_OUT}" | grep -qi 'not been booted with systemd\|Failed to connect to bus\|System has not been booted'; then
    emit "failed-units" "Failed systemd units" "systemctl list-units --state=failed --no-legend --plain --no-pager" "${evidence}" "N/A" \
      "systemd is not the running init here, so failed units cannot be listed." \
      "这里的 init 不是正在运行的 systemd，因此无法列出失败单元。"
    return
  fi
  local count
  count=$(printf '%s\n' "${CAP_OUT}" | awk 'NF>0 && $1 !~ /^(UNIT|LOAD|ACTIVE|SUB|To|listed)/ { n++ } END{print n+0}')
  if [ "${CAP_RC}" -ne 0 ] && [ "${count}" -eq 0 ]; then
    risk="N/A"
    rec_en="systemctl did not return a unit list. Confirm the account can query systemd."
    rec_zh="systemctl 没有返回单元列表。请确认该账户可以查询 systemd。"
  elif [ "${count}" -eq 0 ]; then
    risk="OK"
    rec_en="No failed units. Re-check after the next deploy."
    rec_zh="没有失败单元。下次部署后再复查。"
  elif [ "${count}" -ge 3 ]; then
    risk="High"
    rec_en="Three or more units are failed. Read each unit status before changing the host."
    rec_zh="有三个或更多单元处于失败状态。变更主机前先查看每个单元的状态。"
  else
    risk="Medium"
    rec_en="At least one unit is failed. Read its status and decide whether it is expected."
    rec_zh="至少有一个单元失败。请查看其状态，并判断这是否在预期内。"
  fi
  emit "failed-units" "Failed systemd units" "systemctl list-units --state=failed --no-legend --plain --no-pager" "${evidence:-"(none)"}" "${risk}" "${rec_en}" "${rec_zh}"
}

check_ports() {
  local evidence risk rec_en rec_zh
  if ! have ss; then
    emit "listening-ports" "Listening TCP ports" "ss -tlnp" "ss not present" "N/A" \
      "ss is not on this host. A read-only review can accept saved ss output instead of installing it." \
      "该主机没有 ss。只读检查可以接受事先保存的 ss 输出，而不是现场安装。"
    return
  fi
  capture 15 ss -tlnp
  evidence="${CAP_OUT}"
  if [ "${CAP_RC}" -ne 0 ] && ! printf '%s\n' "${CAP_OUT}" | grep -q LISTEN; then
    emit "listening-ports" "Listening TCP ports" "ss -tlnp" "${evidence}" "N/A" \
      "ss failed. Confirm the account may list sockets." \
      "ss 执行失败。请确认该账户可以列出套接字。"
    return
  fi
  local wild
  wild=$(printf '%s\n' "${CAP_OUT}" | awk 'NR>1 && $1 ~ /LISTEN/ {
    addr=$4
    if (addr ~ /^(0\.0\.0\.0:|\*:|\[::\]:)/) w=1
  } END{print w+0}')
  if [ "${wild}" -gt 0 ]; then
    risk="Low"
    rec_en="At least one TCP port listens on a wildcard address. Confirm each listener is intentional and firewalled."
    rec_zh="至少有一个 TCP 端口在通配地址上监听。请确认每个监听都是有意开放的，并且有防火墙限制。"
  else
    risk="OK"
    rec_en="Listeners are present only on local addresses, or none were listed. Keep the list with the change record."
    rec_zh="监听只出现在本地地址上，或者没有列出监听。请把这份列表和变更记录一起保存。"
  fi
  emit "listening-ports" "Listening TCP ports" "ss -tlnp" "${evidence}" "${risk}" "${rec_en}" "${rec_zh}"
}

ssh_first() {
  local kw="$1"
  shift
  local f line key val
  for f in "$@"; do
    [ -f "${f}" ] || continue
    while IFS= read -r line || [ -n "${line}" ]; do
      case "${line}" in
        ''|\#*) continue ;;
        [Mm]atch*|MATCH*) break ;;
      esac
      line=${line%%#*}
      key=$(printf '%s\n' "${line}" | awk '{print tolower($1)}')
      val=$(printf '%s\n' "${line}" | awk '{print tolower($2)}')
      if [ "${key}" = "${kw}" ] && [ -n "${val}" ]; then
        printf '%s' "${val}"
        return 0
      fi
    done < "${f}"
  done
  return 1
}

check_ssh() {
  local evidence="" prl="" pa="" source="" risk="N/A"
  local files=()
  local f
  if [ -d /etc/ssh/sshd_config.d ]; then
    for f in /etc/ssh/sshd_config.d/*.conf; do
      [ -f "${f}" ] && files+=("${f}")
    done
  fi
  [ -f /etc/ssh/sshd_config ] && files+=("/etc/ssh/sshd_config")
  if have sshd; then
    capture 15 sshd -T
    if printf '%s\n' "${CAP_OUT}" | awk 'tolower($1)=="permitrootlogin"{found=1} END{exit !found}'; then
      evidence="${CAP_OUT}"
      prl=$(printf '%s\n' "${CAP_OUT}" | awk 'tolower($1)=="permitrootlogin"{print tolower($2); exit}')
      pa=$(printf '%s\n' "${CAP_OUT}" | awk 'tolower($1)=="passwordauthentication"{print tolower($2); exit}')
      source="sshd -T"
    fi
  fi
  if [ -z "${prl}" ] && [ "${#files[@]}" -gt 0 ]; then
    prl=$(ssh_first permitrootlogin "${files[@]}" || true)
    pa=$(ssh_first passwordauthentication "${files[@]}" || true)
    evidence=$(printf '%s\n' "${files[@]}" | while read -r f; do
      [ -f "${f}" ] || continue
      printf 'FILE %s\n' "${f}"
      awk '/^[[:space:]]*#/ {next} /^[[:space:]]*$/ {next} tolower($1)=="permitrootlogin" || tolower($1)=="passwordauthentication" || tolower($1)=="match" {print} tolower($1)=="match" {exit}' "${f}"
    done)
    source="config files"
  fi
  if [ -z "${source}" ]; then
    emit "ssh" "SSH root login and password authentication" "sshd -T || read /etc/ssh/sshd_config" "sshd and sshd_config not available" "N/A" \
      "SSH settings could not be read. Skip this item or provide the files from the agreed account." \
      "未能读取 SSH 设置。请跳过此项，或由约定账户提供配置文件。"
    return
  fi
  evidence=$(printf 'source: %s\npermitrootlogin: %s\npasswordauthentication: %s\n%s\n' "${source}" "${prl:-unset}" "${pa:-unset}" "${evidence}")
  case "${prl}" in
    yes) risk="High" ;;
    no) risk="OK" ;;
    prohibit-password|without-password|forced-commands-only) risk="Low" ;;
    "") risk="N/A" ;;
    *) risk="Low" ;;
  esac
  case "${pa}" in
    yes) risk=$(bump "${risk}" Medium) ;;
    no) ;;
    "") ;;
    *) risk=$(bump "${risk}" Low) ;;
  esac
  local rec_en rec_zh
  rec_en="PermitRootLogin yes is High. PasswordAuthentication yes is Medium. Prefer key-only login and root login disabled, applied only after written approval."
  rec_zh="PermitRootLogin 为 yes 记为高。PasswordAuthentication 为 yes 记为中。更稳妥的做法是仅允许密钥登录并禁止 root 登录，且只在书面批准后实施。"
  if [ "${risk}" = "N/A" ]; then
    rec_en="The two directives were not found and sshd -T did not print them. Do not guess the effective policy."
    rec_zh="未找到这两项指令，sshd -T 也没有打印它们。不要猜测实际策略。"
  fi
  emit "ssh" "SSH root login and password authentication" "sshd -T || read /etc/ssh/sshd_config" "${evidence}" "${risk}" "${rec_en}" "${rec_zh}"
}

check_updates() {
  local evidence risk rec_en rec_zh
  if ! have apt-get && ! have apt; then
    emit "updates" "Pending package updates" "apt list --upgradable" "apt not present" "N/A" \
      "apt is not present, so pending updates were not listed." \
      "没有 apt，因此未列出待更新软件包。"
    return
  fi
  capture 30 apt list --upgradable
  evidence="${CAP_OUT}"
  if printf '%s\n' "${CAP_OUT}" | grep -qi 'Unable to locate\|command not found\|Permission denied'; then
    emit "updates" "Pending package updates" "apt list --upgradable" "${evidence}" "N/A" \
      "apt could not list upgradable packages for this account." \
      "该账户无法用 apt 列出可升级软件包。"
    return
  fi
  local total security
  total=$(printf '%s\n' "${CAP_OUT}" | awk '/\// && !/Listing/ {n++} END{print n+0}')
  security=$(printf '%s\n' "${CAP_OUT}" | awk 'tolower($0) ~ /security/ && /\// {n++} END{print n+0}')
  if [ "${security}" -gt 20 ]; then
    risk="High"
  elif [ "${security}" -gt 0 ]; then
    risk="Medium"
  elif [ "${total}" -gt 0 ]; then
    risk="Low"
  else
    risk="OK"
  fi
  evidence=$(printf 'upgradable_count %s\nsecurity_mentions %s\n%s\n' "${total}" "${security}" "$(clip_text "${CAP_OUT}")")
  rec_en="Lines that mention the security pocket are counted apart from other upgradable packages. More than 20 security lines is High, any security line is Medium, other pending packages are Low. Applying updates is outside this read-only check."
  rec_zh="提及安全源的行与其他可升级软件包分开计数。安全相关超过 20 行为高，只要有安全相关行则为中，其余待更新为低。安装更新不在本次只读检查范围内。"
  emit "updates" "Pending package updates" "apt list --upgradable" "${evidence}" "${risk}" "${rec_en}" "${rec_zh}"
}

check_time() {
  local evidence risk rec_en rec_zh
  if ! have timedatectl; then
    emit "time-sync" "Time synchronization" "timedatectl status" "timedatectl not present" "N/A" \
      "timedatectl is not present. Time sync was not judged." \
      "没有 timedatectl。未判断时间同步状态。"
    return
  fi
  capture 15 timedatectl status
  evidence="${CAP_OUT}"
  if printf '%s\n' "${CAP_OUT}" | grep -qi 'not been booted with systemd\|Failed to connect to bus'; then
    emit "time-sync" "Time synchronization" "timedatectl status" "${evidence}" "N/A" \
      "timedatectl cannot query this environment because systemd is not available." \
      "由于没有可用的 systemd，timedatectl 无法查询此环境。"
    return
  fi
  if printf '%s\n' "${CAP_OUT}" | grep -qi 'System clock synchronized: yes\|NTPSynchronized=yes'; then
    risk="OK"
    rec_en="The clock reports synchronization. Keep NTP enabled."
    rec_zh="时钟报告已同步。请保持 NTP 开启。"
  elif printf '%s\n' "${CAP_OUT}" | grep -qi 'System clock synchronized: no\|NTPSynchronized=no'; then
    risk="Medium"
    rec_en="The clock is not synchronized. Logs and certificates will drift until NTP is enabled, after written approval."
    rec_zh="时钟未同步。在书面批准并启用 NTP 之前，日志和证书时间都会漂移。"
  else
    risk="Low"
    rec_en="timedatectl ran but did not state clock synchronization clearly. Confirm NTP by hand from this evidence."
    rec_zh="timedatectl 已运行，但没有明确说明时钟是否同步。请根据这份证据人工确认 NTP。"
  fi
  emit "time-sync" "Time synchronization" "timedatectl status" "${evidence}" "${risk}" "${rec_en}" "${rec_zh}"
}

check_kernel() {
  local evidence="" blob="" risk="N/A" source=""
  if have journalctl; then
    capture 20 journalctl -k -n 120 --no-pager -o cat
    if [ "${CAP_RC}" -eq 0 ] || printf '%s\n' "${CAP_OUT}" | grep -qi 'memory\|error\|oom'; then
      if ! printf '%s\n' "${CAP_OUT}" | grep -qi 'not been booted with systemd\|No journal files\|Failed to connect\|permission denied'; then
        blob="${CAP_OUT}"
        source="journalctl -k -n 120 --no-pager -o cat"
      fi
    fi
  fi
  if [ -z "${blob}" ] && have dmesg; then
    capture 15 dmesg -T
    if [ "${CAP_RC}" -ne 0 ]; then
      capture 15 dmesg
    fi
    if ! printf '%s\n' "${CAP_OUT}" | grep -qi 'operation not permitted\|permission denied\|not available'; then
      blob="${CAP_OUT}"
      source="dmesg"
    else
      evidence="${CAP_OUT}"
    fi
  fi
  if [ -z "${blob}" ]; then
    emit "kernel-errors" "Recent OOM and kernel errors" "journalctl -k -n 120 --no-pager -o cat || dmesg" "${evidence:-kernel log not readable}" "N/A" \
      "Kernel logs were not readable for this account. Do not treat that as a clean bill of health." \
      "该账户读不到内核日志。不要把这一点当成系统健康的证明。"
    return
  fi
  local lowblob
  lowblob=$(printf '%s\n' "${blob}" | tr 'A-Z' 'a-z')
  if printf '%s\n' "${lowblob}" | grep -q 'out of memory\|oom-kill\|killed process\|kernel panic'; then
    risk="High"
  elif printf '%s\n' "${lowblob}" | grep -q 'i/o error\|bug:\|ext4-fs error\|xfs .*error\|call trace'; then
    risk="Medium"
  else
    risk="OK"
  fi
  evidence=$(printf 'source: %s\n%s\n' "${source}" "$(clip_text "${blob}")")
  local rec_en rec_zh
  case "${risk}" in
    High)
      rec_en="The kernel log mentions an out-of-memory kill or a panic. Investigate before adding load."
      rec_zh="内核日志提到内存耗尽终止或 panic。增加负载前先查清原因。"
      ;;
    Medium)
      rec_en="The kernel log mentions I/O or filesystem errors. Investigate the disk path before trusting new writes."
      rec_zh="内核日志提到 I/O 或文件系统错误。在信任新的写入之前，先检查磁盘路径。"
      ;;
    *)
      rec_en="No OOM, panic, or matched kernel error in the excerpt. This is only the recent excerpt, not a full history."
      rec_zh="摘录中没有内存耗尽、panic 或匹配到的内核错误。这只是最近一段摘录，不是完整历史。"
      ;;
  esac
  emit "kernel-errors" "Recent OOM and kernel errors" "${source}" "${evidence}" "${risk}" "${rec_en}" "${rec_zh}"
}

check_world_writable() {
  local evidence risk rec_en rec_zh
  if ! have find; then
    emit "world-writable" "World-writable files in /etc" "find /etc -xdev -type f -perm -0002 -print" "find not present" "N/A" \
      "find is not present, so /etc was not scanned for world-writable files." \
      "没有 find，因此未扫描 /etc 中的全局可写文件。"
    return
  fi
  capture 20 find /etc -xdev -type f -perm -0002 -print
  local paths
  paths=$(printf '%s\n' "${CAP_OUT}" | awk '/^\//{print}')
  local count
  count=$(printf '%s\n' "${paths}" | awk 'NF{n++} END{print n+0}')
  evidence=$(printf 'count %s\n%s\n' "${count}" "$(clip_text "${paths:-"(none)"}")")
  if [ "${count}" -gt 0 ]; then
    risk="High"
    rec_en="World-writable files under /etc let any local account change configuration. List them for the owner. Do not alter them in this read-only pass."
    rec_zh="/etc 下的全局可写文件允许任何本地账户修改配置。请把清单交给负责人。本次只读检查不改动这些文件。"
  else
    risk="OK"
    rec_en="No world-writable regular files were found under /etc on this filesystem."
    rec_zh="在该文件系统的 /etc 下没有发现全局可写的普通文件。"
  fi
  emit "world-writable" "World-writable files in /etc" "find /etc -xdev -type f -perm -0002 -print" "${evidence}" "${risk}" "${rec_en}" "${rec_zh}"
}

check_uid0() {
  local evidence risk rec_en rec_zh
  if [ ! -r /etc/passwd ]; then
    emit "uid0" "Accounts with UID 0" "awk -F: '\$3==0 {print \$1}' /etc/passwd" "passwd not readable" "N/A" \
      "/etc/passwd was not readable, so UID 0 accounts were not listed." \
      "无法读取 /etc/passwd，因此未列出 UID 0 账户。"
    return
  fi
  evidence=$(awk -F: '$3==0 {print $1}' /etc/passwd)
  local extra
  extra=$(printf '%s\n' "${evidence}" | awk '$0!="" && $0!="root"{n++} END{print n+0}')
  if [ -z "${evidence}" ]; then
    risk="High"
    rec_en="No UID 0 account was listed, which is unexpected. Confirm passwd is complete."
    rec_zh="没有列出任何 UID 0 账户，这不正常。请确认 passwd 是否完整。"
  elif [ "${extra}" -gt 0 ]; then
    risk="High"
    rec_en="More than one account has UID 0. Extra root-equivalent accounts should be named in the review and removed only after written approval."
    rec_zh="不止一个账户的 UID 为 0。审查中应点名这些等同 root 的账户，并且只在书面批准后删除。"
  else
    risk="OK"
    rec_en="root is the only UID 0 account in /etc/passwd."
    rec_zh="/etc/passwd 中只有 root 的 UID 为 0。"
  fi
  emit "uid0" "Accounts with UID 0" "awk -F: '\$3==0 {print \$1}' /etc/passwd" "${evidence}" "${risk}" "${rec_en}" "${rec_zh}"
}

check_certs() {
  local evidence="" risk="N/A" seen=0 rank=0
  if ! have openssl; then
    emit "certificates" "Local certificate expiry" "openssl x509 -noout -enddate -in CERT" "openssl not present" "N/A" \
      "openssl is not present, so local certificate dates were not read." \
      "没有 openssl，因此未读取本地证书日期。"
    return
  fi
  local dirs="/etc/nginx /etc/apache2 /etc/ssl/private /etc/letsencrypt /etc/haproxy /etc/pki/tls"
  local d f enddate subject note=""
  local count=0
  for d in ${dirs}; do
    [ -d "${d}" ] || continue
    while IFS= read -r f; do
      [ -n "${f}" ] || continue
      count=$((count + 1))
      [ "${count}" -gt 20 ] && break
      if ! err=$(openssl x509 -noout -in "${f}" 2>&1); then
        continue
      fi
      seen=1
      enddate=$(openssl x509 -noout -enddate -in "${f}" 2>&1 || true)
      subject=$(openssl x509 -noout -subject -in "${f}" 2>&1 || true)
      local level="OK"
      if ! err=$(openssl x509 -checkend 0 -noout -in "${f}" 2>&1); then
        level="High"
        note="expired"
      elif ! err=$(openssl x509 -checkend 2592000 -noout -in "${f}" 2>&1); then
        level="High"
        note="within 30 days"
      elif ! err=$(openssl x509 -checkend 5184000 -noout -in "${f}" 2>&1); then
        level="Medium"
        note="within 60 days"
      else
        note="beyond 60 days"
      fi
      rank=$(worst_rank "$(bump "$(rank_name "${rank}")" "${level}")")
      evidence=$(printf '%s\n%s\n%s\n%s\n' "${evidence}" "${f}" "${subject}" "${enddate} (${note})")
    done <<EOF
$(find "${d}" -xdev -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.cer' \) ! -name 'ca-certificates.crt' ! -name 'ca-bundle.crt' -size -200k -print 2>&1)
EOF
  done
  if [ "${seen}" -eq 0 ]; then
    emit "certificates" "Local certificate expiry" "openssl x509 -noout -enddate -in CERT" "no local leaf certificates found under the usual server paths" "N/A" \
      "No local server certificate was found under nginx, apache, letsencrypt, haproxy, or the private SSL directory. Public CA stores were not treated as server certificates." \
      "在 nginx、apache、letsencrypt、haproxy 或私有 SSL 目录下没有找到本地服务器证书。公共 CA 证书库不视为服务器证书。"
    return
  fi
  risk=$(rank_name "${rank}")
  local rec_en rec_zh
  rec_en="A certificate that is expired or inside 30 days is High. Inside 60 days is Medium. Renewal is a change and is not done by this read-only check."
  rec_zh="已过期或 30 天内到期的证书记为高。60 天内到期记为中。续期属于变更，本次只读检查不执行续期。"
  emit "certificates" "Local certificate expiry" "openssl x509 -checkend -in CERT" "${evidence}" "${risk}" "${rec_en}" "${rec_zh}"
}

check_os
usage_scan disk
usage_scan inodes
check_memory
check_failed_units
check_ports
check_ssh
check_updates
check_time
check_kernel
check_world_writable
check_uid0
check_certs
