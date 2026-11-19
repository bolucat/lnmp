#!/usr/bin/env bash

Nginx_Dependent()
{
    local packages
    if [ "$PM" = "yum" ]; then
        for packages in make gcc gcc-c++ wget ca-certificates crontabs zlib zlib-devel openssl openssl-devel perl perl-IPC-Cmd patch tar bzip2 initscripts xz gzip;
        do yum -y install "$packages" || return 1; done
        if [ "${DISTRO}" = "Fedora" ] || echo "${CentOS_Version}" | grep -Eqi "^9"; then
            dnf install chkconfig -y || return 1
        fi
    elif [ "$PM" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y || apt-get update --allow-releaseinfo-change -y || return 1
        for packages in debian-keyring debian-archive-keyring build-essential gcc g++ make autoconf automake wget ca-certificates cron openssl libssl-dev zlib1g zlib1g-dev perl patch tar bzip2 xz-utils gzip;
        do apt-get --no-install-recommends install -y "$packages" || return 1; done
    else
        Echo_Red "Unsupported package manager: ${PM}"
        return 1
    fi
    return 0
}

Install_Only_Nginx()
{
    local Stack=nginx Source_Version
    Check_Fresh_Install_Targets || return 1
    clear
    echo "+-----------------------------------------------------------------------+"
    echo "|              Install Nginx for LNMP, Written by Licess                |"
    echo "+-----------------------------------------------------------------------+"
    echo "|                     A tool to only install Nginx.                     |"
    echo "+-----------------------------------------------------------------------+"
    echo "|           For more information please visit https://lnmp.org          |"
    echo "+-----------------------------------------------------------------------+"
    Press_Install || return 1
    Echo_Blue "Install dependent packages..."
    cd "${cur_dir}/src" || return 1
    Get_Dist_Version || return 1
    Modify_Source || return 1
    Nginx_Dependent || return 1
    cd "${cur_dir}/src" || return 1
    Install_Pcre || return 1
    if ! grep -q '^/usr/local/lib$' /etc/ld.so.conf; then
        echo "/usr/local/lib" >> /etc/ld.so.conf || return 1
    fi
    ldconfig || return 1
    Download_Files "${Download_Mirror}/web/nginx/${Nginx_Ver}.tar.gz" "${Nginx_Ver}.tar.gz" || return 1
    Install_Nginx || return 1
    StartUp nginx || return 1
    StartOrStop start nginx || return 1
    Check_Nginx_Files || return 1
    [[ "${isNginx}" = ok ]] || return 1
    for Source_Version in "$Nginx_Ver" "$Openssl_Ver" "$Openssl_Compat_Ver" "$Openssl_New_Ver"; do
        [ -n "$Source_Version" ] || continue
        [ ! -d "${cur_dir}/src/${Source_Version}" ] || rm -rf -- "${cur_dir}/src/${Source_Version}" || return 1
    done
    Add_Iptables_Rules || return 1
    \cp "${cur_dir}/conf/index.html" "${Default_Website_Dir}/index.html" || return 1
    \cp "${cur_dir}/conf/lnmp" /bin/lnmp || return 1
}

DB_Dependent()
{
    local packages
    if [[ "${DBSelect}" =~ ^(10|11|12|13)$ ]]; then
        if [ "$PM" = "apt" ]; then
            Install_Debian_Build_Dependencies || return 1
        elif [ "$PM" = "yum" ]; then
            Install_RPM_Build_Dependencies || return 1
        else
            Echo_Red "Unsupported package manager: ${PM}"
            return 1
        fi
        return 0
    fi
    if [ "$PM" = "yum" ]; then
        for packages in make cmake gcc gcc-c++ gcc-g77 flex bison wget zlib zlib-devel openssl openssl-devel ncurses ncurses-devel libaio-devel rpcgen libtirpc-devel patch cyrus-sasl-devel pkg-config pcre-devel libxml2-devel hostname ncurses-libs numactl-devel libxcrypt gnutls-devel initscripts libxcrypt-compat perl xz gzip;
        do yum -y install "$packages" || return 1; done
        if echo "${CentOS_Version}" | grep -Eqi "^8" || echo "${RHEL_Version}" | grep -Eqi "^8" || echo "${Rocky_Version}" | grep -Eqi "^8" || echo "${Alma_Version}" | grep -Eqi "^8"; then
            Check_PowerTools
            dnf --enablerepo=${repo_id} install rpcgen -y || return 1
            dnf install libarchive -y || return 1

            dnf install gcc-toolset-10 -y || return 1
        fi

        if [ "${DISTRO}" = "Oracle" ] && echo "${Oracle_Version}" | grep -Eqi "^8"; then
            Check_Codeready
            dnf --enablerepo=${repo_id} install rpcgen re2c -y || return 1
            dnf install libarchive -y || return 1
        fi

        if [ "${DISTRO}" = "Oracle" ] && echo "${Oracle_Version}" | grep -Eqi "^9"; then
            Check_Codeready
            dnf --enablerepo=${repo_id} install libtirpc-devel -y || return 1
            if [[ "${Bin}" != "y" && "${DBSelect}" = "5" ]]; then
                dnf install gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ gcc-toolset-12-binutils gcc-toolset-12-annobin-annocheck gcc-toolset-12-annobin-plugin-gcc -y || return 1
            fi
        fi

        if [ "${DISTRO}" = "Fedora" ] || echo "${CentOS_Version}" | grep -Eqi "^9" || echo "${Alma_Version}" | grep -Eqi "^9" || echo "${Rocky_Version}" | grep -Eqi "^9"; then
            dnf install chkconfig -y || return 1
        fi

        if echo "${CentOS_Version}" | grep -Eqi "^9" || echo "${Alma_Version}" | grep -Eqi "^9" || echo "${Rocky_Version}" | grep -Eqi "^9"; then
            dnf --enablerepo=crb install libtirpc-devel libxcrypt-compat -y || return 1
            if [[ "${Bin}" != "y" && "${DBSelect}" = "5" ]]; then
                dnf install gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ gcc-toolset-12-binutils gcc-toolset-12-annobin-annocheck gcc-toolset-12-annobin-plugin-gcc -y || return 1
            fi
        fi

        if [ -s /usr/lib64/libtinfo.so.6 ]; then
            ln -sf /usr/lib64/libtinfo.so.6 /usr/lib64/libtinfo.so.5 || return 1
        elif [ -s /usr/lib/libtinfo.so.6 ]; then
            ln -sf /usr/lib/libtinfo.so.6 /usr/lib/libtinfo.so.5 || return 1
        fi

        if [ -s /usr/lib64/libncurses.so.6 ]; then
            ln -sf /usr/lib64/libncurses.so.6 /usr/lib64/libncurses.so.5 || return 1
        elif [ -s /usr/lib/libncurses.so.6 ]; then
            ln -sf /usr/lib/libncurses.so.6 /usr/lib/libncurses.so.5 || return 1
        fi
    elif [ "$PM" = "apt" ]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y || apt-get update --allow-releaseinfo-change -y || return 1
        for packages in debian-keyring debian-archive-keyring build-essential gcc g++ make cmake autoconf automake wget openssl libssl-dev zlib1g zlib1g-dev libncurses5 libncurses5-dev bison libaio-dev libtirpc-dev libsasl2-dev pkg-config libpcre2-dev libxml2-dev libtinfo-dev libnuma-dev gnutls-dev xz-utils gzip;
        do apt-get --no-install-recommends install -y "$packages" || return 1; done
    else
        Echo_Red "Unsupported package manager: ${PM}"
        return 1
    fi
    return 0
}

Install_Database()
{
    if [[ ! "${DBSelect}" =~ ^(1|2|3|4|5|6|7|8|9|10|11|12|13)$ ]]; then
        Echo_Red "Invalid database selection."
        return 1
    fi
    Check_Install_SELinux || return 1
    echo "============================check files=================================="
    cd "${cur_dir}/src" || return 1
    if [ "${DISTRO}" = CentOS ]; then
        Get_Dist_Version || return 1
        if [[ "${CentOS_Version}" = 8 || "${CentOS_Version}" = 8.* ]]; then
            Check_MySQL_Install_Target || return 1
            if [[ "${DBSelect}" =~ ^(1|2|3|4|5|11)$ ]]; then
                Check_MySQL_Data_Dir --check-only || return 1
            else
                Check_MariaDB_Data_Dir || return 1
            fi
            Prepare_CentOS8_Bootstrap || return 1
        fi
    fi
    if [[ "${DBSelect}" =~ ^(1|2|3|4|5|11)$ ]]; then
        if [[ "${Bin}" = "y" && "${DBSelect}" =~ ^[2-4]$ ]]; then
            Mysql_Ver_Short=$(echo ${Mysql_Ver} | sed 's/mysql-//' | cut -d. -f1-2)
            Download_Files https://cdn.mysql.com/Downloads/MySQL-${Mysql_Ver_Short}/${Mysql_Ver}-linux-glibc2.12-${DB_ARCH}.tar.gz ${Mysql_Ver}-linux-glibc2.12-${DB_ARCH}.tar.gz ||
                Download_Files https://cdn.mysql.com/archives/mysql-${Mysql_Ver_Short}/${Mysql_Ver}-linux-glibc2.12-${DB_ARCH}.tar.gz ${Mysql_Ver}-linux-glibc2.12-${DB_ARCH}.tar.gz || return 1
            if [ ! -s ${Mysql_Ver}-linux-glibc2.12-${DB_ARCH}.tar.gz ]; then
                Echo_Red "Error! Unable to download MySQL ${Mysql_Ver_Short} Generic Binaries, please download it to src directory manually."
                sleep 5
                exit 1
            fi
        elif [[ "${Bin}" = "y" && "${DBSelect}" = "5" ]]; then
            [[ "${DB_ARCH}" = "aarch64" ]] && mysql8_glibc_ver="2.17" || mysql8_glibc_ver="2.12"
            Download_Files https://cdn.mysql.com/Downloads/MySQL-8.0/${Mysql_Ver}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}.tar.xz ${Mysql_Ver}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}.tar.xz ||
                Download_Files https://cdn.mysql.com/archives/mysql-8.0/${Mysql_Ver}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}.tar.xz ${Mysql_Ver}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}.tar.xz || return 1
            if [ ! -s ${Mysql_Ver}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}.tar.xz ]; then
                Echo_Red "Error! Unable to download MySQL 8.0 Generic Binaries, please download it to src directory manually."
                sleep 5
                exit 1
            fi
        elif [[ "${Bin}" = "y" && "${DBSelect}" = "11" ]]; then
            Download_Files https://cdn.mysql.com/Downloads/MySQL-8.4/${Mysql_Ver}-linux-glibc2.17-${DB_ARCH}.tar.xz ${Mysql_Ver}-linux-glibc2.17-${DB_ARCH}.tar.xz ||
                Download_Files https://cdn.mysql.com/archives/mysql-8.4/${Mysql_Ver}-linux-glibc2.17-${DB_ARCH}.tar.xz ${Mysql_Ver}-linux-glibc2.17-${DB_ARCH}.tar.xz || return 1
            if [ ! -s ${Mysql_Ver}-linux-glibc2.17-${DB_ARCH}.tar.xz ]; then
                Echo_Red "Error! Unable to download MySQL 8.4 Generic Binaries, please download it to src directory manually."
                sleep 5
                exit 1
            fi
        else
            Download_Files ${Download_Mirror}/datebase/mysql/${Mysql_Ver}.tar.gz ${Mysql_Ver}.tar.gz || return 1
            if [ ! -s ${Mysql_Ver}.tar.gz ]; then
                Echo_Red "Error! Unable to download MySQL source code, please download it to src directory manually."
                sleep 5
                exit 1
            fi
        fi
    elif [[ "${DBSelect}" =~ ^(6|7|8|9|10|12|13)$ ]]; then
        Mariadb_Version=$(echo ${Mariadb_Ver} | cut -d- -f2)
        if [ "${Bin}" = "y" ]; then
            MariaDB_FileName="${Mariadb_Ver}-linux-systemd-${DB_ARCH}"
        else
            MariaDB_FileName="${Mariadb_Ver}"
        fi
        Download_Files https://downloads.mariadb.org/rest-api/mariadb/${Mariadb_Version}/${MariaDB_FileName}.tar.gz ${MariaDB_FileName}.tar.gz || return 1
        if [ ! -s ${MariaDB_FileName}.tar.gz ]; then
            Echo_Red "Error! Unable to download MariaDB, please download it to src directory manually."
            sleep 5
            exit 1
        fi
    fi
    echo "============================check files=================================="

    if [[ "${DBSelect}" =~ ^(1|2|3|4|5|11)$ ]]; then
        Check_MySQL_Install_Target || return 1
        Check_MySQL_Data_Dir --check-only || return 1
    else
        MariaDB_Install_Preflight || return 1
    fi
    Echo_Blue "Install dependent packages..."
    Get_Dist_Version || return 1
    Modify_Source || return 1
    DB_Dependent || return 1
    Check_Openssl || return 1
    if [ "${DBSelect}" = "1" ]; then
        Install_MySQL_51 || return 1
    elif [ "${DBSelect}" = "2" ]; then
        Install_MySQL_55 || return 1
    elif [ "${DBSelect}" = "3" ]; then
        Install_MySQL_56 || return 1
    elif [ "${DBSelect}" = "4" ]; then
        Install_MySQL_57 || return 1
    elif [ "${DBSelect}" = "5" ]; then
        Install_MySQL_80 || return 1
    elif [ "${DBSelect}" = "6" ]; then
        Install_MariaDB_5 || return 1
    elif [ "${DBSelect}" = "7" ]; then
        Install_MariaDB_104 || return 1
    elif [ "${DBSelect}" = "8" ]; then
        Install_MariaDB_105 || return 1
    elif [ "${DBSelect}" = "9" ]; then
        Install_MariaDB_106 || return 1
    elif [ "${DBSelect}" = "10" ]; then
        Install_MariaDB_1011 || return 1
    elif [ "${DBSelect}" = "11" ]; then
        Install_MySQL_84 || return 1
    elif [ "${DBSelect}" = "12" ]; then
        Install_MariaDB_114 || return 1
    elif [ "${DBSelect}" = "13" ]; then
        Install_MariaDB_118 || return 1
    fi
    TempMycnf_Clean

    if [[ "${DBSelect}" =~ ^(6|7|8|9|10|12|13)$ ]]; then
        StartUp mariadb || return 1
        StartOrStop start mariadb || return 1
    elif [[ "${DBSelect}" =~ ^(1|2|3|4|5|11)$ ]]; then
        StartUp mysql || return 1
        StartOrStop start mysql || return 1
    fi

    Check_DB_Files || return 1
    [[ "${isDB}" = "ok" ]] || return 1
    Clean_DB_Src_Dir
    if [[ "${isDB}" = "ok" ]]; then
        if [[ "${DBSelect}" =~ ^(1|2|3|4|5|11)$ ]]; then
            Echo_Green "MySQL root password: ${DB_Root_Password}"
            Echo_Green "Install ${Mysql_Ver} completed! enjoy it."
        elif [[ "${DBSelect}" =~ ^(6|7|8|9|10|12|13)$ ]]; then
            Echo_Green "MariaDB root password: ${DB_Root_Password}"
            Echo_Green "Install ${Mariadb_Ver} completed! enjoy it."
        fi
    fi
}

Install_Only_Database()
{
    local -a Database_Status
    Check_Install_SELinux || return 1
    clear
    echo "+-----------------------------------------------------------------------+"
    echo "|      Install MySQL/MariaDB database for LNMP, Written by Licess       |"
    echo "+-----------------------------------------------------------------------+"
    echo "|               A tool to install MySQL/MariaDB for LNMP                |"
    echo "+-----------------------------------------------------------------------+"
    echo "|           For more information please visit https://lnmp.org          |"
    echo "+-----------------------------------------------------------------------+"

    Get_Dist_Name
    Check_DB
    if [ "${DB_Name}" != "None" ]; then
        echo "You have install ${DB_Name}!"
        exit 1
    fi

    Database_Selection
    if [ "${DBSelect}" = "0" ]; then
        echo "DO NOT Install MySQL or MariaDB."
        exit 1
    fi
    Echo_Blue "Existing system MySQL/MariaDB packages and databases will not be removed automatically."
    Press_Install
    Install_Database 2>&1 | tee /root/install_database.log
    Database_Status=("${PIPESTATUS[@]}")
    [[ "${Database_Status[0]}" -eq 0 && "${Database_Status[1]}" -eq 0 ]]
}
