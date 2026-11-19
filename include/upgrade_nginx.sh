#!/usr/bin/env bash

Rollback_Nginx()
{
    if [ "${Nginx_Upgrade_Active}" = "y" ]; then
        cp -p "/usr/local/nginx/sbin/nginx.${Upgrade_Date}" /usr/local/nginx/sbin/nginx.rollback || return 1
        mv -f /usr/local/nginx/sbin/nginx.rollback /usr/local/nginx/sbin/nginx || return 1
        /usr/local/nginx/sbin/nginx -t || return 1
        /etc/init.d/nginx restart || return 1
        Echo_Red "Nginx upgrade failed; the previous binary has been restored."
    fi
    rm -f /usr/local/nginx/sbin/nginx.new
}

Wait_Nginx_Replacement()
{
    local Previous_PID=$1 New_PID Running_Version Attempt
    for ((Attempt=0; Attempt<10; Attempt++)); do
        New_PID=$(cat /usr/local/nginx/logs/nginx.pid 2>/dev/null)
        if [[ "$New_PID" =~ ^[0-9]+$ && "$New_PID" != "$Previous_PID" ]] && kill -0 "$New_PID" 2>/dev/null; then
            Running_Version=$("/proc/${New_PID}/exe" -v 2>&1) || return 1
            [[ "$Running_Version" = "nginx version: nginx/${Nginx_Version}" ]] && return 0
        fi
        sleep 1
    done
    Echo_Red "The target Nginx master process did not become ready."
    return 1
}

Upgrade_Nginx()
{
    local Http3_Option='' Previous_PID
    Nginx_Upgrade_Active=n
    Cur_Nginx_Version=$(/usr/local/nginx/sbin/nginx -v 2>&1 | sed 's/.*nginx\///')
    if [ -s /usr/local/include/jemalloc/jemalloc.h ] && /usr/local/nginx/sbin/nginx -V 2>&1 | grep -qi ljemalloc; then
        NginxMAOpt="--with-ld-opt=-ljemalloc"
    elif [ -s /usr/local/include/gperftools/tcmalloc.h ] && grep -qi google_perftools_profiles /usr/local/nginx/conf/nginx.conf; then
        NginxMAOpt='--with-google_perftools_module'
    else
        NginxMAOpt=''
    fi
    echo "Current Nginx Version: ${Cur_Nginx_Version}"
    read -r -p "Please enter the target Nginx version: " Nginx_Version
    if [[ ! "${Nginx_Version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        Echo_Red "Invalid Nginx version."
        return 1
    fi
    Press_Start
    cd "${cur_dir}/src" || return 1
    Download_Files "https://nginx.org/download/nginx-${Nginx_Version}.tar.gz" "nginx-${Nginx_Version}.tar.gz" || return 1
    Install_Nginx_Openssl || return 1
    Install_Nginx_Lua || return 1
    Install_Pcre || return 1
    Install_Ngx_FancyIndex || return 1
    Tar_Cd "nginx-${Nginx_Version}.tar.gz" "nginx-${Nginx_Version}"
    Get_Dist_Version
    if [[ "${DISTRO}" = "Fedora" && ${Fedora_Version} -ge 28 ]]; then
        patch -p1 < "${cur_dir}/src/patch/nginx-libxcrypt.patch" || return 1
    fi
    Nginx_Ver_Com=$("${cur_dir}/include/version_compare" 1.14.2 "${Nginx_Version}")
    if gcc -dumpversion | grep -q '^8' && [ "${Nginx_Ver_Com}" = "1" ]; then
        patch -p1 < "${cur_dir}/src/patch/nginx-gcc8.patch" || return 1
    fi
    Nginx_Ver_Com=$("${cur_dir}/include/version_compare" 1.25.0 "${Nginx_Version}")
    [ "${Nginx_Ver_Com}" != "1" ] && Http3_Option='--with-http_v3_module'
    Nginx_Ver_Com=$("${cur_dir}/include/version_compare" 1.9.4 "${Nginx_Version}")
    if [[ "${Nginx_Ver_Com}" = "0" || "${Nginx_Ver_Com}" = "1" ]]; then
        ./configure --user=www --group=www --prefix=/usr/local/nginx --with-http_stub_status_module --with-http_ssl_module --with-http_spdy_module --with-http_gzip_static_module --with-ipv6 --with-http_sub_module --with-http_realip_module ${Nginx_With_Openssl} ${Nginx_With_Pcre} ${Nginx_Module_Lua} ${NginxMAOpt} ${Ngx_FancyIndex} ${Nginx_Modules_Options} || return 1
    else
        ./configure --user=www --group=www --prefix=/usr/local/nginx --with-http_stub_status_module --with-http_ssl_module --with-http_v2_module ${Http3_Option} --with-http_gzip_static_module --with-http_sub_module --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module --with-http_realip_module ${Nginx_With_Openssl} ${Nginx_With_Pcre} ${Nginx_Module_Lua} ${NginxMAOpt} ${Ngx_FancyIndex} ${Nginx_Modules_Options} || return 1
    fi
    if ! make -j "$(getconf _NPROCESSORS_ONLN)"; then
        make || return 1
    fi
    # Validate the candidate against the live configuration before changing the executable.
    objs/nginx -t -p /usr/local/nginx/ -c /usr/local/nginx/conf/nginx.conf || return 1
    Previous_PID=$(cat /usr/local/nginx/logs/nginx.pid) || return 1
    [[ "$Previous_PID" =~ ^[0-9]+$ ]] && kill -0 "$Previous_PID" 2>/dev/null || return 1
    [ ! -e "/usr/local/nginx/sbin/nginx.${Upgrade_Date}" ] || return 1
    cp -p /usr/local/nginx/sbin/nginx "/usr/local/nginx/sbin/nginx.${Upgrade_Date}" || return 1
    cp objs/nginx /usr/local/nginx/sbin/nginx.new || return 1
    Nginx_Upgrade_Active=y
    trap 'Rollback_Nginx; exit 130' INT
    trap 'Rollback_Nginx; exit 143' TERM
    if ! mv -f /usr/local/nginx/sbin/nginx.new /usr/local/nginx/sbin/nginx || ! make upgrade; then
        Rollback_Nginx
        trap - INT TERM
        return 1
    fi
    if ! Wait_Nginx_Replacement "$Previous_PID" || ! /usr/local/nginx/sbin/nginx -t || ! /etc/init.d/nginx status; then
        Rollback_Nginx
        trap - INT TERM
        return 1
    fi
    # The old master stays available until the replacement has been verified.
    kill -QUIT "$Previous_PID" || { Rollback_Nginx; trap - INT TERM; return 1; }
    Nginx_Upgrade_Active=n
    trap - INT TERM
    cd "${cur_dir}" || return 1
    rm -rf "${cur_dir}/src/nginx-${Nginx_Version}"
    Echo_Green "======== upgrade nginx completed ======"
    return 0
}
