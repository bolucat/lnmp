#!/usr/bin/env bash

Backup_MySQL()
{
    [[ "${MySQL_Data_Dir}" = /* && "${MySQL_Data_Dir}" != *[[:space:]]* ]] || return 1
    local Resolved_Data_Dir Runtime_Data_Dir
    Resolved_Data_Dir=$(readlink -f "${MySQL_Data_Dir}") || return 1
    case "$Resolved_Data_Dir" in
        ''|/|/usr|/usr/local|/usr/local/mysql|/var|/var/lib|/etc|/home|/root|/tmp|/dev|/proc|/sys|/boot|/run|/opt|/srv|/mnt|/media)
            Echo_Red "Refusing an unsafe MySQL data directory."
            return 1 ;;
    esac
    [ -d "$Resolved_Data_Dir" ] || return 1
    Runtime_Data_Dir=$(/usr/local/mysql/bin/mysql --defaults-file="${MySQL_Client_Cnf}" -Nse 'SELECT @@GLOBAL.datadir') || return 1
    Runtime_Data_Dir=$(readlink -f "$Runtime_Data_Dir") || return 1
    [ "$Resolved_Data_Dir" = "$Runtime_Data_Dir" ] || { Echo_Red "Configured and running MySQL data directories differ."; return 1; }
    MySQL_Data_Dir=$Resolved_Data_Dir
    echo "Starting backup all databases..."
    echo "If the database is large, the backup time will be longer."
    [ ! -e "/usr/local/oldmysql${Upgrade_Date}" ] || return 1
    [ ! -e "/usr/local/failedmysql${Upgrade_Date}" ] || return 1
    [ ! -e "/root/mysql_all_backup${Upgrade_Date}.sql" ] || return 1
    if [ "${MySQL_Data_Dir}" != "/usr/local/mysql/var" ]; then
        [ ! -e "${MySQL_Data_Dir}${Upgrade_Date}" ] || return 1
        [ ! -e "${MySQL_Data_Dir}.failed.${Upgrade_Date}" ] || return 1
    fi
    read -r MySQL_Old_Read_Only MySQL_Old_Super_Read_Only <<< "$(/usr/local/mysql/bin/mysql --defaults-file="${MySQL_Client_Cnf}" -Nse 'SELECT @@GLOBAL.read_only, @@GLOBAL.super_read_only')"
    [[ "${MySQL_Old_Read_Only}" =~ ^[01]$ && "${MySQL_Old_Super_Read_Only}" =~ ^[01]$ ]] || return 1
    MySQL_Read_Only_Changed=y
    Do_Query "SET GLOBAL super_read_only=ON;" || return 1
    (umask 077; /usr/local/mysql/bin/mysqldump --defaults-file="${MySQL_Client_Cnf}" --all-databases --routines --events --triggers --hex-blob --lock-all-tables > "/root/mysql_all_backup${Upgrade_Date}.sql.tmp") || return 1
    [ -s "/root/mysql_all_backup${Upgrade_Date}.sql.tmp" ] || return 1
    mv "/root/mysql_all_backup${Upgrade_Date}.sql.tmp" "/root/mysql_all_backup${Upgrade_Date}.sql" || return 1
    MySQL_Upgrade_Active=y
    /etc/init.d/mysql stop || return 1
    if /usr/local/mysql/bin/mysql --defaults-file="${MySQL_Client_Cnf}" -Nse 'SELECT 1' >/dev/null 2>&1; then
        Echo_Red "MySQL is still running; refusing to move the data directory."
        return 1
    fi
    mv /usr/local/mysql /usr/local/oldmysql${Upgrade_Date}
    mv /etc/init.d/mysql /usr/local/oldmysql${Upgrade_Date}/init.d.mysql.bak.${Upgrade_Date}
    mv /etc/my.cnf /usr/local/oldmysql${Upgrade_Date}/my.cnf.bak.${Upgrade_Date}
    if [ "${MySQL_Data_Dir}" != "/usr/local/mysql/var" ]; then
        mv ${MySQL_Data_Dir} ${MySQL_Data_Dir}${Upgrade_Date}
    fi
    if echo "${mysql_version}" | grep -Eqi '^5.5.' &&  echo "${cur_mysql_version}" | grep -Eqi '^5.6.';then
        sed -i 's/STATS_PERSISTENT=0//g' /root/mysql_all_backup${Upgrade_Date}.sql
    fi
}

Upgrade_MySQL51()
{
    Tar_Cd mysql-${mysql_version}.tar.gz mysql-${mysql_version}
    MySQL_Gcc7_Patch
    if [ $InstallInnodb = "y" ]; then
        ./configure --prefix=/usr/local/mysql --with-extra-charsets=complex --enable-thread-safe-client --enable-assembler --with-mysqld-ldflags=-all-static --with-charset=utf8 --enable-thread-safe-client --with-big-tables --with-readline --with-ssl --with-embedded-server --enable-local-infile --with-plugins=innobase ${MySQL51MAOpt}
    else
        ./configure --prefix=/usr/local/mysql --with-extra-charsets=complex --enable-thread-safe-client --enable-assembler --with-mysqld-ldflags=-all-static --with-charset=utf8 --enable-thread-safe-client --with-big-tables --with-readline --with-ssl --with-embedded-server --enable-local-infile ${MySQL51MAOpt}
    fi
    sed -i '/set -ex;/,/done/d' Makefile
    Make_Install

    groupadd -f mysql
    id mysql >/dev/null 2>&1 || useradd -s /sbin/nologin -M -g mysql mysql

cat > /etc/my.cnf<<EOF
[client]
#password	= your_password
port		= 3306
socket		= /tmp/mysql.sock

[mysqld]
port		= 3306
socket		= /tmp/mysql.sock
datadir = ${MySQL_Data_Dir}
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
#innodb_data_home_dir = ${MySQL_Data_Dir}
#innodb_data_file_path = ibdata1:10M:autoextend
#innodb_log_group_home_dir = ${MySQL_Data_Dir}
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
EOF
    if [ "${InstallInnodb}" = "y" ]; then
        sed -i 's/^#innodb/innodb/g' /etc/my.cnf
    else
        sed -i '/^default_storage_engine/d' /etc/my.cnf
        sed -i '/skip-external-locking/i\default_storage_engine = MyISAM\nloose-skip-innodb' /etc/my.cnf
    fi
    MySQL_Opt
    if [ -d "${MySQL_Data_Dir}" ]; then
        rm -rf ${MySQL_Data_Dir}/*
    else
        mkdir -p ${MySQL_Data_Dir}
    fi
    chown -R mysql:mysql ${MySQL_Data_Dir}
    /usr/local/mysql/scripts/mysql_install_db --defaults-file=/etc/my.cnf --basedir=/usr/local/mysql --datadir=${MySQL_Data_Dir} --user=mysql

    cat > /etc/ld.so.conf.d/mysql.conf<<EOF
/usr/local/mysql/lib
/usr/local/lib
EOF
    ldconfig
    ln -sf /usr/local/mysql/lib/mysql /usr/lib/mysql
    ln -sf /usr/local/mysql/include/mysql /usr/include/mysql
}

Upgrade_MySQL55()
{
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "Starting upgrade MySQL ${mysql_version} Using Generic Binaries..."
        Tar_Cd ${mysql_src}
        mkdir /usr/local/mysql
        mv mysql-${mysql_version}-linux-glibc2.12-${DB_ARCH}/* /usr/local/mysql/
    else
        Echo_Blue "Starting upgrade MySQL ${mysql_version} Using Source code..."
        if [ "${isOpenSSL3}" = "y" ]; then
            MySQL_WITH_SSL='-DWITH_SSL=bundled'
        else
            MySQL_WITH_SSL=''
        fi
        Tar_Cd mysql-${mysql_version}.tar.gz mysql-${mysql_version}
        MySQL_ARM_Patch
        if  g++ -dM -E -x c++ /dev/null | grep -F __cplusplus | cut -d' ' -f3 | grep -Eqi "^2017|202[0-9]"; then
            sed -i '1s/^/set(CMAKE_CXX_STANDARD 11)\n/' CMakeLists.txt
        fi
        if echo "${Rocky_Version}" | grep -Eqi "^9"; then
            sed -i 's@^INCLUDE(cmake/abi_check.cmake)@#INCLUDE(cmake/abi_check.cmake)@' CMakeLists.txt
        fi
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mysql -DSYSCONFDIR=/etc -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_READLINE=1 -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 ${MySQL_WITH_SSL}
        Make_Install
    fi

    groupadd -f mysql
    id mysql >/dev/null 2>&1 || useradd -s /sbin/nologin -M -g mysql mysql

    cat > /etc/my.cnf<<EOF
[client]
#password	= your_password
port		= 3306
socket		= /tmp/mysql.sock

[mysqld]
port		= 3306
socket		= /tmp/mysql.sock
datadir = ${MySQL_Data_Dir}
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
#innodb_data_home_dir = ${MySQL_Data_Dir}
#innodb_data_file_path = ibdata1:10M:autoextend
#innodb_log_group_home_dir = ${MySQL_Data_Dir}
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
    if [ "${InstallInnodb}" = "y" ]; then
        sed -i 's/^#innodb/innodb/g' /etc/my.cnf
    else
        sed -i '/^default_storage_engine/d' /etc/my.cnf
        sed -i '/skip-external-locking/i\default_storage_engine = MyISAM\nloose-skip-innodb' /etc/my.cnf
    fi
    MySQL_Opt
    if [ -d "${MySQL_Data_Dir}" ]; then
        rm -rf ${MySQL_Data_Dir}/*
    else
        mkdir -p ${MySQL_Data_Dir}
    fi
    chown -R mysql:mysql ${MySQL_Data_Dir}
    /usr/local/mysql/scripts/mysql_install_db --defaults-file=/etc/my.cnf --basedir=/usr/local/mysql --datadir=${MySQL_Data_Dir} --user=mysql

    cat > /etc/ld.so.conf.d/mysql.conf<<EOF
/usr/local/mysql/lib
/usr/local/lib
EOF
    ldconfig
    ln -sf /usr/local/mysql/lib/mysql /usr/lib/mysql
    ln -sf /usr/local/mysql/include/mysql /usr/include/mysql
}

Upgrade_MySQL56()
{
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "Starting upgrade MySQL ${mysql_version} Using Generic Binaries..."
        Tar_Cd ${mysql_src}
        mkdir /usr/local/mysql
        mv mysql-${mysql_version}-linux-glibc2.12-${DB_ARCH}/* /usr/local/mysql/
    else
        Echo_Blue "Starting upgrade MySQL ${mysql_version} Using Source code..."
        if [ "${isOpenSSL3}" = "y" ]; then
            Install_Openssl_Compat
            MySQL_WITH_SSL='-DWITH_SSL=/usr/local/openssl1.1.1'
        else
            MySQL_WITH_SSL=''
        fi
        Tar_Cd mysql-${mysql_version}.tar.gz mysql-${mysql_version}
        if  g++ -dM -E -x c++ /dev/null | grep -F __cplusplus | cut -d' ' -f3 | grep -Eqi "^2017|202[0-9]"; then
            sed -i '1s/^/set(CMAKE_CXX_STANDARD 11)\n/' CMakeLists.txt
        fi
        if echo "${Rocky_Version}" | grep -Eqi "^9"; then
            sed -i 's@^INCLUDE(cmake/abi_check.cmake)@#INCLUDE(cmake/abi_check.cmake)@' CMakeLists.txt
        fi
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mysql -DSYSCONFDIR=/etc -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 ${MySQL_WITH_SSL}
        Make_Install
    fi

    groupadd -f mysql
    id mysql >/dev/null 2>&1 || useradd -s /sbin/nologin -M -g mysql mysql

cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = 3306
socket      = /tmp/mysql.sock

[mysqld]
port        = 3306
socket      = /tmp/mysql.sock
datadir = ${MySQL_Data_Dir}
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
performance_schema_max_table_instances = 500

explicit_defaults_for_timestamp = true
#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535

log-bin=mysql-bin
binlog_format=mixed
server-id   = 1
expire_logs_days = 10

#loose-innodb-trx=0
#loose-innodb-locks=0
#loose-innodb-lock-waits=0
#loose-innodb-cmp=0
#loose-innodb-cmp-per-index=0
#loose-innodb-cmp-per-index-reset=0
#loose-innodb-cmp-reset=0
#loose-innodb-cmpmem=0
#loose-innodb-cmpmem-reset=0
#loose-innodb-buffer-page=0
#loose-innodb-buffer-page-lru=0
#loose-innodb-buffer-pool-stats=0
#loose-innodb-metrics=0
#loose-innodb-ft-default-stopword=0
#loose-innodb-ft-inserted=0
#loose-innodb-ft-deleted=0
#loose-innodb-ft-being-deleted=0
#loose-innodb-ft-config=0
#loose-innodb-ft-index-cache=0
#loose-innodb-ft-index-table=0
#loose-innodb-sys-tables=0
#loose-innodb-sys-tablestats=0
#loose-innodb-sys-indexes=0
#loose-innodb-sys-columns=0
#loose-innodb-sys-fields=0
#loose-innodb-sys-foreign=0
#loose-innodb-sys-foreign-cols=0

default_storage_engine = InnoDB
#innodb_data_home_dir = ${MySQL_Data_Dir}
#innodb_data_file_path = ibdata1:10M:autoextend
#innodb_log_group_home_dir = ${MySQL_Data_Dir}
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

    if [ "${InstallInnodb}" = "y" ]; then
        sed -i 's/^#innodb/innodb/g' /etc/my.cnf
    else
        sed -i '/^default_storage_engine/d' /etc/my.cnf
        sed -i '/skip-external-locking/i\innodb = OFF\nignore-builtin-innodb\nskip-innodb\ndefault_storage_engine = MyISAM\ndefault_tmp_storage_engine = MyISAM' /etc/my.cnf
        sed -i 's/^#loose-innodb/loose-innodb/g' /etc/my.cnf
    fi
    MySQL_Opt
    if [ -d "${MySQL_Data_Dir}" ]; then
        rm -rf ${MySQL_Data_Dir}/*
    else
        mkdir -p ${MySQL_Data_Dir}
    fi
    chown -R mysql:mysql ${MySQL_Data_Dir}
    /usr/local/mysql/scripts/mysql_install_db --defaults-file=/etc/my.cnf --basedir=/usr/local/mysql --datadir=${MySQL_Data_Dir} --user=mysql

    cat > /etc/ld.so.conf.d/mysql.conf<<EOF
/usr/local/mysql/lib
/usr/local/lib
EOF

    ldconfig
    ln -sf /usr/local/mysql/lib/mysql /usr/lib/mysql
    ln -sf /usr/local/mysql/include/mysql /usr/include/mysql
}

Upgrade_MySQL57()
{
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "Starting upgrade MySQL ${mysql_version} Using Generic Binaries..."
        Tar_Cd ${mysql_src}
        mkdir /usr/local/mysql
        mv mysql-${mysql_version}-linux-glibc2.12-${DB_ARCH}/* /usr/local/mysql/
    else
        Echo_Blue "Starting upgrade MySQL ${mysql_version} Using Source code..."
        if [ "${isOpenSSL3}" = "y" ]; then
            Install_Openssl_Compat
            MySQL_WITH_SSL='-DWITH_SSL=/usr/local/openssl1.1.1'
        else
            MySQL_WITH_SSL=''
        fi
        Tar_Cd ${mysql_src} mysql-${mysql_version}
        Install_Boost
        if echo "${Rocky_Version}" | grep -Eqi "^9"; then
            sed -i 's@^INCLUDE(cmake/abi_check.cmake)@#INCLUDE(cmake/abi_check.cmake)@' CMakeLists.txt
        fi
        cmake -DCMAKE_INSTALL_PREFIX=/usr/local/mysql -DSYSCONFDIR=/etc -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 ${MySQL_WITH_SSL} ${MySQL_WITH_BOOST}
        Make_Install
    fi

    groupadd -f mysql
    id mysql >/dev/null 2>&1 || useradd -s /sbin/nologin -M -g mysql mysql

cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = 3306
socket      = /tmp/mysql.sock

[mysqld]
port        = 3306
socket      = /tmp/mysql.sock
datadir = ${MySQL_Data_Dir}
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
performance_schema_max_table_instances = 500

explicit_defaults_for_timestamp = true
#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535

log-bin=mysql-bin
binlog_format=mixed
server-id   = 1
expire_logs_days = 10
early-plugin-load = ""

default_storage_engine = InnoDB
innodb_data_home_dir = ${MySQL_Data_Dir}
innodb_data_file_path = ibdata1:10M:autoextend
innodb_log_group_home_dir = ${MySQL_Data_Dir}
innodb_buffer_pool_size = 16M
innodb_log_file_size = 5M
innodb_log_buffer_size = 8M
innodb_flush_log_at_trx_commit = 1
innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer_size = 2M
write_buffer_size = 2M

[mysqlhotcopy]
interactive-timeout

${MySQLMAOpt}
EOF

    MySQL_Opt
    if [ -d "${MySQL_Data_Dir}" ]; then
        rm -rf ${MySQL_Data_Dir}/*
    else
        mkdir -p ${MySQL_Data_Dir}
    fi
    chown -R mysql:mysql /usr/local/mysql/
    /usr/local/mysql/bin/mysqld --initialize-insecure --basedir=/usr/local/mysql --datadir=${MySQL_Data_Dir} --user=mysql
    chown -R mysql:mysql ${MySQL_Data_Dir}

    cat > /etc/ld.so.conf.d/mysql.conf<<EOF
/usr/local/mysql/lib
/usr/local/lib
EOF

    ldconfig
    ln -sf /usr/local/mysql/lib/mysql /usr/lib/mysql
    ln -sf /usr/local/mysql/include/mysql /usr/include/mysql
}

Upgrade_MySQL80()
{
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "Starting upgrade MySQL ${mysql_version} Using Generic Binaries..."
        Tar_Cd ${mysql_src}
        mkdir /usr/local/mysql
        mv mysql-${mysql_version}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}/* /usr/local/mysql/
    else
        Echo_Blue "Starting upgrade MySQL ${mysql_version} Using Source code..."
        Tar_Cd ${mysql_src} mysql-${mysql_version}
        Install_Boost
        mkdir build && cd build
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local/mysql -DSYSCONFDIR=/etc -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 ${MySQL_WITH_BOOST}
        Make_Install
    fi

    groupadd -f mysql
    id mysql >/dev/null 2>&1 || useradd -s /sbin/nologin -M -g mysql mysql

cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = 3306
socket      = /tmp/mysql.sock

[mysqld]
port        = 3306
socket      = /tmp/mysql.sock
datadir = ${MySQL_Data_Dir}
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
tmp_table_size = 16M
performance_schema_max_table_instances = 500

explicit_defaults_for_timestamp = true
#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535
default_authentication_plugin = mysql_native_password

log-bin=mysql-bin
binlog_format=mixed
server-id   = 1
binlog_expire_logs_seconds = 864000
early-plugin-load = ""

default_storage_engine = InnoDB
innodb_data_home_dir = ${MySQL_Data_Dir}
innodb_data_file_path = ibdata1:10M:autoextend
innodb_log_group_home_dir = ${MySQL_Data_Dir}
innodb_buffer_pool_size = 16M
innodb_log_file_size = 5M
innodb_log_buffer_size = 8M
innodb_flush_log_at_trx_commit = 1
innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer_size = 2M
write_buffer_size = 2M

[mysqlhotcopy]
interactive-timeout

${MySQLMAOpt}
EOF

    MySQL_Opt
    if [ -d "${MySQL_Data_Dir}" ]; then
        rm -rf ${MySQL_Data_Dir}/*
    else
        mkdir -p ${MySQL_Data_Dir}
    fi
    chown -R mysql:mysql /usr/local/mysql/
    /usr/local/mysql/bin/mysqld --initialize-insecure --basedir=/usr/local/mysql --datadir=${MySQL_Data_Dir} --user=mysql
    chown -R mysql:mysql ${MySQL_Data_Dir}

    cat > /etc/ld.so.conf.d/mysql.conf<<EOF
/usr/local/mysql/lib
/usr/local/lib
EOF

    ldconfig
    ln -sf /usr/local/mysql/lib/mysql /usr/lib/mysql
    ln -sf /usr/local/mysql/include/mysql /usr/include/mysql
}

Upgrade_MySQL84()
{
    if [ "${Bin}" = "y" ]; then
        Echo_Blue "Starting upgrade MySQL ${mysql_version} Using Generic Binaries..."
        Tar_Cd ${mysql_src}
        mkdir /usr/local/mysql
        mv mysql-${mysql_version}-linux-glibc2.17-${DB_ARCH}/* /usr/local/mysql/
    else
        Echo_Blue "Starting upgrade MySQL ${mysql_version} Using Source code..."
        Tar_Cd ${mysql_src} mysql-${mysql_version}
        Install_Boost
        mkdir build && cd build
        cmake .. -DCMAKE_INSTALL_PREFIX=/usr/local/mysql -DSYSCONFDIR=/etc -DWITH_MYISAM_STORAGE_ENGINE=1 -DWITH_INNOBASE_STORAGE_ENGINE=1 -DWITH_PARTITION_STORAGE_ENGINE=1 -DWITH_FEDERATED_STORAGE_ENGINE=1 -DEXTRA_CHARSETS=all -DDEFAULT_CHARSET=utf8mb4 -DDEFAULT_COLLATION=utf8mb4_general_ci -DWITH_EMBEDDED_SERVER=1 -DENABLED_LOCAL_INFILE=1 ${MySQL_WITH_BOOST}
        Make_Install
    fi

    groupadd -f mysql
    id mysql >/dev/null 2>&1 || useradd -s /sbin/nologin -M -g mysql mysql

cat > /etc/my.cnf<<EOF
[client]
#password   = your_password
port        = 3306
socket      = /tmp/mysql.sock

[mysqld]
port        = 3306
socket      = /tmp/mysql.sock
datadir = ${MySQL_Data_Dir}
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
tmp_table_size = 16M
performance_schema_max_table_instances = 500

explicit_defaults_for_timestamp = true
#skip-networking
max_connections = 500
max_connect_errors = 100
open_files_limit = 65535
mysql_native_password=ON

log-bin=mysql-bin
binlog_format=mixed
server-id   = 1
binlog_expire_logs_seconds = 864000
early-plugin-load = ""

default_storage_engine = InnoDB
innodb_data_home_dir = ${MySQL_Data_Dir}
innodb_data_file_path = ibdata1:10M:autoextend
innodb_log_group_home_dir = ${MySQL_Data_Dir}
innodb_buffer_pool_size = 16M
innodb_log_file_size = 5M
innodb_log_buffer_size = 8M
innodb_flush_log_at_trx_commit = 1
innodb_lock_wait_timeout = 50

[mysqldump]
quick
max_allowed_packet = 16M

[mysql]
no-auto-rehash

[myisamchk]
key_buffer_size = 20M
sort_buffer_size = 20M
read_buffer_size = 2M
write_buffer_size = 2M

[mysqlhotcopy]
interactive-timeout

${MySQLMAOpt}
EOF

    MySQL_Opt
    if [ -d "${MySQL_Data_Dir}" ]; then
        rm -rf ${MySQL_Data_Dir}/*
    else
        mkdir -p ${MySQL_Data_Dir}
    fi
    chown -R mysql:mysql /usr/local/mysql/
    /usr/local/mysql/bin/mysqld --initialize-insecure --basedir=/usr/local/mysql --datadir=${MySQL_Data_Dir} --user=mysql
    chown -R mysql:mysql ${MySQL_Data_Dir}

    cat > /etc/ld.so.conf.d/mysql.conf<<EOF
/usr/local/mysql/lib
/usr/local/lib
EOF

    ldconfig
    ln -sf /usr/local/mysql/lib/mysql /usr/lib/mysql
    ln -sf /usr/local/mysql/include/mysql /usr/include/mysql
}

Rollback_MySQL()
{
    if [ "${MySQL_Upgrade_Active}" = "y" ]; then
        /etc/init.d/mysql stop 2>/dev/null
        if [ -d "/usr/local/oldmysql${Upgrade_Date}" ]; then
            [ ! -e /usr/local/mysql ] || mv /usr/local/mysql "/usr/local/failedmysql${Upgrade_Date}" || return 1
            mv "/usr/local/oldmysql${Upgrade_Date}" /usr/local/mysql || return 1
            [ ! -f "/usr/local/mysql/init.d.mysql.bak.${Upgrade_Date}" ] || cp -p "/usr/local/mysql/init.d.mysql.bak.${Upgrade_Date}" /etc/init.d/mysql
            [ ! -f "/usr/local/mysql/my.cnf.bak.${Upgrade_Date}" ] || cp -p "/usr/local/mysql/my.cnf.bak.${Upgrade_Date}" /etc/my.cnf
        fi
        if [[ "${MySQL_Data_Dir}" != "/usr/local/mysql/var" && -d "${MySQL_Data_Dir}${Upgrade_Date}" ]]; then
            [ ! -e "${MySQL_Data_Dir}" ] || mv "${MySQL_Data_Dir}" "${MySQL_Data_Dir}.failed.${Upgrade_Date}" || return 1
            mv "${MySQL_Data_Dir}${Upgrade_Date}" "${MySQL_Data_Dir}" || return 1
        fi
        /etc/init.d/mysql start || return 1
        Echo_Red "MySQL upgrade failed; the previous installation and data have been restored."
    fi
    if [ "${MySQL_Read_Only_Changed}" = "y" ]; then
        Wait_MySQL_Ready || return 1
        Do_Query "SET GLOBAL read_only=${MySQL_Old_Read_Only}; SET GLOBAL super_read_only=${MySQL_Old_Super_Read_Only};" || return 1
    fi
    rm -f "/root/mysql_all_backup${Upgrade_Date}.sql.tmp"
}

Wait_MySQL_Ready()
{
    local Attempt
    for ((Attempt=0; Attempt<120; Attempt++)); do
        if /usr/local/mysql/bin/mysql --defaults-file="${MySQL_Client_Cnf}" -Nse 'SELECT 1' >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    Echo_Red "MySQL did not become ready within 120 seconds."
    return 1
}

Restore_Start_MySQL()
{
    local Attempt Ready=n Root_Password
    chgrp -R mysql /usr/local/mysql/. || return 1
    cp /usr/local/mysql/support-files/mysql.server /etc/init.d/mysql || return 1
    chmod 755 /etc/init.d/mysql || return 1
    cp -p "/usr/local/oldmysql${Upgrade_Date}/my.cnf.bak.${Upgrade_Date}" /etc/my.cnf || return 1
    ldconfig
    /etc/init.d/mysql start || return 1
    for ((Attempt=0; Attempt<120; Attempt++)); do
        if /usr/local/mysql/bin/mysql --defaults-file=/etc/my.cnf -u root --skip-password -Nse 'SELECT 1' >/dev/null 2>&1; then
            Ready=y
            break
        fi
        sleep 1
    done
    [ "${Ready}" = "y" ] || return 1
    Root_Password=${DB_Root_Password//\\/\\\\}
    Root_Password=${Root_Password//\'/\'\'}
    /usr/local/mysql/bin/mysql --defaults-file=/etc/my.cnf -u root --skip-password -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${Root_Password}';" || return 1
    echo "Restore backup databases..."
    /usr/local/mysql/bin/mysql --defaults-file="${MySQL_Client_Cnf}" < "/root/mysql_all_backup${Upgrade_Date}.sql" || return 1
    Wait_MySQL_Ready || return 1
    local Actual_Version
    Actual_Version=$(/usr/local/mysql/bin/mysql --defaults-file="${MySQL_Client_Cnf}" -Nse 'SELECT VERSION()') || return 1
    [ "${Actual_Version%%-*}" = "${mysql_version}" ] || return 1
    Do_Query "SET GLOBAL read_only=${MySQL_Old_Read_Only}; SET GLOBAL super_read_only=${MySQL_Old_Super_Read_Only};" || return 1
    MySQL_Read_Only_Changed=n
    MySQL_Upgrade_Active=n
    Echo_Green "======== upgrade MySQL completed ======"
}

Validate_MySQL_Upgrade()
{
    if [[ ! "${mysql_version}" =~ ^8\.(0|4)\.[0-9]+$ ]]; then
        Echo_Red "Automatic MySQL upgrades support only maintained 8.0/8.4 patch releases."
        return 1
    fi
    if [ "${cur_mysql_version%.*}" != "${mysql_version%.*}" ]; then
        Echo_Red "Cross-series database migration requires a separate tested migration plan."
        return 1
    fi
    if [ "$("${cur_dir}/include/version_compare" "${cur_mysql_version}" "${mysql_version}")" != "-1" ]; then
        Echo_Red "The target must be newer than the current MySQL version."
        return 1
    fi
}

Upgrade_MySQL_Transaction()
{
    Check_DB
    if [ "${Is_MySQL}" = "n" ]; then
        Echo_Red "Current database was MariaDB, Can't run MySQL upgrade script."
        exit 1
    fi

    Verify_DB_Password

    cur_mysql_version=`/usr/local/mysql/bin/mysql_config --version`
    mysql_version=""
    echo "Current MYSQL Version:${cur_mysql_version}"
    echo "You can get version number from http://dev.mysql.com/downloads/mysql/"
    Echo_Yellow "Please input MySQL Version you want."
    read -p "(example: 5.5.60 ): " mysql_version
    if [ "${mysql_version}" = "" ]; then
        echo "Error: You must input MySQL Version!!"
        exit 1
    fi

    if [ "${mysql_version}" == "${cur_mysql_version}" ]; then
        echo "Error: The upgrade MYSQL Version is the same as the old Version!!"
        exit 1
    fi
    Validate_MySQL_Upgrade || return 1

    if [[ "${DB_ARCH}" = "x86_64" || "${DB_ARCH}" = "i686" ]] && echo "${mysql_version}" | grep -Eqi '^5.[5-7].';then
        read -p "Using Generic Binaries [y/n]: " Bin
        case "${Bin}" in
        [yY][eE][sS]|[yY])
            echo "You will install MySQL ${mysql_version} Using Generic Binaries."
            Bin="y"
            ;;
        [nN][oO]|[nN])
            echo "You will install MySQL ${mysql_version} Source code."
            Bin="n"
            ;;
        *)
            echo "Default install MySQL ${mysql_version} Using Generic Binaries."
            Bin="y"
            ;;
        esac
    elif [[ "${DB_ARCH}" = "x86_64" || "${DB_ARCH}" = "i686" || "${DB_ARCH}" = "aarch64" ]] && echo "${mysql_version}" | grep -Eqi '^8.';then
        read -p "Using Generic Binaries [y/n]: " Bin
        case "${Bin}" in
        [yY][eE][sS]|[yY])
            echo "You will install MySQL ${mysql_version} Using Generic Binaries."
            Bin="y"
            ;;
        [nN][oO]|[nN])
            echo "You will install MySQL ${mysql_version} Source code."
            Bin="n"
            ;;
        *)
            echo "Default install MySQL ${mysql_version} Using Generic Binaries."
            Bin="y"
            ;;
        esac
    else
        Bin="n"
    fi

    #do you want to install the InnoDB Storage Engine?
    echo "==========================="

    InstallInnodb="y"
    Echo_Yellow "Do you want to install the InnoDB Storage Engine?"
    read -p "(Default yes,if you want please enter: y , if not please enter: n): " InstallInnodb

    case "${InstallInnodb}" in
    [yY][eE][sS]|[yY])
        echo "You will install the InnoDB Storage Engine"
        InstallInnodb="y"
        ;;
    [nN][oO]|[nN])
        echo "You will NOT install the InnoDB Storage Engine!"
        InstallInnodb="n"
        ;;
    *)
        echo "No input, The InnoDB Storage Engine will enable."
        InstallInnodb="y"
        ;;
    esac

    mysql_short_version=`echo ${mysql_version} | cut -d. -f1-2`

    echo "=================================================="
    echo "You will upgrade MySQL Version to ${mysql_version}"
    echo "=================================================="

    if [ -s /usr/local/include/jemalloc/jemalloc.h ] && lsof -n|grep "libjemalloc.so"|grep -q "mysqld"; then
        MySQL51MAOpt='--with-mysqld-ldflags=-ljemalloc'
        MySQL55MAOpt="-DCMAKE_EXE_LINKER_FLAGS='-ljemalloc' -DWITH_SAFEMALLOC=OFF"
    elif [ -s /usr/local/include/gperftools/tcmalloc.h ] && lsof -n|grep "libtcmalloc.so"|grep -q "mysqld"; then
        MySQL51MAOpt='--with-mysqld-ldflags=-ltcmalloc'
        MySQL55MAOpt="-DCMAKE_EXE_LINKER_FLAGS='-ltcmalloc' -DWITH_SAFEMALLOC=OFF"
    else
        MySQL51MAOpt=''
        MySQL55MAOpt=''
    fi

    Press_Start

    echo "============================check files=================================="
    cd ${cur_dir}/src
    if [[ "${Bin}" = "y" && "${mysql_short_version}" = "8.0" ]]; then
        [[ "${DB_ARCH}" = "aarch64" ]] && mysql8_glibc_ver="2.17" || mysql8_glibc_ver="2.12"
        mysql_src="mysql-${mysql_version}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}.tar.xz"
    elif [[ "${Bin}" = "y" && "${mysql_short_version}" = "8.4" ]]; then
        mysql_src="mysql-${mysql_version}-linux-glibc2.17-${DB_ARCH}.tar.xz"
    elif [[ "${Bin}" = "y" && "${mysql_short_version}" =~ ^5.[5-7]$ ]]; then
        mysql_src="mysql-${mysql_version}-linux-glibc2.12-${DB_ARCH}.tar.gz"
    else
        if [[ "${mysql_short_version}" = "5.7" || "${mysql_short_version}" = "8.0" ]]; then
            mysql_src="mysql-boost-${mysql_version}.tar.gz"
        else
            mysql_src="mysql-${mysql_version}.tar.gz"
        fi
    fi
        if Download_Files https://cdn.mysql.com/Downloads/MySQL-${mysql_short_version}/${mysql_src} ${mysql_src}; then
            echo "Download ${mysql_src} successfully!"
        else
            if ! Download_Files https://cdn.mysql.com/archives/mysql-${mysql_short_version}/${mysql_src} ${mysql_src}; then
                echo "You enter MySQL Version was: ${mysql_version}"
                Echo_Red "Error! You entered a wrong version number, please check!"
                sleep 5
                exit 1
            fi
        fi
    tar tf "${mysql_src}" >/dev/null || return 1
    Check_Openssl
    if [ "${Bin}" != "y" ]; then
        Echo_Blue "Install dependent packages..."
        . ${cur_dir}/include/only.sh
        DB_Dependent
    fi
    echo "============================check files=================================="

    Backup_MySQL
    if [ "${mysql_short_version}" = "5.1" ]; then
        Upgrade_MySQL51
    elif [ "${mysql_short_version}" = "5.5" ]; then
        Upgrade_MySQL55
    elif [ "${mysql_short_version}" = "5.6" ]; then
        Upgrade_MySQL56
    elif [ "${mysql_short_version}" = "5.7" ]; then
        Upgrade_MySQL57
    elif [ "${mysql_short_version}" = "8.0" ]; then
        Upgrade_MySQL80
    elif [ "${mysql_short_version}" = "8.4" ]; then
        Upgrade_MySQL84
    fi
    Restore_Start_MySQL
}

Upgrade_MySQL()
{
    MySQL_Upgrade_Active=n
    MySQL_Read_Only_Changed=n
    Run_Upgrade_Guarded Upgrade_MySQL_Transaction Rollback_MySQL
}
