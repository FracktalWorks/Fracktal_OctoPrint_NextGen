"""
Tests for the Fracktal Works additions to octoprint.util.comm:

* heated filament ("F:") is surfaced as the custom sensor ``filament``
* secondary heaters ("H0:", "H1:", ...) flow through as custom sensors
* ``M104 H<n> S<temp>`` addresses a secondary heater and never a tool
* ``M142`` / ``M192`` are suppressed when the profile has no heated filament
"""

import unittest
from unittest import mock

import octoprint.util.comm as comm
from octoprint.printer import PrinterInterface

M105 = "ok T:180.5 /200.0 B:60.3 /60.0 H0:75.2 /80.0 H1:45.0 /50.0 F:35.0 /40.0"


def _machine(profile):
    """A MachineCom stand-in with just enough state for temperature handling."""
    m = mock.create_autospec(comm.MachineCom, instance=True)
    m._currentTool = 0
    m._temperature_hooks = {}
    m._known_broken_temperature_hooks = set()
    m._known_invalid_custom_temps = set()
    m.last_temperature = comm.TemperatureRecord()
    m._printerProfileManager = mock.Mock()
    base = {"extruder": {"count": 2, "sharedNozzle": False}, "heatedChamber": False}
    base.update(profile)
    m._printerProfileManager.get_current_or_default.return_value = base
    m._capability_supported.return_value = False
    m._callback = mock.Mock()
    m._log = mock.Mock()
    m._logger = mock.Mock()
    m._process = lambda line: comm.MachineCom._processTemperatures(m, line)
    return m


class TemperatureParsingTest(unittest.TestCase):
    def test_parse_line_keeps_secondary_heaters_and_filament(self):
        _, parsed = comm.parse_temperature_line(M105, 0)
        self.assertEqual((75.2, 80.0), parsed["H0"])
        self.assertEqual((45.0, 50.0), parsed["H1"])
        self.assertEqual((35.0, 40.0), parsed["F"])

    def test_secondary_heaters_become_custom_sensors(self):
        m = _machine({"hasSecondaryHeaters": True, "heatedFilament": False})
        m._process(M105)
        custom = m.last_temperature.custom
        self.assertEqual((75.2, 80.0), custom["H0"])
        self.assertEqual((45.0, 50.0), custom["H1"])
        # filament is not enabled for this profile: stays a plain custom "F"
        self.assertIn("F", custom)
        self.assertNotIn("filament", custom)

    def test_filament_is_renamed_when_profile_has_heated_filament(self):
        m = _machine({"heatedFilament": True})
        m._process(M105)
        custom = m.last_temperature.custom
        self.assertEqual((35.0, 40.0), custom["filament"])
        self.assertNotIn("F", custom)

    def test_tools_and_bed_unaffected(self):
        m = _machine({"hasSecondaryHeaters": True, "heatedFilament": True})
        m._process(M105)
        self.assertEqual((180.5, 200.0), m.last_temperature.tools[0])
        self.assertEqual((60.3, 60.0), m.last_temperature.bed)


class HeaterCommandTest(unittest.TestCase):
    def test_heater_regexes_accept_fracktal_heaters(self):
        for heater in ("tool0", "tool", "bed", "chamber", "filament", "H0", "H12"):
            self.assertTrue(PrinterInterface.valid_heater_regex.match(heater), heater)
        for heater in ("tool0", "bed", "chamber", "filament", "H0"):
            self.assertTrue(
                PrinterInterface.valid_heater_regex_no_current.match(heater), heater
            )
        for heater in ("h0", "H", "Hx", "heater0", "filament1"):
            self.assertFalse(PrinterInterface.valid_heater_regex.match(heater), heater)

    def test_m104_h_sets_secondary_heater_target_not_tool(self):
        m = _machine({"hasSecondaryHeaters": True})
        m.last_temperature.set_tool(0, actual=20.0, target=0.0)
        comm.MachineCom._gcode_M104_sent(m, "M104 H1 S55")
        self.assertEqual(55.0, m.last_temperature.custom["H1"][1])
        self.assertEqual(0.0, m.last_temperature.tools[0][1])
        m._callback.on_comm_temperature_update.assert_called_once()

    def test_m104_h_without_secondary_heaters_is_plain_tool_command(self):
        m = _machine({"hasSecondaryHeaters": False})
        m.last_temperature.set_tool(0, actual=20.0, target=0.0)
        comm.MachineCom._gcode_M104_sent(m, "M104 H1 S55")
        self.assertEqual(55.0, m.last_temperature.tools[0][1])

    def test_m142_suppressed_without_heated_filament(self):
        m = _machine({"heatedFilament": False})
        with mock.patch.object(comm, "eventManager"):
            result = comm.MachineCom._gcode_M142_queuing(m, "M142 S40")
        self.assertEqual((None,), result)

    def test_m142_passes_with_heated_filament_and_tracks_target(self):
        m = _machine({"heatedFilament": True})
        self.assertIsNone(comm.MachineCom._gcode_M142_queuing(m, "M142 S40"))
        comm.MachineCom._gcode_M142_sent(m, "M142 S40")
        self.assertEqual(40.0, m.last_temperature.custom["filament"][1])
