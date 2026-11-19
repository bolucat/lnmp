#!/usr/bin/env bash

PMA_Safe_Path()
{
    local Path=$1
    [[ "$Path" = /* && "$Path" != *//* && "$Path" != */./* && "$Path" != */../* &&
       "$Path" != */. && "$Path" != */.. && "$Path" != *$'\n'* && "$Path" != *$'\r'* ]] || return 1
    while :; do
        [ ! -L "$Path" ] || return 1
        [ "$Path" != / ] || break
        Path=${Path%/*}
        [ -n "$Path" ] || Path=/
    done
}

PMA_Staging_Parent()
{
    local PHP_Bin=${2:-/usr/local/php/bin/php}
    "$PHP_Bin" -n -r '
        $site = lstat($argv[1]); $uid = (int) $argv[2];
        if (!$site) exit(1);
        $trusted = function ($path) use ($uid) {
            for (;;) {
                $s = lstat($path);
                if (!$s || is_link($path) || ($s["uid"] !== 0 && $s["uid"] !== $uid)) return false;
                if (($s["mode"] & 0022) && !($s["uid"] === 0 && ($s["mode"] & 01000))) return false;
                if ($path === "/") return true;
                $path = dirname($path);
            }
        };
        for ($dir = dirname($argv[1]); ; $dir = dirname($dir)) {
            $s = lstat($dir);
            if ($s && $s["dev"] === $site["dev"] && $s["uid"] === $uid && $trusted($dir)) { echo $dir; exit; }
            if ($dir === "/") break;
        }
        exit(1);
    ' "$1" "$(id -u)"
}

PMA_Rename()
{
    local PHP_Bin=/usr/local/php/bin/php
    # rename(2) never treats a competing destination directory as a container.
    "$PHP_Bin" -n -r '
        if (is_link($argv[1]) || !is_dir($argv[1]) || lstat($argv[2]) !== false) exit(1);
        exit(rename($argv[1], $argv[2]) ? 0 : 1);
    ' "$1" "$2" 2>/dev/null
}

Upgrade_phpMyAdmin()
(
    set -o pipefail
    umask 077
    local Version=${1:-} Package=phpMyAdmin-5.2.3-all-languages
    local Expected=57881348297c4412f86c410547cf76b4d8a236574dd2c6b7d6a2beebe7fc44e3
    local PHP_Bin=/usr/local/php/bin/php
    local Source_Root=${cur_dir:-} Website=${Default_Website_Dir:-}
    local Target Lock Lock_ID Stage_Parent Stage='' Candidate='' Old_Config=n Old_Identity New_Identity=''
    local Listing Types Entry Found Device_Path
    local Enable_Download_Checksum=y Download_Insecure=n
    local Fresh=n

    case "${2:-}" in '') ;; --fresh) Fresh=y ;; *) Echo_Red 'Unknown phpMyAdmin operation.'; exit 1 ;; esac
    [ "$#" -le 2 ] || exit 1
    if [ -z "$Version" ]; then
        read -r -p 'phpMyAdmin version (trusted release: 5.2.3): ' Version || exit 1
    fi
    [ "$Version" = 5.2.3 ] || { Echo_Red 'Only the pinned phpMyAdmin 5.2.3 release is supported.'; exit 1; }
    [ -x "$PHP_Bin" ] && "$PHP_Bin" -n -r 'exit(version_compare(PHP_VERSION, "7.2.0", ">=") ? 0 : 1);' || {
        Echo_Red 'phpMyAdmin 5.2.3 requires the current /usr/local/php PHP runtime to be >= 7.2.'; exit 1;
    }
    while [[ "$Website" = */ && "$Website" != / ]]; do Website=${Website%/}; done
    case "$Website" in
        /|/etc|/etc/*|/proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/bin|/bin/*|/sbin|/sbin/*|/usr|/usr/bin|/usr/bin/*|/usr/sbin|/usr/sbin/*|/usr/local|/lib|/lib/*|/lib64|/lib64/*|/root|/home|/var|/tmp)
            Echo_Red 'Unsafe website root.'; exit 1 ;;
    esac
    PMA_Safe_Path "$Website" && [ -d "$Website" ] &&
        PMA_Safe_Path "$Source_Root" && [ -d "$Source_Root/src" ] || {
        Echo_Red 'Website/source directories must be absolute real directories without symlink parents.'; exit 1;
    }
    Target=$Website/phpmyadmin
    PMA_Safe_Path "$Target" && PMA_Safe_Path "$Source_Root/src" || exit 1
    if [ "$Fresh" = y ] && { [ -e "$Target" ] || [ -L "$Target" ]; }; then
        Echo_Red 'Existing phpMyAdmin found; fresh installation will not overwrite it. Use upgrade.sh phpmyadmin.'; exit 1
    fi
    if [ -e "$Target" ] && [ ! -d "$Target" ]; then Echo_Red 'phpmyadmin is not a directory.'; exit 1; fi
    if [ -d "$Target" ]; then
        Found=$(find "$Target" ! -type d ! -type f -print -quit) || exit 1
        [ -z "$Found" ] || { Echo_Red 'Symlinks/special files in the existing phpMyAdmin tree are not supported.'; exit 1; }
    fi

    PMA_Identity()
    {
        "$PHP_Bin" -n -r '
            if (is_link($argv[1])) exit(1);
            if (!file_exists($argv[1])) { echo "absent"; exit; }
            $s = lstat($argv[1]); if (!$s) exit(1);
            echo $s["dev"], ":", $s["ino"];
        ' "$1"
    }
    Old_Identity=$(PMA_Identity "$Target") || exit 1
    # The web user must not be able to rename/replace the staging or lock directory.
    Stage_Parent=$(PMA_Staging_Parent "$Website" "$PHP_Bin") || {
        Echo_Red 'No protected same-filesystem staging parent; prepare an administrator-owned non-writable ancestor first.'; exit 1;
    }
    PMA_Safe_Path "$Stage_Parent" || exit 1
    Lock_ID=$("$PHP_Bin" -n -r 'echo hash("sha256", $argv[1]);' "$Target") || exit 1
    [[ "$Lock_ID" =~ ^[0-9a-f]{64}$ ]] || exit 1
    Lock=$Stage_Parent/.lnmp-phpmyadmin-$Lock_ID.lock
    if [ "$Fresh" != y ]; then Press_Start || exit 1; fi
    mkdir -m 700 -- "$Lock" || { Echo_Red 'Another phpMyAdmin upgrade/recovery holds the lock; do not remove an active lock.'; exit 1; }

    PMA_Cleanup()
    {
        local Status=$? Recovery=y Current=''
        trap - EXIT INT TERM
        if [ "$Status" -ne 0 ] && [ -n "$Stage" ]; then
            Current=$(PMA_Identity "$Target") || Recovery=n
            if [ -n "$New_Identity" ] && [ "$Current" = "$New_Identity" ]; then
                PMA_Rename "$Target" "$Stage/failed-candidate" || Recovery=n
                Current=absent
            fi
            if [ -d "$Stage/previous" ]; then
                if [ "$Current" = absent ] && [ "$Recovery" = y ]; then
                    PMA_Rename "$Stage/previous" "$Target" || Recovery=n
                else
                    Recovery=n
                fi
            fi
            if [ "$Recovery" = y ] && [ "$Old_Identity" != absent ]; then
                [ "$(PMA_Identity "$Target")" = "$Old_Identity" ] || Recovery=n
            fi
        fi
        if [ "$Recovery" = y ]; then
            rmdir -- "$Lock" || Status=1
            if [ "$Status" -ne 0 ] && [ -n "$Stage" ] && [ ! -d "$Stage/previous" ] && [ ! -d "$Stage/failed-candidate" ]; then
                rm -rf -- "$Stage"
            fi
        else
            Echo_Red "Recovery needs manual attention; lock and private files retained: $Lock $Stage"
            Status=1
        fi
        exit "$Status"
    }
    trap PMA_Cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    if [ "$Fresh" = y ] && { [ -e "$Target" ] || [ -L "$Target" ]; }; then exit 1; fi
    Stage=$(mktemp -d "$Stage_Parent/.lnmp-phpmyadmin-upgrade.XXXXXX") || exit 1
    chmod 700 "$Stage" || exit 1
    mkdir -p "$Stage/work/src" || exit 1
    local cur_dir=$Stage/work
    printf '%s  %s.tar.xz\n' "$Expected" "$Package" > "$cur_dir/src/checksums.sha256" || exit 1
    if [ -e "$Source_Root/src/$Package.tar.xz" ] || [ -L "$Source_Root/src/$Package.tar.xz" ]; then
        PMA_Safe_Path "$Source_Root/src/$Package.tar.xz" && [ -f "$Source_Root/src/$Package.tar.xz" ] || exit 1
        cp -- "$Source_Root/src/$Package.tar.xz" "$cur_dir/src/" || exit 1
    fi
    cd "$cur_dir/src" || exit 1
    Download_Files "https://files.phpmyadmin.net/phpMyAdmin/5.2.3/$Package.tar.xz" "$Package.tar.xz" || exit 1
    # Tar_Cd checks paths but not archive link types; reject links before extraction.
    Listing=$(LC_ALL=C tar tf "$Package.tar.xz") || exit 1
    Types=$(LC_ALL=C tar tvf "$Package.tar.xz") || exit 1
    awk -v root="$Package" '
        /^\// || /(^|\/)\.\.(\/|$)/ {exit 1}
        $0 != root && $0 != root "/" && index($0, root "/") != 1 {exit 1}
    ' <<< "$Listing" && awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" {exit 1}' <<< "$Types" || {
        Echo_Red 'Unsafe phpMyAdmin archive members.'; exit 1;
    }
    Tar_Cd "$Package.tar.xz" "$Package" || exit 1
    Candidate=$cur_dir/src/$Package
    [ -d "$Candidate" ] && [ ! -L "$Candidate" ] || exit 1
    Found=$(find "$Candidate" -type l -print -quit) || exit 1
    [ -z "$Found" ] || exit 1
    for Entry in index.php libraries/classes/Version.php config.sample.inc.php; do
        [ -f "$Candidate/$Entry" ] && [ ! -L "$Candidate/$Entry" ] || exit 1
    done
    find "$Candidate" -type d -exec chmod 755 {} + &&
        find "$Candidate" -type f -exec chmod 644 {} + &&
        chown -R www:www "$Candidate" || exit 1
    for Entry in upload save tmp; do
        if [ -e "$Target/$Entry" ]; then
            [ -d "$Target/$Entry" ] || { Echo_Red "Existing $Entry is not a directory."; exit 1; }
            mkdir -p "$Candidate/$Entry" && cp -a -- "$Target/$Entry/." "$Candidate/$Entry/" || exit 1
        else
            mkdir -p "$Candidate/$Entry" && chown www:www "$Candidate/$Entry" || exit 1
        fi
    done
    if [ -e "$Target/config.inc.php" ]; then
        [ -f "$Target/config.inc.php" ] && [ ! -L "$Target/config.inc.php" ] || exit 1
        Old_Config=y
        cp -p -- "$Target/config.inc.php" "$Candidate/config.inc.php" || exit 1
    else
        PMA_Safe_Path "$Source_Root/conf/config.inc.php" && [ -f "$Source_Root/conf/config.inc.php" ] || exit 1
        "$PHP_Bin" -n -r '
            $text = file_get_contents($argv[1]);
            $marker = chr(39) . "LNMPORG" . chr(39);
            if ($text === false || substr_count($text, $marker) !== 1) exit(1);
            $secret = "hex2bin(" . chr(39) . bin2hex(random_bytes(32)) . chr(39) . ")";
            $text = str_replace($marker, $secret, $text);
            if (file_put_contents($argv[2], $text) !== strlen($text)) exit(1);
        ' "$Source_Root/conf/config.inc.php" "$Candidate/config.inc.php" || exit 1
        chmod 640 "$Candidate/config.inc.php" && chown www:www "$Candidate/config.inc.php" || exit 1
    fi
    "$PHP_Bin" -n -l "$Candidate/index.php" >/dev/null 2>&1 &&
        "$PHP_Bin" -n -l "$Candidate/config.inc.php" >/dev/null 2>&1 || {
        Echo_Red 'Candidate PHP/configuration syntax check failed; existing files remain unchanged.'; exit 1;
    }
    Device_Path=$Website
    [ "$Old_Identity" = absent ] || Device_Path=$Target
    "$PHP_Bin" -n -r '
        $a = lstat($argv[1]); $b = lstat($argv[2]);
        exit($a && $b && $a["dev"] === $b["dev"] ? 0 : 1);
    ' "$Candidate" "$Device_Path" || { Echo_Red 'Candidate and target must be on the same filesystem.'; exit 1; }
    New_Identity=$(PMA_Identity "$Candidate") || exit 1
    PMA_Safe_Path "$Target" && [ "$(PMA_Identity "$Target")" = "$Old_Identity" ] || exit 1
    Found=$(find "$Target" ! -type d ! -type f -print -quit 2>/dev/null) || [ "$Old_Identity" = absent ] || exit 1
    [ -z "$Found" ] || exit 1
    if [ "$Old_Config" = y ]; then
        cmp -s "$Target/config.inc.php" "$Candidate/config.inc.php" || { Echo_Red 'Configuration changed while staging; retry with the current configuration.'; exit 1; }
    else
        [ ! -e "$Target/config.inc.php" ] && [ ! -L "$Target/config.inc.php" ] || exit 1
    fi
    printf 'target=%s\nbackup=%s/previous\nstate=prepared\n' "$Target" "$Stage" > "$Stage/recovery.txt" || exit 1
    if [ "$Old_Identity" != absent ]; then PMA_Rename "$Target" "$Stage/previous" || exit 1; fi
    PMA_Rename "$Candidate" "$Target" || exit 1
    "$PHP_Bin" -n -l "$Target/index.php" >/dev/null 2>&1 &&
        "$PHP_Bin" -n -l "$Target/config.inc.php" >/dev/null 2>&1 || {
        Echo_Red 'Post-switch PHP/configuration check failed; restoring the previous installation.'; exit 1;
    }
    if [ "$Old_Config" = y ]; then cmp -s "$Stage/previous/config.inc.php" "$Target/config.inc.php" || exit 1; fi
    printf 'target=%s\nbackup=%s/previous\nstate=published\n' "$Target" "$Stage" > "$Stage/recovery.txt" || exit 1
    # Keep the old tree behind the root-owned 0700 transaction directory, not a public URL.
    Echo_Green "phpMyAdmin 5.2.3 upgrade completed. Private backup/recovery: $Stage"
)
