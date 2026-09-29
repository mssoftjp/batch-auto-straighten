"""Build pinned image-only OpenCV locally for the macOS distributable."""
import hashlib
import os
import shlex
from pathlib import Path
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
VERSION = '5.0.0'
SHA256 = 'b0528f5a1d379d59d4701cb28c36e22214cc51cf64594e5b56f2d3e6c0233095'


def prefix_map_flag(root):
    # CMake reparses this string when producing shell compiler commands.
    return "-ffile-prefix-map=" + shlex.quote(f"{root}=/build/batch-auto-straighten")


def main():
    local = ROOT / '.local'
    local.mkdir(exist_ok=True)
    archive = local / f'opencv-{VERSION}.tar.gz'
    if not archive.exists():
        urllib.request.urlretrieve(
            f'https://github.com/opencv/opencv/archive/refs/tags/{VERSION}.tar.gz', archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise SystemExit('OpenCV source checksum mismatch')
    source = local / 'opencv-source' / f'opencv-{VERSION}'
    if not source.exists():
        with tarfile.open(archive) as tar:
            # Examples and test images are not needed to build runtime modules.
            members = [m for m in tar.getmembers() if Path(m.name).suffix.lower()
                       not in {'.jpg', '.jpeg', '.png', '.bmp', '.tif', '.tiff',
                               '.webp', '.gif', '.svg', '.exr', '.jp2'}]
            tar.extractall(source.parent, members=members, filter='data')
    build = local / 'opencv-minimal/build'
    install = local / 'opencv-minimal/install'
    cmake = Path(sys.executable).parent / 'cmake'
    ninja = Path(sys.executable).parent / 'ninja'
    options = {
        'CMAKE_BUILD_TYPE': 'Release', 'CMAKE_POLICY_VERSION_MINIMUM': '3.5',
        'CMAKE_MAKE_PROGRAM': ninja, 'CMAKE_INSTALL_PREFIX': install,
        'CMAKE_C_FLAGS': prefix_map_flag(ROOT),
        'CMAKE_CXX_FLAGS': prefix_map_flag(ROOT),
        'BUILD_LIST': 'core,imgproc,imgcodecs,python3',
        'PYTHON3_EXECUTABLE': sys.executable,
        'PYTHON3_PACKAGES_PATH': install / 'python',
    }
    for name in ('SHARED_LIBS', 'TESTS', 'PERF_TESTS', 'EXAMPLES', 'JAVA', 'opencv_apps'):
        options['BUILD_' + name] = 'OFF'
    for name in ('ZLIB', 'JPEG', 'PNG'):
        options['BUILD_' + name] = 'ON'
    for name in ('FFMPEG', 'GSTREAMER', 'AVFOUNDATION', 'OPENCL', 'OPENEXR',
                 'OPENJPEG', 'JASPER', 'WEBP', 'TIFF', 'AVIF', 'JPEGXL',
                 'EIGEN', 'LAPACK', 'IPP', 'TBB', 'VULKAN', 'PROTOBUF',
                 'GTK', 'QT', 'KLEIDICV'):
        options['WITH_' + name] = 'OFF'
    subprocess.run([str(cmake), '-S', str(source), '-B', str(build), '-G', 'Ninja',
                    *[f'-D{k}={v}' for k, v in options.items()]], check=True)
    for name in ('version_string.tmp', 'modules/core/version_string.inc', 'opencv_data_config.hpp'):
        info = build / name
        info.write_text(info.read_text().replace(str(ROOT), '/build/batch-auto-straighten'))
    subprocess.run([str(cmake), '--build', str(build), '--parallel',
                    str(min(os.cpu_count() or 2, 8))], check=True)
    subprocess.run([str(cmake), '--install', str(build)], check=True)
    # CMake emits absolute developer paths. Use paths relative to cv2 instead.
    cv = install / 'python/cv2'
    (cv / 'config.py').write_text('BINARIES_PATHS = []\n')
    version = f'{sys.version_info.major}.{sys.version_info.minor}'
    (cv / f'config-{version}.py').write_text(
        f'PYTHON_EXTENSIONS_PATHS = [os.path.join(LOADER_DIR, "python-{version}")]'
        ' + PYTHON_EXTENSIONS_PATHS\n')
    print(install / 'python')


if __name__ == '__main__':
    main()
