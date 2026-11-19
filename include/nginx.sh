#!/usr/bin/env bash

Install_Nginx_Openssl()
{
    Nginx_With_Openssl=''
    if [ "${Enable_Nginx_Openssl}" = 'y' ]; then
        if [ ! -n "${Nginx_Version}" ]; then
            Nginx_Version=$(echo ${Nginx_Ver} | sed "s/nginx-//")
        fi
        Nginx_Ver_Com=$(${cur_dir}/include/version_compare 1.13.0 ${Nginx_Version})
        if [[ "${Nginx_Ver_Com}" == "0" ||  "${Nginx_Ver_Com}" == "1" ]]; then
            Download_Files "${Download_Mirror}/lib/openssl/${Openssl_Ver}.tar.gz" "${Openssl_Ver}.tar.gz" || return 1
            Tar_Cd "${Openssl_Ver}.tar.gz" "$Openssl_Ver" || return 1
            cd "${cur_dir}/src" || return 1
            Nginx_With_Openssl="--with-openssl=${cur_dir}/src/${Openssl_Ver}"
        else
            if [[ "${Openssl_New_Ver}" = openssl-3.* ]] && ! perl -MIPC::Cmd -e 1 >/dev/null 2>&1; then
                Echo_Red 'OpenSSL 3 source builds require Perl IPC::Cmd; install the distribution Perl build dependencies first.'
                return 1
            fi
            Download_Files ${Download_Mirror}/lib/openssl/${Openssl_New_Ver}.tar.gz ${Openssl_New_Ver}.tar.gz
            if [ $? -ne 0 ]; then
                Download_Files https://www.openssl.org/source/${Openssl_New_Ver}.tar.gz ${Openssl_New_Ver}.tar.gz
                if [ $? -ne 0 ]; then
                    Echo_Red "Error! Unable to download ${Openssl_New_Ver}."
                    exit 1
                fi
            fi
            Tar_Cd "${Openssl_New_Ver}.tar.gz" "$Openssl_New_Ver" || return 1
            cd "${cur_dir}/src" || return 1
            Nginx_With_Openssl="--with-openssl=${cur_dir}/src/${Openssl_New_Ver}"
        fi
    fi
}

Check_Nginx_Lua_Compatibility()
{
    local Target_Nginx=${Nginx_Version:-${Nginx_Ver#nginx-}}
    [ "${Enable_Nginx_Lua}" = 'y' ] || return 0
    # resty.core checks ngx_lua's exact FFI ABI, not a minimum version.
    case "${LuaNginxModule}:${LuaRestyCore}" in
        lua-nginx-module-0.10.26:lua-resty-core-0.1.28|lua-nginx-module-0.10.29:lua-resty-core-0.1.32) ;;
        *)
            Echo_Red 'Unsupported Lua FFI pair. Use lua-nginx-module-0.10.29 with lua-resty-core-0.1.32, or retain a supported historical pair. RC dependencies are not supported.'
            return 1
            ;;
    esac
    if [ "$("${cur_dir}/include/version_compare" 1.29.0 "$Target_Nginx")" != '1' ]; then
        if [[ "$LuaNginxModule" != 'lua-nginx-module-0.10.29' || "$Luajit_Ver" != 'luajit2-2.1-20260415' || "$LuaRestyLrucache" != 'lua-resty-lrucache-0.15' || "$NgxDevelKit" != 'ngx_devel_kit-0.3.4' ]]; then
            Echo_Red 'Nginx >= 1.29 with Lua requires the stable LNMP PCRE2 bundle: ngx_lua 0.10.29, resty-core 0.1.32, LuaJIT 2.1-20260415, lrucache 0.15, NDK 0.3.4. Lua will not be silently disabled or forced to PCRE1.'
            return 1
        fi
        Echo_Blue 'Standalone Nginx Lua: HTTP Lua/PCRE2 supported; OpenResty-only Nginx patches and yieldable TLS/QUIC hooks are not supplied.'
    fi
}

