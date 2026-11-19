#!/usr/bin/env bash

PHP_Imap_Dependencies()
{
    if [ "$PM" = "apt" ]; then
        apt-get install -y libc-client-dev libkrb5-dev || return 1
    elif [ "$PM" = "yum" ]; then
        yum -y install libc-client-devel krb5-devel uw-imap-devel || return 1
    else
        Echo_Red "Unsupported package manager for IMAP dependencies."
        return 1
    fi
}

Build_PHP_Imap()
{
    local Target_PHP=$1 Target_Version=$2 Extension_Dir Source_Dir Source_File
    PHP_Imap_Dependencies || return 1
    cd "${cur_dir}/src" || return 1
    if [ "$("${cur_dir}/include/version_compare" 8.4.0 "${Target_Version}")" != "1" ]; then
        Source_Dir="imap-${PHPImap_Ver}"
        Source_File="${Source_Dir}.tgz"
        Download_Files "https://pecl.php.net/get/${Source_File}" "${Source_File}" || return 1
        Tar_Cd "${Source_File}" "${Source_Dir}"
    else
        Download_PHP_Src || return 1
        Tar_Cd "php-${Target_Version}.tar.bz2" "php-${Target_Version}/ext/imap"
    fi
    "${Target_PHP}/bin/phpize" || return 1
    ./configure --with-php-config="${Target_PHP}/bin/php-config" --with-imap --with-imap-ssl --with-kerberos || return 1
    make -j "$(getconf _NPROCESSORS_ONLN)" || return 1
    make install || return 1
    Extension_Dir=$("${Target_PHP}/bin/php-config" --extension-dir) || return 1
    "${Target_PHP}/bin/php" -n -d "extension=${Extension_Dir}/imap.so" --ri imap >/dev/null || return 1
    mkdir -p "${Target_PHP}/conf.d" || return 1
    printf 'extension = "imap.so"\n' > "${Target_PHP}/conf.d/009-imap.ini" || return 1
    cd "${cur_dir}/src" || return 1
    return 0
}

Install_PHP_Imap()
{
    Echo_Blue "====== Installing PHP Imap ======"
    Press_Start
    Addons_Get_PHP_Ext_Dir
    if "${PHP_Path}/bin/php" -m | grep -qi '^imap$'; then
        Echo_Red "PHP Module 'imap' already loaded!"
        return 1
    fi
    Build_PHP_Imap "${PHP_Path}" "${Cur_PHP_Version}" || return 1
    Restart_PHP || return 1
    Echo_Green "====== PHP Imap install completed ======"
}

Uninstall_PHP_Imap()
{
    echo "You will uninstall PHP Imap..."
    Press_Start
    rm -f "${PHP_Path}/conf.d/009-imap.ini"
    Restart_PHP
    Echo_Green "Uninstall PHP Imap completed."
}
