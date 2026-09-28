"""First-launch converter: translate the player's own TrueCrime.exe into a
loadable ARM64 bundle. The app runs this with its bundled interpreter and
tools; it repeats build_image.sh without CMake, Xcode or the system Python.
Guest code is never executed.

Progress lines on stdout have the form "PROGRESS <percent> <message>".
"""
import argparse
import concurrent.futures
import filecmp
import os
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent            # .../Recompiler/native
TOOLS = HERE.parent                                # .../Recompiler
TRIPLE = "arm64-apple-macos14"
DATA_LAYOUT = "e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-n32:64-S128-Fn32"
SCRIPTS = ("prepare.py", "recover.py", "image_seeds.py", "import_thunks.py", "code_map.py")


def progress(percent, message):
    print(f"PROGRESS {percent} {message}", flush=True)


def run(*command, cwd, log=None):
    with open(log, "w") if log else open(os.devnull, "w") as output:
        result = subprocess.run([str(part) for part in command], cwd=cwd, stdout=output,
                                stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f"{Path(str(command[0])).name} failed ({result.returncode})"
                           + (f"; see {log}" if log else ""))


def compile_part(part):
    llvm = TOOLS / "llvm/bin"
    bitcode = part.with_name(part.name + ".bc")
    run(llvm / "opt", "-O2", f"-mtriple={TRIPLE}", f"--data-layout={DATA_LAYOUT}", part, "-o", bitcode,
        cwd=part.parent)
    run(llvm / "llc", "-O2", f"-mtriple={TRIPLE}", "-filetype=obj", bitcode, "-o",
        part.with_name(part.name + ".o"), cwd=part.parent)
    part.unlink()
    bitcode.unlink()


def convert(executable, output, work):
    shutil.rmtree(work, ignore_errors=True)
    native = work / "native"
    native.mkdir(parents=True)
    for name in SCRIPTS:
        shutil.copy2(HERE / name, native / name)
    shutil.copytree(HERE / "runtime", native / "runtime")
    shutil.copytree(HERE / "build", native / "build")
    (native / "analysis").mkdir()
    (work / "TrueCrime.exe").symlink_to(executable)
    python = sys.executable

    progress(3, "Checking TrueCrime.exe")
    run(python, "prepare.py", cwd=native, log=work / "prepare.log")
    progress(8, "Finding game code")
    run(python, "recover.py", cwd=native, log=native / "analysis/recovery-build.log")

    image = native / "generated/image-recovered"
    image.mkdir(parents=True)
    run(python, "../../image_seeds.py", ".", cwd=image, log=work / "seeds.log")
    (image / "extern.llinc").write_text("include tc_sse.llinc\n")
    (image / "macros.llinc").write_text("; No title-specific macro overrides.\n")
    for attempt in range(1, 17):
        progress(min(15 + attempt * 5, 45), f"Translating game code (pass {attempt})")
        shutil.copy2(image / "global_aliases.sci", image / "previous-aliases.sci")
        run(native / "build/srw", "--fixed-guest-image", "../../analysis/prologues-restored.analysis.pe",
            "truecrime.llasm", cwd=image, log=image / "srw.log")
        run(python, "../../image_seeds.py", ".", cwd=image, log=work / "seeds.log")
        if filecmp.cmp(image / "previous-aliases.sci", image / "global_aliases.sci", shallow=False):
            break
    else:
        raise RuntimeError("Translation roots did not converge after 16 passes")

    run(python, "../../import_thunks.py", ".", cwd=image, log=work / "thunks.log")
    run(python, "../../code_map.py", ".", cwd=image, log=work / "code-map.log")
    progress(50, "Generating native code")
    run(TOOLS / "bin/llasm", "-m64", "-ptrofs", "-O", "-guest-code-map", "code-map.csv",
        "-I", TOOLS / "llasm-support", "-I", native / "runtime",
        "-o", "truecrime.ll", "truecrime.llasm", cwd=image, log=image / "llvm-generation.log")

    progress(65, "Compiling for Apple silicon")
    jobs = max(2, min(16, os.cpu_count() or 4))
    run(TOOLS / "llvm/bin/llvm-split", "-j", jobs, "-o", "part", "truecrime.ll", cwd=image)
    (image / "truecrime.ll").unlink()
    parts = sorted(p for p in image.glob("part*") if p.suffix not in (".o", ".bc"))
    with concurrent.futures.ThreadPoolExecutor(jobs) as pool:
        for done, _ in enumerate(pool.map(compile_part, parts), 1):
            progress(65 + 30 * done // len(parts), "Compiling for Apple silicon")

    progress(96, "Linking")
    temporary = output.with_name(output.name + ".tmp")
    run(TOOLS / "llvm/bin/ld64.lld", "-arch", "arm64", "-platform_version", "macos", "14.0", "14.0",
        "-bundle", "-undefined", "dynamic_lookup", *sorted(image.glob("part*.o")), "-o", temporary,
        cwd=image, log=work / "link.log")
    temporary.rename(output)
    shutil.rmtree(work, ignore_errors=True)
    progress(100, "Done")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    try:
        convert(args.executable.resolve(), args.output.absolute(), args.work.absolute())
    except Exception as error:
        print(f"ERROR {error}", flush=True)
        sys.exit(1)
