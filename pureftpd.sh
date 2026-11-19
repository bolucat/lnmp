#!/usr/bin/env bash
set -o pipefail
export PATH=$PATH:/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin

# Check if user is root
if [ $(id -u) != "0" ]; then
    echo "Error: You must be root to run this script!"
    exit 1
fi
clear
echo "+----------------------------------------------------------+"
echo "|          Pureftpd for LNMP,  Written by Licess           |"
echo "+----------------------------------------------------------+"
echo "|This script is a tool to install pureftpd for LNMP        |"
echo "+----------------------------------------------------------+"
echo "|For more information please visit https://lnmp.org        |"
echo "+----------------------------------------------------------+"
echo "|Usage: ./pureftpd.sh                                      |"
echo "+----------------------------------------------------------+"
cur_dir=$(pwd)
action=$1

. lnmp.conf
. include/main.sh
. include/init.sh
. include/version.sh

Get_Dist_Name

Install_Pureftpd()
{
    local Version_Output Runtime_Version Attempt
    if [ -e /usr/local/pureftpd ] || [ -L /usr/local/pureftpd ]; then
        Echo_Red "Existing Pure-FTPd installation found; preserve its configuration and virtual users before a manual upgrade."
        return 1
    fi
    Press_Install

    Echo_Blue "Installing dependent packages..."
    if [ "$PM" = "yum" ]; then
        for packages in make gcc gcc-c++ gcc-g77 openssl openssl-devel bzip2;
        do yum -y install $packages; done
    elif [ "$PM" = "apt" ]; then
        apt-get update -y
        [[ $? -ne 0 ]] && apt-get update --allow-releaseinfo-change -y
        for packages in build-essential gcc g++ make openssl libssl-dev bzip2;
        do apt-get --no-install-recommends install -y $packages; done
    fi
    Echo_Blue "Download files..."
    cd ${cur_dir}/src
    Download_Files ${Download_Mirror}/ftp/pure-ftpd/${Pureftpd_Ver}.tar.bz2 ${Pureftpd_Ver}.tar.bz2
    if [ $? -eq 0 ]; then
        echo "Download ${Pureftpd_Ver}.tar.bz2 successfully!"
    else
        Download_Files https://download.pureftpd.org/pub/pure-ftpd/releases/${Pureftpd_Ver}.tar.bz2 ${Pureftpd_Ver}.tar.bz2 || return 1
    fi

    Echo_Blue "Installing pure-ftpd..."
    Tar_Cd ${Pureftpd_Ver}.tar.bz2 ${Pureftpd_Ver}
    ./configure --prefix=/usr/local/pureftpd CFLAGS=-O2 --with-puredb --with-quotas --with-cookie --with-virtualhosts --with-diraliases --with-sysquotas --with-ratios --with-altlog --with-paranoidmsg --with-shadow --with-welcomemsg --with-throttling --with-uploadscript --with-language=english --with-rfc2640 --with-ftpwho --with-tls || return 1

    Make_Install

    [ -x /usr/local/pureftpd/sbin/pure-ftpd ] || { Echo_Red 'Pure-FTPd executable is missing.'; return 1; }
    Version_Output=$(/usr/local/pureftpd/sbin/pure-ftpd --help 2>&1) || {
        Echo_Red 'Pure-FTPd runtime version check failed.'; return 1;
    }
    Runtime_Version=$(printf '%s\n' "$Version_Output" | awk 'NR == 1 && $1 == "pure-ftpd" && $2 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ {sub(/^v/, "", $2); print $2}')
    [ -n "$Runtime_Version" ] && [ "pure-ftpd-$Runtime_Version" = "$Pureftpd_Ver" ] || {
        Echo_Red 'Pure-FTPd runtime version does not match the selected release.'; return 1;
    }

    Echo_Blue "Copy configure files..."
    mkdir /usr/local/pureftpd/etc
    \cp ${cur_dir}/conf/pure-ftpd.conf /usr/local/pureftpd/etc/pure-ftpd.conf
    if [ -L /etc/init.d/pureftpd ]; then
        rm -f /etc/init.d/pureftpd
    fi
    \cp ${cur_dir}/init.d/init.d.pureftpd /etc/init.d/pureftpd
    \cp ${cur_dir}/init.d/pureftpd.service /etc/systemd/system/pureftpd.service
    chmod +x /etc/init.d/pureftpd
    touch /usr/local/pureftpd/etc/pureftpd.passwd
    touch /usr/local/pureftpd/etc/pureftpd.pdb

    StartUp pureftpd || return 1

    cd ..
    rm -rf ${cur_dir}/src/${Pureftpd_Ver}

    if [ "${Enable_Firewall_Management:-n}" = y ] && {
        command -v firewall-cmd >/dev/null 2>&1 || command -v firewalld >/dev/null 2>&1 ||
        [ -e /etc/systemd/system/firewalld.service ] || [ -e /usr/lib/systemd/system/firewalld.service ] ||
        [ -e /lib/systemd/system/firewalld.service ];
    }; then
        Echo_Yellow 'Existing firewalld detected. Configure FTP ports manually; LNMP will not change firewall rules or stop/disable firewalld.'
    elif [ "${Enable_Firewall_Management:-n}" = y ] && command -v iptables >/dev/null 2>&1; then
        if [ -s /bin/lnmp ]; then
            iptables -I INPUT 7 -p tcp --dport 20 -j ACCEPT
            iptables -I INPUT 8 -p tcp --dport 21 -j ACCEPT
            iptables -I INPUT 9 -p tcp --dport 20000:30000 -j ACCEPT
        else
            iptables -I INPUT -p tcp --dport 20 -j ACCEPT
            iptables -I INPUT -p tcp --dport 21 -j ACCEPT
            iptables -I INPUT -p tcp --dport 20000:30000 -j ACCEPT
        fi
        if [ "${PM}" = "yum" ]; then
            service iptables save
            service iptables reload
        elif [ "${PM}" = "apt" ]; then
            if [ -s /etc/init.d/netfilter-persistent ]; then
                /etc/init.d/netfilter-persistent save
                /etc/init.d/netfilter-persistent reload
            else
                /etc/init.d/iptables-persistent save
                /etc/init.d/iptables-persistent reload
            fi
        fi
    fi

    if [ ! -s /bin/lnmp ]; then
        \cp ${cur_dir}/conf/lnmp /bin/lnmp
        chmod +x /bin/lnmp
    fi
    id -u www
    if [ $? -ne 0 ]; then
        groupadd www
        useradd -s /sbin/nologin -g www www
    fi

    if [[ -s /usr/local/pureftpd/sbin/pure-ftpd && -s /usr/local/pureftpd/etc/pure-ftpd.conf && -s /etc/init.d/pureftpd ]]; then
        Echo_Blue "Starting pureftpd..."
        StartOrStop start pureftpd || { Echo_Red 'Pure-FTPd failed to start.'; return 1; }
        for Attempt in 1 2 3 4 5; do
            StartOrStop status pureftpd >/dev/null 2>&1 && break
            [ "$Attempt" != 5 ] || { Echo_Red 'Pure-FTPd is not running after startup.'; return 1; }
            sleep 1
        done
        Echo_Green "+----------------------------------------------------------------------+"
        Echo_Green "| Install Pure-FTPd completed,enjoy it!"
        Echo_Green "| =>use command: lnmp ftp {add|list|del|show} to manage FTP users."
        Echo_Green "+----------------------------------------------------------------------+"
        Echo_Green "| For more information please visit https://lnmp.org"
        Echo_Green "+----------------------------------------------------------------------+"
    else
        Echo_Red "Pureftpd install failed!"
        return 1
    fi
}

Uninstall_Pureftpd()
{
    if [ ! -f /usr/local/pureftpd/sbin/pure-ftpd ]; then
        Echo_Red "Pureftpd was not installed!"
        exit 1
    fi
    echo "Stop pureftpd..."
    /etc/init.d/pureftpd stop
    echo "Remove service..."
    Remove_StartUp pureftpd
    echo "Delete files..."
    rm -f /etc/init.d/pureftpd
    rm -rf /usr/local/pureftpd
    echo "Pureftpd uninstall completed."
}

if [ "${action}" = "uninstall" ]; then
    Uninstall_Pureftpd
else
    Install_Pureftpd 2>&1 | tee /root/pureftpd-install.log
fi
