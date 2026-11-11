#!/usr/bin/env python3
"""Puts the speech model into the iPhone app, as the Mac app's build does (ARCHITECTURE.md, "Build and targets").

Usage: copy-model.py PIN MODEL_DIR NOTICES_DIR APP DEPLOYMENT_TARGET

MODEL_DIR must hold the build the pin lists for this app: the first build in PIN whose requirements an iPhone on
DEPLOYMENT_TARGET meets, judged as the app judges them (../../ARCHITECTURE.md, section 5): a build that requires
anything but `macos` and `ios`, or gives a version that cannot be read, is passed over, and a build fits an iPhone
only when it names `ios`. Its bundle.json must have that build's SHA-256, and every file the manifest lists must match
its own. Exactly those files and bundle.json are copied into APP/Model, each checked as it is written, with the pin as
APP/model.lock.json and the model's notices in APP/ModelNotices. On any failure nothing is left in APP and the reason
is printed. Reads only those paths and writes only into APP; no network.
"""
import hashlib
import json
import os
import re
import shutil
import sys

KNOWN = {"macos", "ios"}
VERSION = re.compile(r"[0-9]{1,6}(\.[0-9]{1,6}){0,2}")


def fail(message):
    sys.exit("SORELLO_MODEL_DIR: " + message)


def version(text):
    """The version `text` writes, as three numbers, or None if it cannot be read."""
    if not isinstance(text, str) or not VERSION.fullmatch(text):
        return None
    parts = [int(part) for part in text.split(".")]
    return tuple(parts + [0] * (3 - len(parts)))


def build_for_iphone(pin, target):
    """The first build an iPhone on `target` takes, or None."""
    for build in pin.get("builds", []):
        requires = build.get("requires") if isinstance(build, dict) else None
        if not isinstance(requires, dict) or not set(requires) <= KNOWN:
            continue
        minimum = {key: version(value) for key, value in requires.items()}
        if None in minimum.values():
            continue
        if "ios" in minimum and minimum["ios"] <= target:
            return build
    return None


def is_relative(path):
    """A path that stays where it is put: not empty, not absolute, no empty, `.` or `..` part, no backslash or NUL."""
    return (isinstance(path, str) and path != "" and "\\" not in path and "\0" not in path
            and all(part not in ("", ".", "..") for part in path.split("/")))


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def copy_checked(source, target, expected):
    """Copies `source` to `target`, hashing what is written; True if it matches `expected`."""
    digest = hashlib.sha256()
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(source, "rb") as reading, open(target, "wb") as writing:
        for block in iter(lambda: reading.read(1 << 20), b""):
            digest.update(block)
            writing.write(block)
    return digest.hexdigest() == expected


def main():
    if len(sys.argv) != 6:
        sys.exit(__doc__.split("\n\n")[1])
    pin_path, source, notices, app, deployment = sys.argv[1:]
    target = version(deployment)
    if target is None:
        fail("the deployment target %r is not a version" % deployment)
    try:
        with open(pin_path, "rb") as handle:
            pin = json.load(handle)
    except (OSError, ValueError):
        fail("the pin cannot be read")
    build = build_for_iphone(pin, target) if isinstance(pin, dict) else None
    if build is None:
        fail("the pin lists no build for iOS %s" % deployment)
    pinned = build.get("manifest_sha256")
    if not isinstance(pinned, str) or not re.fullmatch(r"[0-9a-f]{64}", pinned):
        fail("the pin's build for iOS has no SHA-256")

    manifest_path = os.path.join(source, "bundle.json")
    if not os.path.isfile(manifest_path):
        fail("there is no bundle.json")
    if sha256(manifest_path) != pinned:
        fail("this is not the build the pin lists for iOS %s (its bundle.json has another SHA-256)" % deployment)
    with open(manifest_path, "rb") as handle:
        files = json.load(handle).get("files")
    if not isinstance(files, dict) or not files:
        fail("bundle.json lists no files")

    model = os.path.join(app, "Model")
    placed = [model, os.path.join(app, "model.lock.json"), os.path.join(app, "ModelNotices")]

    def undo():
        for path in placed:
            if os.path.isdir(path):
                shutil.rmtree(path)
            elif os.path.exists(path):
                os.remove(path)

    undo()
    try:
        for name, expected in sorted(files.items()):
            if not is_relative(name) or name == "bundle.json":
                undo()
                fail("bundle.json lists a path outside the model")
            if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
                undo()
                fail("bundle.json has no SHA-256 for %s" % name)
            path = os.path.join(source, name)
            if not os.path.isfile(path):
                undo()
                fail("%s is missing" % name)
            if not copy_checked(path, os.path.join(model, name), expected):
                undo()
                fail("%s does not match its SHA-256 in bundle.json" % name)
        if not copy_checked(manifest_path, os.path.join(model, "bundle.json"), pinned):
            undo()
            fail("bundle.json changed while it was copied")
        shutil.copyfile(pin_path, os.path.join(app, "model.lock.json"))
        os.makedirs(os.path.join(app, "ModelNotices"))
        for name in sorted(os.listdir(notices)):
            if not name.startswith("."):
                shutil.copyfile(os.path.join(notices, name), os.path.join(app, "ModelNotices", name))
    except OSError as error:
        undo()
        fail("copying failed (%s)" % error.strerror)
    print("Copied the model (%d files verified against the pin's build %s)" % (len(files) + 1, build.get("directory")))


if __name__ == "__main__":
    main()
