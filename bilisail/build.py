"""Build one Darwin libmpv slice with an embedded CAMetalLayer GPU context."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import zipfile

HERE = Path(__file__).resolve().parent
TARGETS = {
    "mac-arm": ("macos", "macosx", "arm64", "arm64-apple-macos13"),
    "mac-intel": ("macos", "macosx", "x86_64", "x86_64-apple-macos13"),
    "iphone": ("ios", "iphoneos", "arm64", "arm64-apple-ios15"),
    "sim-arm": ("isimulator", "iphonesimulator", "arm64", "arm64-apple-ios15-simulator"),
    "sim-intel": ("isimulator", "iphonesimulator", "x86_64", "x86_64-apple-ios15-simulator"),
}

def run(*args, **kw):
    subprocess.run(list(map(str, args)), check=True, **kw)

def download(dep):
    path = Path("archives") / (dep["name"] + ".zip")
    path.parent.mkdir(exist_ok=True)
    if not path.exists():
        run("curl", "--fail", "--silent", "--show-error", "--location", "--retry", "3",
            "--max-time", "450", dep["url"], "-o", path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != dep["sha256"]:
        raise ValueError(f"Invalid digest: {path}")
    return path

def install_inputs(archive, prefix, platform, arch):
    with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            name = info.filename.removeprefix("./")
            if info.is_dir() or ".." in Path(name).parts:
                continue
            lib = f"lib/{platform}/thin/{arch}/lib/"
            pc = f"pkgconfig-example/{platform}/{arch}/"
            if name.startswith(lib) and name.endswith((".a", ".pc")):
                target = prefix / "lib" / name[len(lib):]
            elif name.startswith("include/"):
                target = prefix / name
            elif name.startswith(pc) and name.endswith(".pc"):
                target = prefix / "lib/pkgconfig" / Path(name).name
            else:
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            data = z.read(info)
            if target.suffix == ".pc":
                data = re.sub(rb"/path/to/workdir/[^\s]+?/thin/[^/\s]+", str(prefix).encode(), data)
                data = re.sub(rb"(?m)^prefix=.*$", b"prefix=" + str(prefix).encode(), data)
            target.write_bytes(data)

def build(key):
    platform, sdk, arch, triple = TARGETS[key]
    prefix = Path("prefix").resolve()
    deps = json.loads((HERE / "dependencies.json").read_text())
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        for archive in pool.map(download, deps):
            install_inputs(archive, prefix, platform, arch)
    sdkroot = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    flags = ["-target", triple, "-isysroot", sdkroot, "-I" + str(prefix / "include")]
    link = ["-target", triple, "-isysroot", sdkroot, "-L" + str(prefix / "lib")]
    pcs = str(prefix / "lib/pkgconfig")
    cross = Path("cross.ini").resolve()
    cross.write_text(f"""[binaries]
