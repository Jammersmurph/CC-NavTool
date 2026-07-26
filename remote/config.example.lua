return {
  activeProfile = "default",
  autoRefresh = true,
  -- The beacon runs silently beside the NavRemote UI. A wireless or Ender modem
  -- and GPS coverage are required before it can transmit a position.
  locationBeacon = {
    enabled = true,
    port = 9999,
    interval = 3,
  },
  profiles = {
    default = {
      channel = "cc-navtool",
      host = "navtool-aircraft",
      sharedKey = "",
      timeout = 3,
    },
  },
}
