#!/usr/bin/env bash

Set_Timezone()
{
    Echo_Blue "Setting timezone..."
    rm -rf /etc/localtime
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
}

CentOS_InstallNTP()
{
    if [ "${CheckMirror}" != "n" ]; then
        if command -v ntpdate >/dev/null 2>&1; then
            ntpdate -u pool.ntp.org
        elif command -v chronyd >/dev/null 2>&1; then
            chronyd -d -q "server pool.ntp.org iburst"
        else
            yum info ntpdate && check_ntp="y"
            if [ "${check_ntp}" = "y" ]; then
                Echo_Blue "[+] Installing ntp..."
                yum install -y ntpdate
                ntpdate -u pool.ntp.org
            else
                Echo_Blue "[+] Installing chrony..."
                yum install chrony -y
                chronyd -d -q "server pool.ntp.org iburst"
            fi
        fi
    fi
    date
    start_time=$(date +%s)
}

Deb_InstallNTP()
{
    if [ "${CheckMirror}" != "n" ]; then
        apt-get update -y
        [[ $? -ne 0 ]] && apt-get update --allow-releaseinfo-change -y
        Echo_Blue "[+] Installing ntp..."
        apt-get install -y ntpdate
        ntpdate -u pool.ntp.org
    fi
    date
    start_time=$(date +%s)
}

CentOS_RemoveAMP()
{
    Echo_Blue "[-] Yum remove packages..."
    rpm -qa|grep httpd
    rpm -e httpd httpd-tools --nodeps
    if [[ "${DBSelect}" != "0" ]]; then
        yum -y remove mysql-server mysql mysql-libs mariadb-server mariadb mariadb-libs
        rpm -qa|grep mysql
        if [ $? -ne 0 ]; then
            rpm -e mysql mysql-libs --nodeps
            rpm -e mariadb mariadb-libs --nodeps
        fi
    fi
    rpm -qa|grep php
    rpm -e php-mysql php-cli php-gd php-common php --nodeps

    Remove_Error_Libcurl

    yum -y remove httpd*
    yum -y remove php*
    yum clean all
}

Deb_RemoveAMP()
{
    Echo_Blue "[-] apt-get remove packages..."
    apt-get update -y
    [[ $? -ne 0 ]] && apt-get update --allow-releaseinfo-change -y
    for removepackages in apache2 apache2-doc apache2-utils apache2.2-common apache2.2-bin apache2-mpm-prefork apache2-doc apache2-mpm-worker php5 php5-common php5-cgi php5-cli php5-mysql php5-curl php5-gd;
    do apt-get purge -y $removepackages; done
    if [[ "${DBSelect}" != "0" ]]; then
        if echo "${Ubuntu_Version}" | grep -Eqi "^2[0-7]\."; then
            dpkg -l |grep mysql
            dpkg --force-all -P mysql-server
            dpkg --force-all -P mariadb-client mariadb-server mariadb-common libmariadbd-dev
            [[ -d "/etc/mysql" ]] && rm -rf /etc/mysql
            for removepackages in mysql-server mariadb-server;
            do apt-get purge -y $removepackages; done
        else
            dpkg -l |grep mysql
            dpkg --force-all -P mysql-server mysql-common libmysqlclient15off libmysqlclient15-dev libmysqlclient18 libmysqlclient18-dev libmysqlclient20 libmysqlclient-dev libmysqlclient21
            dpkg --force-all -P mariadb-client mariadb-server mariadb-common libmariadbd-dev
            for removepackages in mysql-client mysql-server mysql-common mysql-server-core-5.5 mysql-client-5.5 mariadb-client mariadb-server mariadb-common;
            do apt-get purge -y $removepackages; done
        fi
    fi
    killall apache2
    dpkg -l |grep apache
    dpkg -P apache2 apache2-doc apache2-mpm-prefork apache2-utils apache2.2-common
    dpkg -l |grep php
    dpkg -P php5 php5-common php5-cli php5-cgi php5-mysql php5-curl php5-gd
    apt-get autoremove -y && apt-get clean
}

Disable_Selinux()
{
    if [ -s /etc/selinux/config ]; then
        setenforce 0
        sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
    fi
}

Xen_Hwcap_Setting()
{
    if [ -s /etc/ld.so.conf.d/libc6-xen.conf ]; then
        sed -i 's/hwcap 1 nosegneg/hwcap 0 nosegneg/g' /etc/ld.so.conf.d/libc6-xen.conf
    fi
}

Check_Hosts()
{
    if grep -Eqi '^127.0.0.1[[:space:]]*localhost' /etc/hosts; then
        echo "Hosts: ok."
    else
        echo "127.0.0.1 localhost.localdomain localhost" >> /etc/hosts
    fi
    if [ "${CheckMirror}" != "n" ]; then
        pingresult=`ping -c1 lnmp.org 2>&1`
        echo "${pingresult}"
        if echo "${pingresult}" | grep -q "unknown host"; then
            echo "DNS...fail"
            echo "Writing nameserver to /etc/resolv.conf ..."
            echo -e "nameserver 208.67.220.220\nnameserver 114.114.114.114" > /etc/resolv.conf
        else
            echo "DNS...ok"
        fi
    fi
}

RHEL_Modify_Source()
{
    Get_RHEL_Version
    if [ "${RHELRepo}" = "local" ]; then
        echo "DO NOT change RHEL repository, use the repository you set."
    else
        echo "RHEL ${RHEL_Ver} will use aliyun centos repository..."
        if [ ! -s "/etc/yum.repos.d/Centos-${RHEL_Ver}.repo" ]; then
            if command -v curl >/dev/null 2>&1; then
                curl http://mirrors.aliyun.com/repo/Centos-${RHEL_Ver}.repo -o /etc/yum.repos.d/Centos-${RHEL_Ver}.repo
            else
                wget --prefer-family=IPv4 http://mirrors.aliyun.com/repo/Centos-${RHEL_Ver}.repo -O /etc/yum.repos.d/Centos-${RHEL_Ver}.repo
            fi
        fi
        if echo "${RHEL_Version}" | grep -Eqi "^6"; then
            sed -i "s#centos/\$releasever#centos-vault/\$releasever#g" /etc/yum.repos.d/Centos-${RHEL_Ver}.repo
            sed -i "s/\$releasever/${RHEL_Version}/g" /etc/yum.repos.d/Centos-${RHEL_Ver}.repo
        elif echo "${RHEL_Version}" | grep -Eqi "^7"; then
            sed -i "s/\$releasever/7/g" /etc/yum.repos.d/Centos-${RHEL_Ver}.repo
        elif echo "${RHEL_Version}" | grep -Eqi "^8"; then
            sed -i "s#centos/\$releasever#centos-vault/8.5.2111#g" /etc/yum.repos.d/Centos-${RHEL_Ver}.repo
        elif echo "${RHEL_Version}" | grep -Eqi "^9"; then
            [[ -s /etc/yum.repos.d/Centos-9.repo ]] && rm -f /etc/yum.repos.d/Centos-9.repo
            \cp ${cur_dir}/conf/rhel-9.repo /etc/yum.repos.d/Centos-9.repo
        elif echo "${RHEL_Version}" | grep -Eqi "^10"; then
            [[ -s /etc/yum.repos.d/Centos-10.repo ]] && rm -f /etc/yum.repos.d/Centos-10.repo
            \cp ${cur_dir}/conf/rhel-10.repo /etc/yum.repos.d/Centos-10.repo
        fi
        yum clean all
        yum makecache
    fi
    sed -i "s/^enabled[ ]*=[ ]*1/enabled=0/" /etc/yum/pluginconf.d/subscription-manager.conf
}