c = 'clang'
cpp = 'clang++'
objc = 'clang'
objcpp = 'clang++'
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
[host_machine]
system = 'darwin'
cpu_family = '{'aarch64' if arch == 'arm64' else arch}'
cpu = '{arch}'
endian = 'little'
[properties]
needs_exe_wrapper = true
pkg_config_libdir = '{pcs}'
[built-in options]
""" + "".join(f"{l}_args = {flags!r}\n{l}_link_args = {link!r}\n" for l in ["c","cpp","objc","objcpp"]))
    os.environ.update(SDKROOT=sdkroot, PKG_CONFIG_LIBDIR=pcs, PKG_CONFIG_PATH="")
    opts = ["-Dauto_features=disabled", "-Ddefault_library=static", "-Dbuildtype=release",
            "-Dgpl=false", "-Dcplayer=false", "-Dlibmpv=true", "-Dgl=enabled",
            "-Dplain-gl=enabled", "-Dlibavdevice=disabled", "-Dmoltenvk=enabled",
            "-Dvulkan=enabled", "-Dvideotoolbox-pl=enabled", "-Diconv=enabled"]
    opts += (["-Dcocoa=enabled","-Dcoreaudio=enabled","-Dgl-cocoa=enabled","-Dvideotoolbox-gl=enabled"]
             if platform == "macos" else ["-Daudiounit=enabled", "-Dios-gl=enabled"])
    run("meson","setup","mpv-build","mpv","--cross-file",cross,"--wrap-mode=nodownload",*opts)
    run("ninja","-C","mpv-build","libmpv.a")
    libs = sorted((prefix / "lib").glob("*.a"))
    # Leave only public libmpv and the opt-in probe visible to other plugins.
    # In particular, BiliSail's downloadable-media mux owns a separate FFmpeg ABI.
    exports = Path("symbols.list")
    exports.write_text("_mpv_*\n_bilisail_joc_probe_install\n")
    frameworks = ["Foundation","AVFoundation","AudioToolbox","CoreAudio","CoreMedia",
                  "CoreVideo","CoreGraphics","CoreText","Metal","IOSurface","QuartzCore",
                  "VideoToolbox","Security","CoreFoundation","ImageIO","Accelerate",
                  "CoreImage","MetalKit","GameController","Network"]
    frameworks += ["AppKit","IOKit","OpenGL","CoreServices"] if platform=="macos" else ["UIKit","OpenGLES"]
    out = Path("slices") / key / "Mpv"
    out.parent.mkdir(parents=True,exist_ok=True)
    run("xcrun","--sdk",sdk,"clang++",*link,"-dynamiclib","-Wl,-headerpad_max_install_names",
        "-Wl,-install_name,@rpath/Mpv.framework/Mpv","-Wl,-exported_symbols_list,"+str(exports),
        "-Wl,-force_load,mpv-build/libmpv.a",*libs,
        *[a for f in frameworks for a in ["-framework",f]],"-lz","-lbz2","-liconv",
        "-lxml2","-lexpat","-lresolv","-lc++","-o",out)
    run("xcrun","vtool","-show-build",out)
    run("xcrun","otool","-L",out)
    if key=="mac-arm":
        run("clang","-I","mpv/include","-x","c",HERE/"smoke.c","-x","none",out,"-o","smoke")
        run("install_name_tool","-change","@rpath/Mpv.framework/Mpv",out.resolve(),"smoke")
        run("codesign","--force","--sign","-",out)
        run("codesign","--force","--sign","-","smoke")
        run("./smoke")

def package(osname):
    slices = [("macos-arm64_x86_64", ["mac-arm","mac-intel"], ["arm64","x86_64"],None)] if osname=="macos" else [
        ("ios-arm64",["iphone"],["arm64"],None),
        ("ios-arm64_x86_64-simulator",["sim-arm","sim-intel"],["arm64","x86_64"],"simulator")]
    root = Path("pack") / osname
    bundle = root / "Mpv.xcframework"
    catalog = []
    for ident, keys, archs, variant in slices:
        framework = bundle / ident / "Mpv.framework"
        framework.mkdir(parents=True,exist_ok=True)
        run("xcrun","lipo","-create",*[Path("slices")/key/"Mpv" for key in keys],"-output",framework/"Mpv")
        desc = dict(LibraryIdentifier=ident,LibraryPath="Mpv.framework",SupportedArchitectures=archs,SupportedPlatform=osname)
        if variant: desc["SupportedPlatformVariant"]=variant
        catalog.append(desc)
        (framework/"Info.plist").write_bytes(plistlib.dumps(dict(CFBundleExecutable="Mpv",CFBundleIdentifier="dev.bilisail.media.mpv",CFBundlePackageType="FMWK",CFBundleVersion="1")))
    (bundle/"Info.plist").write_bytes(plistlib.dumps(dict(XCFrameworkFormatVersion="1.0",CFBundlePackageType="XFWK",AvailableLibraries=catalog)))
    shutil.copytree(HERE,root/"source",ignore=shutil.ignore_patterns("__pycache__"))
    (root/"licenses").mkdir()
    shutil.copyfile("mpv/LICENSE.LGPL",root/"licenses/mpv-LGPL.txt")
    run("tar","-czf",Path(f"bilisail-edr-{osname}.tar.gz").resolve(),"-C",root,".")

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("command",choices=["build","package"])
    p.add_argument("target")
    a=p.parse_args()
    (build if a.command=="build" else package)(a.target)
