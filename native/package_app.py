"""Create a local app bundle containing its non-system dynamic libraries."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def library_names(output):
    return [line.strip().split(' (compatibility version ', 1)[0]
            for line in output.splitlines()[1:] if line.strip()]


LLVM_TOOLS = ('/opt/homebrew/opt/llvm/bin/llvm-split', '/opt/homebrew/opt/llvm/bin/opt',
              '/opt/homebrew/opt/llvm/bin/llc', '/opt/homebrew/opt/lld/bin/ld64.lld')
CONVERTER_SCRIPTS = ('recompile.py', 'prepare.py', 'recover.py', 'image_seeds.py',
                     'import_thunks.py', 'code_map.py')
CONVERTER_RUNTIME = ('tc_imports.def', 'tc_d3d8_methods.def', 'tc_dinput_methods.def',
                     'tc_dsound_methods.def', 'tc_sse.llinc')
PYTHON_UNUSED = ('idlelib', 'tkinter', 'turtledemo', 'ensurepip', 'lib2to3', 'pydoc_data',
                 'test', 'unittest', 'site-packages', 'config-3.12-darwin', 'sqlite3')


def dependencies(binary):
    """Non-system dylibs a Mach-O file loads, resolving @rpath against its own rpaths."""
    rpaths = re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+)', run('otool', '-l', str(binary)))
    rpaths = [p.replace('@loader_path', str(Path(binary).resolve().parent)) for p in rpaths]
    found = []
    for name in library_names(run('otool', '-L', str(binary))):
        if name.startswith(('/System/Library/', '/usr/lib/')):
            continue
        if name.startswith('@rpath/'):
            candidates = [Path(r) / name[7:] for r in rpaths]
            candidates += [Path('/opt/homebrew/opt/llvm/lib') / name[7:], Path('/opt/homebrew/opt/lld/lib') / name[7:]]
            name = next((str(c) for c in candidates if c.exists()), None)
            if not name:
                raise FileNotFoundError(f'Unresolved {binary}: @rpath dependency')
        found.append((Path(name).name, Path(name).resolve()))
    return found


def relocate(target, rpath):
    """Point every non-system load command at @rpath and sign the copy ad hoc."""
    changes = []
    for name in library_names(run('otool', '-L', str(target))):
        if not name.startswith(('/System/Library/', '/usr/lib/', '@rpath/')):
            changes += ['-change', name, f'@rpath/{Path(name).name}']
    if target.suffix == '.dylib':
        changes += ['-id', f'@rpath/{target.name}']
    existing = re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+)', run('otool', '-l', str(target)))
    changes += [arg for path in existing if path != rpath for arg in ('-delete_rpath', path)]
    if rpath not in existing:
        changes += ['-add_rpath', rpath]
    if changes:
        run('install_name_tool', *changes, str(target))
    run('codesign', '--force', '--sign', '-', '--timestamp=none', str(target))


LICENSES = {
    'LLVM.txt': '/opt/homebrew/opt/llvm/LICENSE.TXT',
    'LLD.txt': '/opt/homebrew/opt/lld/LICENSE.TXT',
    'Z3.txt': '/opt/homebrew/opt/z3/LICENSE.txt',
    'zstd.txt': '/opt/homebrew/opt/zstd/LICENSE',
    'SDL3.txt': '/opt/homebrew/opt/sdl3/LICENSE.txt',
    'Python.txt': ROOT / 'vendor/python-standalone/python/lib/python3.12/LICENSE.txt',
    'FFmpeg-LGPL-2.1.txt': ROOT / 'vendor/ffmpeg-8.1.2/COPYING.LGPLv2.1',
    'Berkeley-SoftFloat-3.txt': ROOT / 'vendor/berkeley-softfloat-3/COPYING.txt',
    'udis86.txt': ROOT / 'vendor/SR/SR/udis86-1.6/LICENSE',
}
NOTICE = '''Third-party components included in True Crime.app

- SR / SRW / LLasm static recompiler (M-HT), MIT: https://github.com/M-HT/SR
  commit ac690ddf3010bc3d2c875cb1b5e8da4f53a8d5b3 with native/srw-macos.patch.
- udis86 disassembler, BSD-2-Clause (udis86.txt).
- Berkeley SoftFloat 3e, BSD-3-Clause (Berkeley-SoftFloat-3.txt).
- LLVM 23.1 (llvm-split, opt, llc) and LLD, Apache-2.0 WITH LLVM-exception.
- Z3 (MIT) and zstd (BSD-3-Clause), libraries loaded by LLVM.
- CPython 3.12 (python-build-standalone), PSF License (Python.txt).
- SDL 3, zlib licence (SDL3.txt).
- FFmpeg 8.1.2 libavformat, libavcodec, libavutil and libswscale, LGPL-2.1-or-later
  (FFmpeg-LGPL-2.1.txt), dynamically linked and replaceable in Contents/Frameworks.
  Built from https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz with:
  --enable-shared --disable-static --disable-programs --disable-doc --disable-everything
  --disable-autodetect --disable-network --disable-avdevice --disable-avfilter
  --disable-swresample --enable-demuxer=bink --enable-decoder=bink,binkaudio_rdft,binkaudio_dct
  --enable-protocol=file --enable-swscale --arch=arm64
  The unmodified source archive is published with each release.

True Crime: Streets of LA is not included. The app converts the player's own
TrueCrime.exe on their Mac and reads their own game data.
'''


def add_converter(bundle):
    """Copy the first-launch converter: translation scripts, SRW, LLasm, LLVM and Python."""
    converter = bundle / 'Contents/Resources/Recompiler'
    native = converter / 'native'
    (native / 'runtime').mkdir(parents=True)
    (native / 'build').mkdir()
    for name in CONVERTER_SCRIPTS:
        shutil.copy2(ROOT / name, native / name)
    for name in CONVERTER_RUNTIME:
        shutil.copy2(ROOT / 'runtime' / name, native / 'runtime' / name)
    for name in ('srw', 'libtc_decode.dylib'):
        shutil.copy2(ROOT / 'build' / name, native / 'build' / name)
    shutil.copytree(ROOT / 'vendor/SR/SR/llasm-support', converter / 'llasm-support',
                    ignore=lambda folder, names: [n for n in names if not n.endswith('.llinc')])
    (converter / 'bin').mkdir()
    shutil.copy2(ROOT / 'build/llasm', converter / 'bin/llasm')
    llvm = converter / 'llvm'
    (llvm / 'bin').mkdir(parents=True)
    (llvm / 'lib').mkdir()
    pending = [Path(tool) for tool in LLVM_TOOLS]
    copied = {}
    for tool in pending:
        shutil.copy2(tool.resolve(), llvm / 'bin' / tool.name)
    while pending:
        binary = pending.pop()
        for name, library in dependencies(binary):
            if name not in copied:
                copied[name] = library
                shutil.copy2(library, llvm / 'lib' / name)
                (llvm / 'lib' / name).chmod(0o755)
                pending.append(library)
    for target in (llvm / 'bin').iterdir():
        target.chmod(0o755)
        relocate(target, '@loader_path/../lib')
    for target in (llvm / 'lib').iterdir():
        relocate(target, '@loader_path')
    shutil.copytree(ROOT / 'vendor/python-standalone/python', converter / 'python', symlinks=True,
                    ignore=lambda folder, names: [n for n in names if n in PYTHON_UNUSED or n == '__pycache__'])
    for name in ('bin/llasm', 'native/build/srw', 'native/build/libtc_decode.dylib'):
        run('codesign', '--force', '--sign', '-', '--timestamp=none', str(converter / name))


def package(source, destination, release=False):
    source, destination = source.resolve(), destination.absolute()
    if destination.exists():
        raise FileExistsError(f'Refusing to replace existing bundle: {destination}')
    executable = source / 'Contents/MacOS/tc_game'
    if not executable.is_file():
        raise FileNotFoundError(executable)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.tc-package-', dir=destination.parent) as folder:
        stage = Path(folder)
        script = stage / 'dependencies.cmake'
        dependencies = stage / 'dependencies.txt'
        script.write_text('''cmake_minimum_required(VERSION 3.20)
file(GET_RUNTIME_DEPENDENCIES EXECUTABLES "${APP}"
    RESOLVED_DEPENDENCIES_VAR resolved CONFLICTING_DEPENDENCIES_PREFIX conflict
    PRE_EXCLUDE_REGEXES "^/System/Library/" "^/usr/lib/")
if(conflict_FILENAMES)
    message(FATAL_ERROR "Conflicting libraries: ${conflict_FILENAMES}")
endif()
file(WRITE "${OUT}" "${resolved}")
''')
        run('cmake', f'-DAPP={executable}', f'-DOUT={dependencies}', '-P', str(script))
        libraries = [Path(p) for p in dependencies.read_text().split(';') if p]
        bundle = stage / destination.name
        shutil.copytree(source, bundle)
        frameworks = bundle / 'Contents/Frameworks'
        frameworks.mkdir(exist_ok=True)
        names = {p.name for p in libraries}
        if len(names) != len(libraries):
            raise ValueError('Library basenames must be unique')
        pairs = [(executable, bundle / 'Contents/MacOS/tc_game')]
        for library in libraries:
            target = frameworks / library.name
            shutil.copy2(library, target)
            target.chmod(target.stat().st_mode | 0o200)
            pairs.append((library, target))
        minimum = (14, 0)
        for original, target in pairs:
            for version in re.findall(r'^\s*minos\s+(\d+(?:\.\d+)+)', run('xcrun', 'vtool', '-arch', 'arm64', '-show-build', str(original)), re.M):
                minimum = max(minimum, tuple(map(int, version.split('.'))))
            changes = []
            for dependency in library_names(run('otool', '-L', str(original))):
                if dependency.startswith(('/System/Library/', '/usr/lib/')):
                    continue
                name = Path(dependency).name
                if name not in names:
                    raise ValueError(f'Unresolved packaged dependency: {dependency}')
                changes += ['-change', dependency, f'@executable_path/../Frameworks/{name}']
            if original != executable:
                changes += ['-id', f'@executable_path/../Frameworks/{target.name}']
            if changes:
                run('install_name_tool', *changes, str(target))
            if original != executable:
                run('codesign', '--force', '--sign', '-', '--timestamp=none', str(target))
        info_path = bundle / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info['LSMinimumSystemVersion'] = '.'.join(map(str, minimum))
        info_path.write_bytes(plistlib.dumps(info))
        resources = bundle / 'Contents/Resources'
        resources.mkdir(exist_ok=True)
        (resources / 'native-libraries.json').write_text(json.dumps({
            'libraries': [p.name for p in libraries],
            'minimum_macos': info['LSMinimumSystemVersion'],
            'signing': 'ad hoc, local use',
            'game_files': 'external; select a folder containing TrueCrime.exe and DATA',
        }, indent=2) + '\n')
        if release:
            add_converter(bundle)
            licenses = resources / 'Licenses'
            licenses.mkdir()
            for name, path in LICENSES.items():
                shutil.copy2(path, licenses / name)
            (licenses / 'NOTICE.txt').write_text(NOTICE)
            # The converted game code is cached per runtime and converter build.
            digest = hashlib.sha256(executable.read_bytes())
            for path in sorted((bundle / 'Contents/Resources/Recompiler/native').rglob('*')):
                if path.is_file():
                    digest.update(path.read_bytes())
            info.update({'CFBundleName': 'True Crime', 'CFBundleDisplayName': 'True Crime',
                         'CFBundleIdentifier': 'io.github.alyx-ml.truecrime',
                         'TCGameCodeID': digest.hexdigest()[:16]})
            info_path.write_bytes(plistlib.dumps(info))
        run('codesign', '--force', '--sign', '-', '--timestamp=none', str(bundle))
        bundle.rename(destination)
    print(f'Packaged {len(libraries)} libraries: {destination}')


GAME_FOLDER_NOTE = '''Copy your installed True Crime: Streets of LA game into this folder.
TrueCrime.exe and the DATA folder must sit directly inside it:

  Put game files here/
    TrueCrime.exe
    DATA/
    Movies/
    ...

Then open True Crime.app. The first launch prepares the game for this Mac
(about 1-2 minutes, once). Your game files are not changed.
'''


def release(output):
    """Build the player app and the downloadable ZIP; neither contains game files or game code."""
    output = output.absolute()
    if output.exists():
        raise FileExistsError(f'Refusing to replace existing release folder: {output}')
    folder = output / 'True Crime Mac'
    (folder / 'Put game files here').mkdir(parents=True)
    (folder / 'Put game files here/README.txt').write_text(GAME_FOLDER_NOTE)
    package(ROOT / 'build/player/tc_game.app', folder / 'True Crime.app', release=True)
    archive = output / 'True-Crime-Mac-ARM64.zip'
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(folder), str(archive))
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / 'SHA256SUMS.txt').write_text(f'{checksum}  {archive.name}\n')
    print(f'Release: {archive} ({archive.stat().st_size // 1048576} MB)')


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'build/tc_game.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist/TrueCrime.app')
    parser.add_argument('--self-check', action='store_true')
    parser.add_argument('--release', type=Path, help='build the player release into this new folder')
    args = parser.parse_args()
    if args.self_check:
        assert library_names('app:\n\t/path with spaces/libA.dylib (compatibility version 1.0.0, current version 1.0.0)\n') == ['/path with spaces/libA.dylib']
        assert library_names('app:\n') == []
    elif args.release:
        release(args.release)
    else:
        package(args.source, args.output)
