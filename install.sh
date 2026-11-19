#!/usr/bin/env bash
set -o pipefail
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this script, please use root to install lnmp"
    exit 1
fi

cur_dir=$(pwd)
Stack=$1
if [ "${Stack}" = "" ]; then
    Stack="lnmp"
else
    Stack=$1
fi

. include/release.sh
. lnmp.conf
. include/main.sh
. include/telemetry.sh
. include/init.sh
. include/mysql.sh
. include/mariadb.sh
. include/php.sh
. include/nginx.sh
. include/apache.sh
. include/end.sh
. include/only.sh
. include/multiplephp.sh
trap TempMycnf_Clean EXIT

Get_Dist_Name

if [ "${DISTRO}" = "unknow" ]; then
    Echo_Red "Unable to get Linux distribution name, or do NOT support the current distribution."
    exit 1
fi

if [[ "${Stack}" = "lnmp" || "${Stack}" = "lnmpa" || "${Stack}" = "lamp" ]]; then
    if [ -f /bin/lnmp ]; then
        Echo_Red "You have installed LNMP!"
        echo -e "If you want to reinstall LNMP, please BACKUP your data.\nand run uninstall script: ./uninstall.sh before you install."
        exit 1
    fi
fi

Check_LNMPConf

clear
echo "+------------------------------------------------------------------------+"
echo "|          LNMP V${LNMP_Ver} for ${DISTRO} Linux Server, Written by Licess          |"
echo "+------------------------------------------------------------------------+"
echo "|        A tool to auto-compile & install LNMP/LNMPA/LAMP on Linux       |"
echo "+------------------------------------------------------------------------+"
echo "|           For more information please visit https://lnmp.org           |"
echo "+------------------------------------------------------------------------+"

Init_Install()
{
    Check_Fresh_Install_Targets || exit 1
    Press_Install
    Telemetry_Begin
    Print_APP_Ver
    Get_Dist_Version || exit 1
    Prepare_CentOS8_Bootstrap || exit 1
    Print_Sys_Info
    Check_Download || exit 1
    Check_Hosts
    Check_CMPT
    if [ "${CheckMirror}" != "n" ]; then
        Modify_Source || exit 1
        Check_Mirror || exit 1
    fi
    Add_Swap
    Set_Timezone
    if [ "$PM" = "yum" ]; then
        CentOS_InstallNTP
        CentOS_Dependent
    elif [ "$PM" = "apt" ]; then
        Deb_InstallNTP
        Xen_Hwcap_Setting
        Deb_Dependent
    fi
    Telemetry_Retry_Started
    Install_Libiconv || exit 1
    if [[ "${PHPSelect}" =~ ^([1-9]|10)$ ]]; then
        Install_Libmcrypt
        Install_Mhash
        Install_Mcrypt
    fi
    Install_Freetype || exit 1
    Install_Pcre || exit 1
    Install_Icu4c || exit 1
    if [ "${SelectMalloc}" = "2" ]; then
        Install_Jemalloc || exit 1
    elif [ "${SelectMalloc}" = "3" ]; then
        Install_TCMalloc || exit 1
    fi
    if [ "$PM" = "yum" ]; then
        CentOS_Lib_Opt
    elif [ "$PM" = "apt" ]; then
        Deb_Lib_Opt
    fi
    if [ "${DBSelect}" = "1" ]; then
        Install_MySQL_51 || exit 1
    elif [ "${DBSelect}" = "2" ]; then
        Install_MySQL_55 || exit 1
    elif [ "${DBSelect}" = "3" ]; then
        Install_MySQL_56 || exit 1
    elif [ "${DBSelect}" = "4" ]; then
        Install_MySQL_57 || exit 1
    elif [ "${DBSelect}" = "5" ]; then
        Install_MySQL_80 || exit 1
    elif [ "${DBSelect}" = "6" ]; then
        Install_MariaDB_5 || exit 1
    elif [ "${DBSelect}" = "7" ]; then
        Install_MariaDB_104 || exit 1
    elif [ "${DBSelect}" = "8" ]; then
        Install_MariaDB_105 || exit 1
    elif [ "${DBSelect}" = "9" ]; then
        Install_MariaDB_106 || exit 1
    elif [ "${DBSelect}" = "10" ]; then
        Install_MariaDB_1011 || exit 1
    elif [ "${DBSelect}" = "11" ]; then
        Install_MySQL_84 || exit 1
    elif [ "${DBSelect}" = "12" ]; then
        Install_MariaDB_114 || exit 1
    elif [ "${DBSelect}" = "13" ]; then
        Install_MariaDB_118 || exit 1
    fi
    TempMycnf_Clean
    Clean_DB_Src_Dir
    Check_PHP_Option || exit 1
}

