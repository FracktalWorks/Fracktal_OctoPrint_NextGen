"""plugins.octoprint.org's check overlay must not redirect the update checks of Fracktal components."""

from octoprint.plugins.softwareupdate import FRACKTAL_MANAGED_CHECKS, without_fracktal_checks

# excerpt of https://plugins.octoprint.org/update_check_overlay.json (2026-10-24)
OVERLAY = {
    "octoprint": {"user": "OctoPrint"},
    "klipper": {"user": "AliceGrey"},
    "costestimation": {"user": "someone"},
}


def test_fracktal_checks_are_dropped_from_the_overlay():
    filtered = without_fracktal_checks(OVERLAY)
    assert "octoprint" not in filtered
    assert "klipper" not in filtered
    assert filtered == {"costestimation": {"user": "someone"}}


def test_other_plugins_keep_their_overlay_and_none_is_safe():
    assert without_fracktal_checks(None) == {}
    assert without_fracktal_checks({"x": 1}) == {"x": 1}
    assert {"octoprint", "klipper", "ControlCenter", "TwinDragonPrintRestore"} <= FRACKTAL_MANAGED_CHECKS