Ubuntu_Modify_Source()
{
    if [ "${country}" = "CN" ]; then
        OldReleasesURL='http://mirrors.ustc.edu.cn/ubuntu-old-releases/'
    else
        OldReleasesURL='http://old-releases.ubuntu.com/ubuntu/'
    fi
    CodeName=''
    if grep -Eqi "10.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^10.10'; then
        CodeName='maverick'
    elif grep -Eqi "11.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^11.04'; then
        CodeName='natty'
    elif  grep -Eqi "11.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^11.10'; then
        CodeName='oneiric'
    elif grep -Eqi "12.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^12.10'; then
        CodeName='quantal'
    elif grep -Eqi "13.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^13.04'; then
        CodeName='raring'
    elif grep -Eqi "13.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^13.10'; then
        CodeName='saucy'
    elif grep -Eqi "10.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^10.04'; then
        CodeName='lucid'
    elif grep -Eqi "14.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^14.10'; then
        CodeName='utopic'
    elif grep -Eqi "15.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^15.04'; then
        CodeName='vivid'
    elif grep -Eqi "12.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^12.04'; then
        CodeName='precise'
    elif grep -Eqi "15.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^15.10'; then
        CodeName='wily'
    elif grep -Eqi "16.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^16.10'; then
        CodeName='yakkety'
    elif grep -Eqi "14.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^14.04'; then
        Ubuntu_Deadline trusty
    elif grep -Eqi "17.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^17.04'; then
        CodeName='zesty'
    elif grep -Eqi "17.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^17.10'; then
        CodeName='artful'
    elif grep -Eqi "16.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^16.04'; then
        Ubuntu_Deadline xenial
    elif grep -Eqi "16.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^16.10'; then
        CodeName='yakkety'
    elif grep -Eqi "18.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^18.04'; then
        Ubuntu_Deadline bionic
    elif grep -Eqi "18.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^18.10'; then
        CodeName='cosmic'
    elif grep -Eqi "19.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^19.04'; then
        CodeName='disco'
    elif grep -Eqi "19.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^19.10'; then
        CodeName='eoan'
    elif grep -Eqi "20.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^20.10'; then
        CodeName='groovy'
    elif grep -Eqi "21.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^21.04'; then
        CodeName='hirsute'
    elif grep -Eqi "21.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^21.10'; then
        CodeName='impish'
    elif grep -Eqi "22.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^22.10'; then
        CodeName='kinetic'
    elif grep -Eqi "23.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^23.04'; then
        CodeName='lunar'
    elif grep -Eqi "23.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^23.10'; then
        Ubuntu_Deadline mantic
    elif grep -Eqi "24.10" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^24.10'; then
        Ubuntu_Deadline oracular
    elif grep -Eqi "25.04" /etc/*-release || echo "${Ubuntu_Version}" | grep -Eqi '^25.04'; then
        Ubuntu_Deadline plucky
    fi
    if [ "${CodeName}" != "" ]; then
        \cp /etc/apt/sources.list /etc/apt/sources.list.$(date +"%Y%m%d")
        cat > /etc/apt/sources.list<<EOF
deb ${OldReleasesURL} ${CodeName} main restricted universe multiverse
deb ${OldReleasesURL} ${CodeName}-security main restricted universe multiverse
deb ${OldReleasesURL} ${CodeName}-updates main restricted universe multiverse
deb ${OldReleasesURL} ${CodeName}-proposed main restricted universe multiverse
deb ${OldReleasesURL} ${CodeName}-backports main restricted universe multiverse
deb-src ${OldReleasesURL} ${CodeName} main restricted universe multiverse
deb-src ${OldReleasesURL} ${CodeName}-security main restricted universe multiverse
deb-src ${OldReleasesURL} ${CodeName}-updates main restricted universe multiverse
deb-src ${OldReleasesURL} ${CodeName}-proposed main restricted universe multiverse
deb-src ${OldReleasesURL} ${CodeName}-backports main restricted universe multiverse
EOF
    fi
}

Check_Old_Releases_URL()
{
    OR_Status=`wget --spider --server-response ${OldReleasesURL}/dists/$1/Release 2>&1 | awk '/^  HTTP/{print $2}'`
    if [ "${OR_Status}" = "200" ]; then
        echo "Ubuntu old-releases status: ${OR_Status}";
        CodeName="$1"
    fi
}

Ubuntu_Deadline()
{
    trusty_deadline=`date -d "2024-4-30 00:00:00" +%s`
    xenial_deadline=`date -d "2026-4-30 00:00:00" +%s`
    bionic_deadline=`date -d "2028-7-30 00:00:00" +%s`
    mantic_deadline=`date -d "2024-7-30 00:00:00" +%s`
    oracular_deadline=`date -d "2025-7-10 00:00:00" +%s`
    plucky_deadline=`date -d "2026-1-15 00:00:00" +%s`
    cur_time=`date  +%s`
    case "$1" in
        trusty)
            if [ ${cur_time} -gt ${trusty_deadline} ]; then
                echo "${cur_time} > ${trusty_deadline}"
                Check_Old_Releases_URL trusty
            fi
            ;;
        xenial)
            if [ ${cur_time} -gt ${xenial_deadline} ]; then
                echo "${cur_time} > ${xenial_deadline}"
                Check_Old_Releases_URL xenial
            fi
            ;;
        bionic)
            if [ ${cur_time} -gt ${bionic_deadline} ]; then
                echo "${cur_time} > ${bionic_deadline}"
                Check_Old_Releases_URL bionic
            fi
            ;;
        mantic)
            if [ ${cur_time} -gt ${mantic_deadline} ]; then
                echo "${cur_time} > ${mantic_deadline}"
                Check_Old_Releases_URL mantic
            fi
            ;;
        oracular)
            if [ ${cur_time} -gt ${oracular_deadline} ]; then
                echo "${cur_time} > ${oracular_deadline}"
                Check_Old_Releases_URL oracular
            fi
            ;;
        plucky)
            if [ ${cur_time} -gt ${plucky_deadline} ]; then
                echo "${cur_time} > ${plucky_deadline}"
                Check_Old_Releases_URL plucky
            fi
            ;;
    esac
}

CentOS6_Modify_Source()
{
    if echo "${CentOS_Version}" | grep -Eqi "^6"; then
        Echo_Yellow "CentOS 6 is now end of life, use vault repository."
        mkdir /etc/yum.repos.d/backup
        mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/backup/
        \cp ${cur_dir}/conf/CentOS6-Base-Vault.repo /etc/yum.repos.d/CentOS-Base.repo
    fi
}

CentOS8_Modify_Source()
{
    local Template Target Repo Name Backup='' Temporary Source_Digest Target_Digest=''
    [[ "${CentOS_Version}" = 8 || "${CentOS_Version}" = 8.* ]] || return 0
    Template=CentOS8-vault.repo
    [ "${isCentosStream}" != y ] || Template=CentOSStream8-vault.repo
    Target="/etc/yum.repos.d/$Template"
    [ -s "${cur_dir}/conf/$Template" ] || { Echo_Red "Missing CentOS 8 vault template: $Template"; return 1; }
    Source_Digest=$(sha256sum < "${cur_dir}/conf/$Template") || return 1
    if [ -f "$Target" ]; then
        Target_Digest=$(sha256sum < "$Target") || return 1
    fi
    Echo_Yellow 'CentOS 8 is end of life; using signed packages from its HTTPS archive.'
    mkdir -p /etc/yum.repos.d || return 1
    for Repo in /etc/yum.repos.d/CentOS*.repo; do
        [ -e "$Repo" ] || [ -L "$Repo" ] || continue
        [ "$Repo" != "$Target" ] || continue
        Name=${Repo##*/}
        case "$Name" in
            CentOS-Base.repo|CentOS-AppStream.repo|CentOS-Extras.repo|CentOS-PowerTools.repo|CentOS-centosplus.repo|CentOS-Media.repo|CentOS-CR.repo|CentOS-Debuginfo.repo|CentOS-fasttrack.repo|CentOS-Sources.repo|CentOS-Vault.repo|CentOS-Linux-*.repo|CentOS-Stream-*.repo|CentOS8-vault.repo|CentOSStream8-vault.repo) ;;
            *) continue ;;
        esac
        if [ -z "$Backup" ]; then
            Backup=$(mktemp -d /etc/yum.repos.d/lnmp-centos8.XXXXXX) || return 1
        fi
        mv -- "$Repo" "$Backup/" || return 1
    done
    if [ "$Source_Digest" != "$Target_Digest" ]; then
        if [ -e "$Target" ] || [ -L "$Target" ]; then
            if [ -z "$Backup" ]; then
                Backup=$(mktemp -d /etc/yum.repos.d/lnmp-centos8.XXXXXX) || return 1
            fi
            cp -Pp -- "$Target" "$Backup/" || return 1
        fi
        Temporary=$(mktemp /etc/yum.repos.d/.lnmp-vault.XXXXXX) || return 1
        if ! cp "${cur_dir}/conf/$Template" "$Temporary" || ! chmod 644 "$Temporary" || ! mv -f -- "$Temporary" "$Target"; then
            rm -f -- "$Temporary"
            return 1
        fi
    fi
    [ -z "$Backup" ] || Echo_Blue "Previous CentOS repositories retained in $Backup"
    return 0
}

Prepare_CentOS8_Bootstrap()
{
    local Manager=yum Curl_Package=curl
    [ "${DISTRO}" = CentOS ] || return 0
    [[ "${CentOS_Version}" = 8 || "${CentOS_Version}" = 8.* ]] || return 0
    [ "${CheckMirror}" != n ] || return 0
    CentOS8_Modify_Source || return 1
    command -v dnf >/dev/null 2>&1 && Manager=dnf
    rpm -q curl-minimal >/dev/null 2>&1 && Curl_Package=curl-minimal
    "$Manager" install -y wget "$Curl_Package" ca-certificates || return 1
}

Modify_Source()
{
    if [ "${DISTRO}" = "RHEL" ]; then
        if subscription-manager status; then
            Echo_Blue "RHEL subscription exists on the system, skip setting up third-party sources."
            Get_RHEL_Version
            if echo "${RHEL_Version}" | grep -Eqi "^(8|9|10)"; then
                subscription-manager repos --enable codeready-builder-for-rhel-${RHEL_Ver}-${DB_ARCH}-rpms
            fi
        else
            RHEL_Modify_Source
        fi
    elif [ "${DISTRO}" = "Ubuntu" ]; then
        Ubuntu_Modify_Source
    elif [ "${DISTRO}" = "CentOS" ]; then
        CentOS6_Modify_Source
        CentOS8_Modify_Source
    fi
}

