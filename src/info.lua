-- =============================================================
-- info.lua -- Elo 6554L Control
--
-- Plugin identity block. Embedded in the .qplug file and read by
-- Q-SYS Designer when loading the plugin.
--
-- Version is injected from package.json by build.js. Do not edit
-- it here.
--
-- Id is a stable GUID that uniquely identifies this plugin.
-- Do not change it after the plugin has been deployed, or
-- existing designs will lose the reference and need to be
-- manually reconnected.
-- =============================================================

PluginInfo = {
  Name = "Hybridsix Software~Displays~Elo~Elo 6554L Control",
  Version = "@VERSION@",
  BuildVersion = "@VERSION@.0",
  Id = "791af0df-abb0-47c2-ad28-6580e602d157",
  Author = "Michael King",
  Description = "Control the Elo 6554L (ET6554L) interactive display from Q-SYS: display on / off (backlight), input, brightness and volume over Elo MDC on TCP port 5000, with temperature and usage-hour feedback.",
}
