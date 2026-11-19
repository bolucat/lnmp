#!/usr/bin/env bash

Telemetry_Field()
{
    local Value
    Value=$(printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9._+-' | cut -c1-48)
    printf '%s' "${Value:-unknown}"
}

Telemetry_Random_ID()
{
    LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'
}

Telemetry_Instance_ID()
{
    local Directory="${LNMP_Stats_State_Dir:-/var/lib/lnmp}" Candidate Temporary
    [ ! -L "$Directory" ] || return 1
    (umask 077; mkdir -p "$Directory") || return 1
    [ -d "$Directory" ] && [ ! -L "$Directory/instance-id" ] || return 1
    if [ ! -e "$Directory/instance-id" ]; then
        Candidate=$(Telemetry_Random_ID)
        [[ "$Candidate" =~ ^[a-f0-9]{32}$ ]] || return 1
        Temporary=$(mktemp "$Directory/.instance-id.XXXXXX") || return 1
        printf '%s\n' "$Candidate" > "$Temporary" || { rm -f "$Temporary"; return 1; }
        chmod 600 "$Temporary" || { rm -f "$Temporary"; return 1; }
        ln "$Temporary" "$Directory/instance-id" 2>/dev/null || true
        rm -f "$Temporary"
    fi
    [ -f "$Directory/instance-id" ] && [ ! -L "$Directory/instance-id" ] || return 1
    IFS= read -r LNMP_Stats_Instance_ID < "$Directory/instance-id" || return 1
    [[ "$LNMP_Stats_Instance_ID" =~ ^[a-f0-9]{32}$ ]]
}

Telemetry_Post()
{
    local Payload="$1" Budget="${2:-2}" HTTP_Status Request_PID Watchdog_PID Status=0
    if command -v curl >/dev/null 2>&1; then
        HTTP_Status=$(curl --disable --proto '=https' --tlsv1.2 --connect-timeout 1 --max-time "$Budget" --retry 0 \
            --silent --fail --output /dev/null --write-out '%{http_code}' --header 'Content-Type: application/json' \
            --data "$Payload" 'https://soft.lnmp.com/stats/api/v1/install' </dev/null 2>/dev/null) || return 1
        [[ "$HTTP_Status" =~ ^2[0-9][0-9]$ ]]
        return $?
    elif command -v wget >/dev/null 2>&1; then
        wget --no-config --no-netrc --https-only --secure-protocol=TLSv1_2 --max-redirect=0 --tries=1 --timeout=1 \
            --quiet --output-document=/dev/null --header='Content-Type: application/json' \
            --post-data="$Payload" 'https://soft.lnmp.com/stats/api/v1/install' </dev/null >/dev/null 2>&1 &
        Request_PID=$!
        # Wget timeouts apply per operation; also enforce the request's wall-clock budget.
        (
            local Sleep_PID=
            trap 'kill "${Sleep_PID:-}" 2>/dev/null; wait "${Sleep_PID:-}" 2>/dev/null; exit 0' TERM
            sleep "$Budget" &
            Sleep_PID=$!
            wait "$Sleep_PID"
            kill -KILL "$Request_PID" 2>/dev/null
        ) </dev/null >/dev/null 2>&1 &
        Watchdog_PID=$!
        wait "$Request_PID" 2>/dev/null || Status=$?
        kill "$Watchdog_PID" 2>/dev/null || true
        wait "$Watchdog_PID" 2>/dev/null || true
        return "$Status"
    fi
    return 1
}

Telemetry_Send()
{
    [ "${LNMP_Stats_Active:-n}" = y ] || return 0
    local Event="$1" Duration=0 Now Payload Web_Version
    if [ "$Event" = started ]; then
        [ "${LNMP_Stats_Started_Sent:-n}" != y ] || return 0
        if [ -n "${LNMP_Stats_Started_Payload:-}" ]; then
            if Telemetry_Post "$LNMP_Stats_Started_Payload" 1; then
                LNMP_Stats_Started_Sent=y
            fi
            return 0
        fi
    fi
    if [ -z "${LNMP_Stats_Payload_Fields:-}" ]; then
        Web_Version="${Nginx_Ver:-none}"
        if [ "$Stack" = lamp ]; then
            Web_Version="${Apache_Ver:-none}"
        elif [ "$Stack" = lnmpa ]; then
            Web_Version="${Nginx_Ver:-none}+${Apache_Ver:-none}"
        fi
        LNMP_Stats_Payload_Fields=$(printf '"run_id":"%s","instance_id":"%s","version":"%s","stack":"%s","os":"%s","os_version":"%s","arch":"%s","php":"%s","database":"%s","web":"%s"' \
            "$LNMP_Stats_Run_ID" "$LNMP_Stats_Instance_ID" \
            "$(Telemetry_Field "$LNMP_Ver")" "$(Telemetry_Field "$Stack")" \
            "$LNMP_Stats_OS" "$LNMP_Stats_OS_Version" "$(Telemetry_Field "$(uname -m)")" \
            "$(Telemetry_Field "${Php_Ver:-none}")" "$(Telemetry_Field "${Mysql_Ver:-${Mariadb_Ver:-none}}")" \
            "$(Telemetry_Field "$Web_Version")")
    fi
    Now=$(date +%s)
    if [[ "$Now" =~ ^[0-9]+$ && "${LNMP_Stats_Start:-}" =~ ^[0-9]+$ ]]; then
        Duration=$((Now - LNMP_Stats_Start))
    fi
    [ "$Duration" -ge 0 ] && [ "$Duration" -le 604800 ] || Duration=0
    Payload=$(printf '{%s,"event":"%s","duration_seconds":%s}' "$LNMP_Stats_Payload_Fields" "$Event" "$Duration")
    # Keep the original started payload so a bounded retry never creates another run.
    if [ "$Event" = started ]; then
        LNMP_Stats_Started_Payload="$Payload"
        if Telemetry_Post "$Payload" 1; then
            LNMP_Stats_Started_Sent=y
        fi
    else
        Telemetry_Post "$Payload" || true
    fi
    return 0
}

Telemetry_Retry_Started()
{
    [ "${LNMP_Stats_Active:-n}" = y ] || return 0
    [ "${LNMP_Stats_Started_Sent:-n}" != y ] || return 0
    [ "${LNMP_Stats_Started_Retried:-n}" != y ] || return 0
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || return 0
    LNMP_Stats_Started_Retried=y
    Telemetry_Send started
    return 0
}

Telemetry_On_Exit()
{
    local Status="$1" Event=failed
    [ "${LNMP_Stats_Active:-n}" = y ] || return 0
    [ "${LNMP_Stats_Finished:-n}" != y ] || return 0
    LNMP_Stats_Finished=y
    if [ "$Status" = 0 ] && [ "${LNMP_Stats_Success:-n}" = y ]; then
        Event=succeeded
    fi
    # Reserve the terminal request first; both started attempts together take at most two seconds.
    Telemetry_Send "$Event"
    Telemetry_Retry_Started
    return 0
}

Telemetry_Begin()
{
    local Choice="${LNMP_Install_Stats:-y}" Answer=n
    [ "${LNMP_Stats_Active:-n}" != y ] || return 0
    LNMP_Stats_Active=n
    case "$Stack" in lnmp|lnmpa|lamp) ;; *) return 0 ;; esac
    if [ "$Choice" = ask ]; then
        if [ -t 0 ] && [ -z "${LNMP_Auto:-}" ]; then
            printf '\nOptional LNMP installation statistics: version, OS, architecture, selected components, duration and a random instance ID.\nNo passwords, domains or installation logs are sent. HTTPS service: soft.lnmp.com.\nAllow statistics for this installation? [y/N]: '
            read -r Answer || Answer=n
            case "$Answer" in y|Y) Choice=y ;; *) Choice=n ;; esac
        else
            Choice=n
        fi
    fi
    [ "$Choice" = y ] || return 0
    Telemetry_Instance_ID || return 0
    LNMP_Stats_Run_ID=$(Telemetry_Random_ID)
    [[ "$LNMP_Stats_Run_ID" =~ ^[a-f0-9]{32}$ ]] || return 0
    LNMP_Stats_Start=$(date +%s)
    LNMP_Stats_OS=$(Telemetry_Field "${DISTRO:-unknown}")
    LNMP_Stats_OS_Version=unknown
    if [ -r /etc/os-release ]; then
        LNMP_Stats_OS=$(Telemetry_Field "$(. /etc/os-release; printf '%s' "${ID:-unknown}")")
        LNMP_Stats_OS_Version=$(Telemetry_Field "$(. /etc/os-release; printf '%s' "${VERSION_ID:-unknown}")")
    fi
    LNMP_Stats_Success=n
    LNMP_Stats_Payload_Fields=
    LNMP_Stats_Started_Payload=
    LNMP_Stats_Started_Sent=n
    LNMP_Stats_Started_Retried=n
    LNMP_Stats_Finished=n
    LNMP_Stats_Active=y
    trap 'Telemetry_On_Exit "$?"; TempMycnf_Clean' EXIT
    Telemetry_Send started
    return 0
}
