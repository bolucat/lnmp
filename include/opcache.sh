#!/usr/bin/env bash

Install_Old_Opcache()
{
    cd ${cur_dir}/src

    if [ -d "${ZendOpcache_Ver}" ]; then
        rm -rf "${ZendOpcache_Ver}"
    fi

    Download_Files ${Download_Mirror}/web/opcache/${ZendOpcache_Ver}.tgz ${ZendOpcache_Ver}.tgz
    Tar_Cd ${ZendOpcache_Ver}.tgz ${ZendOpcache_Ver}
    ${PHP_Path}/bin/phpize
    ./configure --with-php-config=${PHP_Path}/bin/php-config
    make
    make install
    cd ../
}

PHP85_Migrate_Opcache_Ini()
{
    local Ini=$1 Pending
    [ ! -L "$Ini" ] || return 1
    [ -e "$Ini" ] || return 0
    [ -f "$Ini" ] || return 1
    Pending=$(mktemp "${Ini}.migrate.XXXXXX") || return 1
    # Only remove the old loader from LNMP's owned configuration, preserving tuning.
    if ! sed -E '/^[[:space:]]*zend_extension[[:space:]]*=[[:space:]]*"?([^";]*\/)?opcache(\.so)?"?[[:space:]]*(;.*)?$/d' "$Ini" > "$Pending" ||
       ! chmod 644 "$Pending" || ! mv -f "$Pending" "$Ini"; then
        rm -f "$Pending"
        return 1
    fi
}

Configure_Builtin_Opcache()
(
    local Enabled=$1 Ini="${PHP_Path}/conf.d/004-opcache.ini"
    local Pending='' Backup='' Had=n Changed=n Restarted=n Committed=n Output
    [[ "$Enabled" = 0 || "$Enabled" = 1 ]] || return 1
    [ ! -L "${PHP_Path}/conf.d" ] && [ ! -L "$Ini" ] || return 1
    "${PHP_Path}/bin/php" -n -r 'exit(extension_loaded("Zend OPcache") ? 0 : 1);' || return 1
    mkdir -p "${PHP_Path}/conf.d" || return 1
    Backup=$(mktemp "${Ini}.backup.XXXXXX") || return 1
    Pending=$(mktemp "${Ini}.new.XXXXXX") || { rm -f "$Backup"; return 1; }
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    trap '
        Status=$?
        if [ "$Changed" = y ] && [ "$Committed" != y ]; then
            if [ "$Had" = y ]; then
                cp -p "$Backup" "$Ini" || { echo "OPcache recovery failed; backup retained: $Backup" >&2; exit 1; }
            else
                rm -f "$Ini" || exit 1
            fi
            if [ "$Restarted" = y ]; then
                Restart_PHP || echo "OPcache configuration restored; PHP service recovery needs attention." >&2
            fi
        fi
        rm -f "$Pending" "$Backup"
        exit "$Status"
    ' EXIT
    if [ -e "$Ini" ]; then
        [ -f "$Ini" ] || return 1
        cp -p "$Ini" "$Backup" || return 1
        Had=y
    fi
    # PHP 8.5 embeds OPcache: no shared object or zend_extension directive.
    printf '%s\n' '[Zend Opcache]' "opcache.enable=$Enabled" "opcache.enable_cli=$Enabled" \
        'opcache.memory_consumption=128' 'opcache.interned_strings_buffer=8' \
        'opcache.max_accelerated_files=4000' 'opcache.revalidate_freq=60' > "$Pending" || return 1
    PHP_INI_SCAN_DIR='' "${PHP_Path}/bin/php" -c "$Pending" -r \
        "exit(extension_loaded('Zend OPcache') && (int)ini_get('opcache.enable') === $Enabled && (int)ini_get('opcache.enable_cli') === $Enabled ? 0 : 1);" || return 1
    chmod 644 "$Pending" || return 1
    Changed=y
    mv -f "$Pending" "$Ini" || return 1
    Output=$(LC_ALL=C "${PHP_Path}/bin/php" -m 2>&1) || return 1
    if printf '%s\n' "$Output" | grep -Eq 'PHP (Startup:|Warning|Fatal error)|Unable to load|Cannot load|already loaded'; then
        Echo_Red "PHP startup warnings; check other ini files for obsolete OPcache loaders."
        return 1
    fi
    Restarted=y
    Restart_PHP || return 1
    Committed=y
    Echo_Green "Built-in OPcache configured (enabled=$Enabled)."
)