Install_PHP()
{
    if [ "${PHPSelect}" = "1" ]; then
        Install_PHP_52 || exit 1
    elif [ "${PHPSelect}" = "2" ]; then
        Install_PHP_53 || exit 1
    elif [ "${PHPSelect}" = "3" ]; then
        Install_PHP_54 || exit 1
    elif [ "${PHPSelect}" = "4" ]; then
        Install_PHP_55 || exit 1
    elif [ "${PHPSelect}" = "5" ]; then
        Install_PHP_56 || exit 1
    elif [ "${PHPSelect}" = "6" ]; then
        Install_PHP_7 || exit 1
    elif [ "${PHPSelect}" = "7" ]; then
        Install_PHP_71 || exit 1
    elif [ "${PHPSelect}" = "8" ]; then
        Install_PHP_72 || exit 1
    elif [ "${PHPSelect}" = "9" ]; then
        Install_PHP_73 || exit 1
    elif [ "${PHPSelect}" = "10" ]; then
        Install_PHP_74 || exit 1
    elif [ "${PHPSelect}" = "11" ]; then
        Install_PHP_80 || exit 1
    elif [ "${PHPSelect}" = "12" ]; then
        Install_PHP_81 || exit 1
    elif [ "${PHPSelect}" = "13" ]; then
        Install_PHP_82 || exit 1
    elif [ "${PHPSelect}" = "14" ]; then
        Install_PHP_83 || exit 1
    elif [ "${PHPSelect}" = "15" ]; then
        Install_PHP_84 || exit 1
    elif [ "${PHPSelect}" = "16" ]; then
        Install_PHP_85 || exit 1
    fi
    Clean_PHP_Src_Dir
}

LNMP_Stack()
{
    Init_Install || exit 1
    Install_PHP || exit 1
    LNMP_PHP_Opt || exit 1
    Install_Nginx || exit 1
    Creat_PHP_Tools || exit 1
    Add_Iptables_Rules
    Add_LNMP_Startup || exit 1
    Check_LNMP_Install
}

LNMPA_Stack()
{
    Apache_Selection
    Init_Install || exit 1
    if [ "${ApacheSelect}" = "1" ]; then
        Install_Apache_22 || exit 1
    else
        Install_Apache_24 || exit 1
    fi
    Install_PHP || exit 1
    Install_Nginx || exit 1
    Creat_PHP_Tools || exit 1
    Add_Iptables_Rules
    Add_LNMPA_Startup || exit 1
    Check_LNMPA_Install
}

LAMP_Stack()
{
    Apache_Selection
    Init_Install || exit 1
    if [ "${ApacheSelect}" = "1" ]; then
        Install_Apache_22 || exit 1
    else
        Install_Apache_24 || exit 1
    fi
    Install_PHP || exit 1
    Creat_PHP_Tools || exit 1
    Add_Iptables_Rules
    Add_LAMP_Startup || exit 1
    Check_LAMP_Install
}

case "${Stack}" in
    lnmp)
        Dispaly_Selection
        LNMP_Stack 2>&1 | tee /root/lnmp-install.log
        ;;
    lnmpa)
        Dispaly_Selection
        LNMPA_Stack 2>&1 | tee /root/lnmp-install.log
        ;;
    lamp)
        Dispaly_Selection
        LAMP_Stack 2>&1 | tee /root/lnmp-install.log
        ;;
    nginx)
        Install_Only_Nginx 2>&1 | tee /root/nginx-install.log
        ;;
    db)
        Install_Only_Database
        ;;
    mphp)
        Install_Multiplephp
        ;;
    *)
        Echo_Red "Usage: $0 {lnmp|lnmpa|lamp}"
        Echo_Red "Usage: $0 {nginx|db|mphp}"
        ;;
esac

exit
