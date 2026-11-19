#!/usr/bin/env bash

. "$(dirname -- "${BASH_SOURCE[0]}")/php_extension.sh"

Install_PHPMemcache()
{
    Echo_Red "The legacy php-memcache profile is not supported here. Select php-memcached (2)."
    return 1
}

PHP_Memcached_Dependencies()
{
    if [ "${PM}" = apt ]; then
        apt-get install -y cmake g++ make autoconf bison flex pkg-config libsasl2-dev zlib1g-dev libevent-dev || return $?
    elif [ "${PM}" = yum ]; then
        yum install -y cmake gcc-c++ make autoconf bison flex pkgconfig cyrus-sasl-devel zlib-devel libevent-devel || return $?
    else
        Echo_Red "Unsupported package manager for Memcached dependencies."
        return 1
    fi
}

Build_Libmemcached()
(
    # A versioned prefix keeps the old library used by existing modules intact.
    if [ -e "${Libmemcached_Prefix}" ]; then
        [ -s "${Libmemcached_Prefix}/include/libmemcached/memcached.h" ] &&
            [ -s "${Libmemcached_Prefix}/lib/libmemcached.so" ] &&
            [ -s "${Libmemcached_Prefix}/lib/pkgconfig/libmemcached.pc" ] &&
            grep -Eq '^#define LIBMEMCACHED_WITH_SASL_SUPPORT +1' "${Libmemcached_Prefix}/include/libmemcached-1.0/configure.h" &&
            PKG_CONFIG_PATH="${Libmemcached_Prefix}/lib/pkgconfig:${PKG_CONFIG_PATH}" pkg-config --exact-version="${Libmemcached_Ver#libmemcached-}" libmemcached || {
                Echo_Red "Existing ${Libmemcached_Prefix} is incomplete or lacks SASL; refusing to overwrite it."
                return 1
            }
        return 0
    fi
    PHP_Extension_Fetch "https://github.com/awesomized/libmemcached/archive/refs/tags/${Libmemcached_Ver#libmemcached-}.tar.gz" "${Libmemcached_Ver}.tar.gz" "${Libmemcached_Ver}" || return $?
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="${Libmemcached_Prefix}" -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_SHARED_LIBS=ON -DENABLE_SASL=ON -DBUILD_TESTING=OFF \
        -DBUILD_DOCS=OFF -DENABLE_MEMASLAP=OFF || return $?
    cmake --build build || return $?
    cmake --build build --target install || return $?
    [ -s "${Libmemcached_Prefix}/include/libmemcached/memcached.h" ] || return 1
    [ -s "${Libmemcached_Prefix}/lib/libmemcached.so" ] || return 1
    [ -s "${Libmemcached_Prefix}/lib/pkgconfig/libmemcached.pc" ] || return 1
    grep -Eq '^#define LIBMEMCACHED_WITH_SASL_SUPPORT +1' "${Libmemcached_Prefix}/include/libmemcached-1.0/configure.h" || return 1
    PKG_CONFIG_PATH="${Libmemcached_Prefix}/lib/pkgconfig:${PKG_CONFIG_PATH}" pkg-config --exact-version="${Libmemcached_Ver#libmemcached-}" libmemcached || return $?
)

Install_PHPMemcached()
{
    PHP_Extension_Prepare 70000 80599 || return $?
    case "${Libmemcached_Ver}" in
        libmemcached-1.0.*)
            Echo_Red "The modern Memcached profile requires libmemcached-awesome; set Libmemcached_Ver=libmemcached-1.1.4."
            return 1
            ;;
    esac
    PHP_Memcached_Dependencies || return $?
    Libmemcached_Prefix="/usr/local/${Libmemcached_Ver}"
    Build_Libmemcached || return $?
    export PKG_CONFIG_PATH="${Libmemcached_Prefix}/lib/pkgconfig:${PKG_CONFIG_PATH}"
    export LDFLAGS="${LDFLAGS} -Wl,-rpath,${Libmemcached_Prefix}/lib"
    PHP_Extension_Fetch "https://pecl.php.net/get/${PHP8Memcached_Ver}.tgz" "${PHP8Memcached_Ver}.tgz" "${PHP8Memcached_Ver}" || return $?
    PHP_Extension_Build memcached --enable-memcached --enable-memcached-sasl \
        --disable-memcached-igbinary --disable-memcached-msgpack \
        --with-libmemcached-dir="${Libmemcached_Prefix}" || return $?
}

Build_Memcached_Server()
(
    if [ -s /usr/local/memcached/bin/memcached ]; then
        echo "Existing Memcached server preserved."
        return 0
    fi
    if [ -e /usr/local/memcached ]; then
        Echo_Red "Incomplete Memcached prefix; refusing to overwrite existing files."
        return 1
    fi
    PHP_Extension_Fetch "https://memcached.org/files/${Memcached_Ver}.tar.gz" "${Memcached_Ver}.tar.gz" "${Memcached_Ver}" || return $?
    ./configure --prefix=/usr/local/memcached || return $?
    make || return $?
    make install || return $?
    [ -s /usr/local/memcached/bin/memcached ] || return 1
    /usr/local/memcached/bin/memcached -h >/dev/null || return $?
)

