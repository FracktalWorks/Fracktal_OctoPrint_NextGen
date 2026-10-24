"""
Profiles written by upstream OctoPrint (or this fork before the Fracktal heater keys
existed) must survive loading: they get the new keys filled in instead of being
rejected and replaced by the factory default profile.
"""

import copy
import logging

import pytest

from octoprint.printer.profile import PrinterProfileManager

# _default.profile as saved by upstream OctoPrint 1.11.7 on a TwinDragon 600 V2
UPSTREAM_PROFILE = {
    "axes": {
        "e": {"inverted": False, "speed": 300},
        "x": {"inverted": False, "speed": 6000},
        "y": {"inverted": False, "speed": 6000},
        "z": {"inverted": True, "speed": 3000},
    },
    "color": "default",
    "extruder": {
        "count": 2,
        "defaultExtrusionLength": 5,
        "nozzleDiameter": 0.4,
        "offsets": [[0.0, 0.0], [0.0, 0.0]],
        "sharedNozzle": False,
    },
    "heatedBed": True,
    "heatedChamber": False,
    "id": "_default",
    "model": "Fracktal Works Series",
    "name": "Twin Dragon 600 V2",
    "volume": {
        "custom_box": False,
        "depth": 620.0,
        "formFactor": "rectangular",
        "height": 414.0,
        "origin": "lowerleft",
        "width": 660.0,
    },
}


@pytest.fixture
def manager():
    # the migration/validation helpers need no settings or profile folder
    m = PrinterProfileManager.__new__(PrinterProfileManager)
    m._logger = logging.getLogger(__name__)
    return m


@pytest.mark.parametrize(
    "present",
    [{}, {"heatedFilament": False}, {"hasSecondaryHeaters": False}],
    ids=["both-missing", "secondary-heaters-missing", "filament-missing"],
)
def test_upstream_profile_is_migrated_not_rejected(manager, present):
    profile = copy.deepcopy(UPSTREAM_PROFILE)
    profile.update(present)

    assert manager._migrate_profile(profile)
    validated = manager._ensure_valid_profile(profile)

    assert validated, "migrated upstream profile must validate"
    assert validated["name"] == "Twin Dragon 600 V2"
    assert validated["extruder"]["count"] == 2
    assert validated["volume"]["width"] == 660.0
    assert validated["heatedFilament"] is False
    assert validated["hasSecondaryHeaters"] is False


def test_current_profile_is_left_unchanged(manager):
    profile = copy.deepcopy(UPSTREAM_PROFILE)
    profile.update(heatedFilament=True, hasSecondaryHeaters=True)

    assert not manager._migrate_profile(profile)
    validated = manager._ensure_valid_profile(profile)
    assert validated["heatedFilament"] is True
    assert validated["hasSecondaryHeaters"] is True
