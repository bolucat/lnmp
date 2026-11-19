#!/usr/bin/env bash

MariaDB_Manual_Upgrade_Guide()
{
    cat <<'EOF'
Automatic MariaDB upgrade is DISABLED in this release.
The MariaDB backup/restore/rollback workflow has not passed real-server acceptance.
No databases are stopped, moved, initialized, imported or modified by this entry point.
Cross-series upgrades and automatic MySQL-to-MariaDB migration are not supported here.
Disabling checksums or setting an override cannot enable automatic upgrades.

Manual upgrade prerequisites (DBA approval and a separate tested plan are required):
1. Use only a newer patch in the SAME series (10.11 -> 10.11, 11.4 -> 11.4,
   or 11.8 -> 11.8). Do not use this installer to overwrite an existing instance.
2. Obtain the archive from its trusted HTTPS source and verify the fixed SHA256
   in src/checksums.sha256, including cached archives. A missing entry is a STOP,
   not permission to disable verification. Review the target release notes.
3. Build and stage the candidate in a SEPARATE prefix before scheduling downtime.
   Check dependencies, plugins and configuration there, without changing /etc/my.cnf
   or the live installation/data directory. Never build inside the maintenance window.
4. Verify the running server version and @@datadir. Quiesce ALL writers, scheduled
   events, replication and external jobs. With protected client credentials, create
   a private, non-overwriting logical backup using the installed mariadb-dump:
   mariadb-dump --defaults-file=/secure/client.cnf --all-databases \
     --routines --events --triggers --hex-blob --lock-all-tables > /secure/new-backup.sql
   The defaults file must be mode 0600; use umask 077 and noclobber for the dump.
   Check the exit status and nonempty output. A successful dump is NOT a restore test.
5. Restore the dump into isolated disposable instances of BOTH the old and candidate
   versions, using separate empty datadirs/sockets with networking, event_scheduler
   and replication disabled. Check every import/upgrade exit status, tables, row
   counts, routines, events, triggers, grants and application queries. Rehearse the
   rollback. Any failure or missing restore evidence means STOP before production.
6. Only after that acceptance, enter the agreed maintenance window and stop ONLY
   the relevant MariaDB service (/etc/init.d/mariadb stop), never 'lnmp stop'. Verify
   its process has exited. Preserve a verified cold copy/snapshot of the complete
   datadir, external tablespaces, binlogs, encryption keys, binaries, configuration
   and service definitions before switching anything. Keep the originals intact.
7. Keep writers blocked until startup, authentication, schema/data and application
   checks pass. On failure stop the candidate and restore the OLD binaries/config
   AND the untouched pre-upgrade physical snapshot. Never start old binaries on a
   datadir modified by the candidate. Preserve failed files and logs for diagnosis.
   Once writes resume, rollback needs a separately tested data recovery/PITR plan.

MariaDB reference:
https://mariadb.com/docs/server/server-management/install-and-upgrade-mariadb/upgrading
EOF
}

Validate_MariaDB_Upgrade()
{
    # Eligibility check only; this never activates an upgrade.
    if [[ ! "${cur_mariadb_version}" =~ ^(10\.11|11\.(4|8))\.(0|[1-9][0-9]*)$ ||
          ! "${mariadb_version}" =~ ^(10\.11|11\.(4|8))\.(0|[1-9][0-9]*)$ ]]; then
        Echo_Red "Only canonical MariaDB 10.11/11.4/11.8 patch versions are eligible for a manual upgrade plan."
        return 1
    fi
    if [ "${cur_mariadb_version%.*}" != "${mariadb_version%.*}" ]; then
        Echo_Red "Cross-series MariaDB migration requires a separate tested migration plan."
        return 1
    fi
    if [ "$("${cur_dir}/include/version_compare" "${cur_mariadb_version}" "${mariadb_version}")" != -1 ]; then
        Echo_Red "The target must be newer than the current MariaDB version."
        return 1
    fi
    if [ "${Bin}" = y ]; then
        Echo_Red "Generic binary upgrades have not passed MariaDB restore acceptance."
        return 1
    fi
    Verify_MariaDB_Archive "${cur_dir}/src/mariadb-${mariadb_version}.tar.gz"
}