Memcached_Install_Service()
{
    if [ -e /etc/init.d/memcached ] || [ -L /etc/init.d/memcached ] ||
        [ -e /etc/systemd/system/memcached.service ] || [ -L /etc/systemd/system/memcached.service ]; then
        Echo_Red "Existing Memcached service files found; refusing to overwrite them."
        return 1
    fi
    command -v runuser >/dev/null || return 1
    if ! id lnmp-memcached >/dev/null 2>&1; then
        useradd -r -U -M -s /bin/false lnmp-memcached || return $?
    fi
    [ "$(id -u lnmp-memcached)" != 0 ] || return 1
    mkdir -p /usr/local/memcached/run || return $?
    chown lnmp-memcached:lnmp-memcached /usr/local/memcached/run || return $?
    chmod 750 /usr/local/memcached/run || return $?
    cat > /etc/init.d/memcached <<'EOF' || return $?
#!/bin/sh
# chkconfig: - 90 25
# description: LNMP Memcached loopback cache
### BEGIN INIT INFO
# Provides: memcached
# Required-Start: $local_fs $network
# Required-Stop: $local_fs $network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: LNMP Memcached loopback cache
### END INIT INFO
PIDFILE=/usr/local/memcached/run/memcached.pid
case "$1" in
    start)
        if [ -r "$PIDFILE" ] && runuser -u lnmp-memcached -- /bin/kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then exit 0; fi
        exec /usr/local/memcached/bin/memcached -d -l 127.0.0.1 -U 0 -p 11211 -u lnmp-memcached -m 64 -c 1024 -P "$PIDFILE"
        ;;
    stop)
        [ -r "$PIDFILE" ] || exit 0
        PID=$(cat "$PIDFILE")
        case "$PID" in ''|*[!0-9]*) exit 1 ;; esac
        [ "$PID" -gt 1 ] || exit 1
        runuser -u lnmp-memcached -- /bin/kill -0 "$PID" 2>/dev/null || exit 0
        runuser -u lnmp-memcached -- /bin/kill -TERM "$PID" || exit $?
        for Attempt in 1 2 3 4 5; do
            if ! runuser -u lnmp-memcached -- /bin/kill -0 "$PID" 2>/dev/null ||
                { [ -r "/proc/$PID/stat" ] && awk '$3 == "Z" {found=1} END {exit !found}' "/proc/$PID/stat"; }; then
                rm -f "$PIDFILE"
                exit 0
            fi
            sleep 1
        done
        exit 1
        ;;
    restart) "$0" stop && "$0" start ;;
    status) [ -r "$PIDFILE" ] && runuser -u lnmp-memcached -- /bin/kill -0 "$(cat "$PIDFILE")" ;;
    *) echo "Usage: $0 {start|stop|restart|status}" >&2; exit 1 ;;
esac
EOF
    chmod 755 /etc/init.d/memcached || return $?
    if [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/memcached.service <<'EOF' || return $?
[Unit]
Description=LNMP Memcached loopback cache
After=network.target
[Service]
Type=forking
User=lnmp-memcached
Group=lnmp-memcached
PIDFile=/usr/local/memcached/run/memcached.pid
ExecStart=/usr/local/memcached/bin/memcached -d -l 127.0.0.1 -U 0 -p 11211 -m 64 -c 1024 -P /usr/local/memcached/run/memcached.pid
ExecStop=/bin/kill -TERM $MAINPID
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
    fi
}

Install_Memcached()
(
    echo "====== Installing Memcached ======"
    PHP_Extension_Prepare 70000 80599 || return $?
    local ver
    read -r -p "PHP extension: 2=php-memcached, 1=legacy php-memcache (Default 2): " ver || return 1
    case "${ver:-2}" in
        2) ;;
        1) Install_PHPMemcache; return 1 ;;
        *) Echo_Red "Invalid extension selection."; return 1 ;;
    esac
    Press_Start
    Install_PHPMemcached || return $?
    local New_Server=n
    [ -s /usr/local/memcached/bin/memcached ] || New_Server=y
    Build_Memcached_Server || return $?
    if [ "${New_Server}" = y ]; then
        Memcached_Install_Service || return $?
        StartUp memcached || return $?
        StartOrStop start memcached || return $?
    fi
    PHP_Extension_Activate memcached 005-memcached.ini <<'EOF' || return $?
extension = "memcached.so"
EOF
    Echo_Green "====== Memcached install completed ======"
)

Uninstall_Memcached()
{
    echo "You will uninstall Memcached..."
    Press_Start
    rm -f ${PHP_Path}/conf.d/005-memcached.ini
    Restart_PHP
    Remove_StartUp memcached
    echo "Delete Memcached files..."
    rm -rf /usr/local/libmemcached
    rm -rf /usr/local/memcached
    rm -rf /etc/init.d/memcached
    rm -rf /usr/bin/memcached
    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport 11211 -j DROP
        iptables -D INPUT -p udp --dport 11211 -j DROP
        if [ "$PM" = "yum" ]; then
            service iptables save
            service iptables reload
        elif [ "$PM" = "apt" ]; then
            if [ -s /etc/init.d/netfilter-persistent ]; then
                /etc/init.d/netfilter-persistent save
                /etc/init.d/netfilter-persistent reload
            else
                /etc/init.d/iptables-persistent save
                /etc/init.d/iptables-persistent reload
            fi
        fi
    fi
    Echo_Green "Uninstall Memcached completed."
}
