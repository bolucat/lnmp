#!/usr/bin/env bash

. "$(dirname -- "${BASH_SOURCE[0]}")/php_extension.sh"

Build_Redis_Server()
(
    if [ -s /usr/local/redis/bin/redis-server ]; then
        echo "Existing Redis server and configuration preserved."
        return 0
    fi
    if [ -e /usr/local/redis ]; then
        Echo_Red "Incomplete Redis prefix; refusing to overwrite existing files."
        return 1
    fi
    PHP_Extension_Fetch "https://download.redis.io/releases/${Redis_Stable_Ver}.tar.gz" "${Redis_Stable_Ver}.tar.gz" "${Redis_Stable_Ver}" || return $?
    # Redis 8 detects ARM atomic linkage itself. Build only the core server.
    make BUILD_WITH_MODULES=no || return $?
    make BUILD_WITH_MODULES=no PREFIX=/usr/local/redis install || return $?
    [ -s /usr/local/redis/bin/redis-server ] || return 1
    /usr/local/redis/bin/redis-server --version || return $?
    mkdir -p /usr/local/redis/etc || return $?
    cp redis.conf /usr/local/redis/etc/redis.conf || return $?
    sed -i -e 's/^daemonize no/daemonize yes/' \
        -e 's/^bind .*/bind 127.0.0.1/' \
        -e 's/^protected-mode .*/protected-mode yes/' \
        -e 's#^dir .*#dir /usr/local/redis/data#' \
        -e 's#^pidfile .*#pidfile /usr/local/redis/run/redis.pid#' /usr/local/redis/etc/redis.conf || return $?
    grep -Eq '^bind 127[.]0[.]0[.]1$' /usr/local/redis/etc/redis.conf || return 1
    grep -Eq '^protected-mode yes$' /usr/local/redis/etc/redis.conf || return 1
)

Redis_Install_Service()
{
    if [ -e /etc/init.d/redis ] || [ -L /etc/init.d/redis ] ||
        [ -e /etc/systemd/system/redis.service ] || [ -L /etc/systemd/system/redis.service ]; then
        Echo_Red "Existing Redis service files found; refusing to overwrite them."
        return 1
    fi
    command -v runuser >/dev/null || return 1
    if ! id lnmp-redis >/dev/null 2>&1; then
        useradd -r -U -M -s /bin/false lnmp-redis || return $?
    fi
    [ "$(id -u lnmp-redis)" != 0 ] || return 1
    mkdir -p /usr/local/redis/data /usr/local/redis/run || return $?
    chown lnmp-redis:lnmp-redis /usr/local/redis/data /usr/local/redis/run || return $?
    chmod 750 /usr/local/redis/data /usr/local/redis/run || return $?
    cat > /etc/init.d/redis <<'EOF' || return $?
#!/bin/sh
# chkconfig: 2345 80 90
# description: LNMP Redis loopback cache
### BEGIN INIT INFO
# Provides: redis
# Required-Start: $local_fs $network
# Required-Stop: $local_fs $network
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: LNMP Redis loopback cache
### END INIT INFO
PIDFILE=/usr/local/redis/run/redis.pid
case "$1" in
    start)
        if [ -r "$PIDFILE" ] && runuser -u lnmp-redis -- /bin/kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then exit 0; fi
        exec runuser -u lnmp-redis -- /usr/local/redis/bin/redis-server /usr/local/redis/etc/redis.conf
        ;;
    stop)
        [ -r "$PIDFILE" ] || exit 0
        exec runuser -u lnmp-redis -- /usr/local/redis/bin/redis-cli -h 127.0.0.1 -p 6379 shutdown
        ;;
    restart) "$0" stop && "$0" start ;;
    status) [ -r "$PIDFILE" ] && runuser -u lnmp-redis -- /bin/kill -0 "$(cat "$PIDFILE")" ;;
    *) echo "Usage: $0 {start|stop|restart|status}" >&2; exit 1 ;;
esac
EOF
    chmod 755 /etc/init.d/redis || return $?
    if [ -d /etc/systemd/system ]; then
        cat > /etc/systemd/system/redis.service <<'EOF' || return $?
[Unit]
Description=LNMP Redis loopback cache
After=network.target
[Service]
Type=forking
User=lnmp-redis
Group=lnmp-redis
PIDFile=/usr/local/redis/run/redis.pid
ExecStart=/usr/local/redis/bin/redis-server /usr/local/redis/etc/redis.conf
ExecStop=/usr/local/redis/bin/redis-cli -h 127.0.0.1 -p 6379 shutdown
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
    fi
}

Install_Redis()
(
    echo "====== Installing Redis ======"
    PHP_Extension_Prepare 70400 80599 || return $?
    Press_Start
    PHP_Extension_Fetch "https://pecl.php.net/get/${PHPRedis_Ver}.tgz" "${PHPRedis_Ver}.tgz" "${PHPRedis_Ver}" || return $?
    PHP_Extension_Build redis || return $?
    local New_Server=n
    [ -s /usr/local/redis/bin/redis-server ] || New_Server=y
    Build_Redis_Server || return $?
    if [ "${New_Server}" = y ]; then
        Redis_Install_Service || return $?
        StartUp redis || return $?
        StartOrStop start redis || return $?
    fi
    PHP_Extension_Activate redis 007-redis.ini <<'EOF' || return $?
extension = "redis.so"
EOF
    Echo_Green "====== Redis install completed ======"
)

Uninstall_Redis()
{
    echo "You will uninstall Redis..."
    Press_Start
    rm -f ${PHP_Path}/conf.d/007-redis.ini
    Restart_PHP
    Remove_StartUp redis
    echo "Delete Redis files..."
    rm -rf /usr/local/redis
    rm -rf /etc/init.d/redis
    if command -v iptables >/dev/null 2>&1; then
        iptables -D INPUT -p tcp --dport 6379 -j DROP
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
    Echo_Green "Uninstall Redis completed."
}