Backup_MariaDB()
{
    if [ "${MariaDB_Candidate_Ready}" != y ] || [ ! -d "${MariaDB_Upgrade_Work}/private" ]; then
        MariaDB_Manual_Upgrade_Guide
        return 1
    fi
    local Dump Client Count Expected_PID=$MariaDB_Old_PID Expected_Version=$cur_mariadb_version
    MariaDB_Upgrade_Preflight
    [ "$MariaDB_Old_PID" = "$Expected_PID" ] && [ "$cur_mariadb_version" = "$Expected_Version" ] || { Echo_Red 'The running database changed during the candidate build.'; return 1; }
    Client=$(MariaDB_Upgrade_Program /usr/local/mariadb mariadb mysql)
    Dump=$(MariaDB_Upgrade_Program "${MariaDB_Candidate}" mariadb-dump mysqldump)
    [ -s "${MariaDB_Upgrade_Work}/private/my.cnf" ] || return 1
    cmp -s /etc/my.cnf "${MariaDB_Upgrade_Work}/private/my.cnf" || return 1
    cmp -s /etc/init.d/mariadb "${MariaDB_Upgrade_Work}/private/service" || return 1
    MariaDB_Write_State_Changed=y
    "$Client" --defaults-file="${MySQL_Client_Cnf}" -e 'SET GLOBAL read_only=ON; SET GLOBAL event_scheduler=OFF;'
    mkfifo -m 600 "${MariaDB_Upgrade_Work}/private/lock.in"
    "$Client" --defaults-file="${MySQL_Client_Cnf}" --batch --skip-column-names --unbuffered < "${MariaDB_Upgrade_Work}/private/lock.in" > "${MariaDB_Upgrade_Work}/private/lock.out" 2> "${MariaDB_Upgrade_Work}/private/lock.err" &
    MariaDB_Lock_PID=$!
    exec 9> "${MariaDB_Upgrade_Work}/private/lock.in"
    printf 'FLUSH TABLES WITH READ LOCK;\nSELECT "LNMP_MARIADB_LOCKED";\n' >&9
    for Count in {1..120}; do
        kill -0 "$MariaDB_Lock_PID" 2>/dev/null || return 1
        if grep -qx LNMP_MARIADB_LOCKED "${MariaDB_Upgrade_Work}/private/lock.out"; then break; fi
        sleep 1
    done
    grep -qx LNMP_MARIADB_LOCKED "${MariaDB_Upgrade_Work}/private/lock.out" || return 1
    MariaDB_Lock_Held=y
    "$Dump" --defaults-file="${MySQL_Client_Cnf}" --all-databases --add-drop-database --routines --events --triggers --hex-blob --lock-all-tables > "${MariaDB_Upgrade_Work}/private/all.sql"
    [ -s "${MariaDB_Upgrade_Work}/private/all.sql" ] || return 1
    MariaDB_Upgrade_Fingerprint /usr/local/mariadb "${MySQL_Client_Cnf}" "${MariaDB_Upgrade_Work}/private/before"
    MariaDB_Rehearse_Restore /usr/local/mariadb old
    MariaDB_Rehearse_Restore "${MariaDB_Candidate}" candidate
    kill -0 "$MariaDB_Lock_PID" 2>/dev/null || return 1
    MariaDB_Backup_Verified=y
}

MariaDB_Upgrade_Program()
{
    local Prefix=$1 Name
    shift
    for Name in "$@"; do
        if [ -x "$Prefix/bin/$Name" ]; then printf '%s\n' "$Prefix/bin/$Name"; return 0; fi
        if [ -x "$Prefix/scripts/$Name" ]; then printf '%s\n' "$Prefix/scripts/$Name"; return 0; fi
    done
    Echo_Red "Required MariaDB program is missing under $Prefix." >&2
    return 1
}