Install_Nginx_Lua()
{
    local Build_Jobs
    Nginx_Module_Lua=''
    if [ "${Enable_Nginx_Lua}" = 'y' ]; then
        Check_Nginx_Lua_Compatibility || return 1
        Build_Jobs=$(LNMP_Get_Build_Jobs) || return 1
        echo "Installing Lua for Nginx..."
        cd "${cur_dir}/src" || return 1
        Download_Files "${Download_Mirror}/lib/lua/${Luajit_Ver}.tar.gz" "${Luajit_Ver}.tar.gz" || return 1
        Download_Files "${Download_Mirror}/lib/lua/${LuaNginxModule}.tar.gz" "${LuaNginxModule}.tar.gz" || return 1
        Download_Files "${Download_Mirror}/lib/lua/${NgxDevelKit}.tar.gz" "${NgxDevelKit}.tar.gz" || return 1
        Download_Files "${Download_Mirror}/lib/lua/${LuaRestyCore}.tar.gz" "${LuaRestyCore}.tar.gz" || return 1
        Download_Files "${Download_Mirror}/lib/lua/${LuaRestyLrucache}.tar.gz" "${LuaRestyLrucache}.tar.gz" || return 1

        Echo_Blue "[+] Installing ${Luajit_Ver}... "
        Tar_Cd "${LuaNginxModule}.tar.gz" "$LuaNginxModule" || return 1
        if [[ "${Pcre_Ver}" = pcre2-* ]] && ! grep -q NGX_PCRE2 src/ngx_http_lua_regex.c; then
            Echo_Red 'This Lua module source has no PCRE2 implementation; refusing an implicit PCRE1 fallback.'
            return 1
        fi
        Tar_Cd "${NgxDevelKit}.tar.gz" "$NgxDevelKit" || return 1
        Tar_Cd "${Luajit_Ver}.tar.gz" "$Luajit_Ver" || return 1
        make -j "$Build_Jobs" || return 1
        make -j1 install PREFIX=/usr/local/luajit || return 1
        cd ${cur_dir}/src
        rm -rf ${cur_dir}/src/${Luajit_Ver}

        cat > /etc/ld.so.conf.d/luajit.conf<<EOF
/usr/local/luajit/lib
EOF
        ldconfig || return 1

        cat >/etc/profile.d/luajit.sh<<EOF
export LUAJIT_LIB=/usr/local/luajit/lib
export LUAJIT_INC=/usr/local/luajit/include/luajit-2.1
EOF

        source /etc/profile.d/luajit.sh || return 1

        Tar_Cd "${LuaRestyCore}.tar.gz" "$LuaRestyCore" || return 1
        make install PREFIX=/usr/local/nginx || return 1
        Tar_Cd "${LuaRestyLrucache}.tar.gz" "$LuaRestyLrucache" || return 1
        make install PREFIX=/usr/local/nginx || return 1
        cd "${cur_dir}/src" || return 1

        Nginx_Module_Lua="--with-ld-opt=-Wl,-rpath,/usr/local/luajit/lib --add-module=${cur_dir}/src/${NgxDevelKit} --add-module=${cur_dir}/src/${LuaNginxModule}"
    fi
}

Install_Ngx_FancyIndex()
{
    Ngx_FancyIndex=''
    if [ "${Enable_Ngx_FancyIndex}" = 'y' ]; then
        echo "Installing Ngx FancyIndex for Nginx..."
        cd "${cur_dir}/src" || return 1
        Download_Files "${Download_Mirror}/web/nginx/${NgxFancyIndex_Ver}.tar.xz" "${NgxFancyIndex_Ver}.tar.xz" || return 1

        Tar_Cd "${NgxFancyIndex_Ver}.tar.xz" "$NgxFancyIndex_Ver" || return 1
        Ngx_FancyIndex="--add-module=${cur_dir}/src/${NgxFancyIndex_Ver}"
        cd "${cur_dir}/src" || return 1
    fi
}