Check_PowerTools()
{
    if ! yum -v repolist all|grep "PowerTools"; then
        Echo_Red "PowerTools repository not found!"
    fi
    repo_id=$(yum repolist all|grep -Ei "PowerTools"|head -n 1|awk '{print $1}')
}

Check_Codeready()
{
    repo_id=$(yum repolist all|grep -E "CodeReady"|head -n 1|awk '{print $1}')
    [ -z "${repo_id}" ] && repo_id="ol8_codeready_builder"
}

CentOS_Legacy_Dependent()
{
    if [ -s /etc/yum.conf ]; then
        \cp /etc/yum.conf /etc/yum.conf.lnmp
        sed -i 's:exclude=.*:exclude=:g' /etc/yum.conf
    fi

    Echo_Blue "[+] Yum installing dependent packages..."
    for packages in make cmake gcc gcc-c++ gcc-g77 kernel-headers glibc-headers flex bison file libtool libtool-libs autoconf patch wget crontabs libjpeg libjpeg-devel libjpeg-turbo-devel libpng libpng-devel libpng10 libpng10-devel gd gd-devel libxml2 libxml2-devel zlib zlib-devel glib2 glib2-devel unzip tar bzip2 bzip2-devel libzip-devel libevent libevent-devel ncurses ncurses-devel curl curl-devel libcurl libcurl-devel e2fsprogs e2fsprogs-devel krb5 krb5-devel libidn libidn-devel openssl openssl-devel pcre-devel gettext gettext-devel ncurses-devel gmp-devel pspell-devel unzip libcap diffutils ca-certificates net-tools libc-client-devel psmisc libXpm-devel git-core c-ares-devel libicu-devel libxslt libxslt-devel xz expat-devel libaio-devel rpcgen libtirpc-devel perl cyrus-sasl-devel sqlite-devel oniguruma-devel lsof re2c pkg-config libarchive hostname ncurses-libs numactl-devel libxcrypt libwebp-devel gnutls-devel initscripts iproute libxcrypt-compat;
    do yum -y install $packages; done

    yum -y update nss

    if echo "${CentOS_Version}" | grep -Eqi "^8" || echo "${RHEL_Version}" | grep -Eqi "^8" || echo "${Rocky_Version}" | grep -Eqi "^8" || echo "${Alma_Version}" | grep -Eqi "^8" || echo "${Anolis_Version}" | grep -Eqi "^8" || echo "${OpenCloudOS_Version}" | grep -Eqi "^8"; then
        Check_PowerTools
        if [ "${repo_id}" != "" ]; then
            echo "Installing packages in PowerTools repository..."
            for c8packages in rpcgen re2c oniguruma-devel;
            do dnf --enablerepo=${repo_id} install ${c8packages} -y; done
        fi
        dnf install libarchive -y

        dnf install gcc-toolset-10 -y
    fi

    if echo "${CentOS_Version}" | grep -Eqi "^(9|10)"; then
        crb_source_check=$(yum repolist all | grep -E '^crb' | awk '{print $1}')

        if [[ ! -n "$crb_source_check" ]]; then
            echo "Add crb source..."
            cat > /etc/yum.repos.d/centos-crb.repo << EOF
[CRB]
name=CentOS-\$releasever - CRB - mirrors.ustc.edu.cn
#failovermethod=priority
baseurl=https://mirrors.ustc.edu.cn/centos-stream/\$stream/CRB/\$basearch/os/
gpgcheck=1
gpgkey=https://mirrors.ustc.edu.cn/centos-stream/RPM-GPG-KEY-CentOS-Official
EOF
        fi
    fi
    if echo "${CentOS_Version}" | grep -Eqi "^(9|10)" || echo "${RHEL_Version}" | grep -Eqi "^10" || echo "${Alma_Version}" | grep -Eqi "^(9|10)" || echo "${Rocky_Version}" | grep -Eqi "^(9|10)"; then
        for cs9packages in oniguruma-devel libzip-devel libtirpc-devel libxcrypt-compat;
        do dnf --enablerepo=crb install ${cs9packages} -y; done
        if [[ "${Bin}" != "y" && "${DBSelect}" = "5" ]]; then
            dnf install gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ gcc-toolset-12-binutils gcc-toolset-12-annobin-annocheck gcc-toolset-12-annobin-plugin-gcc -y
        fi
    fi

    if [ "${DISTRO}" = "Oracle" ] && echo "${Oracle_Version}" | grep -Eqi "^8"; then
        Check_Codeready
        for o8packages in rpcgen re2c oniguruma-devel;
        do dnf --enablerepo=${repo_id} install ${o8packages} -y; done
        dnf install libarchive -y
    fi

    if [ "${DISTRO}" = "Oracle" ] && echo "${Oracle_Version}" | grep -Eqi "^9"; then
        Check_Codeready
        dnf --enablerepo=${repo_id} install libtirpc-devel -y
        if [[ "${Bin}" != "y" && "${DBSelect}" = "5" ]]; then
            dnf install gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ gcc-toolset-12-binutils gcc-toolset-12-annobin-annocheck gcc-toolset-12-annobin-plugin-gcc -y
        fi
    fi

    if echo "${CentOS_Version}" | grep -Eqi "^7" || echo "${RHEL_Version}" | grep -Eqi "^7"  || echo "${Aliyun_Version}" | grep -Eqi "^2" || echo "${Alibaba_Version}" | grep -Eqi "^2" || echo "${Oracle_Version}" | grep -Eqi "^7" || echo "${Anolis_Version}" | grep -Eqi "^7"; then
        if [ "${DISTRO}" = "Oracle" ]; then
            yum -y install oracle-epel-release
            yum -y --enablerepo=*EPEL* install oniguruma-devel
        else
            yum -y install epel-release
            if [ "${country}" = "CN" ]; then
                sed -e 's!^metalink=!#metalink=!g' \
                    -e 's!^#baseurl=!baseurl=!g' \
                    -e 's!//download\.fedoraproject\.org/pub!//mirrors.ustc.edu.cn!g' \
                    -e 's!//download\.example/pub!//mirrors.ustc.edu.cn!g' \
                    -i /etc/yum.repos.d/epel*.repo
            fi
        fi
        yum -y install oniguruma oniguruma-devel
        if [ "${CheckMirror}" = "n" ]; then
            rpm -ivh ${cur_dir}/src/oniguruma-6.8.2-2.el7.x86_64.rpm ${cur_dir}/src/oniguruma-devel-6.8.2-2.el7.x86_64.rpm
        fi
    fi

    if [ "${DISTRO}" = "Fedora" ] || echo "${CentOS_Version}" | grep -Eqi "^(9|10)" || echo "${RHEL_Version}" | grep -Eqi "^10" || echo "${Alma_Version}" | grep -Eqi "^(9|10)" || echo "${Rocky_Version}" | grep -Eqi "^(9|10)" || echo "${Amazon_Version}" | grep -Eqi "^202[3-9]" || echo "${OpenCloudOS_Version}" | grep -Eqi "^(9|10)"; then
        dnf install chkconfig -y
    fi

    if [ "${DISTRO}" = "UOS" ]; then
        Check_PowerTools
        if [ "${repo_id}" != "" ]; then
            echo "Installing packages in PowerTools repository..."
            for uospackages in rpcgen re2c oniguruma-devel;
            do dnf --enablerepo=${repo_id} install ${uospackages} -y; done
        fi
    fi

    if [ -s /etc/yum.conf.lnmp ]; then
        mv -f /etc/yum.conf.lnmp /etc/yum.conf
    fi
}

Install_RPM_Build_Dependencies()
{
    local Manager=yum Repo Curl_Package=curl
    local Repo_Options=() Extra_Packages=()
    command -v dnf >/dev/null 2>&1 && Manager=dnf
    rpm -q curl-minimal >/dev/null 2>&1 && Curl_Package=curl-minimal
    Repo=$("$Manager" repolist all 2>/dev/null | awk 'tolower($1) ~ /(^crb$|^powertools$|codeready)/ {print $1; exit}')
    [ -z "$Repo" ] || Repo_Options=("--enablerepo=$Repo")
    if [ "${DISTRO}" = CentOS ] && [[ "${CentOS_Version}" = 8 || "${CentOS_Version}" = 8.* ]]; then
        Extra_Packages=(libarchive rpcgen)
        if { [ "${DBSelect}" = 11 ] && [ "${Bin}" != y ]; } || PHP_Uses_CentOS8_Toolset; then
            Extra_Packages+=(gcc-toolset-10-gcc gcc-toolset-10-gcc-c++ gcc-toolset-10-binutils)
        fi
    fi
    "$Manager" "${Repo_Options[@]}" install -y make cmake gcc gcc-c++ autoconf automake bison flex file libtool patch wget "$Curl_Package" ca-certificates crontabs tar bzip2 xz unzip git pkgconfig pcre2-devel openssl-devel zlib-devel bzip2-devel libjpeg-turbo-devel libpng-devel freetype-devel libxml2-devel libcurl-devel libzip-devel libicu-devel libxslt-devel sqlite-devel oniguruma-devel ncurses-devel numactl-devel libaio-devel libtirpc-devel cyrus-sasl-devel c-ares-devel libwebp-devel libxcrypt-devel lsof psmisc iproute initscripts perl perl-IPC-Cmd "${Extra_Packages[@]}" || return 1
}

