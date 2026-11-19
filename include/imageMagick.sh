#!/usr/bin/env bash

. "$(dirname -- "${BASH_SOURCE[0]}")/php_extension.sh"

PHP_Imagick_Dependencies()
{
    if [ "${PM}" = apt ]; then
        apt-get install -y pkg-config libwebp-dev libjpeg-dev libpng-dev libtiff-dev || return $?
    elif [ "${PM}" = yum ]; then
        yum install -y pkgconfig libwebp-devel libjpeg-turbo-devel libpng-devel libtiff-devel || return $?
    else
        Echo_Red "Unsupported package manager for ImageMagick dependencies."
        return 1
    fi
}

Build_ImageMagick()
(
    if [ -s /usr/local/imagemagick/bin/magick ] || [ -s /usr/local/imagemagick/bin/convert ]; then
        echo "Existing ImageMagick installation preserved."
        return 0
    fi
    if [ -e /usr/local/imagemagick ]; then
        Echo_Red "Incomplete ImageMagick prefix; refusing to overwrite existing files."
        return 1
    fi
    PHP_Extension_Fetch "https://github.com/ImageMagick/ImageMagick/releases/download/${ImageMagick_Ver#ImageMagick-}/${ImageMagick_Ver}.tar.xz" "${ImageMagick_Ver}.tar.xz" "${ImageMagick_Ver}" || return $?
    ./configure --prefix=/usr/local/imagemagick || return $?
    make || return $?
    make install || return $?
    /usr/local/imagemagick/bin/magick -version || return $?
)

Install_ImageMagic()
(
    echo "====== Installing ImageMagick ======"
    PHP_Extension_Prepare 50600 80599 || return $?
    Press_Start
    PHP_Imagick_Dependencies || return $?
    Build_ImageMagick || return $?
    export PKG_CONFIG_PATH="/usr/local/imagemagick/lib/pkgconfig:${PKG_CONFIG_PATH}"
    export LDFLAGS="${LDFLAGS} -Wl,-rpath,/usr/local/imagemagick/lib"
    PHP_Extension_Fetch "https://pecl.php.net/get/${Imagick_Ver}.tgz" "${Imagick_Ver}.tgz" "${Imagick_Ver}" || return $?
    PHP_Extension_Build imagick --with-imagick=/usr/local/imagemagick || return $?
    PHP_Extension_Activate imagick 008-imagick.ini <<'EOF' || return $?
extension = "imagick.so"
EOF
    Echo_Green "====== ImageMagick install completed ======"
)

Uninstall_ImageMagick()
{
    echo "You will uninstall ImageMagick..."
    Press_Start
    rm -f ${PHP_Path}/conf.d/008-imagick.ini
    echo "Delete ImageMagick directory..."
    rm -rf /usr/local/imagemagick
    Restart_PHP
    Echo_Green "Uninstall ImageMagick completed."
}