Install_Opcache()
{
    Cur_PHP_Version=$("${PHP_Path}/bin/php-config" --version) || return 1
    if [[ "$Cur_PHP_Version" =~ ^8\.5\.[0-9]+$ ]]; then
        Press_Start
        Configure_Builtin_Opcache 1
        return $?
    fi

    Echo_Red "Install Opcache will auto uninstall eAccelerator if exists..."
    echo "====== Installing zend opcache ======"
    Press_Start

    echo "Uninstall eAccelerator..."
    rm -f ${PHP_Path}/conf.d/004-opcache.ini

    Addons_Get_PHP_Ext_Dir
    zend_ext="${zend_ext_dir}opcache.so"
    if echo "${Cur_PHP_Version}" | grep -Eqi '^5.[234].'; then
        if [ -s "${zend_ext}" ]; then
            rm -f "${zend_ext}"
        fi
    fi

    if echo "${Cur_PHP_Version}" | grep -Eqi '^5.2.'; then
        echo "Zend Opcache do NOT SUPPORT PHP 5.2.* and lower version of php 5.3"
        sleep 1
        exit 1
    elif echo "${Cur_PHP_Version}" | grep -Eqi '^5.3.'; then
        if echo ${Cur_PHP_Version} | grep -vEqi '^5.3.2[0-9]';then
            echo "If PHP under version 5.3.20, we do not recommend install opcache, it maybe cause 502 Bad Gateway error!"
            sleep 3
            exit 1
        fi
        Install_Old_Opcache
    elif echo "${Cur_PHP_Version}" | grep -Eqi '^5.4.'; then
        echo "${Cur_PHP_Version}"
        Install_Old_Opcache
    elif echo "${Cur_PHP_Version}" | grep -Eqi '^5.[56].' || echo "${Cur_PHP_Version}" | grep -Eqi '^7.'; then
        cat >${PHP_Path}/conf.d/004-opcache.ini<<EOF
[Zend Opcache]
zend_extension="opcache.so"
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
opcache.enable_cli=1
EOF
    elif echo "${Cur_PHP_Version}" | grep -Eqi '^8.'; then
        cat >${PHP_Path}/conf.d/004-opcache.ini<<EOF
[Zend Opcache]
zend_extension="opcache.so"
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=4000
opcache.revalidate_freq=60
opcache.fast_shutdown=1
opcache.enable_cli=1

opcache.jit = 1255
opcache.jit_buffer_size = 64M
EOF

    else
        echo "Error: can't get php version!"
        echo "Maybe php was didn't install or php configuration file has errors.Please check."
        sleep 3
        exit 1
    fi

    echo "Copy Opcache Control Panel..."
    \cp ${cur_dir}/conf/ocp.php ${Default_Website_Dir}/ocp.php
    Restart_PHP
    if [ -s "${zend_ext}" ]; then
        Echo_Green "====== Opcache install completed ======"
        Echo_Green "Opcache installed successfully, enjoy it!"
        exit 0
    else
        rm -f ${PHP_Path}/conf.d/004-opcache.ini
        Echo_Red "OPcache install failed!"
        exit 1
    fi
}

Uninstall_Opcache()
{
    Cur_PHP_Version=$("${PHP_Path}/bin/php-config" --version) || return 1
    if [[ "$Cur_PHP_Version" =~ ^8\.5\.[0-9]+$ ]]; then
        Press_Start
        Configure_Builtin_Opcache 0
        return $?
    fi
    echo "You will uninstall opcache..."
    Press_Start
    rm -f ${PHP_Path}/conf.d/004-opcache.ini
    Restart_PHP
    Echo_Green "Uninstall Opcache completed."
}