CentOS_Dependent()
{
    if [[ "${PHPSelect}" =~ ^1[1-6]$ ]]; then
        Install_RPM_Build_Dependencies || exit 1
    else
        CentOS_Legacy_Dependent
    fi
}

PHP_Uses_CentOS8_Toolset()
{
    local Target_PHP=${php_version:-${Php_Ver#php-}}
    [ "${DISTRO}" = CentOS ] || return 1
    [[ "${CentOS_Version}" = 8 || "${CentOS_Version}" = 8.* ]] || return 1
    if [ -n "$Target_PHP" ]; then
        [[ "$Target_PHP" =~ ^8\.[3-5](\.|$) ]]
    else
        [[ "${PHPSelect}" =~ ^(14|15|16)$ ]]
    fi
}

Prepare_CentOS8_PHP_Compiler()
{
    local Prefix=/opt/rh/gcc-toolset-10 Version
    PHP_Uses_CentOS8_Toolset || return 0
    [ -z "${CC:-}" ] && [ -z "${CXX:-}" ] || return 0
    if [ ! -x "$Prefix/root/usr/bin/gcc" ] || [ ! -x "$Prefix/root/usr/bin/g++" ] || [ ! -x "$Prefix/root/usr/bin/ld" ] || [ ! -s "$Prefix/enable" ]; then
        Echo_Red 'PHP 8.3-8.5 on CentOS 8 requires gcc-toolset-10 compiler and binutils packages.'
        return 1
    fi
    . "$Prefix/enable" || return 1
    Version=$("$Prefix/root/usr/bin/gcc" -dumpversion) || return 1
    [[ "${Version%%.*}" =~ ^[0-9]+$ ]] && [ "${Version%%.*}" -ge 10 ] || return 1
    export CC="$Prefix/root/usr/bin/gcc" CXX="$Prefix/root/usr/bin/g++"
    Echo_Blue "Using CentOS 8 PHP compiler: $CC ($Version), with GCC Toolset binutils"
}

Install_Debian_Build_Dependencies()
{
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || apt-get update --allow-releaseinfo-change -y || return 1
    apt-get --no-install-recommends install -y build-essential cmake autoconf automake re2c wget curl ca-certificates cron bzip2 xz-utils gzip tar unzip patch git pkg-config libpcre2-dev bison flex file libtool libzip-dev libbz2-dev libncurses-dev libevent-dev libssl-dev libsasl2-dev libltdl-dev zlib1g-dev libglib2.0-dev libjpeg-dev libpng-dev libkrb5-dev libcurl4-openssl-dev libpq-dev gettext libxml2-dev libcap-dev libc-ares-dev libicu-dev libxslt1-dev libexpat1-dev libaio-dev libtirpc-dev libsqlite3-dev libonig-dev lsof libnuma-dev libwebp-dev libgnutls28-dev iproute2 psmisc || return 1
}

Deb_Dependent()
{
    Install_Debian_Build_Dependencies || exit 1
}

Check_Download()
{
    Echo_Blue "[+] Downloading files..."
    cd ${cur_dir}/src
    Download_Files ${Download_Mirror}/web/libiconv/${Libiconv_Ver}.tar.gz ${Libiconv_Ver}.tar.gz || return 1
    if [[ "${PHPSelect}" =~ ^([1-9]|10)$ ]]; then
        Download_Files ${Download_Mirror}/web/libmcrypt/${LibMcrypt_Ver}.tar.gz ${LibMcrypt_Ver}.tar.gz || return 1
        Download_Files ${Download_Mirror}/web/mcrypt/${Mcypt_Ver}.tar.gz ${Mcypt_Ver}.tar.gz || return 1
        Download_Files ${Download_Mirror}/web/mhash/${Mhash_Ver}.tar.bz2 ${Mhash_Ver}.tar.bz2 || return 1
    fi
    if [ "${SelectMalloc}" = "2" ]; then
        Download_Files ${Download_Mirror}/lib/jemalloc/${Jemalloc_Ver}.tar.bz2 ${Jemalloc_Ver}.tar.bz2 || return 1
    elif [ "${SelectMalloc}" = "3" ]; then
        Download_Files ${Download_Mirror}/lib/tcmalloc/${TCMalloc_Ver}.tar.gz ${TCMalloc_Ver}.tar.gz || return 1
        Download_Files ${Download_Mirror}/lib/libunwind/${Libunwind_Ver}.tar.gz ${Libunwind_Ver}.tar.gz || return 1
    fi
    if [ "${Stack}" != "lamp" ]; then
        Download_Files ${Download_Mirror}/web/nginx/${Nginx_Ver}.tar.gz ${Nginx_Ver}.tar.gz || return 1
    fi
    if [[ "${DBSelect}" =~ ^(1|2|3|4|5|11)$ ]]; then
        if [[ "${Bin}" = "y" && "${DBSelect}" =~ ^[2-4]$ ]]; then
            Mysql_Ver_Short=$(echo ${Mysql_Ver} | sed 's/mysql-//' | cut -d. -f1-2)
            if ! Download_Files https://cdn.mysql.com/Downloads/MySQL-${Mysql_Ver_Short}/${Mysql_Ver}-linux-glibc2.12-${DB_ARCH}.tar.gz ${Mysql_Ver}-linux-glibc2.12-${DB_ARCH}.tar.gz; then
                Download_Files https://cdn.mysql.com/archives/mysql-${Mysql_Ver_Short}/${Mysql_Ver}-linux-glibc2.12-${DB_ARCH}.tar.gz ${Mysql_Ver}-linux-glibc2.12-${DB_ARCH}.tar.gz || return 1
            fi
        elif [[ "${Bin}" = "y" && "${DBSelect}" = "5" ]]; then
            [[ "${DB_ARCH}" = "aarch64" ]] && mysql8_glibc_ver="2.17" || mysql8_glibc_ver="2.12"
            if ! Download_Files https://cdn.mysql.com/Downloads/MySQL-8.0/${Mysql_Ver}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}.tar.xz ${Mysql_Ver}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}.tar.xz; then
                Download_Files https://cdn.mysql.com/archives/mysql-8.0/${Mysql_Ver}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}.tar.xz ${Mysql_Ver}-linux-glibc${mysql8_glibc_ver}-${DB_ARCH}.tar.xz || return 1
            fi
        elif [[ "${Bin}" = "y" && "${DBSelect}" = "11" ]]; then
            if ! Download_Files https://cdn.mysql.com/Downloads/MySQL-8.4/${Mysql_Ver}-linux-glibc2.17-${DB_ARCH}.tar.xz ${Mysql_Ver}-linux-glibc2.17-${DB_ARCH}.tar.xz; then
                Download_Files https://cdn.mysql.com/archives/mysql-8.4/${Mysql_Ver}-linux-glibc2.17-${DB_ARCH}.tar.xz ${Mysql_Ver}-linux-glibc2.17-${DB_ARCH}.tar.xz || return 1
            fi
        else
            Download_Files ${Download_Mirror}/datebase/mysql/${Mysql_Ver}.tar.gz ${Mysql_Ver}.tar.gz || return 1
        fi
    elif [[ "${DBSelect}" =~ ^(6|7|8|9|10|12|13)$ ]]; then
        Mariadb_Version=$(echo ${Mariadb_Ver} | cut -d- -f2)
        if [ "${Bin}" = "y" ]; then
            Download_Files https://downloads.mariadb.org/rest-api/mariadb/${Mariadb_Version}/${Mariadb_Ver}-linux-systemd-${DB_ARCH}.tar.gz ${Mariadb_Ver}-linux-systemd-${DB_ARCH}.tar.gz || return 1
        else
            Download_Files https://downloads.mariadb.org/rest-api/mariadb/${Mariadb_Version}/${Mariadb_Ver}.tar.gz ${Mariadb_Ver}.tar.gz || return 1
        fi
    fi
    Download_Files ${Download_Mirror}/web/php/${Php_Ver}.tar.bz2 ${Php_Ver}.tar.bz2 || return 1
    if [ ${PHPSelect} = "1" ]; then
        Download_Files ${Download_Mirror}/web/phpfpm/${Php_Ver}-fpm-0.5.14.diff.gz ${Php_Ver}-fpm-0.5.14.diff.gz || return 1
    fi
    Download_Files ${Download_Mirror}/datebase/phpmyadmin/${PhpMyAdmin_Ver}.tar.xz ${PhpMyAdmin_Ver}.tar.xz || return 1
    Download_Files ${Download_Mirror}/prober/p.tar.gz p.tar.gz || return 1
    if [ "${Stack}" != "lnmp" ]; then
        Download_Files ${Download_Mirror}/web/apache/${Apache_Ver}.tar.bz2 ${Apache_Ver}.tar.bz2 || return 1
        Download_Files ${Download_Mirror}/web/apache/${APR_Ver}.tar.bz2 ${APR_Ver}.tar.bz2 || return 1
        Download_Files ${Download_Mirror}/web/apache/${APR_Util_Ver}.tar.bz2 ${APR_Util_Ver}.tar.bz2 || return 1
    fi
}

LNMP_Get_Build_Jobs()
{
    local Jobs Available_KB Memory_Jobs Limit Usage Cgroup
    if [ -n "${LNMP_BUILD_JOBS:-}" ]; then
        if [[ ! "$LNMP_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
            Echo_Red 'LNMP_BUILD_JOBS must be a positive integer.'
            return 1
        fi
        printf '%s\n' "$LNMP_BUILD_JOBS"
        return 0
    fi
    Jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || Jobs=1
    [[ "$Jobs" =~ ^[1-9][0-9]*$ ]] || Jobs=1
    [ "$Jobs" -le 4 ] || Jobs=4
    Available_KB=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null) || Available_KB=''
    # Respect both cgroup v2 and v1 remaining memory, not the host's RAM size.
    for Cgroup in /sys/fs/cgroup /sys/fs/cgroup/memory; do
        Limit='' Usage=''
        if [[ -r "$Cgroup/memory.max" && -r "$Cgroup/memory.current" ]]; then
            read -r Limit < "$Cgroup/memory.max"
            read -r Usage < "$Cgroup/memory.current"
        elif [[ -r "$Cgroup/memory.limit_in_bytes" && -r "$Cgroup/memory.usage_in_bytes" ]]; then
            read -r Limit < "$Cgroup/memory.limit_in_bytes"
            read -r Usage < "$Cgroup/memory.usage_in_bytes"
        fi
        if [[ "$Limit" =~ ^[0-9]+$ && "$Usage" =~ ^[0-9]+$ ]]; then
            Limit=$(awk -v limit="$Limit" -v usage="$Usage" 'BEGIN {n=int((limit-usage)/1024); printf "%.0f\n", (n > 0 ? n : 0)}')
            if [[ ! "$Available_KB" =~ ^[0-9]+$ ]] || [ "$Limit" -lt "$Available_KB" ]; then
                Available_KB=$Limit
            fi
        fi
    done
    if [[ "$Available_KB" =~ ^[0-9]+$ ]]; then
        Memory_Jobs=$((Available_KB / 1048576))
        [ "$Memory_Jobs" -ge 1 ] || Memory_Jobs=1
        [ "$Jobs" -le "$Memory_Jobs" ] || Jobs=$Memory_Jobs
    fi
    printf '%s\n' "$Jobs"
}

Make_Install()
{
    local Build_Jobs
    Build_Jobs=$(LNMP_Get_Build_Jobs) || exit 1
    if ! make -j "$Build_Jobs"; then
        make -j1 || exit 1
    fi
    make -j1 install || exit 1
}

PHP_Make_Install()
{
    local Build_Jobs
    Build_Jobs=$(LNMP_Get_Build_Jobs) || exit 1
    if ! make ZEND_EXTRA_LIBS='-liconv' -j "$Build_Jobs"; then
        make ZEND_EXTRA_LIBS='-liconv' -j1 || exit 1
    fi
    make -j1 install || exit 1
}

Install_Autoconf()
{
    Echo_Blue "[+] Installing ${Autoconf_Ver}"
    cd ${cur_dir}/src
    Download_Files ${Download_Mirror}/lib/autoconf/${Autoconf_Ver}.tar.gz ${Autoconf_Ver}.tar.gz
    Tar_Cd ${Autoconf_Ver}.tar.gz ${Autoconf_Ver}
    ./configure --prefix=/usr/local/autoconf-2.13
    Make_Install
    cd ${cur_dir}/src/
    rm -rf ${cur_dir}/src/${Autoconf_Ver}
}

Install_Libiconv()
{
    Echo_Blue "[+] Installing ${Libiconv_Ver}"
    Tar_Cd "${Libiconv_Ver}.tar.gz" "$Libiconv_Ver" || exit 1
    ./configure --enable-static || exit 1
    Make_Install || exit 1
    cd ${cur_dir}/src/
    rm -rf ${cur_dir}/src/${Libiconv_Ver}
}

Install_Libmcrypt()
{
    Echo_Blue "[+] Installing ${LibMcrypt_Ver}"
    Tar_Cd ${LibMcrypt_Ver}.tar.gz ${LibMcrypt_Ver}
    ./configure
    Make_Install
    /sbin/ldconfig
    cd libltdl/
    ./configure --enable-ltdl-install
    Make_Install
    ln -sf /usr/local/lib/libmcrypt.la /usr/lib/libmcrypt.la
    ln -sf /usr/local/lib/libmcrypt.so /usr/lib/libmcrypt.so
    ln -sf /usr/local/lib/libmcrypt.so.4 /usr/lib/libmcrypt.so.4
    ln -sf /usr/local/lib/libmcrypt.so.4.4.8 /usr/lib/libmcrypt.so.4.4.8
    ldconfig
    cd ${cur_dir}/src/
    rm -rf ${cur_dir}/src/${LibMcrypt_Ver}
}

Install_Mcrypt()
{
    Echo_Blue "[+] Installing ${Mcypt_Ver}"
    Tar_Cd ${Mcypt_Ver}.tar.gz ${Mcypt_Ver}
    ./configure
    Make_Install
    cd ${cur_dir}/src/
    rm -rf ${cur_dir}/src/${Mcypt_Ver}
}

Install_Mhash()
{
    Echo_Blue "[+] Installing ${Mhash_Ver}"
    Tar_Cd ${Mhash_Ver}.tar.bz2 ${Mhash_Ver}
    ./configure
    Make_Install
    ln -sf /usr/local/lib/libmhash.a /usr/lib/libmhash.a
    ln -sf /usr/local/lib/libmhash.la /usr/lib/libmhash.la
    ln -sf /usr/local/lib/libmhash.so /usr/lib/libmhash.so
    ln -sf /usr/local/lib/libmhash.so.2 /usr/lib/libmhash.so.2
    ln -sf /usr/local/lib/libmhash.so.2.0.1 /usr/lib/libmhash.so.2.0.1
    ldconfig
    cd ${cur_dir}/src/
    rm -rf ${cur_dir}/src/${Mhash_Ver}
}

Install_Freetype()
{
    if PHP_Uses_System_Dependencies || echo "${Ubuntu_Version}" | grep -Eqi "^1[89]\.|2[0-9]\." || echo "${Mint_Version}" | grep -Eqi "^19|2[0-9]" || echo "${Deepin_Version}" | grep -Eqi "^15\.[7-9]|15.1[0-9]|1[6-9]|2[0-9]" || echo "${Debian_Version}" | grep -Eqi "^9|1[0-9]" || echo "${Raspbian_Version}" | grep -Eqi "^9|1[0-9]" || echo "${Kali_Version}" | grep -Eqi "^202[0-9]" || echo "${UOS_Version}" | grep -Eqi "^2[0-9]" || echo "${CentOS_Version}" | grep -Eqi "^(8|9|10)" || echo "${RHEL_Version}" | grep -Eqi "^(8|9|10)" || echo "${Oracle_Version}" | grep -Eqi "^(8|9|10)" || echo "${Fedora_Version}" | grep -Eqi "^3[0-9]|29" || echo "${Rocky_Version}" | grep -Eqi "^(8|9|10)" || echo "${Alma_Version}" | grep -Eqi "^(8|9|10)" || echo "${openEuler_Version}" | grep -Eqi "^2[0-9]" || echo "${Anolis_Version}" | grep -Eqi "^(8|9|10)" || echo "${Kylin_Version}" | grep -Eqi "^V1[0-9]" || echo "${Amazon_Version}" | grep -Eqi "^202[3-9]" || echo "${OpenCloudOS_Version}" | grep -Eqi "^(8|9|10|23)" || echo "${HCE_Version}" | grep -Eqi "^2\.[0-9]"; then
        Download_Files "${Download_Mirror}/lib/freetype/${Freetype_New_Ver}.tar.xz" "${Freetype_New_Ver}.tar.xz" || exit 1
        Echo_Blue "[+] Installing ${Freetype_New_Ver}"
        Tar_Cd "${Freetype_New_Ver}.tar.xz" "$Freetype_New_Ver" || exit 1
        ./configure --prefix=/usr/local/freetype --enable-freetype-config || exit 1
    else
        Download_Files "${Download_Mirror}/lib/freetype/${Freetype_Ver}.tar.bz2" "${Freetype_Ver}.tar.bz2" || exit 1
        Echo_Blue "[+] Installing ${Freetype_Ver}"
        Tar_Cd "${Freetype_Ver}.tar.bz2" "$Freetype_Ver" || exit 1
        ./configure --prefix=/usr/local/freetype || exit 1
    fi
    Make_Install || exit 1

    [[ -d /usr/lib/pkgconfig ]] && \cp /usr/local/freetype/lib/pkgconfig/freetype2.pc /usr/lib/pkgconfig/
    cat > /etc/ld.so.conf.d/freetype.conf<<EOF
/usr/local/freetype/lib
EOF
    ldconfig
    ln -sf /usr/local/freetype/include/freetype2/* /usr/include/
    cd ${cur_dir}/src/
    rm -rf ${cur_dir}/src/${Freetype_Ver}
}

Install_Curl()
{
    if PHP_Uses_System_Dependencies; then
        Prepare_PHP_System_Dependencies || exit 1
        return 0
    fi
    if [[ ! -s /usr/local/curl/bin/curl || ! -s /usr/local/curl/lib/libcurl.so || ! -s /usr/local/curl/include/curl/curl.h ]]; then
        Echo_Blue "[+] Installing ${Curl_Ver}"
        cd ${cur_dir}/src
        Download_Files ${Download_Mirror}/lib/curl/${Curl_Ver}.tar.bz2 ${Curl_Ver}.tar.bz2
        Tar_Cd ${Curl_Ver}.tar.bz2 ${Curl_Ver}
        if [ -s /usr/local/openssl/bin/openssl ] || /usr/local/openssl/bin/openssl version | grep -Eqi 'OpenSSL 1.0.2'; then
            ./configure --prefix=/usr/local/curl --enable-ares --without-nss --with-zlib --with-ssl=/usr/local/openssl
        else
            ./configure --prefix=/usr/local/curl --enable-ares --without-nss --with-zlib --with-ssl
        fi
        Make_Install
        cd ${cur_dir}/src/
        rm -rf ${cur_dir}/src/${Curl_Ver}
        ldconfig
    fi
    Remove_Error_Libcurl
}

Install_Pcre()
{
    local Target_Nginx=${Nginx_Version:-${Nginx_Ver#nginx-}} Regex_Source Option
    Nginx_With_Pcre=''
    if [[ ! "$Target_Nginx" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        Echo_Red "Cannot select PCRE for invalid Nginx version: ${Target_Nginx}."
        return 1
    fi
    if [ "$("${cur_dir}/include/version_compare" 1.21.5 "$Target_Nginx")" = '1' ]; then
        Regex_Source=${Pcre_Legacy_Ver:-pcre-8.45}
        [[ "$Regex_Source" =~ ^pcre-8\.[0-9]+$ ]] || return 1
        Echo_Red "Legacy Nginx ${Target_Nginx}: isolated PCRE1 ${Regex_Source}; PCRE2 requires Nginx >= 1.21.5."
    else
        Regex_Source=$Pcre_Ver
        if [[ ! "$Regex_Source" =~ ^pcre2-10\.[0-9]+$ ]]; then
            Echo_Red "Nginx >= 1.21.5 requires Pcre_Ver=pcre2-10.xx (archive: .tar.bz2)."
            return 1
        fi
        for Option in ${Nginx_Modules_Options}; do
            case "$Option" in
                --without-pcre|--without-pcre2|--with-pcre=*)
                    Echo_Red "Conflicting PCRE option: ${Option}; LNMP selects the pinned PCRE2 source."
                    return 1
                    ;;
            esac
        done
    fi
    Echo_Blue "[+] Preparing ${Regex_Source} for Nginx ${Target_Nginx}"
    cd "${cur_dir}/src" || return 1
    Download_Files "${Download_Mirror}/web/pcre/${Regex_Source}.tar.bz2" "${Regex_Source}.tar.bz2" || return 1
    Tar_Cd "${Regex_Source}.tar.bz2" "$Regex_Source" || return 1
    Nginx_With_Pcre="--with-pcre=${cur_dir}/src/${Regex_Source} --with-pcre-jit"
    cd "${cur_dir}/src" || return 1
}

Install_Jemalloc()
{
    Echo_Blue "[+] Installing ${Jemalloc_Ver}"
    cd ${cur_dir}/src
    Tar_Cd ${Jemalloc_Ver}.tar.bz2 ${Jemalloc_Ver}
    ./configure
    Make_Install
    ldconfig
    cd ${cur_dir}/src/
    rm -rf ${cur_dir}/src/${Jemalloc_Ver}
    ln -sf /usr/local/lib/libjemalloc* /usr/lib/
}

Install_TCMalloc()
{
    Echo_Blue "[+] Installing ${TCMalloc_Ver}"
    if [ "${Is_64bit}" = "y" ]; then
        Tar_Cd ${Libunwind_Ver}.tar.gz ${Libunwind_Ver}
        CFLAGS=-fPIC ./configure
        make CFLAGS=-fPIC
        make CFLAGS=-fPIC install
        rm -rf ${cur_dir}/src/${Libunwind_Ver}
    fi
    Tar_Cd ${TCMalloc_Ver}.tar.gz ${TCMalloc_Ver}
    if [ "${Is_64bit}" = "y" ]; then
        ./configure
    else
        ./configure --enable-frame-pointers
    fi
    Make_Install
    ldconfig
    cd ${cur_dir}/src/
    rm -rf ${cur_dir}/src/${TCMalloc_Ver}
    ln -sf /usr/local/lib/libtcmalloc* /usr/lib/
}

Install_Icu4c()
{
    if PHP_Uses_System_Dependencies; then
        Prepare_PHP_System_Dependencies || exit 1
        return 0
    fi
    if command -v icu-config >/dev/null 2>&1 && icu-config --version | grep -Eq "^3."; then
        Echo_Blue "[+] Installing ${Libicu4c_Ver}"
        cd ${cur_dir}/src
        Download_Files ${Download_Mirror}/lib/icu4c/${Libicu4c_Ver}-src.tgz ${Libicu4c_Ver}-src.tgz
        Tar_Cd ${Libicu4c_Ver}-src.tgz icu/source
        ./configure --prefix=/usr
        if [ ! -s /usr/include/xlocale.h ]; then
            ln -s /usr/include/locale.h /usr/include/xlocale.h
        fi
        Make_Install
        cd ${cur_dir}/src/
        rm -rf ${cur_dir}/src/icu
    fi
}

Install_Icu60()
{
    if PHP_Uses_System_Dependencies; then
        Prepare_PHP_System_Dependencies || exit 1
        return 0
    fi
    if [ ! -s /usr/local/icu/bin/icu-config ]; then
        Echo_Blue "[+] Installing icu4c-60_3..."
        cd ${cur_dir}/src
        Download_Files ${Download_Mirror}/lib/icu4c/icu4c-60_3-src.tgz icu4c-60_3-src.tgz
        Tar_Cd icu4c-60_3-src.tgz icu/source
        ./configure --prefix=/usr/local/icu
        Make_Install
        cd ${cur_dir}/src/

        echo "/usr/local/icu/lib" > /etc/ld.so.conf.d/icu.conf
        ldconfig
    fi
}

Download_Boost()
{
    Echo_Blue "[+] Download or use exist boost..."
    if [ "${DBSelect}" = "4" ] || echo "${mysql_version}" | grep -Eqi '^5.7.'; then
        if [ -s "${cur_dir}/src/${Boost_Ver}.tar.bz2" ]; then
            [[ -d "${cur_dir}/src/${Boost_Ver}" ]] && rm -rf "${cur_dir}/src/${Boost_Ver}"
            tar jxf ${cur_dir}/src/${Boost_Ver}.tar.bz2 -C ${cur_dir}/src
            MySQL_WITH_BOOST="-DWITH_BOOST=${cur_dir}/src/${Boost_Ver}"
        else
            cd ${cur_dir}/src/
            Download_Files ${Download_Mirror}/lib/boost/${Boost_Ver}.tar.bz2 ${Boost_Ver}.tar.bz2
            tar jxf ${cur_dir}/src/${Boost_Ver}.tar.bz2
            cd -
            MySQL_WITH_BOOST="-DWITH_BOOST=${cur_dir}/src/${Boost_Ver}"
        fi
    elif [ "${DBSelect}" = "5" ] || echo "${mysql_version}" | grep -Eqi '^8.'; then
        Get_Boost_Ver=$(grep 'SET(BOOST_PACKAGE_NAME' cmake/boost.cmake |grep -oP '\d+(\_\d+){2}')
        if [ -s "${cur_dir}/src/boost_${Get_Boost_Ver}.tar.bz2" ]; then
            [[ -d "${cur_dir}/src/boost_${Get_Boost_Ver}" ]] && rm -rf "${cur_dir}/src/boost_${Get_Boost_Ver}"
            tar jxf ${cur_dir}/src/boost_${Get_Boost_Ver}.tar.bz2 -C ${cur_dir}/src
            MySQL_WITH_BOOST="-DWITH_BOOST=${cur_dir}/src/boost_${Get_Boost_Ver}"
        else
            MySQL_WITH_BOOST="-DDOWNLOAD_BOOST=1 -DWITH_BOOST=${cur_dir}/src"
        fi
    fi
}

Install_Boost()
{
    if [ -d extra/boost ]; then
        MySQL_WITH_BOOST=''
        return 0
    fi
    Echo_Blue "[+] Download or use exist boost..."
    if [ "${DBSelect}" = "4" ] || [ "${DBSelect}" = "5" ]; then
        if [ -d "${cur_dir}/src/${Mysql_Ver}/boost" ]; then
            MySQL_WITH_BOOST="-DWITH_BOOST=${cur_dir}/src/${Mysql_Ver}/boost"
        else
            Download_Boost
        fi
    elif echo "${mysql_version}" | grep -Eqi '^5.7.' || echo "${mysql_version}" | grep -Eqi '^8.'; then
        if [ -d "${cur_dir}/src/mysql-${mysql_version}/boost" ]; then
            MySQL_WITH_BOOST="-DWITH_BOOST=${cur_dir}/src/mysql-${mysql_version}/boost"
        else
            Download_Boost
        fi
    fi
}

Install_Openssl()
{
    if [ ! -s /usr/local/openssl/bin/openssl ] || /usr/local/openssl/bin/openssl version | grep -v 'OpenSSL 1.0.2'; then
        Echo_Blue "[+] Installing ${Openssl_Ver}"
        cd ${cur_dir}/src
        Download_Files ${Download_Mirror}/lib/openssl/${Openssl_Ver}.tar.gz ${Openssl_Ver}.tar.gz
        [[ -d "${Openssl_Ver}" ]] && rm -rf ${Openssl_Ver}
        Tar_Cd ${Openssl_Ver}.tar.gz ${Openssl_Ver}
        ./config -fPIC --prefix=/usr/local/openssl --openssldir=/usr/local/openssl
        make depend
        Make_Install
        cd ${cur_dir}/src/
        rm -rf ${cur_dir}/src/${Openssl_Ver}
    fi
}

Install_Openssl_New()
{
    apache_with_ssl=''
    if openssl version | grep -Eqi "OpenSSL 3."; then
        apache_with_ssl='--with-ssl'
    else
        if [ ! -s /usr/local/openssl3/bin/openssl ] || /usr/local/openssl3/bin/openssl version | grep -v 'OpenSSL 3'; then
            Echo_Blue "[+] Installing ${Openssl_New_Ver}"
            cd "${cur_dir}/src" || exit 1
            if ! Download_Files "${Download_Mirror}/lib/openssl/${Openssl_New_Ver}.tar.gz" "${Openssl_New_Ver}.tar.gz"; then
                Download_Files "https://www.openssl.org/source/${Openssl_New_Ver}.tar.gz" "${Openssl_New_Ver}.tar.gz" || exit 1
            fi
            Tar_Cd "${Openssl_New_Ver}.tar.gz" "$Openssl_New_Ver" || exit 1
            ./config -fPIC --prefix=/usr/local/openssl3 --openssldir=/usr/local/openssl3 || exit 1
            make depend || exit 1
            Make_Install || exit 1
            cd "${cur_dir}/src" || exit 1
            rm -rf "${cur_dir}/src/${Openssl_New_Ver}"
        fi
        ldconfig || exit 1
        apache_with_ssl='--with-ssl=/usr/local/openssl3'
    fi
}

Install_Openssl_Compat()
{
    if [ ! -s /usr/local/openssl1.1.1/bin/openssl ] || /usr/local/openssl1.1.1/bin/openssl version | grep -v 'OpenSSL 1.1.1'; then
        Echo_Blue "[+] Installing ${Openssl_Compat_Ver}"
        cd ${cur_dir}/src
        Download_Files ${Download_Mirror}/lib/openssl/${Openssl_Compat_Ver}.tar.gz ${Openssl_Compat_Ver}.tar.gz
        if [ $? -ne 0 ]; then
            Download_Files https://www.openssl.org/source/old/1.1.1/${Openssl_Compat_Ver}.tar.gz ${Openssl_Compat_Ver}.tar.gz
            if [ $? -ne 0 ]; then
                Echo_Red "Error! Unable to download ${Openssl_Compat_Ver}."
                exit 1
            fi
        fi
        [[ -d "${Openssl_Compat_Ver}" ]] && rm -rf ${Openssl_Compat_Ver}
        Tar_Cd ${Openssl_Compat_Ver}.tar.gz ${Openssl_Compat_Ver}
        ./config -fPIC --prefix=/usr/local/openssl1.1.1 --openssldir=/usr/local/openssl1.1.1
        make depend
        Make_Install
        if [ -s /usr/local/openssl1.1.1/lib/libcrypto.so.1.1 ]; then
            ln -sf /usr/local/openssl1.1.1/lib/libcrypto.so.1.1 /usr/lib/
            ln -sf /usr/local/openssl1.1.1/lib/libssl.so.1.1 /usr/lib/
        elif [ -s /usr/local/openssl1.1.1/lib64/libcrypto.so.1.1 ]; then
            ln -sf /usr/local/openssl1.1.1/lib64/libcrypto.so.1.1 /usr/lib/
            ln -sf /usr/local/openssl1.1.1/lib64/libssl.so.1.1 /usr/lib/
        fi
        cd ${cur_dir}/src/
        rm -rf ${cur_dir}/src/${Openssl_Compat_Ver}
    fi
    ldconfig
}

Install_Nghttp2()
{
    if [[ ! -s /usr/local/nghttp2/lib/libnghttp2.so || ! -s /usr/local/nghttp2/include/nghttp2/nghttp2.h ]]; then
        Echo_Blue "[+] Installing ${Nghttp2_Ver}"
        cd "${cur_dir}/src" || exit 1
        Download_Files "${Download_Mirror}/lib/nghttp2/${Nghttp2_Ver}.tar.bz2" "${Nghttp2_Ver}.tar.bz2" || exit 1
        Tar_Cd "${Nghttp2_Ver}.tar.bz2" "$Nghttp2_Ver" || exit 1
        ./configure --prefix=/usr/local/nghttp2 --enable-lib-only || exit 1
        Make_Install || exit 1
        cd "${cur_dir}/src" || exit 1
        rm -rf "${cur_dir}/src/${Nghttp2_Ver}"
    fi
}

PHP_Uses_System_Dependencies()
{
    # Prefer the explicit target version over a possibly stale menu selection.
    local Target_PHP=${php_version:-${Php_Ver#php-}}
    if [ -n "$Target_PHP" ]; then
        [[ "$Target_PHP" =~ ^8\.[2-5](\.|$) ]]
    else
        [[ "$PHPSelect" =~ ^1[3-6]$ ]]
    fi
}

Prepare_PHP_System_Dependencies()
{
    local Pc_Dirs='' Directory Module Prefix Flags Libs Curl_Features Curl_Min=7.29.0
    local Target_PHP=${php_version:-${Php_Ver#php-}}
    PHP_Uses_System_Dependencies || return 0
    command -v pkg-config >/dev/null 2>&1 || { Echo_Red 'pkg-config is required for PHP system dependencies.'; return 1; }
    # Ignore /usr/local and user PKG_CONFIG_PATH only for these three libraries.
    for Directory in $(pkg-config --variable=pc_path pkg-config | tr ':' ' '); do
        case "$Directory" in
            /usr/local/*) ;;
            /usr/lib/*|/usr/lib64/pkgconfig|/usr/lib/pkgconfig|/usr/share/pkgconfig|/lib/*|/lib64/pkgconfig)
                Pc_Dirs=${Pc_Dirs:+${Pc_Dirs}:}${Directory}
                ;;
        esac
    done
    [ -n "$Pc_Dirs" ] || { Echo_Red 'Cannot locate distribution pkg-config directories.'; return 1; }
    [[ "$Target_PHP" =~ ^8\.5(\.|$) || ( -z "$Target_PHP" && "$PHPSelect" = '16' ) ]] && Curl_Min=7.61.0
    if ! PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$Pc_Dirs" pkg-config --exists "libcurl >= $Curl_Min" 'libzip >= 0.11' 'libzip != 1.3.1' 'libzip != 1.7.0' 'icu-uc >= 57.1' icu-io icu-i18n; then
        Echo_Red "Install distribution libcurl (>= ${Curl_Min}), libzip and ICU development packages; legacy source fallback is disabled for PHP 8.2-8.5."
        return 1
    fi
    for Module in libcurl libzip icu-uc icu-io icu-i18n; do
        Prefix=$(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$Pc_Dirs" pkg-config --variable=prefix "$Module") || return 1
        if [[ "$Prefix" != /usr && "$Prefix" != / ]]; then
            Echo_Red "Expected a distribution ${Module}, found prefix ${Prefix}."
            return 1
        fi
    done
    Flags=$(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$Pc_Dirs" pkg-config --cflags libcurl) || return 1
    Libs=$(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$Pc_Dirs" pkg-config --libs libcurl) || return 1
    export CURL_CFLAGS="$Flags" CURL_LIBS="$Libs"
    Curl_Features=$(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$Pc_Dirs" pkg-config --variable=supported_features libcurl) || return 1
    # Older pkgconf can retain the .pc value's enclosing quotes.
    case "$Curl_Features" in
        \"*\") Curl_Features=${Curl_Features#\"}; Curl_Features=${Curl_Features%\"} ;;
        \'*\') Curl_Features=${Curl_Features#\'}; Curl_Features=${Curl_Features%\'} ;;
    esac
    if [[ ! "$Curl_Features" =~ ^[A-Za-z0-9_.+[:blank:]-]*$ ]]; then
        Echo_Red 'Unsupported characters in distribution cURL feature metadata.'
        return 1
    fi
    export CURL_FEATURES="$Curl_Features"
    Flags=$(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$Pc_Dirs" pkg-config --cflags libzip) || return 1
    Libs=$(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$Pc_Dirs" pkg-config --libs libzip) || return 1
    export LIBZIP_CFLAGS="$Flags" LIBZIP_LIBS="$Libs"
    Flags=$(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$Pc_Dirs" pkg-config --cflags icu-uc icu-io icu-i18n) || return 1
    Libs=$(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$Pc_Dirs" pkg-config --libs icu-uc icu-io icu-i18n) || return 1
    export ICU_CFLAGS="$Flags" ICU_LIBS="$Libs"
    with_curl='--with-curl'
    with_icu_dir=''
}

Install_Libzip()
{
    if PHP_Uses_System_Dependencies; then
        Prepare_PHP_System_Dependencies || exit 1
        return 0
    fi
    if echo "${CentOS_Version}" | grep -Eqi "^7"  || echo "${RHEL_Version}" | grep -Eqi "^7"  || echo "${Aliyun_Version}" | grep -Eqi "^2" || echo "${Alibaba_Version}" | grep -Eqi "^2" || echo "${Oracle_Version}" | grep -Eqi "^7" || echo "${Anolis_Version}" | grep -Eqi "^7"; then
        if [ ! -s /usr/local/lib/libzip.so ]; then
            Echo_Blue "[+] Installing ${Libzip_Ver}"
            cd ${cur_dir}/src
            Download_Files ${Download_Mirror}/lib/libzip/${Libzip_Ver}.tar.xz ${Libzip_Ver}.tar.xz
            Tar_Cd ${Libzip_Ver}.tar.xz ${Libzip_Ver}
            ./configure
            Make_Install
            cd ${cur_dir}/src/
            rm -rf ${cur_dir}/src/${Libzip_Ver}
        fi
        export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:$PKG_CONFIG_PATH
        ldconfig
    fi
}

CentOS_Lib_Opt()
{
    if [ "${Is_64bit}" = "y" ] ; then
        ln -sf /usr/lib64/libpng.* /usr/lib/
        ln -sf /usr/lib64/libjpeg.* /usr/lib/
    fi

    ulimit -v unlimited

    if [ `grep -L "/lib"    '/etc/ld.so.conf'` ]; then
        echo "/lib" >> /etc/ld.so.conf
    fi

    if [ `grep -L '/usr/lib'    '/etc/ld.so.conf'` ]; then
        echo "/usr/lib" >> /etc/ld.so.conf
        #echo "/usr/lib/openssl/engines" >> /etc/ld.so.conf
    fi

    if [ -d "/usr/lib64" ] && [ `grep -L '/usr/lib64'    '/etc/ld.so.conf'` ]; then
        echo "/usr/lib64" >> /etc/ld.so.conf
        #echo "/usr/lib64/openssl/engines" >> /etc/ld.so.conf
    fi

    if [ `grep -L '/usr/local/lib'    '/etc/ld.so.conf'` ]; then
        echo "/usr/local/lib" >> /etc/ld.so.conf
    fi

    ldconfig

    if command -v systemd-detect-virt >/dev/null 2>&1 && [[ "$(systemd-detect-virt)" = "lxc" ]]; then
        cat >>/etc/security/limits.conf<<eof
* soft nofile 65535
* hard nofile 65535
eof
    else
        cat >>/etc/security/limits.conf<<eof
* soft nproc 65535
* hard nproc 65535
* soft nofile 65535
* hard nofile 65535
eof
    fi

    echo "fs.file-max=65535" >> /etc/sysctl.conf

    if echo "${Fedora_Version}" | grep -Eqi "3[0-9]" && [ ! -d "/etc/init.d" ]; then
        ln -sf /etc/rc.d/init.d /etc/init.d
    fi

    if [ -s /usr/lib64/libtinfo.so.6 ]; then
        ln -sf /usr/lib64/libtinfo.so.6 /usr/lib64/libtinfo.so.5
    elif [ -s /usr/lib/libtinfo.so.6 ]; then
        ln -sf /usr/lib/libtinfo.so.6 /usr/lib/libtinfo.so.5
    fi

    if [ -s /usr/lib64/libncurses.so.6 ]; then
        ln -sf /usr/lib64/libncurses.so.6 /usr/lib64/libncurses.so.5
    elif [ -s /usr/lib/libncurses.so.6 ]; then
        ln -sf /usr/lib/libncurses.so.6 /usr/lib/libncurses.so.5
    fi
}

Deb_Lib_Opt()
{
    if [ "${Is_64bit}" = "y" ]; then
        ln -sf /usr/lib/x86_64-linux-gnu/libpng* /usr/lib/
        ln -sf /usr/lib/x86_64-linux-gnu/libjpeg* /usr/lib/
    else
        ln -sf /usr/lib/i386-linux-gnu/libpng* /usr/lib/
        ln -sf /usr/lib/i386-linux-gnu/libjpeg* /usr/lib/
        ln -sf /usr/include/i386-linux-gnu/asm /usr/include/asm
    fi

    if [ -d "/usr/lib/arm-linux-gnueabihf" ]; then
        ln -sf /usr/lib/arm-linux-gnueabihf/libpng* /usr/lib/
        ln -sf /usr/lib/arm-linux-gnueabihf/libjpeg* /usr/lib/
        ln -sf /usr/include/arm-linux-gnueabihf/curl /usr/include/
    fi

    ulimit -v unlimited

    if [ `grep -L "/lib"    '/etc/ld.so.conf'` ]; then
        echo "/lib" >> /etc/ld.so.conf
    fi

    if [ `grep -L '/usr/lib'    '/etc/ld.so.conf'` ]; then
        echo "/usr/lib" >> /etc/ld.so.conf
    fi

    if [ -d "/usr/lib64" ] && [ `grep -L '/usr/lib64'    '/etc/ld.so.conf'` ]; then
        echo "/usr/lib64" >> /etc/ld.so.conf
    fi

    if [ `grep -L '/usr/local/lib'    '/etc/ld.so.conf'` ]; then
        echo "/usr/local/lib" >> /etc/ld.so.conf
    fi

    if [ -d /usr/include/x86_64-linux-gnu/curl ]; then
        ln -sf /usr/include/x86_64-linux-gnu/curl /usr/include/
    elif [ -d /usr/include/i386-linux-gnu/curl ]; then
        ln -sf /usr/include/i386-linux-gnu/curl /usr/include/
    fi

    if [ -d /usr/include/arm-linux-gnueabihf/curl ]; then
        ln -sf /usr/include/arm-linux-gnueabihf/curl /usr/include/
    fi

    if [ -d /usr/include/aarch64-linux-gnu/curl ]; then
        ln -sf /usr/include/aarch64-linux-gnu/curl /usr/include/
    fi

    ldconfig

    cat >>/etc/security/limits.conf<<eof
* soft nproc 65535
* hard nproc 65535
* soft nofile 65535
* hard nofile 65535
eof

    echo "fs.file-max=65535" >> /etc/sysctl.conf
}

Remove_Error_Libcurl()
{
    if [ -s /usr/local/lib/libcurl.so ]; then
        rm -f /usr/local/lib/libcurl*
    fi
}

Add_Swap()
{

    Disk_Avail=$(($(df -mP /var | tail -1 | awk '{print $4}' | sed s/[[:space:]]//g)/1024))

    DD_Count='1024'
    if [[ "${MemTotal}" -lt 1024 ]]; then
        DD_Count='1024'
        if [[ "${Disk_Avail}" -lt 5 ]]; then
            Enable_Swap='n'
        fi
    elif [[ "${MemTotal}" -ge 1024 && "${MemTotal}" -le 2048 ]]; then
        DD_Count='2048'
        if [[ "${Disk_Avail}" -lt 13 ]]; then
            Enable_Swap='n'
        fi
    elif [[ "${MemTotal}" -ge 2048 && "${MemTotal}" -le 4096 ]]; then
        DD_Count='4096'
        if [[ "${Disk_Avail}" -lt 17 ]]; then
            Enable_Swap='n'
        fi
    elif [[ "${MemTotal}" -ge 4096 && "${MemTotal}" -le 16384 ]]; then
        DD_Count='8192'
        if [[ "${Disk_Avail}" -lt 19 ]]; then
            Enable_Swap='n'
        fi
    elif [[ "${MemTotal}" -ge 16384 ]]; then
        DD_Count='8192'
        if [[ "${Disk_Avail}" -lt 27 ]]; then
            Enable_Swap='n'
        fi
    fi
    Swap_Total=$(awk '/SwapTotal/ {printf( "%d\n", $2 / 1024 )}' /proc/meminfo)
    if [[ "${Enable_Swap}" = "y" && "${Swap_Total}" -le 512 && ! -s /var/swapfile ]]; then
        echo "Add Swap file..."
        [ $(cat /proc/sys/vm/swappiness) -eq 0 ] && sysctl vm.swappiness=10
        dd if=/dev/zero of=/var/swapfile bs=1M count=${DD_Count}
        chmod 0600 /var/swapfile
        echo "Enable Swap..."
        /sbin/mkswap /var/swapfile
        /sbin/swapon /var/swapfile
        if [ $? -eq 0 ]; then
            [ `grep -L '/var/swapfile'    '/etc/fstab'` ] && echo "/var/swapfile swap swap defaults 0 0" >>/etc/fstab
            /sbin/swapon -s
        else
            rm -f /var/swapfile
            echo "Add Swap Failed!"
        fi
    fi
}