MariaDB_Upgrade_Preflight()
{
    local Client Runtime_Version Runtime_Data Resolved Pid_File Socket Parent Count Path Value Rows
    [ ! -e /sys/fs/selinux/enforce ] || { Echo_Red 'SELinux upgrade recovery requires separate acceptance.'; return 1; }
    [ -d /usr/local/mariadb ] && [ ! -L /usr/local/mariadb ] || return 1
    [ -f /etc/my.cnf ] && [ ! -L /etc/my.cnf ] || return 1
    [ -x /etc/init.d/mariadb ] && [ ! -L /etc/init.d/mariadb ] || return 1
    if grep -Eq '^[[:space:]]*!include' /etc/my.cnf; then
        Echo_Red 'Included MariaDB configuration requires a separately tested upgrade plan.'
        return 1
    fi
    [[ "${MariaDB_Data_Dir}" =~ ^/[A-Za-z0-9_./-]+$ && ! "${MariaDB_Data_Dir}/" =~ /\.\.?/ ]] || return 1
    Resolved=$(readlink -f "${MariaDB_Data_Dir}")
    case "$Resolved" in
        ''|/|/usr|/usr/local|/usr/local/mariadb|/var|/var/lib|/home|/root|/tmp|/opt|/srv|/mnt|/media|/etc|/etc/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/boot|/boot/*|/run|/run/*) return 1 ;;
    esac
    [ -d "$Resolved" ] || return 1
    Parent=${MariaDB_Data_Dir%/}
    while [ "$Parent" != / ]; do
        [ ! -L "$Parent" ] || { Echo_Red 'Symlink datadir paths are not supported for automatic upgrade.'; return 1; }
        Parent=${Parent%/*}; [ -n "$Parent" ] || Parent=/
    done
    Path=$(find "$Resolved" -type l -print -quit)
    [ -z "$Path" ] || { Echo_Red 'Symlinks or external tablespaces require a manual upgrade plan.'; return 1; }
    MariaDB_Data_Dir=$Resolved
    MariaDB_Data_Internal=n
    case "$Resolved" in
        /usr/local/mariadb/var) MariaDB_Data_Internal=y ;;
        /usr/local/mariadb/*) Echo_Red 'Only var/ is supported for a datadir inside the MariaDB prefix.'; return 1 ;;
    esac
    Client=$(MariaDB_Upgrade_Program /usr/local/mariadb mariadb mysql)
    Rows=$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse 'SELECT VERSION(), @@datadir, @@pid_file, @@socket, @@read_only, @@event_scheduler') || return 1
    IFS=$'\t' read -r Runtime_Version Runtime_Data Pid_File Socket MariaDB_Old_Read_Only MariaDB_Old_Event_Scheduler <<< "$Rows"
    [[ "$Runtime_Version" = *MariaDB* ]] || return 1
    cur_mariadb_version=${Runtime_Version%%-MariaDB*}
    [ "$(readlink -f "$Runtime_Data")" = "$Resolved" ] || { Echo_Red 'Configured and running MariaDB datadirs differ.'; return 1; }
    [[ "$MariaDB_Old_Read_Only" =~ ^[01]$ && "$MariaDB_Old_Event_Scheduler" =~ ^(ON|OFF)$ ]] || { Echo_Red 'Unsupported initial database write/event state.'; return 1; }
    [[ "$Pid_File" = "$Resolved/"* && "$Socket" = /* ]] || return 1
    [ -f "$Pid_File" ] && [ ! -L "$Pid_File" ] || return 1
    read -r MariaDB_Old_PID < "$Pid_File"
    [[ "$MariaDB_Old_PID" =~ ^[1-9][0-9]*$ ]] && kill -0 "$MariaDB_Old_PID" 2>/dev/null || return 1
    if ! Path=$(readlink -f "/proc/${MariaDB_Old_PID}/exe" 2>/dev/null); then
        Path=$(tr '\000' '\n' < "/proc/${MariaDB_Old_PID}/cmdline" | head -n 1)
    fi
    case "$Path" in /usr/local/mariadb/bin/*) ;; *) Echo_Red 'Running MariaDB is outside the managed prefix.'; return 1 ;; esac
    MariaDB_PID_File=$Pid_File
    Rows=$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse 'SHOW ALL SLAVES STATUS')
    [ -z "$Rows" ] || { Echo_Red 'Replication upgrades are not accepted by this path.'; return 1; }
    Rows=$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse 'SHOW SLAVE HOSTS')
    [ -z "$Rows" ] || return 1
    Count=$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE COMMAND LIKE 'Binlog Dump%'")
    [ "$Count" = 0 ] || return 1
    Value=$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse "SHOW GLOBAL VARIABLES LIKE 'wsrep_on'" | awk '{print $2}')
    [ "$Value" = OFF ] || { Echo_Red 'Galera/wsrep upgrades require separate acceptance.'; return 1; }
    Count=$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse "SELECT COUNT(*) FROM information_schema.PLUGINS WHERE PLUGIN_STATUS='ACTIVE' AND PLUGIN_TYPE='ENCRYPTION'")
    [ "$Count" = 0 ] || { Echo_Red 'Encrypted databases require a separately tested backup/key recovery plan.'; return 1; }
    Count=$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema') AND TABLE_TYPE='BASE TABLE' AND ENGINE NOT IN ('InnoDB','Aria','MyISAM')")
    [ "$Count" = 0 ] || { Echo_Red 'Only InnoDB/Aria/MyISAM user tables are accepted.'; return 1; }
    Count=$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('mysql','sys','information_schema','performance_schema') AND TABLE_TYPE NOT IN ('BASE TABLE','VIEW')")
    [ "$Count" = 0 ] || { Echo_Red 'System-versioned tables and sequences require a separate restore plan.'; return 1; }
    Count=$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='sys' AND TABLE_NAME='sys_config'")
    [ "$Count" = 1 ] || { Echo_Red 'A nonstandard/removed sys schema requires a separate restore plan.'; return 1; }
    Count=$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse "SELECT COUNT(*) FROM information_schema.INNODB_SYS_TABLESPACES WHERE FILENAME NOT LIKE './%' AND FILENAME NOT LIKE '${Resolved}/%'")
    [ "$Count" = 0 ] || return 1
    Rows=$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('innodb_data_home_dir','innodb_log_group_home_dir','innodb_undo_directory','aria_log_dir_path','log_bin_basename','log_bin_index')")
    while IFS=$'\t' read -r Path Value; do
        case "$Value" in ''|.|./|"$Resolved"|"$Resolved/"|"$Resolved/"*) ;; *) Echo_Red "External database files ($Path) require a manual upgrade plan."; return 1 ;; esac
    done <<< "$Rows"
}

Build_MariaDB_Candidate()
{
    local Jobs Listing Library Libraries
    Verify_MariaDB_Archive "${cur_dir}/src/mariadb-${mariadb_version}.tar.gz"
    Listing=$(tar tf "${cur_dir}/src/mariadb-${mariadb_version}.tar.gz")
    awk '/^\// || /(^|\/)\.\.(\/|$)/ {bad=1} END {exit bad}' <<< "$Listing"
    mkdir "${MariaDB_Upgrade_Work}/source" "${MariaDB_Upgrade_Work}/build" "${MariaDB_Upgrade_Work}/stage"
    tar xf "${cur_dir}/src/mariadb-${mariadb_version}.tar.gz" --strip-components=1 -C "${MariaDB_Upgrade_Work}/source"
    Jobs=$(LNMP_Get_Build_Jobs)
    cmake -S "${MariaDB_Upgrade_Work}/source" -B "${MariaDB_Upgrade_Work}/build" -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DMYSQL_UNIX_ADDR=/tmp/mysql.sock -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITH_PCRE=system > "${MariaDB_Upgrade_Work}/configure.log" 2>&1
    make -C "${MariaDB_Upgrade_Work}/build" -j "$Jobs" > "${MariaDB_Upgrade_Work}/build.log" 2>&1
    make -C "${MariaDB_Upgrade_Work}/build" DESTDIR="${MariaDB_Upgrade_Work}/stage" install > "${MariaDB_Upgrade_Work}/install.log" 2>&1
    MariaDB_Candidate=${MariaDB_Upgrade_Work}/stage/usr/local/mariadb
    [ "$(stat -c %d "$MariaDB_Candidate")" = "$(stat -c %d /usr/local)" ] || return 1
    "$(MariaDB_Upgrade_Program "$MariaDB_Candidate" mariadbd mysqld)" --no-defaults --version | grep -F "${mariadb_version}-MariaDB"
    Libraries=$("$(MariaDB_Upgrade_Program /usr/local/mariadb mariadb mysql)" --defaults-file="${MySQL_Client_Cnf}" -Nse "SELECT DISTINCT PLUGIN_LIBRARY FROM information_schema.PLUGINS WHERE PLUGIN_STATUS='ACTIVE' AND PLUGIN_LIBRARY IS NOT NULL")
    while IFS= read -r Library; do
        [ -n "$Library" ] || continue
        [ -f "$MariaDB_Candidate/lib/plugin/$Library" ] || { Echo_Red "Candidate plugin is missing: $Library"; return 1; }
    done <<< "$Libraries"
    mkdir "${MariaDB_Upgrade_Work}/config-test"
    "$(MariaDB_Upgrade_Program "$MariaDB_Candidate" mariadbd mysqld)" --defaults-file="${MariaDB_Upgrade_Work}/private/my.cnf" --basedir="$MariaDB_Candidate" --datadir="${MariaDB_Upgrade_Work}/config-test" --log-error="${MariaDB_Upgrade_Work}/config-test.log" --verbose --help > "${MariaDB_Upgrade_Work}/candidate-config.log" 2>&1
    MariaDB_Candidate_Ready=y
}

MariaDB_Upgrade_Fingerprint()
{
    local Client Prefix=$1 Defaults=$2 Output=$3
    Client=$(MariaDB_Upgrade_Program "$Prefix" mariadb mysql)
    "$Client" --defaults-file="$Defaults" --batch --raw --skip-column-names > "$Output.meta" <<'SQL'
SELECT 'TABLE',TABLE_SCHEMA,TABLE_NAME,TABLE_TYPE,IFNULL(ENGINE,''),IFNULL(TABLE_COLLATION,'') FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema') ORDER BY TABLE_SCHEMA,TABLE_NAME;
SELECT 'COLUMN',TABLE_SCHEMA,TABLE_NAME,COLUMN_NAME,ORDINAL_POSITION,COLUMN_TYPE,IS_NULLABLE,IFNULL(COLUMN_DEFAULT,''),EXTRA FROM information_schema.COLUMNS c WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema') AND NOT (TABLE_SCHEMA='sys' AND EXISTS (SELECT 1 FROM information_schema.TABLES t WHERE t.TABLE_SCHEMA=c.TABLE_SCHEMA AND t.TABLE_NAME=c.TABLE_NAME AND t.TABLE_TYPE='VIEW')) ORDER BY TABLE_SCHEMA,TABLE_NAME,ORDINAL_POSITION;
SELECT 'ROUTINE',ROUTINE_SCHEMA,ROUTINE_NAME,ROUTINE_TYPE,SHA2(IFNULL(ROUTINE_DEFINITION,''),256),SQL_MODE,SECURITY_TYPE,DEFINER,IS_DETERMINISTIC,SQL_DATA_ACCESS,IFNULL(DTD_IDENTIFIER,'') FROM information_schema.ROUTINES ORDER BY ROUTINE_SCHEMA,ROUTINE_NAME;
SELECT 'PARAMETER',SPECIFIC_SCHEMA,SPECIFIC_NAME,ORDINAL_POSITION,IFNULL(PARAMETER_MODE,''),IFNULL(PARAMETER_NAME,''),DTD_IDENTIFIER,IFNULL(CHARACTER_SET_NAME,''),IFNULL(COLLATION_NAME,'') FROM information_schema.PARAMETERS ORDER BY SPECIFIC_SCHEMA,SPECIFIC_NAME,ORDINAL_POSITION;
SELECT 'EVENT',EVENT_SCHEMA,EVENT_NAME,SHA2(EVENT_DEFINITION,256),STATUS,IFNULL(INTERVAL_VALUE,''),IFNULL(INTERVAL_FIELD,''),DEFINER,TIME_ZONE,EVENT_TYPE,IFNULL(EXECUTE_AT,''),IFNULL(STARTS,''),IFNULL(ENDS,''),ON_COMPLETION,SQL_MODE FROM information_schema.EVENTS ORDER BY EVENT_SCHEMA,EVENT_NAME;
SELECT 'TRIGGER',TRIGGER_SCHEMA,TRIGGER_NAME,EVENT_MANIPULATION,EVENT_OBJECT_TABLE,SHA2(ACTION_STATEMENT,256),ACTION_TIMING,DEFINER,SQL_MODE FROM information_schema.TRIGGERS ORDER BY TRIGGER_SCHEMA,TRIGGER_NAME;
SELECT 'VIEW',TABLE_SCHEMA,TABLE_NAME,SHA2(VIEW_DEFINITION,256),CHECK_OPTION,IS_UPDATABLE,DEFINER,SECURITY_TYPE FROM information_schema.VIEWS WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema') ORDER BY TABLE_SCHEMA,TABLE_NAME;
SELECT 'SYS_CONFIG',variable,IFNULL(value,''),IFNULL(set_by,'') FROM sys.sys_config ORDER BY variable;
SQL
    # sys view column types derive from performance_schema and can widen in a patch;
    # their definitions are still checked above. proc/event/sys_config timestamps
    # are recreated on restore; their definitions and semantic values are checked.
    "$Client" --defaults-file="$Defaults" -Nse "SELECT CONCAT('CHECKSUM TABLE \`',REPLACE(TABLE_SCHEMA,'\`','\`\`'),'\`.\`',REPLACE(TABLE_NAME,'\`','\`\`'),'\` EXTENDED;') FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('information_schema','performance_schema') AND TABLE_TYPE='BASE TABLE' AND NOT (TABLE_SCHEMA='mysql' AND TABLE_NAME IN ('general_log','slow_log','innodb_table_stats','innodb_index_stats','table_stats','index_stats','column_stats','transaction_registry','proc','event')) AND NOT (TABLE_SCHEMA='sys' AND TABLE_NAME='sys_config') ORDER BY TABLE_SCHEMA,TABLE_NAME" > "$Output.check.sql"
    "$Client" --defaults-file="$Defaults" --batch --raw --skip-column-names < "$Output.check.sql" > "$Output.checksums"
    if grep -q $'\tNULL$' "$Output.checksums"; then Echo_Red 'A user table cannot be checksummed; refusing an unverifiable restore.'; return 1; fi
    # SHOW GRANTS quoting changes between patch versions. Compare every field in
    # the authoritative privilege tables instead of normalizing executable SQL.
    "$Client" --defaults-file="$Defaults" -Nse "SET SESSION group_concat_max_len=16384; SELECT CONCAT('SELECT ',QUOTE(TABLE_NAME),',SHA2(JSON_ARRAY(',GROUP_CONCAT(CONCAT('\`',COLUMN_NAME,'\`') ORDER BY ORDINAL_POSITION SEPARATOR ','),'),256) FROM \`mysql\`.\`',TABLE_NAME,'\`;') FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='mysql' AND TABLE_NAME IN ('global_priv','db','tables_priv','columns_priv','procs_priv','proxies_priv','roles_mapping') GROUP BY TABLE_NAME ORDER BY TABLE_NAME" > "$Output.users.sql"
    "$Client" --defaults-file="$Defaults" --batch --raw --skip-column-names < "$Output.users.sql" | LC_ALL=C sort > "$Output.users"
}

MariaDB_Rehearse_Restore()
{
    local Prefix=$1 Label=$2 Init Daemon Client Admin Upgrade Count Suffix
    MariaDB_Drill_Dir=$(mktemp -d /tmp/lnmp-mariadb-drill.XXXXXX)
    Init=$(MariaDB_Upgrade_Program "$Prefix" mariadb-install-db mysql_install_db)
    Daemon=$(MariaDB_Upgrade_Program "$Prefix" mariadbd mysqld)
    Client=$(MariaDB_Upgrade_Program "$Prefix" mariadb mysql)
    Admin=$(MariaDB_Upgrade_Program "$Prefix" mariadb-admin mysqladmin)
    Upgrade=$(MariaDB_Upgrade_Program "$Prefix" mariadb-upgrade mysql_upgrade)
    "$Init" --no-defaults --basedir="$Prefix" --datadir="${MariaDB_Drill_Dir}/data" --user=root --auth-root-authentication-method=normal --skip-test-db > "${MariaDB_Upgrade_Work}/restore-${Label}-initialize.log" 2>&1
    "$Daemon" --no-defaults --basedir="$Prefix" --datadir="${MariaDB_Drill_Dir}/data" --user=root --socket="${MariaDB_Drill_Dir}/server.sock" --pid-file="${MariaDB_Drill_Dir}/server.pid" --log-error="${MariaDB_Drill_Dir}/server.log" --skip-networking --event-scheduler=OFF --skip-slave-start --skip-log-bin > "${MariaDB_Upgrade_Work}/restore-${Label}-server.log" 2>&1 &
    MariaDB_Drill_PID=$!
    for Count in {1..120}; do
        kill -0 "$MariaDB_Drill_PID" 2>/dev/null || return 1
        if "$Client" --no-defaults --protocol=socket --socket="${MariaDB_Drill_Dir}/server.sock" -uroot -Nse 'SELECT 1' >/dev/null 2>&1; then break; fi
        sleep 1
    done
    { cat "${MariaDB_Upgrade_Work}/private/all.sql"; printf '\nFLUSH PRIVILEGES;\n'; } | "$Client" --no-defaults --protocol=socket --socket="${MariaDB_Drill_Dir}/server.sock" -uroot > "${MariaDB_Upgrade_Work}/restore-${Label}-import.log" 2>&1
    cp "${MySQL_Client_Cnf}" "${MariaDB_Drill_Dir}/client.cnf"
    printf '\n[client]\nprotocol=socket\nsocket=%s/server.sock\n' "$MariaDB_Drill_Dir" >> "${MariaDB_Drill_Dir}/client.cnf"
    "$Upgrade" --defaults-file="${MariaDB_Drill_Dir}/client.cnf" --force > "${MariaDB_Upgrade_Work}/restore-${Label}-upgrade.log" 2>&1
    MariaDB_Upgrade_Fingerprint "$Prefix" "${MariaDB_Drill_Dir}/client.cnf" "${MariaDB_Upgrade_Work}/private/$Label"
    for Suffix in meta checksums users; do
        cmp -s "${MariaDB_Upgrade_Work}/private/before.$Suffix" "${MariaDB_Upgrade_Work}/private/$Label.$Suffix" || { Echo_Red "MariaDB $Label restore verification failed ($Suffix)."; return 1; }
    done
    "$Admin" --defaults-file="${MariaDB_Drill_Dir}/client.cnf" shutdown
    wait "$MariaDB_Drill_PID"
    MariaDB_Drill_PID=''
    rm -f -- "${MariaDB_Drill_Dir}/client.cnf"
    Echo_Green "MariaDB ${Label} restore rehearsal passed."
}

MariaDB_Upgrade_Ensure_Stopped()
{
    local PID Client Process Executable
    if [ -f "${MariaDB_PID_File}" ]; then
        read -r PID < "${MariaDB_PID_File}"
        [[ "$PID" =~ ^[1-9][0-9]*$ ]] || return 1
        if kill -0 "$PID" 2>/dev/null; then Echo_Red 'MariaDB is still running; no directories will be moved.'; return 1; fi
    fi
    if kill -0 "${MariaDB_Old_PID}" 2>/dev/null; then return 1; fi
    for Process in /proc/[0-9]*/exe; do
        if ! Executable=$(readlink -f "$Process" 2>/dev/null); then
            Executable=$(tr '\000' '\n' < "${Process%/exe}/cmdline" 2>/dev/null | head -n 1) || continue
        fi
        case "$Executable" in
            /usr/local/mariadb/bin/mariadbd|/usr/local/mariadb/bin/mysqld|"${MariaDB_Old_Prefix}/bin/mariadbd"|"${MariaDB_Old_Prefix}/bin/mysqld")
                Echo_Red 'A managed database process is still alive; refusing to move its files.'
                return 1 ;;
        esac
    done
    Client=$(MariaDB_Upgrade_Program /usr/local/mariadb mariadb mysql)
    if "$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse 'SELECT 1' >/dev/null 2>&1; then return 1; fi
}

