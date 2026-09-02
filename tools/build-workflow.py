#!/usr/bin/env python3
"""Generate the "Send to ImageOptim" Automator Quick Action.

An .workflow bundle is just a folder holding two property lists, so we build
it from src/send-to-imageoptim.sh instead of keeping a second, hand-edited
copy of the script inside a plist. Run this after editing the script:

    python3 tools/build-workflow.py

UUIDs are fixed rather than random so that rebuilding produces no diff.
"""

import plistlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "src" / "send-to-imageoptim.sh"
BUNDLE = ROOT / "Send to ImageOptim.workflow"

MENU_TITLE = "Send to ImageOptim"

# Which Finder selections make the Quick Action appear. The script itself does
# the real filtering; this only decides when the menu item is offered.
SEND_FILE_TYPES = ["public.image", "public.folder"]

ACTION_UUID = "3E1F5B0A-4C6D-4E2A-9B77-1D2C3F4A5B60"
INPUT_UUID = "7A0C2D14-8E39-4F51-A6B2-0C9D8E7F6A51"
OUTPUT_UUID = "C4B39E27-5A18-4D63-8F0E-2B7A1C6D9E42"


def info_plist() -> dict:
    return {
        "NSServices": [
            {
                "NSMenuItem": {"default": MENU_TITLE},
                "NSMessage": "runWorkflowAsService",
                "NSRequiredContext": {"NSApplicationIdentifier": "com.apple.finder"},
                "NSSendFileTypes": SEND_FILE_TYPES,
            }
        ]
    }


def document_wflow(command: str) -> dict:
    run_shell_script = {
        "action": {
            "AMAccepts": {
                "Container": "List",
                "Optional": True,
                "Types": ["com.apple.cocoa.string"],
            },
            "AMActionVersion": "2.0.3",
            "AMApplication": ["Automator"],
            "AMParameterProperties": {
                "COMMAND_STRING": {},
                "CheckedForUserDefaultShell": {},
                "inputMethod": {},
                "shell": {},
                "source": {},
            },
            "AMProvides": {
                "Container": "List",
                "Types": ["com.apple.cocoa.string"],
            },
            "ActionBundlePath": "/System/Library/Automator/Run Shell Script.action",
            "ActionName": "Run Shell Script",
            "ActionParameters": {
                "COMMAND_STRING": command,
                "CheckedForUserDefaultShell": True,
                # 1 = pass the Finder selection as "$@" rather than on stdin.
                "inputMethod": 1,
                "shell": "/bin/bash",
                "source": "",
            },
            "BundleIdentifier": "com.apple.RunShellScript",
            "CFBundleVersion": "2.0.3",
            "CanShowSelectedItemsWhenRun": False,
            "CanShowWhenRun": True,
            "Category": ["AMCategoryUtilities"],
            "Class Name": "RunShellScriptAction",
            "InputUUID": INPUT_UUID,
            "Keywords": ["Shell", "Script", "Command", "Run", "Unix"],
            "OutputUUID": OUTPUT_UUID,
            "UUID": ACTION_UUID,
            "UnlocalizedApplications": ["Automator"],
            "arguments": {
                "0": {
                    "default value": 0,
                    "name": "inputMethod",
                    "required": "0",
                    "type": "0",
                    "uuid": "0",
                },
                "1": {
                    "default value": "",
                    "name": "source",
                    "required": "0",
                    "type": "0",
                    "uuid": "1",
                },
                "2": {
                    "default value": False,
                    "name": "CheckedForUserDefaultShell",
                    "required": "0",
                    "type": "0",
                    "uuid": "2",
                },
                "3": {
                    "default value": "",
                    "name": "COMMAND_STRING",
                    "required": "0",
                    "type": "0",
                    "uuid": "3",
                },
                "4": {
                    "default value": "/bin/sh",
                    "name": "shell",
                    "required": "0",
                    "type": "0",
                    "uuid": "4",
                },
            },
            "isViewVisible": 1,
            "location": "309.000000:253.000000",
            "nibPath": "/System/Library/Automator/Run Shell Script.action/Contents/"
            "Resources/Base.lproj/main.nib",
        },
        "isViewVisible": 1,
    }

    return {
        "AMApplicationBuild": "521",
        "AMApplicationVersion": "2.10",
        "AMDocumentVersion": "2",
        "actions": [run_shell_script],
        "connectors": {},
        "workflowMetaData": {
            "applicationBundleIDsByPath": {
                "/System/Library/CoreServices/Finder.app": "com.apple.finder"
            },
            "applicationPaths": ["/System/Library/CoreServices/Finder.app"],
            "inputTypeIdentifier": "com.apple.Automator.fileSystemObject",
            "outputTypeIdentifier": "com.apple.Automator.nothing",
            # 11 = Quick Action: run silently, no Automator window.
            "presentationMode": 11,
            "processesInput": 0,
            "serviceApplicationBundleID": "com.apple.finder",
            "serviceApplicationPath": "/System/Library/CoreServices/Finder.app",
            "serviceInputTypeIdentifier": "com.apple.Automator.fileSystemObject",
            "serviceOutputTypeIdentifier": "com.apple.Automator.nothing",
            "serviceProcessesInput": 0,
            "systemImageName": "NSActionTemplate",
            "useAutomaticInputType": 0,
            "workflowTypeIdentifier": "com.apple.Automator.servicesMenu",
        },
    }


def main() -> int:
    if not SCRIPT.is_file():
        print(f"missing {SCRIPT}", file=sys.stderr)
        return 1

    command = SCRIPT.read_text()

    contents = BUNDLE / "Contents"
    contents.mkdir(parents=True, exist_ok=True)

    with (contents / "Info.plist").open("wb") as handle:
        plistlib.dump(info_plist(), handle)
    with (contents / "document.wflow").open("wb") as handle:
        plistlib.dump(document_wflow(command), handle)

    print(f"built {BUNDLE.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
