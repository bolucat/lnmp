#!/usr/bin/env bash

. "$(dirname -- "${BASH_SOURCE[0]}")/php_extension.sh"

Install_Apcu()
(
    echo "====== Installing APCu ======"
    PHP_Extension_Prepare 70000 80599 || return $?
    Press_Start
    PHP_Extension_Fetch "https://pecl.php.net/get/${PHPNewApcu_Ver}.tgz" "${PHPNewApcu_Ver}.tgz" "${PHPNewApcu_Ver}" || return $?
    PHP_Extension_Build apcu || return $?
    PHP_Extension_Activate apcu 009-apcu.ini <<'EOF' || return $?
[apcu]
extension=apcu.so
apc.enabled=1
apc.shm_size=32M
apc.enable_cli=1
EOF
    # Keep the dashboard opt-in; never publish the upstream default password.
    Echo_Green "APCu built successfully. Dashboard source (not published): ${PWD}/apc.php"
    Echo_Green "====== APCu install completed ======"
)

Uninstall_Apcu()
{
    echo "You will uninstall APCu..."
    Press_Start
    rm -f "${PHP_Path}/conf.d/009-apcu.ini" || return $?
    Restart_PHP || return $?
    Echo_Green "Uninstall APCu completed."
}