Install_Nginx()
{
    local Http3_Option=''
    Nginx_Version=${Nginx_Version:-${Nginx_Ver#nginx-}}
    Check_Nginx_Lua_Compatibility || exit 1
    Install_Pcre || exit 1
    Echo_Blue "[+] Installing ${Nginx_Ver}... "
    groupadd www
    useradd -s /sbin/nologin -g www www

    cd ${cur_dir}/src
    Install_Nginx_Openssl || exit 1
    Install_Nginx_Lua || exit 1
    Install_Ngx_FancyIndex || exit 1
    Tar_Cd ${Nginx_Ver}.tar.gz ${Nginx_Ver}
    if [[ "${DISTRO}" = "Fedora" && ${Fedora_Version} -ge 28 ]]; then
        patch -p1 < ${cur_dir}/src/patch/nginx-libxcrypt.patch || exit 1
    fi
    Nginx_Ver_Com=$(${cur_dir}/include/version_compare 1.14.2 ${Nginx_Version})
    if gcc -dumpversion|grep -q "^[8]" && [ "${Nginx_Ver_Com}" == "1" ]; then
        patch -p1 < ${cur_dir}/src/patch/nginx-gcc8.patch || exit 1
    fi
    Nginx_Ver_Com=$(${cur_dir}/include/version_compare 1.25.0 ${Nginx_Version})
    [ "${Nginx_Ver_Com}" != '1' ] && Http3_Option='--with-http_v3_module'
    Nginx_Ver_Com=$(${cur_dir}/include/version_compare 1.9.4 ${Nginx_Version})
    if [[ "${Nginx_Ver_Com}" == "0" ||  "${Nginx_Ver_Com}" == "1" ]]; then
        ./configure --user=www --group=www --prefix=/usr/local/nginx --with-http_stub_status_module --with-http_ssl_module --with-http_spdy_module --with-http_gzip_static_module --with-ipv6 --with-http_sub_module --with-http_realip_module ${Nginx_With_Openssl} ${Nginx_With_Pcre} ${Nginx_Module_Lua} ${NginxMAOpt} ${Ngx_FancyIndex} ${Nginx_Modules_Options} || exit 1
    else
        ./configure --user=www --group=www --prefix=/usr/local/nginx --with-http_stub_status_module --with-http_ssl_module --with-http_v2_module ${Http3_Option} --with-http_gzip_static_module --with-http_sub_module --with-stream --with-stream_ssl_module --with-stream_ssl_preread_module --with-http_realip_module ${Nginx_With_Openssl} ${Nginx_With_Pcre} ${Nginx_Module_Lua} ${NginxMAOpt} ${Ngx_FancyIndex} ${Nginx_Modules_Options} || exit 1
    fi
    Make_Install
    cd ../

    ln -sf /usr/local/nginx/sbin/nginx /usr/bin/nginx

    rm -f /usr/local/nginx/conf/nginx.conf
    cd ${cur_dir}
    if [ "${Stack}" = "lnmpa" ]; then
        \cp conf/nginx_a.conf /usr/local/nginx/conf/nginx.conf
        \cp conf/proxy.conf /usr/local/nginx/conf/proxy.conf
        \cp conf/proxy-pass-php.conf /usr/local/nginx/conf/proxy-pass-php.conf
    else
        \cp conf/nginx.conf /usr/local/nginx/conf/nginx.conf
    fi
    \cp -ra conf/rewrite /usr/local/nginx/conf/
    \cp conf/pathinfo.conf /usr/local/nginx/conf/pathinfo.conf
    \cp conf/enable-php.conf /usr/local/nginx/conf/enable-php.conf
    \cp conf/enable-php-pathinfo.conf /usr/local/nginx/conf/enable-php-pathinfo.conf
    \cp -ra conf/example /usr/local/nginx/conf/example
    if [ "${Enable_Nginx_Lua}" = 'y' ]; then
        if ! grep -q 'lua_package_path' /usr/local/nginx/conf/nginx.conf; then
            sed -i "/server_tokens off;/i\        lua_package_path \"/usr/local/nginx/lib/lua/?.lua;;\";\n" /usr/local/nginx/conf/nginx.conf
        fi
        if [ "${Stack}" = "lnmp" ]; then
            sed -i "/include enable-php.conf;/i\        location /lua\n        {\n            default_type text/html;\n            content_by_lua 'ngx.say\(\"hello world\"\)';\n        }\n" /usr/local/nginx/conf/nginx.conf
        else
            sed -i "/include proxy-pass-php.conf;/i\        location /lua\n        {\n            default_type text/html;\n            content_by_lua 'ngx.say\(\"hello world\"\)';\n        }\n" /usr/local/nginx/conf/nginx.conf
        fi
    fi
    if [ "${isWSL}" = "y" ]; then
        sed -i "/gzip on;/i\        fastcgi_buffering off;\n" /usr/local/nginx/conf/nginx.conf
    fi

    mkdir -p ${Default_Website_Dir}
    chmod +w ${Default_Website_Dir}
    mkdir -p /home/wwwlogs
    chmod 750 /home/wwwlogs

    chown -R www:www ${Default_Website_Dir}

    mkdir /usr/local/nginx/conf/vhost

    if [ "${Default_Website_Dir}" != "/home/wwwroot/default" ]; then
        sed -i "s#/home/wwwroot/default#${Default_Website_Dir}#g" /usr/local/nginx/conf/nginx.conf
    fi

    if [ "${Stack}" = "lnmp" ]; then
        cat >${Default_Website_Dir}/.user.ini<<EOF
open_basedir=${Default_Website_Dir}:/tmp/:/proc/
EOF
        chmod 644 ${Default_Website_Dir}/.user.ini
        chattr +i ${Default_Website_Dir}/.user.ini
        cat >>/usr/local/nginx/conf/fastcgi.conf<<EOF
fastcgi_param PHP_ADMIN_VALUE "open_basedir=\$document_root/:/tmp/:/proc/";
EOF
    fi

    \cp init.d/init.d.nginx /etc/init.d/nginx
    \cp init.d/nginx.service /etc/systemd/system/nginx.service
    chmod +x /etc/init.d/nginx

    if [ "${SelectMalloc}" = "3" ]; then
        mkdir /tmp/tcmalloc
        chown -R www:www /tmp/tcmalloc
        sed -i '/nginx.pid/a\
google_perftools_profiles /tmp/tcmalloc;' /usr/local/nginx/conf/nginx.conf
    fi

    if [ "${Stack}" != "lamp" ]; then
        uname_r=$(uname -r)
        if echo $uname_r|grep -Eq "^3\.(9|1[0-9])*|^[4-9]\.*"; then
            echo "3.9+";
            sed -i 's/listen 80 default_server;/listen 80 default_server reuseport;/g' /usr/local/nginx/conf/nginx.conf
        fi
    fi
}
