#!/usr/bin/env bash

PHP_Extension_Prepare()
{
    local Minimum=$1 Maximum=${2:-80599} Version_ID
    Cur_PHP_Version=$("${PHP_Path}/bin/php-config" --version) || return 1
    if [[ ! "${Cur_PHP_Version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        Echo_Red "Invalid PHP version: ${Cur_PHP_Version}"
        return 1
    fi
    Version_ID=$((10#${BASH_REMATCH[1]} * 10000 + 10#${BASH_REMATCH[2]} * 100 + 10#${BASH_REMATCH[3]}))
    if (( Version_ID < Minimum || Version_ID > Maximum )); then
        Echo_Red "Unsupported PHP ${Cur_PHP_Version} for this extension profile (version ID ${Minimum}-${Maximum})."
        return 1
    fi
    zend_ext_dir=$("${PHP_Path}/bin/php-config" --extension-dir) || return 1
    [[ "${zend_ext_dir}" = /* ]] || return 1
    zend_ext_dir="${zend_ext_dir%/}/"
    PHP_Extension_Module=''
}

PHP_Extension_Fetch()
{
    local URL=$1 Archive=$2 Directory=$3
    [[ "${URL}" = https://* ]] || { Echo_Red "HTTPS source required: ${URL}"; return 1; }
    cd "${cur_dir}/src" || return 1
    Download_Files "${URL}" "${Archive}" || return $?
    Tar_Cd "${Archive}" "${Directory}" || return $?
}

PHP_Extension_Check()
{
    local Module=$1 File=$2
    [ -s "${File}" ] || { Echo_Red "Missing built extension: ${File}"; return 1; }
    "${PHP_Path}/bin/php" -n -d "extension=${File}" -r "exit(extension_loaded('${Module}') ? 0 : 1);" || return $?
}

PHP_Extension_Build()
{
    local Module=$1
    shift
    "${PHP_Path}/bin/phpize" || return $?
    ./configure --with-php-config="${PHP_Path}/bin/php-config" "$@" || return $?
    make || return $?
    # Only promote the runtime module; make install would overwrite the live .so.
    PHP_Extension_Module="${PWD}/modules/${Module}.so"
    PHP_Extension_Check "${Module}" "${PHP_Extension_Module}" || return $?
}

PHP_Extension_Activate()
(
    local Module=$1 Target="${zend_ext_dir}$1.so" Ini="${PHP_Path}/conf.d/$2"
    local Module_New='' Ini_New='' Backup='' Changed=n Committed=n Had_Module=n Had_Ini=n Restart_Attempted=n
    PHP_Extension_Check "${Module}" "${PHP_Extension_Module}" || return $?
    # Keep both backups until activation succeeds, including a failed restart.
    [ ! -L "${Target}" ] && [ ! -L "${Ini}" ] || return 1
    mkdir -p "${zend_ext_dir}" "${PHP_Path}/conf.d" || return 1
    Backup=$(mktemp -d "${TMPDIR:-/tmp}/lnmp-extension.XXXXXX") || return 1
    trap 'exit 1' HUP INT TERM
    trap '
        Status=$?
        Restore_Failed=n
        if [ "${Changed}" = y ] && [ "${Committed}" != y ]; then
            if [ "${Had_Module}" = y ]; then mv -f "${Backup}/module" "${Target}" || Restore_Failed=y; else rm -f "${Target}" || Restore_Failed=y; fi
            if [ "${Had_Ini}" = y ]; then mv -f "${Backup}/ini" "${Ini}" || Restore_Failed=y; else rm -f "${Ini}" || Restore_Failed=y; fi
            if [ "${Restore_Failed}" = n ] && [ "${Restart_Attempted}" = y ]; then
                if ! Restart_PHP; then
                    Echo_Red "Old extension files restored, but PHP service recovery failed. Manual recovery is required."
                fi
            fi
        fi
        [ -z "${Module_New}" ] || rm -f "${Module_New}"
        [ -z "${Ini_New}" ] || rm -f "${Ini_New}"
        if [ "${Restore_Failed}" = y ]; then
            Echo_Red "Rollback failed; recovery files retained at ${Backup}"
            Status=1
        else
            rm -rf "${Backup}"
        fi
        exit "${Status}"
    ' EXIT
    if [ -e "${Target}" ]; then
        [ -f "${Target}" ] || return 1
        cp -p "${Target}" "${Backup}/module" || return 1
        Had_Module=y
    fi
    if [ -e "${Ini}" ]; then
        [ -f "${Ini}" ] || return 1
        cp -p "${Ini}" "${Backup}/ini" || return 1
        Had_Ini=y
    fi
    Module_New=$(mktemp "${Target}.new.XXXXXX") || return 1
    Ini_New=$(mktemp "${Ini}.new.XXXXXX") || return 1
    cp "${PHP_Extension_Module}" "${Module_New}" || return 1
    chmod 755 "${Module_New}" || return 1
    cat > "${Ini_New}" || return 1
    [ -s "${Ini_New}" ] || return 1
    chmod 644 "${Ini_New}" || return 1
    Changed=y
    mv -f "${Module_New}" "${Target}" || return 1
    mv -f "${Ini_New}" "${Ini}" || return 1
    Restart_Attempted=y
    Restart_PHP || return $?
    Committed=y
)
