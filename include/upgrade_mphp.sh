#!/usr/bin/env bash

MPHP_Manual_Upgrade_Guide()
{
    cat <<'EOF'
Legacy multiple-PHP upgrade (PHP <= 8.1) is DISABLED; use a separate migration plan.
Modern upgrades support only same-branch patches to 8.2.35/8.3.36/8.4.27/8.5.12.
Unsupported configuration or extensions are refused BEFORE stopping the target FPM.
Only extensions rebuilt by the verified PHP source/configure recipe are supported;
external PECL modules need a separately trusted build plan and are not silently lost.
No unsafe/checksum/TLS override can enable an unsupported path.
Runtime: Linux root, Python >= 3.9, flock, timeout, curl, make, a working compiler
and Nginx are required. renameat2(RENAME_EXCHANGE) must work on this filesystem;
an actual exchange probe runs BEFORE any target service stop.
After success /usr/local/php8.x is a symlink to a PERMANENT release candidate.
NEVER delete its /usr/local/.mphp-8.x-XXXXXX directory: it contains the active
runtime and retained rollback copy. KEEP-THIS-DIRECTORY records this requirement.
Managed live symlinks are valid inputs to subsequent patch upgrades and no-ops.
EOF
}

MPHP_Trusted_Target()
{
    case "${1-}" in
        8.2.35|8.3.36|8.4.27|8.5.12) return 0 ;;
        *) printf '%s\n' 'Missing trusted multiple-PHP target; update the reviewed release manifest first.' >&2; return 1 ;;
    esac
}

