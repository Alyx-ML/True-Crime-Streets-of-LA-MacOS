# Building the app

The release app contains the runtime, the Metal renderer and the first-launch
converter. It does not contain game code, and building it does not need the game.

## Requirements

- Apple silicon Mac, macOS 27, Xcode Command Line Tools, CMake 3.20+
- Homebrew packages: `llvm lld sdl3 pkg-config`

## Third-party sources (in `native/vendor`)

```sh
cd native/vendor
git clone https://github.com/M-HT/SR.git
git -C SR checkout ac690ddf3010bc3d2c875cb1b5e8da4f53a8d5b3
git -C SR apply ../../srw-macos.patch
git clone https://github.com/ucb-bar/berkeley-softfloat-3.git
git -C berkeley-softfloat-3 checkout a0c6494cdc11865811dec815d5c0049fba9d82a8
```

LDC (builds the LLasm compiler) and the standalone Python bundled with the app;
URLs and SHA-256 are in `ldc-provenance.json` and `python-provenance.json`:

```sh
curl -LO https://github.com/ldc-developers/ldc/releases/download/v1.43.0/ldc2-1.43.0-osx-arm64.tar.xz
tar -xf ldc2-1.43.0-osx-arm64.tar.xz
curl -L -o python-standalone.tar.gz "https://github.com/astral-sh/python-build-standalone/releases/download/20260924/cpython-3.12.14%2B20260924-aarch64-apple-darwin-install_only_stripped.tar.gz"
mkdir python-standalone && tar -xzf python-standalone.tar.gz -C python-standalone
```

Minimal LGPL FFmpeg (Bink only):

```sh
curl -LO https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz && tar -xf ffmpeg-8.1.2.tar.xz
cd ffmpeg-8.1.2
./configure --prefix="$PWD/../ffmpeg-lgpl" --install-name-dir="$PWD/../ffmpeg-lgpl/lib" \
  --enable-shared --disable-static --disable-programs --disable-doc --disable-everything \
  --disable-autodetect --disable-network --disable-avdevice --disable-avfilter \
  --disable-swresample --enable-demuxer=bink --enable-decoder=bink,binkaudio_rdft,binkaudio_dct \
  --enable-protocol=file --enable-swscale --arch=arm64 --cc=clang \
  --extra-cflags=-mmacosx-version-min=14.0 --extra-ldflags=-mmacosx-version-min=14.0
make -j && make install
```

## Build and package

From the repository root:

```sh
cmake -S native -B native/build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build native/build -j
native/vendor/ldc2-1.43.0-osx-arm64/bin/ldc2 -O2 native/vendor/SR/llasm/llasm.d -of=native/build/llasm
cmake --build native/build --target tc_player
python3 native/package_app.py --release native/dist/release
```

`native/dist/release` then holds `True-Crime-Mac-ARM64.zip` (the `True Crime Mac`
folder with the app and **Put game files here**) and `SHA256SUMS.txt`.

## How the first launch works

`tc_player` is the runtime alone. `package_app.py --release` adds
`Contents/Resources/Recompiler`: the translation scripts, SRW, LLasm, LLVM
(`llvm-split`, `opt`, `llc`, `ld64.lld`) and Python, with library paths rewritten
into the bundle. On first launch the app checks the player's `TrueCrime.exe`,
copies the converter to Application Support, and runs `recompile.py`, which
repeats `build_image.sh` and links the result as `truecrime.bundle`. The app then
loads that bundle with `dlopen`. The cache key (`TCGameCodeID` in Info.plist) is
a hash of the runtime executable and the converter scripts.

## Development build

`build_image.sh` produces the same translation inside the source tree; it needs
`TrueCrime.exe` in the folder above `native`. `cmake --build native/build --target tc_game`
then links it statically into a development app.
