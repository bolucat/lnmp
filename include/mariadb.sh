#!/usr/bin/env bash

MariaDB_WITHSSL()
{
    if openssl version | grep -Eqi "OpenSSL 1.1.*"; then
        if [[ "${DBSelect}" =~ ^7$ ]] || echo "${mariadb_version}" | grep -Eqi '^10.[01].'; then
            Install_Openssl
            MariaDBWITHSSL='-DWITH_SSL=/usr/local/openssl'
        else
            MariaDBWITHSSL=''
        fi
    fi
}

Secure_MariaDB_Install()
(
    set +x
    local Escaped_Password User_Statement User_Statements Remaining Client
    local MySQL_Client_Cnf='' Bootstrap_Cnf='' Service_Attempted=n
    Secure_MariaDB_Cleanup()
    {
        local Status=$?
        trap - EXIT INT TERM
        if [ "$Service_Attempted" = y ]; then
            /etc/init.d/mariadb stop || {
                Echo_Red 'MariaDB security initialization failed and service stop failed; stop this instance immediately before allowing access.'
                Status=1
            }
        fi
        TempMycnf_Clean || Status=1
        [ -z "$Bootstrap_Cnf" ] || rm -f -- "$Bootstrap_Cnf" || Status=1
        exit "$Status"
    }
    trap Secure_MariaDB_Cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [[ "${Mariadb_Ver}" =~ ^mariadb-(10\.11|11\.(4|8))\.(0|[1-9][0-9]*)$ ]] || {
        Echo_Red 'Legacy MariaDB security initialization is unsupported; use a separately tested manual installation.'
        return 1
    }
    if [ -z "${DB_Root_Password}" ] || [[ "${DB_Root_Password}" = *$'\n'* || "${DB_Root_Password}" = *$'\r'* ]]; then
        Echo_Red 'A nonempty, single-line MariaDB root password is required.'
        return 1
    fi
    Escaped_Password=${DB_Root_Password//\\/\\\\}
    Escaped_Password=${Escaped_Password//\'/\\\'}
    (set -o noclobber; printf '%s\n' /usr/local/mariadb/lib /usr/local/lib > /etc/ld.so.conf.d/mariadb.conf) || return 1
    ldconfig || return 1
    MySQL_Bin=/usr/local/mariadb/bin/mysql
    Make_TempMycnf '' || return 1
    printf 'protocol=socket\nsocket=/tmp/mysql.sock\n' >> "$MySQL_Client_Cnf" || return 1
    Bootstrap_Cnf=$MySQL_Client_Cnf
    Service_Attempted=y
    /etc/init.d/mariadb start || return 1
    # Explicit authentication removes the default unix_socket alternative; use
    # known session modes for escaping and native password hashing.
    Do_Query "SET SESSION sql_mode=''; SET SESSION old_passwords=0; ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${Escaped_Password}');" >/dev/null 2>&1 || {
        Echo_Red 'MariaDB root password initialization failed; service will be stopped.'
        return 1
    }
    MySQL_Client_Cnf=''
    Make_TempMycnf "${DB_Root_Password}" || return 1
    printf 'protocol=socket\nsocket=/tmp/mysql.sock\n' >> "$MySQL_Client_Cnf" || return 1
    Do_Query 'SELECT 1;' || return 1
    if "$MySQL_Bin" --defaults-file="$Bootstrap_Cnf" -e 'SELECT 1;' >/dev/null 2>&1; then
        Echo_Red 'MariaDB root still accepts passwordless authentication; refusing insecure success.'
        return 1
    fi
    # Keep only the verified root@localhost; remove anonymous and other root aliases.
    User_Statements=$("$MySQL_Bin" --defaults-file="$MySQL_Client_Cnf" --batch --raw --skip-column-names -e "SELECT CONCAT('DROP USER IF EXISTS ', QUOTE(User), '@', QUOTE(Host), ';') FROM mysql.user WHERE User='' OR (User='root' AND Host <> 'localhost');") || return 1
    while IFS= read -r User_Statement; do
        [ -z "$User_Statement" ] || Do_Query "SET SESSION sql_mode=''; ${User_Statement}" || return 1
    done <<< "$User_Statements"
    Do_Query 'DROP DATABASE IF EXISTS test;' || return 1
    Remaining=$("$MySQL_Bin" --defaults-file="$MySQL_Client_Cnf" --batch --skip-column-names -e "SELECT COUNT(*) FROM mysql.user WHERE User='' OR (User='root' AND Host <> 'localhost');") || return 1
    [ "$Remaining" = 0 ] || { Echo_Red 'MariaDB account cleanup verification failed.'; return 1; }
    /etc/init.d/mariadb stop || return 1
    Service_Attempted=n
    for Client in mysql mysqldump myisamchk mysqld_safe mysqlcheck; do
        [ ! -x "/usr/local/mariadb/bin/$Client" ] || ln -sf "/usr/local/mariadb/bin/$Client" "/usr/bin/$Client" || return 1
    done
    StartUp mariadb || return 1
    TempMycnf_Clean || return 1
    rm -f -- "$Bootstrap_Cnf" || return 1
    Bootstrap_Cnf=''
    Echo_Green 'MariaDB root authentication verified; anonymous users, other root aliases and test database removed.'
    echo 'MariaDB binds to 127.0.0.1 by default. Remote database access requires manual bind-address and firewall configuration plus restricted database grants.'
)

Mariadb_Sec_Setting()
{
    Secure_MariaDB_Install || return 1
}

Check_MariaDB_Data_Dir()
{
    local Data_Dir=${MariaDB_Data_Dir%/} Parent Contents
    if [[ ! "$Data_Dir" =~ ^/[a-zA-Z0-9_./-]+$ || "$Data_Dir/" =~ /\.\.?/ || "$Data_Dir" = *//* ]]; then
        Echo_Red "Refusing an unsafe MariaDB data directory. Use an absolute, non-symlink path."
        return 1
    fi
    case "$Data_Dir" in
        /|/usr|/usr/local|/usr/local/mariadb|/usr/local/mysql|/var|/var/lib|/home|/root|/tmp|/opt|/srv|/mnt|/media|/etc|/etc/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/boot|/boot/*|/run|/run/*)
            Echo_Red "Refusing an unsafe MariaDB data directory: $Data_Dir."
            return 1 ;;
    esac
    Parent=$Data_Dir
    while [ "$Parent" != / ]; do
        if [ -L "$Parent" ]; then
            Echo_Red "Refusing a symlink in the MariaDB data directory path: $Parent."
            return 1
        fi
        Parent=${Parent%/*}
        [ -n "$Parent" ] || Parent=/
    done
    if [ -e "$Data_Dir" ]; then
        [ -d "$Data_Dir" ] || { Echo_Red "MariaDB data path is not a directory."; return 1; }
        Contents=$(find "$Data_Dir" -mindepth 1 -maxdepth 1 -print -quit) || return 1
        if [ -n "$Contents" ]; then
            Echo_Red "MariaDB data directory is not empty; existing data is preserved. Use a new empty directory or a separately tested manual upgrade."
            return 1
        fi
    fi
}

Verify_MariaDB_Archive()
{
    # Bash locals also force verification in the shared download helper.
    local Enable_Download_Checksum=y
    Verify_Download_File "$1"
}

MariaDB_Install_Preflight()
{
    local Existing Archive
    Check_MariaDB_Data_Dir || return 1
    for Existing in /usr/local/mariadb /usr/local/mysql /etc/my.cnf /etc/mysql /etc/init.d/mariadb /etc/init.d/mysql /etc/systemd/system/mariadb.service /etc/systemd/system/mysql.service; do
        if [ -e "$Existing" ] || [ -L "$Existing" ]; then
            Echo_Red "Refusing to overwrite an existing database installation/configuration: $Existing. Use a separately tested manual upgrade."
            return 1
        fi
    done
    [[ "${Mariadb_Ver}" =~ ^mariadb-(10\.11|11\.(4|8))\.(0|[1-9][0-9]*)$ ]] || { Echo_Red "Unsupported MariaDB release: only modern 10.11/11.4/11.8 fresh security initialization is supported."; return 1; }
    Archive=${Mariadb_Ver}.tar.gz
    if [ "${Bin}" = y ]; then
        [[ "${DB_ARCH}" =~ ^(x86_64|i686|aarch64)$ ]] || return 1
        Archive=${Mariadb_Ver}-linux-systemd-${DB_ARCH}.tar.gz
    fi
    Verify_MariaDB_Archive "${cur_dir}/src/${Archive}"
}

Install_MariaDB_5()
{
    local Enable_Download_Checksum=y Download_Insecure=n
    MariaDB_Install_Preflight || exit 1
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Generic Binaries..."
        Tar_Cd ${Mariadb_Ver}-linux-systemd-${DB_ARCH}.tar.gz
        mkdir /usr/local/mariadb || exit 1
        mv ${Mariadb_Ver}-linux-systemd-${DB_ARCH}/* /usr/local/mariadb/ || exit 1
    else
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Source code..."
        Tar_Cd ${Mariadb_Ver}.tar.gz ${Mariadb_Ver}
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DWITH_ARIA_STORAGE_ENGINE=1 -DWITH_XTRADB_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 || exit 1
        Make_Install || exit 1
    fi

    Check_MariaDB_Data_Dir || exit 1
    groupadd mariadb
    useradd -s /sbin/nologin -M -g mariadb mariadb

    (set -o noclobber; cat > /etc/my.cnf<<EOF
[client]
#password	= your_password
port		= 3306
socket		= /tmp/mysql.sock

[mysqld]
# Remote access requires manual bind-address and firewall configuration.
bind-address = 127.0.0.1
port		= 3306
socket		= /tmp/mysql.sock
user    = mariadb
basedir = /usr/local/mariadb
datadir = ${MariaDB_Data_Dir}
log_error = ${MariaDB_Data_Dir}/mariadb.err
pid-file = ${MariaDB_Data_Dir}/mariadb.pid
skip-external-locking
key_buffer_size = 16M
max_allowed_packet = 1M
table_open_cache = 64
sort_buffer_size = 512K
net_buffer_length = 8K
read_buffer_size = 256K
read_rnd_buffer_size = 512K
myisam_sort_buffer_size = 8M
thread_cache_size = 8
query_cache_size = 8M
tmp_table_size = 16M

#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535

log-bin=mysql-bin
binlog_format=mixed
server-id	= 1
expire_logs_days = 10

default_storage_engine = InnoDB
#innodb_file_per_table = 1
#innodb_data_home_dir = ${MariaDB_Data_Dir}
#innodb_data_file_path = ibdata1:10M:autoextend
#innodb_log_group_home_dir = ${MariaDB_Data_Dir}
#innodb_buffer_pool_size = 16M
#innodb_additional_mem_pool_size = 2M
#innodb_log_file_size = 5M
#innodb_log_buffer_size = 8M
#innodb_flush_log_at_trx_commit = 1
#innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer = 2M
write_buffer = 2M

[mysqlhotcopy]
interactive-timeout

${MySQLMAOpt}
EOF
    ) || { Echo_Red "Refusing to overwrite MariaDB configuration, or configuration creation failed."; exit 1; }

    if [ "${InstallInnodb}" = "y" ]; then
        sed -i 's/^#innodb/innodb/g' /etc/my.cnf
    else
        sed -i '/^default_storage_engine/d' /etc/my.cnf
        sed -i 's/^#loose-innodb/loose-innodb/g' /etc/my.cnf
        sed -i '/skip-external-locking/i\default_storage_engine = MyISAM\nloose-skip-innodb' /etc/my.cnf
    fi
    MySQL_Opt
    Check_MariaDB_Data_Dir || exit 1
    mkdir -p -- "${MariaDB_Data_Dir}" || exit 1
    chown -R mariadb:mariadb /usr/local/mariadb
    /usr/local/mariadb/scripts/mysql_install_db --defaults-file=/etc/my.cnf --basedir=/usr/local/mariadb --datadir="${MariaDB_Data_Dir}" --user=mariadb || exit 1
    chown -R mariadb:mariadb ${MariaDB_Data_Dir}
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    \cp ${cur_dir}/init.d/mariadb.service /etc/systemd/system/mariadb.service
    chmod 755 /etc/init.d/mariadb

    Mariadb_Sec_Setting || exit 1
}

Install_MariaDB_103()
{
    local Enable_Download_Checksum=y Download_Insecure=n
    MariaDB_Install_Preflight || exit 1
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Generic Binaries..."
        Tar_Cd ${Mariadb_Ver}-linux-systemd-${DB_ARCH}.tar.gz
        mkdir /usr/local/mariadb || exit 1
        mv ${Mariadb_Ver}-linux-systemd-${DB_ARCH}/* /usr/local/mariadb/ || exit 1
    else
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Source code..."
        Tar_Cd ${Mariadb_Ver}.tar.gz ${Mariadb_Ver}
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DWITH_ARIA_STORAGE_ENGINE=1 -DWITH_XTRADB_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITHOUT_TOKUDB=1 || exit 1
        Make_Install || exit 1
    fi

    Check_MariaDB_Data_Dir || exit 1
    groupadd mariadb
    useradd -s /sbin/nologin -M -g mariadb mariadb

    (set -o noclobber; cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = 3306
socket      = /tmp/mysql.sock

[mysqld]
# Remote access requires manual bind-address and firewall configuration.
bind-address = 127.0.0.1
port        = 3306
socket      = /tmp/mysql.sock
user    = mariadb
basedir = /usr/local/mariadb
datadir = ${MariaDB_Data_Dir}
log_error = ${MariaDB_Data_Dir}/mariadb.err
pid-file = ${MariaDB_Data_Dir}/mariadb.pid
skip-external-locking
key_buffer_size = 16M
max_allowed_packet = 1M
table_open_cache = 64
sort_buffer_size = 512K
net_buffer_length = 8K
read_buffer_size = 256K
read_rnd_buffer_size = 512K
myisam_sort_buffer_size = 8M
thread_cache_size = 8
query_cache_size = 8M
tmp_table_size = 16M

explicit_defaults_for_timestamp = true
#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535

log-bin=mysql-bin
binlog_format=mixed
server-id   = 1
expire_logs_days = 10

default_storage_engine = InnoDB
#innodb_file_per_table = 1
#innodb_data_home_dir = ${MariaDB_Data_Dir}
#innodb_data_file_path = ibdata1:10M:autoextend
#innodb_log_group_home_dir = ${MariaDB_Data_Dir}
#innodb_buffer_pool_size = 16M
#innodb_log_file_size = 5M
#innodb_log_buffer_size = 8M
#innodb_flush_log_at_trx_commit = 1
#innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer = 2M
write_buffer = 2M

[mysqlhotcopy]
interactive-timeout

${MySQLMAOpt}
EOF
    ) || { Echo_Red "Refusing to overwrite MariaDB configuration, or configuration creation failed."; exit 1; }
    if [ "${InstallInnodb}" = "y" ]; then
        sed -i 's/^#innodb/innodb/g' /etc/my.cnf
    else
        sed -i '/^default_storage_engine/d' /etc/my.cnf
        sed -i 's/^#loose-innodb/loose-innodb/g' /etc/my.cnf
        sed -i '/skip-external-locking/i\default_storage_engine = MyISAM\nloose-skip-innodb' /etc/my.cnf
    fi
    MySQL_Opt
    Check_MariaDB_Data_Dir || exit 1
    mkdir -p -- "${MariaDB_Data_Dir}" || exit 1
    chown -R mariadb:mariadb /usr/local/mariadb
    /usr/local/mariadb/scripts/mysql_install_db --defaults-file=/etc/my.cnf --basedir=/usr/local/mariadb --datadir="${MariaDB_Data_Dir}" --user=mariadb || exit 1
    chown -R mariadb:mariadb ${MariaDB_Data_Dir}
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    \cp ${cur_dir}/init.d/mariadb.service /etc/systemd/system/mariadb.service
    chmod 755 /etc/init.d/mariadb

    Mariadb_Sec_Setting || exit 1
}

Install_MariaDB_104()
{
    local Enable_Download_Checksum=y Download_Insecure=n
    MariaDB_Install_Preflight || exit 1
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Generic Binaries..."
        Tar_Cd ${Mariadb_Ver}-linux-systemd-${DB_ARCH}.tar.gz
        mkdir /usr/local/mariadb || exit 1
        mv ${Mariadb_Ver}-linux-systemd-${DB_ARCH}/* /usr/local/mariadb/ || exit 1
    else
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Source code..."
        Tar_Cd ${Mariadb_Ver}.tar.gz ${Mariadb_Ver}
        patch -p1 < ${cur_dir}/src/patch/mariadb_10.4_install_db.patch || exit 1
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DMYSQL_UNIX_ADDR=/tmp/mysql.sock -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITHOUT_TOKUDB=1 || exit 1
        Make_Install || exit 1
    fi

    Check_MariaDB_Data_Dir || exit 1
    groupadd mariadb
    useradd -s /sbin/nologin -M -g mariadb mariadb

    (set -o noclobber; cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = 3306
socket      = /tmp/mysql.sock

[mysqld]
# Remote access requires manual bind-address and firewall configuration.
bind-address = 127.0.0.1
port        = 3306
socket      = /tmp/mysql.sock
user    = mariadb
basedir = /usr/local/mariadb
datadir = ${MariaDB_Data_Dir}
log_error = ${MariaDB_Data_Dir}/mariadb.err
pid-file = ${MariaDB_Data_Dir}/mariadb.pid
skip-external-locking
key_buffer_size = 16M
max_allowed_packet = 1M
table_open_cache = 64
sort_buffer_size = 512K
net_buffer_length = 8K
read_buffer_size = 256K
read_rnd_buffer_size = 512K
myisam_sort_buffer_size = 8M
thread_cache_size = 8
query_cache_size = 8M
tmp_table_size = 16M

explicit_defaults_for_timestamp = true
#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535

log-bin=mysql-bin
binlog_format=mixed
server-id   = 1
expire_logs_days = 10

default_storage_engine = InnoDB
#innodb_file_per_table = 1
#innodb_data_home_dir = ${MariaDB_Data_Dir}
#innodb_data_file_path = ibdata1:10M:autoextend
#innodb_log_group_home_dir = ${MariaDB_Data_Dir}
#innodb_buffer_pool_size = 16M
#innodb_log_file_size = 5M
#innodb_log_buffer_size = 8M
#innodb_flush_log_at_trx_commit = 1
#innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer = 2M
write_buffer = 2M

[mysqlhotcopy]
interactive-timeout

${MySQLMAOpt}
EOF
    ) || { Echo_Red "Refusing to overwrite MariaDB configuration, or configuration creation failed."; exit 1; }
    if [ "${InstallInnodb}" = "y" ]; then
        sed -i 's/^#innodb/innodb/g' /etc/my.cnf
    else
        sed -i '/^default_storage_engine/d' /etc/my.cnf
        sed -i 's/^#loose-innodb/loose-innodb/g' /etc/my.cnf
        sed -i '/skip-external-locking/i\default_storage_engine = MyISAM\nloose-skip-innodb' /etc/my.cnf
    fi
    MySQL_Opt
    Check_MariaDB_Data_Dir || exit 1
    mkdir -p -- "${MariaDB_Data_Dir}" || exit 1
    chown -R mariadb:mariadb /usr/local/mariadb
    /usr/local/mariadb/scripts/mysql_install_db --defaults-file=/etc/my.cnf --basedir=/usr/local/mariadb --datadir="${MariaDB_Data_Dir}" --user=mariadb || exit 1
    chown -R mariadb:mariadb ${MariaDB_Data_Dir}
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    \cp ${cur_dir}/init.d/mariadb.service /etc/systemd/system/mariadb.service
    chmod 755 /etc/init.d/mariadb

    Mariadb_Sec_Setting || exit 1
}

Install_MariaDB_105()
{
    local Enable_Download_Checksum=y Download_Insecure=n
    MariaDB_Install_Preflight || exit 1
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Generic Binaries..."
        Tar_Cd ${Mariadb_Ver}-linux-systemd-${DB_ARCH}.tar.gz
        mkdir /usr/local/mariadb || exit 1
        mv ${Mariadb_Ver}-linux-systemd-${DB_ARCH}/* /usr/local/mariadb/ || exit 1
    else
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Source code..."
        Tar_Cd ${Mariadb_Ver}.tar.gz ${Mariadb_Ver}
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DMYSQL_UNIX_ADDR=/tmp/mysql.sock -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITHOUT_TOKUDB=1 || exit 1
        Make_Install || exit 1
    fi

    Check_MariaDB_Data_Dir || exit 1
    groupadd mariadb
    useradd -s /sbin/nologin -M -g mariadb mariadb

    (set -o noclobber; cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = 3306
socket      = /tmp/mysql.sock

[mysqld]
# Remote access requires manual bind-address and firewall configuration.
bind-address = 127.0.0.1
port        = 3306
socket      = /tmp/mysql.sock
user    = mariadb
basedir = /usr/local/mariadb
datadir = ${MariaDB_Data_Dir}
log_error = ${MariaDB_Data_Dir}/mariadb.err
pid-file = ${MariaDB_Data_Dir}/mariadb.pid
skip-external-locking
key_buffer_size = 16M
max_allowed_packet = 1M
table_open_cache = 64
sort_buffer_size = 512K
net_buffer_length = 8K
read_buffer_size = 256K
read_rnd_buffer_size = 512K
myisam_sort_buffer_size = 8M
thread_cache_size = 8
query_cache_size = 8M
tmp_table_size = 16M

explicit_defaults_for_timestamp = true
#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535

log-bin=mysql-bin
binlog_format=mixed
server-id   = 1
expire_logs_days = 10

default_storage_engine = InnoDB
#innodb_file_per_table = 1
#innodb_data_home_dir = ${MariaDB_Data_Dir}
#innodb_data_file_path = ibdata1:10M:autoextend
#innodb_log_group_home_dir = ${MariaDB_Data_Dir}
#innodb_buffer_pool_size = 16M
#innodb_log_file_size = 5M
#innodb_log_buffer_size = 8M
#innodb_flush_log_at_trx_commit = 1
#innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer = 2M
write_buffer = 2M

[mysqlhotcopy]
interactive-timeout

${MySQLMAOpt}
EOF
    ) || { Echo_Red "Refusing to overwrite MariaDB configuration, or configuration creation failed."; exit 1; }
    if [ "${InstallInnodb}" = "y" ]; then
        sed -i 's/^#innodb/innodb/g' /etc/my.cnf
    else
        sed -i '/^default_storage_engine/d' /etc/my.cnf
        sed -i 's/^#loose-innodb/loose-innodb/g' /etc/my.cnf
        sed -i '/skip-external-locking/i\default_storage_engine = MyISAM\nloose-skip-innodb' /etc/my.cnf
    fi
    MySQL_Opt
    Check_MariaDB_Data_Dir || exit 1
    mkdir -p -- "${MariaDB_Data_Dir}" || exit 1
    chown -R mariadb:mariadb /usr/local/mariadb
    /usr/local/mariadb/scripts/mysql_install_db --defaults-file=/etc/my.cnf --basedir=/usr/local/mariadb --datadir="${MariaDB_Data_Dir}" --user=mariadb || exit 1
    chown -R mariadb:mariadb ${MariaDB_Data_Dir}
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    \cp ${cur_dir}/init.d/mariadb.service /etc/systemd/system/mariadb.service
    chmod 755 /etc/init.d/mariadb

    Mariadb_Sec_Setting || exit 1
}

Install_MariaDB_106()
{
    local Enable_Download_Checksum=y Download_Insecure=n
    MariaDB_Install_Preflight || exit 1
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Generic Binaries..."
        Tar_Cd ${Mariadb_Ver}-linux-systemd-${DB_ARCH}.tar.gz
        mkdir /usr/local/mariadb || exit 1
        mv ${Mariadb_Ver}-linux-systemd-${DB_ARCH}/* /usr/local/mariadb/ || exit 1
    else
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Source code..."
        Tar_Cd ${Mariadb_Ver}.tar.gz ${Mariadb_Ver}
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DMYSQL_UNIX_ADDR=/tmp/mysql.sock -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITHOUT_TOKUDB=1 || exit 1
        Make_Install || exit 1
    fi

    Check_MariaDB_Data_Dir || exit 1
    groupadd mariadb
    useradd -s /sbin/nologin -M -g mariadb mariadb

    (set -o noclobber; cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = 3306
socket      = /tmp/mysql.sock

[mysqld]
# Remote access requires manual bind-address and firewall configuration.
bind-address = 127.0.0.1
port        = 3306
socket      = /tmp/mysql.sock
user    = mariadb
basedir = /usr/local/mariadb
datadir = ${MariaDB_Data_Dir}
log_error = ${MariaDB_Data_Dir}/mariadb.err
pid-file = ${MariaDB_Data_Dir}/mariadb.pid
skip-external-locking
key_buffer_size = 16M
max_allowed_packet = 1M
table_open_cache = 64
sort_buffer_size = 512K
net_buffer_length = 8K
read_buffer_size = 256K
read_rnd_buffer_size = 512K
myisam_sort_buffer_size = 8M
thread_cache_size = 8
query_cache_size = 8M
tmp_table_size = 16M

explicit_defaults_for_timestamp = true
#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535

log-bin=mysql-bin
binlog_format=mixed
server-id   = 1
expire_logs_days = 10

default_storage_engine = InnoDB
#innodb_file_per_table = 1
#innodb_data_home_dir = ${MariaDB_Data_Dir}
#innodb_data_file_path = ibdata1:10M:autoextend
#innodb_log_group_home_dir = ${MariaDB_Data_Dir}
#innodb_buffer_pool_size = 16M
#innodb_log_file_size = 5M
#innodb_log_buffer_size = 8M
#innodb_flush_log_at_trx_commit = 1
#innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer = 2M
write_buffer = 2M

[mysqlhotcopy]
interactive-timeout

${MySQLMAOpt}
EOF
    ) || { Echo_Red "Refusing to overwrite MariaDB configuration, or configuration creation failed."; exit 1; }
    if [ "${InstallInnodb}" = "y" ]; then
        sed -i 's/^#innodb/innodb/g' /etc/my.cnf
    else
        sed -i '/^default_storage_engine/d' /etc/my.cnf
        sed -i 's/^#loose-innodb/loose-innodb/g' /etc/my.cnf
        sed -i '/skip-external-locking/i\default_storage_engine = MyISAM\nloose-skip-innodb' /etc/my.cnf
    fi
    MySQL_Opt
    Check_MariaDB_Data_Dir || exit 1
    mkdir -p -- "${MariaDB_Data_Dir}" || exit 1
    chown -R mariadb:mariadb /usr/local/mariadb
    /usr/local/mariadb/scripts/mysql_install_db --defaults-file=/etc/my.cnf --basedir=/usr/local/mariadb --datadir="${MariaDB_Data_Dir}" --user=mariadb || exit 1
    chown -R mariadb:mariadb ${MariaDB_Data_Dir}
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    \cp ${cur_dir}/init.d/mariadb.service /etc/systemd/system/mariadb.service
    chmod 755 /etc/init.d/mariadb

    Mariadb_Sec_Setting || exit 1
}

Install_MariaDB_1011()
{
    local Enable_Download_Checksum=y Download_Insecure=n
    MariaDB_Install_Preflight || exit 1
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Generic Binaries..."
        Tar_Cd ${Mariadb_Ver}-linux-systemd-${DB_ARCH}.tar.gz
        mkdir /usr/local/mariadb || exit 1
        mv ${Mariadb_Ver}-linux-systemd-${DB_ARCH}/* /usr/local/mariadb/ || exit 1
    else
        Echo_Blue "[+] Installing ${Mariadb_Ver} Using Source code..."
        Tar_Cd ${Mariadb_Ver}.tar.gz ${Mariadb_Ver}
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mariadb -DMYSQL_UNIX_ADDR=/tmp/mysql.sock -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 -DWITHOUT_TOKUDB=1 || exit 1
        Make_Install || exit 1
    fi

    Check_MariaDB_Data_Dir || exit 1
    groupadd mariadb
    useradd -s /sbin/nologin -M -g mariadb mariadb

    (set -o noclobber; cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = 3306
socket      = /tmp/mysql.sock

[mysqld]
# Remote access requires manual bind-address and firewall configuration.
bind-address = 127.0.0.1
port        = 3306
socket      = /tmp/mysql.sock
user    = mariadb
basedir = /usr/local/mariadb
datadir = ${MariaDB_Data_Dir}
log_error = ${MariaDB_Data_Dir}/mariadb.err
pid-file = ${MariaDB_Data_Dir}/mariadb.pid
skip-external-locking
key_buffer_size = 16M
max_allowed_packet = 1M
table_open_cache = 64
sort_buffer_size = 512K
net_buffer_length = 8K
read_buffer_size = 256K
read_rnd_buffer_size = 512K
myisam_sort_buffer_size = 8M
thread_cache_size = 8
query_cache_size = 8M
tmp_table_size = 16M

explicit_defaults_for_timestamp = true
#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535

log-bin=mysql-bin
binlog_format=mixed
server-id   = 1
expire_logs_days = 10

default_storage_engine = InnoDB
#innodb_file_per_table = 1
#innodb_data_home_dir = ${MariaDB_Data_Dir}
#innodb_data_file_path = ibdata1:10M:autoextend
#innodb_log_group_home_dir = ${MariaDB_Data_Dir}
#innodb_buffer_pool_size = 16M
#innodb_log_file_size = 5M
#innodb_log_buffer_size = 8M
#innodb_flush_log_at_trx_commit = 1
#innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer = 2M
write_buffer = 2M

[mysqlhotcopy]
interactive-timeout

${MySQLMAOpt}
EOF
    ) || { Echo_Red "Refusing to overwrite MariaDB configuration, or configuration creation failed."; exit 1; }
    if [ "${InstallInnodb}" = "y" ]; then
        sed -i 's/^#innodb/innodb/g' /etc/my.cnf
    else
        sed -i '/^default_storage_engine/d' /etc/my.cnf
        sed -i 's/^#loose-innodb/loose-innodb/g' /etc/my.cnf
        sed -i '/skip-external-locking/i\default_storage_engine = MyISAM\nloose-skip-innodb' /etc/my.cnf
    fi
    MySQL_Opt
    Check_MariaDB_Data_Dir || exit 1
    mkdir -p -- "${MariaDB_Data_Dir}" || exit 1
    chown -R mariadb:mariadb /usr/local/mariadb
    /usr/local/mariadb/scripts/mysql_install_db --defaults-file=/etc/my.cnf --basedir=/usr/local/mariadb --datadir="${MariaDB_Data_Dir}" --user=mariadb || exit 1
    chown -R mariadb:mariadb ${MariaDB_Data_Dir}
    \cp /usr/local/mariadb/support-files/mysql.server /etc/init.d/mariadb
    \cp ${cur_dir}/init.d/mariadb.service /etc/systemd/system/mariadb.service
    chmod 755 /etc/init.d/mariadb

    Mariadb_Sec_Setting || exit 1
}

Install_MariaDB_114()
{
    Install_MariaDB_1011
}

Install_MariaDB_118()
{
    Install_MariaDB_1011
}
