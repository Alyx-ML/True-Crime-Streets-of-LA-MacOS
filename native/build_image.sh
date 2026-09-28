#!/bin/sh
# Offline whole-image translation only. Never executes guest code.
set -eu
task_image_opt=${TC_IMAGE_OPT:-2}
case "$task_image_opt" in
    0|1|2|3) ;;
    *) echo "TC_IMAGE_OPT must be 0, 1, 2 or 3" >&2; exit 1 ;;
esac
export TC_IMAGE_OPT="$task_image_opt"
cd "$(dirname "$0")"
case "${1:-}" in
    ""|--reuse-translation|--refresh-translation) ;;
    *) echo "Usage: $0 [--reuse-translation|--refresh-translation]" >&2; exit 1 ;;
esac
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
cmake --build build -j 4
if [ -z "${1:-}" ]; then
    python3 prepare.py
    python3 recover.py > analysis/recovery-build.log
fi
mkdir -p generated/image-recovered
cd generated/image-recovered
if [ "${1:-}" != --reuse-translation ]; then
    python3 ../../image_seeds.py .
    printf 'include tc_sse.llinc\n' > extern.llinc
    printf '; No title-specific macro overrides.\n' > macros.llinc
    task_seed_pass=0
    while :; do
        task_seed_pass=$((task_seed_pass+1))
        cp global_aliases.sci previous-aliases.sci
        ../../build/srw --fixed-guest-image ../../analysis/prologues-restored.analysis.pe truecrime.llasm > srw.log 2>&1
        python3 ../../image_seeds.py .
        if cmp -s previous-aliases.sci global_aliases.sci; then break; fi
        if [ "$task_seed_pass" -ge 16 ]; then
            echo "Translation roots did not converge after 16 passes" >&2
            exit 1
        fi
    done
fi
python3 ../../import_thunks.py .
python3 ../../code_map.py .
../../vendor/ldc2-1.43.0-osx-arm64/bin/ldc2 -O2 ../../vendor/SR/llasm/llasm.d -of=../../build/llasm
../../build/llasm -m64 -ptrofs -O -guest-code-map code-map.csv \
    -I ../../vendor/SR/SR/llasm-support -I ../../runtime \
    -o truecrime.ll truecrime.llasm > llvm-generation.log 2>&1
# Split the translated module and compile the parts on every core (arm64 only).
llvm=/opt/homebrew/opt/llvm/bin
if [ -x "$llvm/llvm-split" ] && [ -x "$llvm/clang" ]; then
    rm -f part part[0-9]*
    "$llvm/llvm-split" -j 16 -o part truecrime.ll > arm64-build.log 2>&1
    ls part[0-9]* | grep -v '\.o$' | xargs -P 16 -I{} "$llvm/clang" -target arm64-apple-macos14 "-O$task_image_opt" \
        -Wno-override-module -c -x ir {} -o {}.o >> arm64-build.log 2>&1
    xcrun ld -r -arch arm64 part[0-9]*.o -o truecrime.o >> arm64-build.log 2>&1
    rm -f part[0-9]*
else
    xcrun clang -target arm64-apple-macos14 "-O$task_image_opt" -c truecrime.ll -o truecrime.o > arm64-build.log 2>&1
fi
xcrun nm -u truecrime.o > unresolved-native-symbols.txt
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

manifest = {
    "input": "../../analysis/prologues-restored.analysis.pe",
    "input_sha256": hashlib.sha256(Path("../../analysis/prologues-restored.analysis.pe").read_bytes()).hexdigest(),
    "object_sha256": hashlib.sha256(Path("truecrime.o").read_bytes()).hexdigest(),
    "target": "arm64-apple-macos14",
    "optimization": "O" + os.environ["TC_IMAGE_OPT"],
    "import_definitions_sha256": Path("import-definitions.sha256").read_text().strip(),
    "generated_procedures": len(Path("code-map.csv").read_text().splitlines()),
    "unresolved_native_symbols": Path("unresolved-native-symbols.txt").read_text().splitlines(),
    "complete_code_coverage": False,
    "guest_executed": False,
    "runnable_game": False,
}
Path("provenance.json").write_text(json.dumps(manifest, indent=2) + "\n")
PY
