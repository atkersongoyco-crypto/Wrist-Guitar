#!/usr/bin/env python3
"""Package an iPhone app and its embedded Watch app without performing signing.

Usage:
    python3 Scripts/package_unsigned_app.py \
        --app /path/to/AirGuitar.app --output /path/to/AirGuitar-unsigned.ipa

The input is read-only. Symlinks are rejected rather than followed, and an
existing output is never overwritten. This validates bundle relationships and
Mach-O headers, not code signatures, provisioning, or device installability.
"""

import argparse
import os
from pathlib import Path
import plistlib
import stat
import sys
import zipfile
from xml.parsers.expat import ExpatError


class PackageError(Exception):
    """A bundle cannot be packaged safely or consistently."""


MACHO_MAGICS = {
    b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe",  # 32-bit Mach-O
    b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe",  # 64-bit Mach-O
    b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",  # universal
    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca",  # universal 64-bit
}


def inside(path, directory):
    try:
        path.relative_to(directory)
        return True
    except ValueError:
        return False


def bundle_info(bundle):
    info_path = bundle / "Info.plist"
    if not info_path.is_file() or info_path.is_symlink():
        raise PackageError(f"Missing regular Info.plist: {info_path}")
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
        raise PackageError(f"Cannot read {info_path}: {error}") from error
    if not isinstance(info, dict):
        raise PackageError(f"Info.plist must contain a dictionary: {info_path}")

    identifier = info.get("CFBundleIdentifier")
    if (not isinstance(identifier, str) or not identifier
            or any(character.isspace() for character in identifier)
            or "$" in identifier):
        raise PackageError(f"Invalid or unresolved CFBundleIdentifier: {info_path}")
    executable = info.get("CFBundleExecutable")
    if (not isinstance(executable, str) or not executable
            or executable in (".", "..") or "/" in executable or "\\" in executable):
        raise PackageError(f"Invalid CFBundleExecutable: {info_path}")
    binary = bundle / executable
    if not binary.is_file() or binary.is_symlink():
        raise PackageError(f"Missing regular app executable: {binary}")
    if not binary.stat().st_mode & 0o111:
        raise PackageError(f"App executable has no executable permission bits: {binary}")
    with binary.open("rb") as handle:
        if handle.read(4) not in MACHO_MAGICS:
            raise PackageError(f"App executable does not have a Mach-O header: {binary}")
    return info


def source_entries(app):
    """List every regular file and directory; never traverse symbolic links."""
    entries = [app]
    for directory, child_directories, filenames in os.walk(app, followlinks=False):
        child_directories.sort()
        filenames.sort()
        for name in child_directories + filenames:
            path = Path(directory) / name
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise PackageError(f"Symlinks are not supported; input was not changed: {path}")
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise PackageError(f"Only regular files and directories are supported: {path}")
            entries.append(path)
    return entries


def package_app(app_argument, output_argument):
    original_app = Path(app_argument).expanduser().absolute()
    if original_app.is_symlink():
        raise PackageError(f"The input app must not be a symlink: {original_app}")
    app = original_app.resolve()
    if not app.is_dir() or app.suffix != ".app":
        raise PackageError(f"--app must name an existing .app directory: {app}")
    original_output = Path(output_argument).expanduser().absolute()
    if original_output.is_symlink():
        raise PackageError(f"The output must not be a symlink: {original_output}")
    output = original_output.resolve()
    if inside(output, app):
        raise PackageError("The output must be outside the input app bundle.")
    if output.suffix.lower() != ".ipa":
        raise PackageError("--output must have the .ipa extension.")
    if output.exists():
        raise PackageError(f"Refusing to overwrite an existing output: {output}")

    # Complete validation before creating the output file.
    entries = source_entries(app)
    phone = bundle_info(app)
    watch_directory = app / "Watch"
    watches = sorted(watch_directory.glob("*.app")) if watch_directory.is_dir() else []
    if not watches:
        raise PackageError("No embedded Watch/*.app found in the iPhone app.")
    watch_identifiers = []
    for watch in watches:
        if not watch.is_dir():
            raise PackageError(f"Embedded Watch app is not a directory: {watch}")
        info = bundle_info(watch)
        identifier = info["CFBundleIdentifier"]
        if not identifier.startswith(phone["CFBundleIdentifier"] + "."):
            raise PackageError(f"Watch bundle identifier must extend the iPhone identifier: {identifier}")
        if info.get("WKCompanionAppBundleIdentifier") != phone["CFBundleIdentifier"]:
            raise PackageError(f"WKCompanionAppBundleIdentifier does not match the iPhone app: {watch}")
        if identifier in watch_identifiers:
            raise PackageError(f"Duplicate embedded Watch bundle identifier: {identifier}")
        watch_identifiers.append(identifier)

    output.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation also protects against an output appearing after validation.
    try:
        with output.open("xb") as handle:
            with zipfile.ZipFile(handle, "w", compression=zipfile.ZIP_DEFLATED,
                                 compresslevel=6, strict_timestamps=False) as archive:
                payload = zipfile.ZipInfo("Payload/")
                payload.create_system = 3
                payload.external_attr = (stat.S_IFDIR | 0o755) << 16 | 0x10
                archive.writestr(payload, b"")
                for entry in entries:
                    if entry.is_symlink():
                        raise PackageError(f"Input changed during packaging; symlink found: {entry}")
                    archive_path = (Path("Payload") / app.name / entry.relative_to(app)).as_posix()
                    # ZipFile.write preserves Unix permission bits, including executable bits.
                    archive.write(entry, arcname=archive_path)
    except FileExistsError as error:
        raise PackageError(f"Refusing to overwrite an existing output: {output}") from error
    except Exception as error:
        # Do not delete either source or output; a failed write remains visible.
        raise PackageError(f"Packaging failed; any partial output was left at {output}: {error}") from error
    return output, phone["CFBundleIdentifier"], watch_identifiers


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, type=Path, help="Built physical-device iPhone .app directory")
    parser.add_argument("--output", required=True, type=Path, help="New .ipa path, outside the input bundle")
    arguments = parser.parse_args()
    try:
        output, phone_identifier, watch_identifiers = package_app(arguments.app, arguments.output)
    except (PackageError, OSError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    print(f"Created {output}")
    print(f"iPhone: {phone_identifier}")
    print(f"Watch: {', '.join(watch_identifiers)}")
    print("No signing was performed. Sign the iPhone app and embedded Watch app before installation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