MPHP_Expected_SHA256()
{
    local Version=${1-} Expected Manifest="${cur_dir}/src/checksums.sha256"
    MPHP_Trusted_Target "$Version" || return 1
    if [ ! -f "$Manifest" ] || [ -L "$Manifest" ]; then
        printf '%s\n' 'Missing or unsafe trusted SHA256 manifest.' >&2
        return 1
    fi
    Expected=$(awk -v name="php-${Version}.tar.bz2" '
        $2 == name {count++; hash=$1; if (NF != 2) bad=1}
        END {if (count != 1 || bad) exit 1; print hash}
    ' "$Manifest") || {
        printf '%s\n' 'Missing, duplicate or malformed trusted PHP SHA256 entry.' >&2
        return 1
    }
    if [[ ! "$Expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
        printf '%s\n' 'Invalid trusted PHP SHA256.' >&2
        return 1
    fi
    printf '%s\n' "$Expected" | tr 'A-F' 'a-f'
}

Verify_MPHP_Archive()
{
    # Read-only, mandatory verification. Never delete a corrupt cache as a side effect.
    local Version=${1-} Expected Actual Output
    local Archive=${2:-${cur_dir}/src/php-${1-}.tar.bz2}
    Expected=$(MPHP_Expected_SHA256 "$Version") || return 1
    if [ ! -f "$Archive" ] || [ -L "$Archive" ] || [ ! -s "$Archive" ]; then
        printf '%s\n' 'Missing, empty or unsafe PHP source cache; no service was changed.' >&2
        return 1
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        Output=$(sha256sum < "$Archive") || return 1
    elif command -v shasum >/dev/null 2>&1; then
        Output=$(shasum -a 256 < "$Archive") || return 1
    else
        printf '%s\n' 'No SHA256 tool available; refusing multiple-PHP archive.' >&2
        return 1
    fi
    Actual=${Output%% *}
    if [ "$Actual" != "$Expected" ]; then
        printf '%s\n' 'PHP source SHA256 mismatch; cache preserved, no service was changed.' >&2
        return 1
    fi
}

Validate_MPHP_Upgrade()
{
    # Return 2 for an already-installed target, without needing an archive.
    local Current=${Cur_MPHP_Version-} Target=${php_version-} Branch=${Cur_MPHP_Big_Ver-}
    if [[ ! "$Branch" =~ ^8\.[2-5]$ ||
          ! "$Current" =~ ^8\.[2-5]\.(0|[1-9][0-9]{0,3})$ ||
          ! "$Target" =~ ^8\.[2-5]\.(0|[1-9][0-9]{0,3})$ ]]; then
        printf '%s\n' 'Only canonical PHP 8.2-8.5 patch versions are eligible; legacy PHP needs separate migration.' >&2
        return 1
    fi
    if [ "${Current%.*}" != "$Branch" ] || [ "${Target%.*}" != "$Branch" ]; then
        printf '%s\n' 'Cross-branch multiple-PHP upgrades are refused.' >&2
        return 1
    fi
    MPHP_Trusted_Target "$Target" || return 1
    if [ "$Current" = "$Target" ]; then
        printf 'PHP %s is already installed; no-op.\n' "$Target"
        return 2
    fi
    if [ "${Current##*.}" -gt "${Target##*.}" ]; then
        printf '%s\n' 'The PHP target must be newer; downgrades are refused.' >&2
        return 1
    fi
    return 0
}

MPHP_Tool()
{
    python3 - "$@" <<'PY'
import ctypes, hashlib, json, os, re, shlex, shutil, signal, socket, stat, subprocess, sys, tarfile, time, urllib.request
from pathlib import Path

if sys.version_info < (3, 9):
    print('Python >= 3.9 is required; no service was changed.', file=sys.stderr)
    sys.exit(1)
command, *args = sys.argv[1:]
def require(ok, message):
    if not ok:
        raise RuntimeError(message)
def save(path, data):
    path = Path(path)
    temporary = path.with_suffix('.new')
    with temporary.open('w') as stream:
        os.chmod(temporary, 0o600)
        json.dump(data, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
def exchange(a, b):
    libc = ctypes.CDLL(None, use_errno=True)
    require(hasattr(libc, 'renameat2'), 'renameat2 unavailable; cannot switch atomically')
    if libc.renameat2(-100, os.fsencode(a), -100, os.fsencode(b), 2):
        raise OSError(ctypes.get_errno(), 'atomic RENAME_EXCHANGE failed')
    for directory in {Path(a).parent, Path(b).parent}:
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
def run(argv, scan=None):
    env = dict(os.environ, LC_ALL='C')
    env.pop('PHPRC', None)
    env['PHP_INI_SCAN_DIR'] = str(scan) if scan else ''
    result = subprocess.run([str(x) for x in argv], env=env, capture_output=True, text=True, timeout=30)
    require(result.returncode == 0, 'Command failed: ' + str(argv) + '\n' + result.stdout + result.stderr)
    require(not re.search(r'PHP (?:Warning|Fatal|Parse)|Unable to load|already loaded|\b(?:WARNING|ERROR|ALERT)\b', result.stdout + result.stderr), 'Startup diagnostics: ' + result.stdout + result.stderr)
    return result.stdout + result.stderr
def inventory(live, service, libraries=True):
    paths = [service, live/'bin/php', live/'bin/php-config', live/'sbin/php-fpm']
    if libraries:
        paths += [live/'bin'/name for name in ('pear','peardev','pecl') if (live/'bin'/name).exists()]
    for name in ('etc', 'conf.d', 'lib/php' if libraries else 'lib/php/extensions'):
        root = live/name
        if root.exists():
            paths += [root] + sorted(root.rglob('*'))
    result = {}
    for path in paths:
        require(not path.is_symlink(), 'Symlinked configuration/extension is unsupported: ' + str(path))
        info = path.stat()
        require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode), 'Non-regular instance input: ' + str(path))
        result[str(path)] = [info.st_mode, info.st_uid, info.st_gid, hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None]
    return result
def same_inventory(live, service, state):
    # Journals remain readable when the installer itself is updated between runs.
    libraries = state.get('inventory_scope') == 'libraries' or str(live/'lib/php') in state['snapshot']
    return inventory(live, service, libraries) == state['snapshot']
def inode(path):
    s = Path(path).lstat()
    return [s.st_dev, s.st_ino]
def pids(executable):
    expected = Path(executable).stat()
    found = []
    for path in Path('/proc').glob('[0-9]*/exe'):
        try:
            info = path.stat()
            if (info.st_dev, info.st_ino) == (expected.st_dev, expected.st_ino):
                found.append(int(path.parent.name))
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            pass
    return found
def wait_idle(executable):
    for _ in range(100):
        if not pids(executable):
            return
        time.sleep(.1)
    raise RuntimeError('FPM processes did not exit: ' + str(executable))
def copy_config(source, destination):
    shutil.copytree(source, destination, copy_function=shutil.copy2, dirs_exist_ok=True)
    for old in [source] + list(source.rglob('*')):
        new = destination / old.relative_to(source)
        info = old.stat()
        os.chown(new, info.st_uid, info.st_gid)
def php_json(prefix, scan, ini):
    return json.loads(run([prefix/'bin/php', '-c', ini, '-d', 'display_startup_errors=1', '-d', 'display_errors=stderr', '-r', 'echo json_encode(["version"=>PHP_VERSION,"modules"=>get_loaded_extensions()]);'], scan))
def check_config(live):
    # Reject executable startup hooks before running even the OLD configured PHP.
    shared = set()
    for path in [live/'etc/php.ini'] + sorted((live/'conf.d').glob('*.ini')):
        for line in path.read_text().splitlines():
            match = re.match(r'\s*(extension|zend_extension|extension_dir|opcache.preload|opcache.file_cache|auto_prepend_file|auto_append_file|ffi.preload)\s*=\s*([^;]*)', line, re.I)
            if not match:
                continue
            key, value = match.group(1).lower(), match.group(2).strip().strip('\"\'')
            if not value:
                continue
            if key in ('extension','zend_extension'):
                name = Path(value).name
                require(re.fullmatch(r'[A-Za-z0-9_]+\.so', name) is not None, 'Unsupported extension directive: ' + value)
                require('/' not in value or (value.startswith(str(live/'lib/php/extensions') + '/') and '..' not in Path(value).parts), 'External extension path is unsupported: ' + value)
                shared.add(name)
            elif key == 'extension_dir':
                require(value.startswith(str(live/'lib/php/extensions') + '/') and '..' not in Path(value).parts, 'External extension_dir is unsupported')
            else:
                raise RuntimeError('Unsafe startup hook/cache: ' + key)
    for path in (live/'etc').rglob('*.conf'):
        text = path.read_text()
        require(not re.search(r'php_(?:admin_)?value\[(?:extension|zend_extension|extension_dir|auto_prepend_file|auto_append_file|opcache.preload|opcache.file_cache|ffi.preload)\]', text, re.I), 'Unsupported per-pool startup override')
        for value in re.findall(r'^\s*include\s*=\s*(\S+)', text, re.M):
            require(value.startswith(str(live/'etc') + '/') and '..' not in Path(value).parts, 'External FPM include is unsupported')
    return shared

try:
    if command == 'pending':
        branch = args[0]
        pending = Path('/usr/local/.mphp-' + branch + '.pending')
        require(not pending.is_symlink(), 'Unsafe pending transaction')
        if pending.exists():
            work = pending.read_text().strip()
            require(re.fullmatch(r'/usr/local/\.mphp-' + re.escape(branch) + r'-[A-Za-z0-9_-]+', work) is not None, 'Invalid recovery directory')
            require(not Path(work).is_symlink() and Path(work).stat().st_uid == 0, 'Unsafe recovery directory')
            print(work)
        sys.exit(0)
    work = Path(args[0])
    statefile = work/'state.json'
    candidate = work/'candidate'
    if command == 'prepare':
        live, service, version = Path(args[1]), Path(args[2]), args[3]
        branch = version.rsplit('.', 1)[0]
        require(str(live) == '/usr/local/php' + branch and str(service) == '/etc/init.d/php-fpm' + branch, 'Unexpected instance/service path')
        require(live.is_dir() and not service.is_symlink(), 'Missing instance or symlinked service')
        if live.is_symlink():
            require(re.fullmatch(r'/usr/local/\.mphp-' + re.escape(branch) + r'-[A-Za-z0-9_-]+/candidate', str(live.resolve())) is not None, 'Only managed permanent release symlinks are supported')
        snapshot = inventory(live, service)
        shared = check_config(live)
        require(os.lstat(live).st_dev == work.stat().st_dev, 'Live prefix and candidate must share a filesystem')
        mountpoints = [line.split()[4] for line in Path('/proc/self/mountinfo').read_text().splitlines()]
        require(str(live) not in mountpoints, 'A mounted live prefix cannot be atomically exchanged')
        old = php_json(live, live/'conf.d', live/'etc/php.ini')
        require(old['version'].rsplit('.', 1)[0] == branch, 'Installed branch mismatch')
        require(re.fullmatch(r'8\.[2-5]\.(0|[1-9][0-9]{0,3})', old['version']) is not None and int(old['version'].rsplit('.',1)[1]) < int(version.rsplit('.',1)[1]), 'Target is not a newer canonical same-branch patch')
        require(len(args) < 5 or old['version'] == args[4], 'Installed PHP changed during version preflight')
        fpm = run([live/'sbin/php-fpm', '-tt', '-y', live/'etc/php-fpm.conf', '-c', live/'etc/php.ini'], live/'conf.d')
        listens = re.findall(r'NOTICE:\s+listen = (\S+)', fpm)
        pidfiles = re.findall(r'NOTICE:\s+pid = (\S+)', fpm)
        require(listens == ['/tmp/php-cgi' + branch + '.sock'], 'Only one standard multi-PHP Unix-socket pool is supported')
        require(pidfiles == [str(live/'var/run/php-fpm.pid')], 'Unsupported FPM pid path')
        require(shutil.disk_usage(work).free >= 2 * 1024**3, 'At least 2 GiB free space is required before building a candidate')
        running = bool(pids(live/'sbin/php-fpm'))
        if running:
            pid = int(Path(pidfiles[0]).read_text().strip())
            require(pid in pids(live/'sbin/php-fpm'), 'Unmanaged FPM or stale pid file')
        options = shlex.split(run([live/'bin/php-config', '--configure-options']).strip())
        safe = []
        directories = {'prefix','exec-prefix','bindir','sbindir','libexecdir','sysconfdir','localstatedir','runstatedir','datarootdir','datadir','includedir','oldincludedir','libdir','mandir','infodir','docdir','htmldir','dvidir','pdfdir','psdir'}
        for option in options:
            require(re.fullmatch(r'--[A-Za-z0-9_-]+(?:=[A-Za-z0-9_./,:+=@${}-]*)?', option) is not None, 'Unsupported configure argument: ' + option)
            key = option[2:].split('=', 1)[0]
            require(key not in ('with-apxs','with-apxs2','enable-embed','with-litespeed'), 'Non-FPM SAPI is unsupported')
            if key in directories or key in ('with-config-file-path','with-config-file-scan-dir','with-pear','without-pear'):
                continue
            require(str(live) not in option, 'Build dependency inside live prefix is unsupported')
            safe.append(option)
        safe += ['--prefix=' + str(candidate), '--with-config-file-path=' + str(live/'etc'), '--with-config-file-scan-dir=' + str(live/'conf.d'), '--without-pear', '--enable-fpm']
        (work/'options').write_bytes(b''.join(os.fsencode(x) + b'\0' for x in safe))
        state = dict(live=str(live), service=str(service), branch=branch, version=version, old=old, snapshot=snapshot, inventory_scope='libraries', inode=inode(live), running=running, shared=sorted(shared), phase='prepared')
        save(statefile, state)
        # Exercise filesystem support before the target is stopped.
        if not (work/'exchange-a').exists():
            (work/'exchange-a').mkdir()
            (work/'exchange-b').symlink_to(candidate)
        require((work/'exchange-a').is_dir() and not (work/'exchange-a').is_symlink() and (work/'exchange-b').is_symlink(), 'Invalid filesystem probe state')
        exchange(work/'exchange-a', work/'exchange-b')
        exchange(work/'exchange-a', work/'exchange-b')
    else:
        require(not statefile.is_symlink(), 'Unsafe transaction journal')
        state = json.loads(statefile.read_text())
        live, service = Path(state['live']), Path(state['service'])
        require(str(live) == '/usr/local/php' + state['branch'] and str(service) == '/etc/init.d/php-fpm' + state['branch'], 'Invalid journal paths')
        if command == 'unpack':
            archive = Path(args[1])
            with tarfile.open(archive, 'r:bz2') as source:
                for member in source.getmembers():
                    path = Path(member.name)
                    require(not path.is_absolute() and '..' not in path.parts and path.parts[0] == 'php-' + state['version'] and (member.isdir() or member.isfile()), 'Unsafe PHP archive member: ' + member.name)
                source.extractall(work/'source')
            for name in state['shared']:
                require((work/'source'/('php-' + state['version'])/'ext'/name[:-3]).is_dir(), 'No trusted bundled source for extension: ' + name + '; separate extension migration required')
        elif command == 'unchanged':
            require(same_inventory(live, service, state) and inode(live) == state['inode'], 'Live binaries/configuration/service changed during preparation; refusing switch')
        elif command == 'stage':
            # Preserve existing PEAR/application PHP libraries without running PEAR's
            # network installer or copying old native modules/phpize build files.
            if (live/'lib/php').exists():
                for old in (live/'lib/php').iterdir():
                    if old.name in ('build', 'extensions'):
                        continue
                    new = candidate/'lib/php'/old.name
                    if old.is_dir():
                        copy_config(old, new)
                    else:
                        shutil.copy2(old, new)
                        info = old.stat()
                        os.chown(new, info.st_uid, info.st_gid)
                for name in ('pear','peardev','pecl'):
                    old = live/'bin'/name
                    if old.is_file():
                        require(not old.is_symlink(), 'Symlinked PEAR launcher is unsupported')
                        shutil.copy2(old, candidate/'bin'/name)
            for name in ('etc', 'conf.d'):
                copy_config(live/name, candidate/name)
                copy_config(live/name, work/'check'/name)
            for path in (work/'check').rglob('*'):
                if path.is_file():
                    text = path.read_text()
                    if path.suffix == '.conf':
                        text = text.replace(str(live/'etc'), str(work/'check/etc')).replace(str(live), str(candidate))
                        text = re.sub(r'(?m)^(\s*listen\s*=).*', r'\1 ' + str(work/'private.sock'), text)
                        text = re.sub(r'(?m)^(\s*pid\s*=).*', r'\1 ' + str(work/'private.pid'), text)
                        text = re.sub(r'(?m)^(\s*(?:error_log|slowlog|access.log)\s*=).*', lambda m: m[1] + ' ' + str(work/'private.log'), text)
                    else:
                        text = text.replace(str(live), str(candidate))
                    path.write_text(text)
            for directory in ('var/run','var/log'):
                (candidate/directory).mkdir(parents=True, exist_ok=True)
            data = php_json(candidate, work/'check/conf.d', work/'check/etc/php.ini')
            require(data['version'] == state['version'] and set(state['old']['modules']) <= set(data['modules']), 'Candidate version/module regression')
            extension_dir = Path(run([candidate/'bin/php-config', '--extension-dir']).strip())
            require(extension_dir.is_relative_to(candidate), 'Candidate extension directory escapes prefix')
            for name in state['shared']:
                installed = extension_dir/name
                built = work/'source'/('php-' + state['version'])/'modules'/name
                require(installed.is_file() and built.is_file() and installed.read_bytes() == built.read_bytes(), 'Extension was not rebuilt from verified source: ' + name)
            state['extension_dir'] = str(extension_dir)
            save(statefile, state)
            run([candidate/'sbin/php-fpm','-t','-p',candidate,'-y',work/'check/etc/php-fpm.conf','-c',work/'check/etc/php.ini'], work/'check/conf.d')
        elif command == 'probe-config':
            ports = []
            for _ in range(2):
                with socket.socket() as sock:
                    sock.bind(('127.0.0.1', 0))
                    ports.append(sock.getsockname()[1])
            (work/'health.php').write_text('<?php header("Content-Type: application/json"); echo json_encode(["version"=>PHP_VERSION,"sapi"=>PHP_SAPI,"modules"=>get_loaded_extensions()]);')
            os.chmod(work/'health.php', 0o644)
            config = 'pid ' + str(work/'nginx.pid') + '; error_log ' + str(work/'nginx.log') + '; events {} http { access_log off;'
            for port, sockpath in zip(ports, [str(work/'private.sock'), '/tmp/php-cgi' + state['branch'] + '.sock']):
                config += 'server { listen 127.0.0.1:' + str(port) + '; location = /health { fastcgi_pass unix:' + sockpath + '; fastcgi_param SCRIPT_FILENAME ' + str(work/'health.php') + '; fastcgi_param REQUEST_METHOD GET; fastcgi_param SERVER_PROTOCOL HTTP/1.1; fastcgi_param GATEWAY_INTERFACE CGI/1.1; } }'
            (work/'nginx.conf').write_text(config + '}')
            save(work/'ports.json', ports)
        elif command == 'http':
            which, version = args[1:3]
            port = json.loads((work/'ports.json').read_text())[0 if which == 'private' else 1]
            error = None
            for _ in range(50):
                try:
                    # Ignore proxy environment variables for the loopback-only probe.
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                    with opener.open('http://127.0.0.1:' + str(port) + '/health', timeout=2) as response:
                        data = json.loads(response.read())
                    require(data['version'] == version and data['sapi'] == 'fpm-fcgi' and set(state['old']['modules']) <= set(data['modules']), 'HTTP version/SAPI/module mismatch: ' + repr(data))
                    print('HTTP_OK ' + which + ' ' + version)
                    error = None
                    break
                except Exception as exc:
                    error = exc
                    time.sleep(.1)
            require(error is None, 'FPM HTTP health failed: ' + str(error))
        elif command == 'maps':
            private = args[1] == 'private'
            pidfile = work/'private.pid' if private else live/'var/run/php-fpm.pid'
            pid = int(pidfile.read_text().strip())
            require(pid in pids(candidate/'sbin/php-fpm'), 'FPM is not running the candidate executable')
            mappings = Path('/proc/' + str(pid) + '/maps').read_text()
            for name in state['shared']:
                require(str(Path(state['extension_dir'])/name) in mappings, 'FPM did not map NEW extension: ' + name)
            print('NEW_EXTENSION_MAPS_OK ' + ','.join(state['shared']))
        elif command == 'private-stop':
            pidfile = work/'private.pid'
            if pidfile.exists():
                pid = int(pidfile.read_text().strip())
                own = pids(candidate/'sbin/php-fpm')
                if pid in own:
                    os.kill(pid, signal.SIGQUIT)
                    for _ in range(100):
                        if not pidfile.exists():
                            break
                        time.sleep(.1)
                    require(not pidfile.exists(), 'Private FPM failed to exit')
                else:
                    require(not own, 'Private PID mismatch; no signal sent')
        elif command == 'probe-stop':
            pidfile = work/'nginx.pid'
            if pidfile.exists():
                pid = int(pidfile.read_text().strip())
                proc = Path('/proc/' + str(pid))
                if proc.exists():
                    require(str(work/'nginx.conf').encode() in (proc/'cmdline').read_bytes(), 'Probe PID does not belong to this transaction')
                    os.kill(pid, signal.SIGQUIT)
                    for _ in range(100):
                        if not pidfile.exists():
                            break
                        time.sleep(.1)
                    require(not pidfile.exists(), 'Private HTTP probe failed to exit')
                else:
                    pidfile.unlink()
        elif command == 'running':
            sys.exit(0 if state['running'] else 1)
        elif command == 'idle':
            wait_idle(live/'sbin/php-fpm')
        elif command == 'can-stop':
            own = pids(live/'sbin/php-fpm')
            if not own:
                sys.exit(2)
            pidfile = live/'var/run/php-fpm.pid'
            require(pidfile.is_file() and int(pidfile.read_text().strip()) in own, 'Target PID does not identify this FPM; no signal sent')
        elif command == 'old-version':
            print(state['old']['version'])
        elif command == 'activate':
            (work/'KEEP-THIS-DIRECTORY').write_text('PERMANENT PHP RELEASE DIRECTORY. NEVER DELETE OR AUTO-CLEAN THIS DIRECTORY.\nActive prefix: ' + str(candidate) + '\nStable instance link: ' + str(live) + '\nRollback installation: ' + str(work/'switch') + '\n')
            os.chmod(work/'KEEP-THIS-DIRECTORY', 0o444)
            pending = Path('/usr/local/.mphp-' + state['branch'] + '.pending')
            with pending.open('x') as stream:
                os.chmod(pending, 0o600)
                stream.write(str(work))
                stream.flush()
                os.fsync(stream.fileno())
            fd = os.open(pending.parent, os.O_RDONLY | os.O_DIRECTORY)
            os.fsync(fd)
            os.close(fd)
            if not (work/'switch').exists() and not (work/'switch').is_symlink():
                (work/'switch').symlink_to(candidate)
            require((work/'switch').is_symlink() and (work/'switch').resolve() == candidate, 'Existing rollback slot is not empty')
        elif command == 'exchange':
            require(inode(live) == state['inode'] and (work/'switch').is_symlink(), 'Switch inputs changed')
            state['phase'] = 'switching'
            save(statefile, state)
            exchange(live, work/'switch')
            state['phase'] = 'switched'
            save(statefile, state)
        elif command == 'restore':
            if inode(live) != state['inode']:
                require(live.is_symlink() and live.resolve() == candidate and inode(work/'switch') == state['inode'], 'Cannot identify old installation; no files overwritten')
                exchange(live, work/'switch')
            require(same_inventory(live, service, state), 'Restored installation/configuration/service differs from original')
            state['phase'] = 'restored'
            save(statefile, state)
        elif command == 'complete':
            state['phase'] = args[1]
            save(statefile, state)
            pending = Path('/usr/local/.mphp-' + state['branch'] + '.pending')
            require(pending.read_text().strip() == str(work), 'Pending transaction changed')
            pending.unlink()
            fd = os.open(pending.parent, os.O_RDONLY | os.O_DIRECTORY)
            os.fsync(fd)
            os.close(fd)
        else:
            raise RuntimeError('Unknown MPHP tool command: ' + command)
except Exception as error:
    print('MPHP refusal/failure: ' + str(error), file=sys.stderr)
    sys.exit(1)
PY
}

MPHP_Download_Source()
{
    local Archive="php-${php_version}.tar.bz2" URL
    MPHP_Expected_SHA256 "$php_version" >/dev/null || return 1
    if [ -e "${cur_dir}/src/${Archive}" ] || [ -L "${cur_dir}/src/${Archive}" ]; then
        Verify_MPHP_Archive "$php_version" || return 1
        cp "${cur_dir}/src/${Archive}" "${MPHP_Work}/${Archive}" || return 1
    else
        [[ "${Download_Mirror:-https://www.php.net}" = https://* ]] || { echo 'Insecure PHP mirror refused.' >&2; return 1; }
        for URL in "${Download_Mirror:-https://www.php.net}/web/php/${Archive}" "https://www.php.net/distributions/${Archive}"; do
            if curl --fail --location --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 --output "${MPHP_Work}/${Archive}" "$URL" && Verify_MPHP_Archive "$php_version" "${MPHP_Work}/${Archive}"; then
                break
            fi
        done
    fi
    Verify_MPHP_Archive "$php_version" "${MPHP_Work}/${Archive}" || return 1
    MPHP_Tool unpack "$MPHP_Work" "${MPHP_Work}/${Archive}"
}

MPHP_Start_Probe()
{
    [ "${MPHP_Probe_Started:-n}" != y ] || return 0
    MPHP_Tool probe-stop "$MPHP_Work" || return 1
    MPHP_Tool probe-config "$MPHP_Work" || return 1
    "$MPHP_Nginx" -p "$MPHP_Work/" -c "$MPHP_Work/nginx.conf" 9>&- || return 1
    MPHP_Probe_Started=y
}

MPHP_Stop_Target()
{
    local Status
    MPHP_Tool can-stop "$MPHP_Work" && Status=0 || Status=$?
    [ "$Status" != 2 ] || return 0
    [ "$Status" = 0 ] || return 1
    timeout 30 "$MPHP_Service" stop 9>&- || return 1
    MPHP_Tool idle "$MPHP_Work"
}

Rollback_MPHP()
{
    echo "Rolling back target FPM; transaction retained: $MPHP_Work" >&2
    # Stop the current target even if a candidate start returned failure after forking.
    MPHP_Stop_Target || { MPHP_Tool idle "$MPHP_Work" || return 1; }
    MPHP_Tool idle "$MPHP_Work" || return 1
    MPHP_Tool restore "$MPHP_Work" || return 1
    if MPHP_Tool running "$MPHP_Work"; then
        env -u PHPRC -u PHP_INI_SCAN_DIR timeout 30 "$MPHP_Service" start 9>&- || return 1
        MPHP_Start_Probe || return 1
        MPHP_Tool http "$MPHP_Work" live "$(MPHP_Tool old-version "$MPHP_Work")" || return 1
    else
        MPHP_Tool idle "$MPHP_Work" || return 1
    fi
    MPHP_Tool complete "$MPHP_Work" rolled-back || return 1
    echo 'ROLLBACK_OK: original binaries, etc, conf.d, extensions, service and running/stopped state restored.' >&2
}

MPHP_Finish()
{
    local Status=$1
    trap - EXIT INT TERM
    if [ "$Status" -ne 0 ] && [ -n "${MPHP_Work:-}" ] && [ -f "/usr/local/.mphp-${Cur_MPHP_Big_Ver}.pending" ]; then
        Rollback_MPHP || { echo "ROLLBACK FAILED; do not delete $MPHP_Work or its pending journal." >&2; Status=70; }
    fi
    if [ -n "${MPHP_Work:-}" ] && [ -f "$MPHP_Work/state.json" ]; then
        MPHP_Tool private-stop "$MPHP_Work" || { echo 'Private candidate cleanup failed.' >&2; Status=70; }
    fi
    if [ -n "${MPHP_Work:-}" ] && [ -f "$MPHP_Work/state.json" ]; then
        MPHP_Tool probe-stop "$MPHP_Work" || Status=70
    fi
    exit "$Status"
}

MPHP_Transaction()
{
    local Status Option Current_Config Pending Command
    [[ "$Cur_MPHP_Big_Ver" =~ ^8\.[2-5]$ ]] || { MPHP_Manual_Upgrade_Guide >&2; return 1; }
    Cur_MPHP_Path="/usr/local/php${Cur_MPHP_Big_Ver}"
    MPHP_Service="/etc/init.d/php-fpm${Cur_MPHP_Big_Ver}"
    MPHP_Trusted_Target "$php_version" || return 1
    for Command in python3 flock timeout curl make; do
        command -v "$Command" >/dev/null || { echo "Missing prerequisite: $Command" >&2; return 1; }
    done
    MPHP_Check_Python || return 1
    [ "$(uname -s)" = Linux ] && [ "$(id -u)" = 0 ] || { echo 'Modern multi-PHP upgrades require Linux root.' >&2; return 1; }
    MPHP_Nginx=/usr/local/nginx/sbin/nginx
    [ -x "$MPHP_Nginx" ] || MPHP_Nginx=$(command -v nginx) || return 1
    umask 077
    exec 9>"/usr/local/.mphp-${Cur_MPHP_Big_Ver}.lock" || return 1
    flock -n 9 || { echo 'Another upgrade holds this FPM lock.' >&2; return 1; }
    Pending=$(MPHP_Tool pending "$Cur_MPHP_Big_Ver") || return 1
    if [ -n "$Pending" ]; then
        MPHP_Work=$Pending
        Rollback_MPHP || return 1
        echo 'Interrupted transaction recovered; rerun the upgrade.' >&2
        return 1
    fi
    Cur_MPHP_Version=$("$Cur_MPHP_Path/bin/php" -n -r 'echo PHP_VERSION;') || return 1
    Current_Config=$("$Cur_MPHP_Path/bin/php-config" --version) || return 1
    [ "$Current_Config" = "$Cur_MPHP_Version" ] || { echo 'Installed PHP/php-config version mismatch.' >&2; return 1; }
    Validate_MPHP_Upgrade && Status=0 || Status=$?
    [ "$Status" != 2 ] || return 0
    [ "$Status" = 0 ] || return 1
    [ -x "$MPHP_Service" ] || return 1
    MPHP_Work=$(mktemp -d "/usr/local/.mphp-${Cur_MPHP_Big_Ver}-XXXXXX") || return 1
    chmod 755 "$MPHP_Work" || return 1
    echo "Preparing independent candidate; logs/rollback retained at $MPHP_Work"
    MPHP_Tool prepare "$MPHP_Work" "$Cur_MPHP_Path" "$MPHP_Service" "$php_version" "$Cur_MPHP_Version" || return 1
    MPHP_Start_Probe || return 1
    if MPHP_Tool running "$MPHP_Work"; then
        MPHP_Tool http "$MPHP_Work" live "$Cur_MPHP_Version" || return 1
    fi
    MPHP_Download_Source || return 1
    [[ "${MPHP_Build_Jobs:-2}" =~ ^[1-9][0-9]?$ ]] || { echo 'Invalid build concurrency.' >&2; return 1; }
    local Options=()
    while IFS= read -r -d '' Option; do Options+=("$Option"); done < "$MPHP_Work/options"
    (
        cd "$MPHP_Work/source/php-${php_version}" || exit 1
        ./configure "${Options[@]}" >"$MPHP_Work/configure.log" 2>&1 || exit 1
        make -j "${MPHP_Build_Jobs:-2}" >"$MPHP_Work/make.log" 2>&1 || exit 1
        make install >"$MPHP_Work/install.log" 2>&1 || exit 1
    ) || { echo "Candidate build failed; original FPM unchanged. See $MPHP_Work" >&2; return 1; }
    chmod 755 "$MPHP_Work/candidate" || return 1
    MPHP_Tool unchanged "$MPHP_Work" || return 1
    MPHP_Validate_Candidate || return 1
    MPHP_Tool unchanged "$MPHP_Work" || return 1
    MPHP_Commit_Candidate
}

MPHP_Validate_Candidate()
{
    MPHP_Tool stage "$MPHP_Work" || return 1
    PHP_INI_SCAN_DIR="$MPHP_Work/check/conf.d" "$MPHP_Work/candidate/sbin/php-fpm" -D -p "$MPHP_Work/candidate" -y "$MPHP_Work/check/etc/php-fpm.conf" -c "$MPHP_Work/check/etc/php.ini" 9>&- || return 1
    MPHP_Tool http "$MPHP_Work" private "$php_version" || return 1
    MPHP_Tool maps "$MPHP_Work" private || return 1
    MPHP_Tool private-stop "$MPHP_Work" || return 1
}

MPHP_Commit_Candidate()
{
    MPHP_Tool unchanged "$MPHP_Work" || return 1
    MPHP_Tool activate "$MPHP_Work" || return 1
    if MPHP_Tool running "$MPHP_Work"; then
        MPHP_Stop_Target || return 1
    fi
    MPHP_Tool exchange "$MPHP_Work" || return 1
    env -u PHPRC -u PHP_INI_SCAN_DIR timeout 30 "$MPHP_Service" start 9>&- || return 1
    MPHP_Tool http "$MPHP_Work" live "$php_version" || return 1
    MPHP_Tool maps "$MPHP_Work" live || return 1
    if ! MPHP_Tool running "$MPHP_Work"; then
        MPHP_Stop_Target || return 1
    fi
    MPHP_Tool complete "$MPHP_Work" committed || return 1
    echo "UPGRADE_OK PHP $php_version; original configuration/service preserved; rollback copy: $MPHP_Work/switch"
    echo "PERMANENT active release: $MPHP_Work/candidate. NEVER delete or auto-clean $MPHP_Work."
}

MPHP_Check_Python()
{
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' || {
        echo 'Python >= 3.9 is required for multi-PHP upgrades; no service was changed.' >&2
        return 1
    }
}

MPHP_Release_Accepted()
{
    # Remains closed until the real source-build/FPM/HTTP recovery matrix passes.
    return 1
}

Upgrade_MPHP_Modern()
(
    local Cur_MPHP_Big_Ver=${1-} php_version=${2-} MPHP_Work='' MPHP_Probe_Started=n MPHP_Service MPHP_Nginx
    set -o pipefail
    trap 'MPHP_Finish $?' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    MPHP_Release_Accepted || { echo 'Modern MPHP acceptance is in progress; no service changed.' >&2; exit 1; }
    MPHP_Transaction || exit $?
)

Upgrade_Multiplephp()
{
    local Choice Branch Target
    printf '%s\n' '9: PHP 8.2; 10: PHP 8.3; 11: PHP 8.4; 12: PHP 8.5'
    read -r -p 'Select the installed multiple-PHP instance: ' Choice || return 1
    case "$Choice" in
        9|8.2) Branch=8.2; Target=8.2.35 ;;
        10|8.3) Branch=8.3; Target=8.3.36 ;;
        11|8.4) Branch=8.4; Target=8.4.27 ;;
        12|8.5) Branch=8.5; Target=8.5.12 ;;
        *) MPHP_Manual_Upgrade_Guide >&2; return 1 ;;
    esac
    Upgrade_MPHP_Modern "$Branch" "$Target"
}

# Legacy entry points never dispatch into a modern transaction.
Upgrade_MPHP5.6()
{
    MPHP_Manual_Upgrade_Guide >&2; return 1
}

Upgrade_MPHP7.0()
{
    MPHP_Manual_Upgrade_Guide >&2; return 1
}

Upgrade_MPHP7.1()
{
    MPHP_Manual_Upgrade_Guide >&2; return 1
}

Upgrade_MPHP7.2()
{
    MPHP_Manual_Upgrade_Guide >&2; return 1
}

Upgrade_MPHP7.3()
{
    MPHP_Manual_Upgrade_Guide >&2; return 1
}

Upgrade_MPHP7.4()
{
    MPHP_Manual_Upgrade_Guide >&2; return 1
}

Upgrade_MPHP8.0()
{
    MPHP_Manual_Upgrade_Guide >&2; return 1
}

Upgrade_MPHP8.1()
{
    MPHP_Manual_Upgrade_Guide >&2; return 1
}

Upgrade_MPHP8.2()
{
    Upgrade_MPHP_Modern 8.2 "${php_version:-8.2.35}"
}

Upgrade_MPHP8x()
{
    Upgrade_MPHP_Modern "${Cur_MPHP_Big_Ver-}" "${php_version-}"
}
