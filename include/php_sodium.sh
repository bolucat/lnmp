#!/usr/bin/env bash

. "$(dirname -- "${BASH_SOURCE[0]}")/php_extension.sh"

PHP_Sodium_Dependencies()
{
    if [ "${PM}" = apt ]; then
        apt-get install -y libsodium-dev pkg-config || return $?
    elif [ "${PM}" = yum ]; then
        yum install -y libsodium-devel pkgconfig || return $?
    else
        Echo_Red "Unsupported package manager for Sodium dependencies."
        return 1
    fi
}

Install_PHP_Sodium()
(
    echo "====== Installing PHP Sodium ======"
    PHP_Extension_Prepare 70200 80599 || return $?
    if "${PHP_Path}/bin/php" -r 'exit(extension_loaded("sodium") ? 0 : 1);'; then
        Echo_Green "PHP Sodium is already loaded; leaving the installation unchanged."
        return 0
    fi
    Press_Start
    PHP_Sodium_Dependencies || return $?
    # Since PHP 7.2 sodium is bundled. Use the selected PHP's exact source.
    PHP_Extension_Fetch "https://www.php.net/distributions/php-${Cur_PHP_Version}.tar.bz2" "php-${Cur_PHP_Version}.tar.bz2" "php-${Cur_PHP_Version}/ext/sodium" || return $?
    PHP_Extension_Build sodium --with-sodium || return $?
    PHP_Extension_Activate sodium 009-sodium.ini <<'EOF' || return $?
extension = "sodium.so"
EOF
    Echo_Green "====== PHP Sodium install completed ======"
)

Uninstall_PHP_Sodium()
{
    echo "You will uninstall PHP Sodium..."
    Press_Start
    rm -f "${PHP_Path}/conf.d/009-sodium.ini" || return $?
    Restart_PHP || return $?
    Echo_Green "Uninstall PHP Sodium completed."
}