MariaDB_Upgrade_Restore_Config()
{
    local Temp
    Temp=$(mktemp /etc/.lnmp-mariadb-config.XXXXXX)
    cp -p "${MariaDB_Upgrade_Work}/private/my.cnf" "$Temp"
    mv -f -- "$Temp" /etc/my.cnf
}

Activate_MariaDB_Candidate()
{
    [ "${MariaDB_Backup_Verified}" = y ] && kill -0 "$MariaDB_Lock_PID" 2>/dev/null || return 1
    local Temp Count Client Actual Suffix Space Needed
    cmp -s /etc/my.cnf "${MariaDB_Upgrade_Work}/private/my.cnf" || return 1
    MariaDB_Stop_Attempted=y
    /etc/init.d/mariadb stop
    MariaDB_Upgrade_Ensure_Stopped
    exec 9>&-
    wait "$MariaDB_Lock_PID" 2>/dev/null || true
    MariaDB_Lock_PID=''
    if [ "$MariaDB_Data_Internal" = y ]; then
        MariaDB_New_Data=${MariaDB_Candidate}/var
    fi
    [ ! -e "$MariaDB_New_Data" ] && [ ! -L "$MariaDB_New_Data" ] || return 1
    Space=$(df -Pk "$(dirname "$MariaDB_New_Data")" | awk 'END {print $4}')
    Needed=$(du -sk "$MariaDB_Data_Dir" | awk '{print $1}')
    [[ "$Space" =~ ^[0-9]+$ && "$Needed" =~ ^[0-9]+$ ]] && [ "$Space" -gt "$((Needed + 262144))" ] || return 1
    mkdir "$MariaDB_New_Data"
    cp -a -- "$MariaDB_Data_Dir/." "$MariaDB_New_Data/"
    diff -qr -- "$MariaDB_Data_Dir" "$MariaDB_New_Data" > "${MariaDB_Upgrade_Work}/cold-copy-verification.log"
    sync
    Temp=$(mktemp /etc/.lnmp-mariadb-config.XXXXXX)
    cp -p "${MariaDB_Upgrade_Work}/private/my.cnf" "$Temp"
    printf '\n[mysqld]\nread_only=ON\nevent_scheduler=OFF\nskip_slave_start=ON\n' >> "$Temp"
    MariaDB_Config_Guarded=y
    mv -f -- "$Temp" /etc/my.cnf
    mv -- /usr/local/mariadb "$MariaDB_Old_Prefix"
    mv -- "$MariaDB_Candidate" /usr/local/mariadb
    if [ "$MariaDB_Data_Internal" != y ]; then
        mv -- "$MariaDB_Data_Dir" "$MariaDB_Old_Data"
        mv -- "$MariaDB_New_Data" "$MariaDB_Data_Dir"
    fi
    /etc/init.d/mariadb start
    Client=$(MariaDB_Upgrade_Program /usr/local/mariadb mariadb mysql)
    for Count in {1..120}; do
        if "$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse 'SELECT 1' >/dev/null 2>&1; then break; fi
        sleep 1
    done
    Actual=$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse 'SELECT VERSION()')
    [ "${Actual%%-MariaDB*}" = "$mariadb_version" ] || return 1
    [ "$("$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse 'SELECT @@read_only')" = 1 ] || return 1
    "$(MariaDB_Upgrade_Program /usr/local/mariadb mariadb-upgrade mysql_upgrade)" --defaults-file="${MySQL_Client_Cnf}" --force > "${MariaDB_Upgrade_Work}/live-upgrade.log" 2>&1
    MariaDB_Upgrade_Fingerprint /usr/local/mariadb "${MySQL_Client_Cnf}" "${MariaDB_Upgrade_Work}/private/after"
    for Suffix in meta checksums users; do
        cmp -s "${MariaDB_Upgrade_Work}/private/before.$Suffix" "${MariaDB_Upgrade_Work}/private/after.$Suffix" || return 1
    done
    MariaDB_Upgrade_Restore_Config
    MariaDB_Config_Guarded=n
    # After the commit point writers may resume; never silently discard their writes.
    MariaDB_Upgrade_Committed=y
    "$Client" --defaults-file="${MySQL_Client_Cnf}" -e "SET GLOBAL read_only=${MariaDB_Old_Read_Only}; SET GLOBAL event_scheduler=${MariaDB_Old_Event_Scheduler};"
    Echo_Green "MariaDB patch upgrade verified: ${cur_mariadb_version} -> ${mariadb_version}."
    echo "Protected logical backup and restore evidence: ${MariaDB_Upgrade_Work}"
    echo "Retained original cold installation: ${MariaDB_Old_Prefix}"
    [ "$MariaDB_Data_Internal" = y ] || echo "Retained original cold data: ${MariaDB_Old_Data}"
}

