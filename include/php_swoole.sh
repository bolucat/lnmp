#!/usr/bin/env bash

. "$(dirname -- "${BASH_SOURCE[0]}")/php_extension.sh"

PHP_Swoole_Dependencies()
{
    if [ "${PM}" = apt ]; then
        apt-get install -y g++ autoconf make pkg-config libssl-dev zlib1g-dev || return $?
    elif [ "${PM}" = yum ]; then
        yum install -y gcc-c++ autoconf make pkgconfig openssl-devel zlib-devel || return $?
    else
        Echo_Red "Unsupported package manager for Swoole dependencies."
        return 1
    fi
}

Install_PHP_Swoole()
(
    echo "====== Installing PHP Swoole ======"
    PHP_Extension_Prepare 80200 80599 || return $?
    Press_Start
    PHP_Swoole_Dependencies || return $?
    PHP_Extension_Fetch "https://pecl.php.net/get/${PHPSwoole_Ver}.tgz" "${PHPSwoole_Ver}.tgz" "${PHPSwoole_Ver}" || return $?
    # Swoole 6.2 has built-in JSON/HTTP2 and discovers OpenSSL via pkg-config.
    PHP_Extension_Build swoole --enable-swoole --disable-brotli || return $?
    PHP_Extension_Activate swoole 009-swoole.ini <<'EOF' || return $?
extension = "swoole.so"
EOF
    Echo_Green "====== PHP Swoole install completed ======"
)

Uninstall_PHP_Swoole()
{
    echo "You will uninstall PHP Swoole..."
    Press_Start
    rm -f "${PHP_Path}/conf.d/009-swoole.ini" || return $?
    Restart_PHP || return $?
    Echo_Green "Uninstall PHP Swoole completed."
}
