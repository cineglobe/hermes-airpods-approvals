"""AirPods Approvals: agent half.

The plugin's work happens on the Mac, in ``desktop/plugin.js`` and the helper in ``helper/``. This
half only adds optional Gemini speech, through the route in ``dashboard/plugin_api.py``, and
``hermes airpods-approvals doctor`` for checking it.
"""

from __future__ import annotations


def _doctor(_args) -> int:
    from . import airpods_core as core

    state = core.status()
    print(f"AirPods Approvals {state['version']}")
    if state["ready"]:
        print(f"Gemini voice ready ({state['model']}, {state['voice']}, key from {state['key_source']})")
    else:
        print("No Gemini key found. The Mac's own voice will be used.")
        print("To add one:  hermes config set AIRPODS_APPROVALS_GEMINI_KEY <key>")
    return 0


def _setup(parser) -> None:
    commands = parser.add_subparsers(dest="airpods_command")
    commands.add_parser("doctor", help="Check the optional Gemini voice").set_defaults(func=_doctor)
    parser.set_defaults(func=_doctor)


def register(ctx) -> None:
    ctx.register_cli_command(
        name="airpods-approvals",
        help="AirPods Approvals: check the optional Gemini voice",
        setup_fn=_setup,
        handler_fn=_doctor,
    )