Rollback_MariaDB()
{
    local Client Count
    if [ -n "${MariaDB_Drill_PID}" ]; then
        kill -TERM "$MariaDB_Drill_PID" 2>/dev/null
        wait "$MariaDB_Drill_PID" 2>/dev/null
    fi
    [ -z "${MariaDB_Drill_Dir}" ] || rm -f -- "${MariaDB_Drill_Dir}/client.cnf"
    if [ "${MariaDB_Upgrade_Committed}" = y ]; then
        Echo_Red 'MariaDB was validated and committed; refusing automatic data rollback after writers may have resumed. Check service/write settings manually.'
    elif [ "${MariaDB_Stop_Attempted}" = y ]; then
        /etc/init.d/mariadb stop
        if ! MariaDB_Upgrade_Ensure_Stopped; then
            Echo_Red "MariaDB could not be proven stopped. Cold backups are preserved; manual recovery is required: ${MariaDB_Upgrade_Work}"
            return 1
        fi
        if [ -d "${MariaDB_Old_Prefix}" ]; then
            [ ! -e /usr/local/mariadb ] || mv -- /usr/local/mariadb "${MariaDB_Failed_Prefix}" || return 1
            mv -- "$MariaDB_Old_Prefix" /usr/local/mariadb || return 1
        fi
        if [ -d "${MariaDB_Old_Data}" ]; then
            [ ! -e "$MariaDB_Data_Dir" ] || mv -- "$MariaDB_Data_Dir" "$MariaDB_Failed_Data" || return 1
            mv -- "$MariaDB_Old_Data" "$MariaDB_Data_Dir" || return 1
        fi
        if [ "${MariaDB_Config_Guarded}" = y ]; then MariaDB_Upgrade_Restore_Config || return 1; fi
        /etc/init.d/mariadb start || return 1
        Client=$(MariaDB_Upgrade_Program /usr/local/mariadb mariadb mysql) || return 1
        for Count in {1..120}; do
            if "$Client" --defaults-file="${MySQL_Client_Cnf}" -Nse 'SELECT 1' >/dev/null 2>&1; then break; fi
            sleep 1
        done
        "$Client" --defaults-file="${MySQL_Client_Cnf}" -e "SET GLOBAL read_only=${MariaDB_Old_Read_Only}; SET GLOBAL event_scheduler=${MariaDB_Old_Event_Scheduler};" || return 1
        Echo_Red "Upgrade failed; original MariaDB installation and data restored. Evidence: ${MariaDB_Upgrade_Work}"
    elif [ "${MariaDB_Write_State_Changed}" = y ]; then
        Client=$(MariaDB_Upgrade_Program /usr/local/mariadb mariadb mysql)
        "$Client" --defaults-file="${MySQL_Client_Cnf}" -e "SET GLOBAL read_only=${MariaDB_Old_Read_Only}; SET GLOBAL event_scheduler=${MariaDB_Old_Event_Scheduler};"
    fi
    if [ -n "${MariaDB_Lock_PID}" ]; then
        exec 9>&-
        kill -TERM "$MariaDB_Lock_PID" 2>/dev/null
        wait "$MariaDB_Lock_PID" 2>/dev/null
    fi
    [ "${MariaDB_Upgrade_Lock_Owned}" != y ] || rmdir /var/lock/lnmp-mariadb-upgrade
}

Upgrade_MariaDB_Transaction()
{
    local Enable_Download_Checksum=y Download_Insecure=n URL Tag Confirm
    MariaDB_Candidate_Ready=n
    MariaDB_Backup_Verified=n
    MariaDB_Stop_Attempted=n
    MariaDB_Config_Guarded=n
    MariaDB_Write_State_Changed=n
    MariaDB_Upgrade_Committed=n
    MariaDB_Upgrade_Lock_Owned=n
    MariaDB_Lock_PID=''
    MariaDB_Drill_PID=''
    MariaDB_Drill_Dir=''
    umask 077
    Check_DB
    [ "${Is_MySQL}" = n ] || { Echo_Red 'MySQL-to-MariaDB migration is not supported.'; return 1; }
    Verify_DB_Password
    MariaDB_Upgrade_Preflight
    echo "Current MariaDB server: ${cur_mariadb_version}"
    read -r -p 'Target same-series patch version: ' mariadb_version
    [[ "$mariadb_version" =~ ^10\.11\.(0|[1-9][0-9]*)$ && "$cur_mariadb_version" =~ ^10\.11\.(0|[1-9][0-9]*)$ ]] || { Echo_Red 'Only the MariaDB 10.11 standalone patch path is under acceptance; other series/cross-series require a manual plan.'; return 1; }
    [ "$("${cur_dir}/include/version_compare" "$cur_mariadb_version" "$mariadb_version")" = -1 ] || return 1
    if [ ! -s "${cur_dir}/src/mariadb-${mariadb_version}.tar.gz" ]; then
        URL=$(awk -F '\t' -v name="mariadb-${mariadb_version}.tar.gz" '$1 == name {print $2; exit}' "${cur_dir}/src/fallback-sources.tsv")
        [[ "$URL" = https://* ]] || return 1
        Download_Files "$URL" "${cur_dir}/src/mariadb-${mariadb_version}.tar.gz"
    fi
    Bin=n
    Validate_MariaDB_Upgrade
    mkdir /var/lock/lnmp-mariadb-upgrade || { Echo_Red 'A MariaDB upgrade lock exists; investigate it before retrying.'; return 1; }
    MariaDB_Upgrade_Lock_Owned=y
    MariaDB_Upgrade_Work=$(mktemp -d /usr/local/.lnmp-mariadb.XXXXXX)
    echo "MariaDB candidate build and protected recovery artifacts: ${MariaDB_Upgrade_Work}"
    mkdir "${MariaDB_Upgrade_Work}/private"
    cp -p /etc/my.cnf "${MariaDB_Upgrade_Work}/private/my.cnf"
    cp -p /etc/init.d/mariadb "${MariaDB_Upgrade_Work}/private/service"
    Tag=${MariaDB_Upgrade_Work##*.}
    MariaDB_Old_Prefix=/usr/local/mariadb.before.${Tag}
    MariaDB_Failed_Prefix=/usr/local/mariadb.failed.${Tag}
    MariaDB_Old_Data=${MariaDB_Data_Dir}.before.${Tag}
    MariaDB_New_Data=${MariaDB_Data_Dir}.candidate.${Tag}
    MariaDB_Failed_Data=${MariaDB_Data_Dir}.failed.${Tag}
    for URL in "$MariaDB_Old_Prefix" "$MariaDB_Failed_Prefix" "$MariaDB_Old_Data" "$MariaDB_New_Data" "$MariaDB_Failed_Data"; do
        [ ! -e "$URL" ] && [ ! -L "$URL" ] || return 1
    done
    Build_MariaDB_Candidate
    echo 'Candidate ready. Maintenance now freezes ALL writes while backups are restored and checked.'
    echo 'Standalone only: stop application/admin/cron writers first. read_only does not block privileged writers.'
    read -r -p 'After quiescing all writers, type UPGRADE to enter maintenance: ' Confirm
    [ "$Confirm" = UPGRADE ] || return 1
    Backup_MariaDB
    Activate_MariaDB_Candidate
    rmdir /var/lock/lnmp-mariadb-upgrade
    MariaDB_Upgrade_Lock_Owned=n
}

Upgrade_MariaDB()
{
    # Keep the public entry closed until the new transaction passes real acceptance.
    MariaDB_Manual_Upgrade_Guide
    return 1
}

Run_MariaDB_Patch_Upgrade()
(
    set -Ee -o pipefail
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'MariaDB_Exit_Status=$?; trap - EXIT INT TERM; set +e; if [ "$MariaDB_Exit_Status" -ne 0 ]; then Rollback_MariaDB; fi; TempMycnf_Clean; exit "$MariaDB_Exit_Status"' EXIT
    Upgrade_MariaDB_Transaction
)
