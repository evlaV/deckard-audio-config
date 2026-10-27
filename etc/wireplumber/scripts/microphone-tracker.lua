log = Log.open_topic("m-node")

-- returns the parsed table if value is a JSON object, nil otherwise
local function parseJsonObject (value)
  if value == nil then
    return nil
  end
  local json = Json.Raw (value)
  if not json:is_object () then
    return nil
  end
  return json:parse ()
end

local state = State ("steamos-filters")
local state_table = state:load ()

local mic_tracker_state = {
   stream_count = 0,
   default_source_name = "",
   default_sink_name = "",
}

local BUILTIN_SOURCE_NAME = "alsa_input.platform-sound.HiFi__Mic__source"
local BUILTIN_SINK_NAME   = "alsa_output.platform-sound.HiFi__Speaker__sink"

local BUILTIN_SOURCE_LOOPACK_NAME = "alsa_loopback_device." .. BUILTIN_SOURCE_NAME
local BUILTIN_SINK_LOOPACK_NAME   = "alsa_loopback_device.stereo." .. BUILTIN_SINK_NAME -- todo: should handle the 7.1 loopback as well

local function getEnabledMicFilters (mic_name)
  local enabled_filters = { aec = true, ns = true }

  local setting = Settings.get_object ("steamos.mic-filters")
  if mic_name == BUILTIN_SOURCE_LOOPACK_NAME then
    if setting then
      enabled_filters = setting.builtin
    else
      enabled_filters = setting.external
    end
  end

  local stored = parseJsonObject (state_table [mic_name])
  if stored then
    for k, v in pairs (stored) do enabled_filters [k] = v end
  end

  return enabled_filters
end

local function saveEnabledMicFilters (mic_name, value)
  local new_value = nil
  local enabled_filters = parseJsonObject (value)

  if enabled_filters then
    new_value = Json.Object {
      aec = enabled_filters.aec,
      ns = enabled_filters.ns,
    }:to_string ()
  end

  if state_table [mic_name] == new_value then
    return
  end

  state_table [mic_name] = new_value
  state:save_after_timeout (state_table)
end

function updateMicSmartFilters(event)
  local is_any_stream_active = false
  if mic_tracker_state.stream_count > 0 then
    is_any_stream_active = true
  end

  local source = event:get_source ()
  local node_om = source:call ("get-object-manager", "node")
  local metadata_om = source:call ("get-object-manager", "metadata")
  local metadata =
        metadata_om:lookup { Constraint { "metadata.name", "=", "filters" } }
  local mic_name = mic_tracker_state.default_source_name
  local spk_name = mic_tracker_state.default_sink_name
  local enabled_filters = getEnabledMicFilters (mic_name)

  for node in node_om:iterate() do
    if node.properties["steamos.mic_filter"] == "true" then
      local should_enable = false
      if node.properties["node.name"] == "eq_source" then
        if mic_name == BUILTIN_SOURCE_LOOPACK_NAME then
          should_enable = true
        end
      elseif node.properties["node.name"] == "echo_cancel_source" or node.properties["node.name"] == "echo_cancel_sink" then
        if mic_name == BUILTIN_SOURCE_LOOPACK_NAME and spk_name == BUILTIN_SINK_LOOPACK_NAME then
          should_enable = enabled_filters.aec
        end
      elseif node.properties["node.name"] == "echo_cancel_fallback_source" or node.properties["node.name"] == "echo_cancel_fallback_sink" then
        if mic_name ~= BUILTIN_SOURCE_LOOPACK_NAME or spk_name ~= BUILTIN_SINK_LOOPACK_NAME then
          should_enable = enabled_filters.aec
        end
      elseif node.properties["node.name"] == "ns_source" then
        if mic_name == BUILTIN_SOURCE_LOOPACK_NAME and spk_name == BUILTIN_SINK_LOOPACK_NAME then
          should_enable = enabled_filters.ns
        end
      end

      if is_any_stream_active and should_enable then
        metadata:set(node.properties["object.id"], "filter.smart.disabled", "Spa:String:JSON", "false")
        -- log:warning("ENABLING MIC FILTER: " .. node.properties["node.name"])
      else
        metadata:set(node.properties["object.id"], "filter.smart.disabled", "Spa:String:JSON")
        -- log:warning("DISABLING MIC FILTER: " .. node.properties["node.name"])
      end
    end
  end
end

-- if the given source node is a loopback (e.g. ALSA or bluez loopback), return
-- the name of the device node that its capture stream targets, otherwise
-- return the given name
function getLoopbackTargetNameForSource(node_om, source_name)
  local source = node_om:lookup{ Constraint{ "node.name", "=", source_name } }
  if source == nil then
    return source_name
  end

  local link_group = source.properties["node.link-group"]
  if link_group == nil then
    return source_name
  end

  -- node.link-group and target.object are not global properties
  local stream = node_om:lookup{
    Constraint{ "node.link-group", "=", link_group, type = "pw" },
    Constraint{ "media.class", "#", "Stream/Input/Audio*" },
    Constraint{ "target.object", "+", type = "pw" },
  }
  if stream == nil then
    return source_name
  end

  return stream.properties["target.object"]
end

-- if the given sink node is a loopback (e.g. ALSA or bluez loopback), return
-- the name of the device node that its playback stream targets, otherwise
-- return the given name
function getLoopbackTargetNameForSink(node_om, sink_name)
  local sink = node_om:lookup{ Constraint{ "node.name", "=", sink_name } }
  if sink == nil then
    return sink_name
  end

  local link_group = sink.properties["node.link-group"]
  if link_group == nil then
    return sink_name
  end

  -- node.link-group and target.object are not global properties
  local stream = node_om:lookup{
    Constraint{ "node.link-group", "=", link_group, type = "pw" },
    Constraint{ "media.class", "#", "Stream/Output/Audio*" },
    Constraint{ "target.object", "+", type = "pw" },
  }
  if stream == nil then
    return sink_name
  end

  return stream.properties["target.object"]
end

function selectMicSmartFilters(event)
  -- get the default source/sink pair
  local event_source = event:get_source()
  local metadata_om = event_source:call("get-object-manager", "metadata")
  local defaults = metadata_om:lookup{ Constraint{ "metadata.name", "=", "default" } }
  local default_source_name = Json.Raw(defaults:find(0, "default.audio.source")):parse().name
  local default_sink_name = Json.Raw(defaults:find(0, "default.audio.sink")):parse().name
  -- log:warning("DEFAULTS UPDATED: " .. default_source_name .. " / " .. default_sink_name)

  -- if either the source or the sink is built-in, but without the loopback, stop
  if default_source_name == BUILTIN_SOURCE_NAME or default_sink_name == BUILTIN_SINK_NAME then
    -- log:warning("LOOPBACK MISSING, NOT DOING ANYTHING YET")
    return
  end

  -- if the defaults didn't actually change, stop
  if default_source_name == mic_tracker_state.default_source_name and default_sink_name == mic_tracker_state.default_sink_name then
    -- log:warning("DEFAULTS UNCHANGED, NO WORK NEEDED")
    return
  end

  -- update state
  mic_tracker_state.default_source_name = default_source_name
  mic_tracker_state.default_sink_name = default_sink_name

  -- if using either external mic or external speakers, update the targeting metadata
  -- for the fallback aec
  if default_source_name ~= BUILTIN_SOURCE_LOOPACK_NAME or default_sink_name ~= BUILTIN_SINK_LOOPACK_NAME then
    local node_om = event_source:call("get-object-manager", "node")
    local filters = metadata_om:lookup{ Constraint { "metadata.name", "=", "filters" } }

    local fallback_aec_source = node_om:lookup{ Constraint{ "node.name", "=", "echo_cancel_fallback_source" } }
    if fallback_aec_source ~= nil then
      if default_source_name == BUILTIN_SOURCE_LOOPACK_NAME then
        filters:set(fallback_aec_source.properties["object.id"], "filter.smart.target", "Spa:String:JSON")
        -- log:warning("RESET FALLBACK AEC SOURCE TARGET")
      else
        -- target the device behind the loopback, so that the filter is linked
        -- between the device and the loopback stream, hidden from applications
        local target_name = getLoopbackTargetNameForSource(node_om, default_source_name)
        filters:set(fallback_aec_source.properties["object.id"], "filter.smart.target", "Spa:String:JSON", "{ node.name = \"" .. target_name .. "\" }")
        -- log:warning("SET FALLBACK AEC SOURCE TARGET: " .. target_name)
      end
    end

    local fallback_aec_sink = node_om:lookup{ Constraint{ "node.name", "=", "echo_cancel_fallback_sink" } }
    if fallback_aec_sink ~= nil then
      if default_sink_name == BUILTIN_SINK_LOOPACK_NAME then
        filters:set(fallback_aec_sink.properties["object.id"], "filter.smart.target", "Spa:String:JSON")
        -- log:warning("RESET FALLBACK AEC SINK TARGET")
      else
        -- target the device behind the loopback, so that the filter is linked
        -- between the device and the loopback stream, hidden from applications
        local target_name = getLoopbackTargetNameForSink(node_om, default_sink_name)
        filters:set(fallback_aec_sink.properties["object.id"], "filter.smart.target", "Spa:String:JSON", "{ node.name = \"" .. target_name .. "\" }")
        -- log:warning("SET FALLBACK AEC SINK TARGET: " .. default_sink_name)
      end
    end
  end

  -- if any recording streams are active, update which filters are enabled
  if mic_tracker_state.stream_count > 0 then
    updateMicSmartFilters(event)
  end
end

SimpleEventHook {
  name = "mic-stream-added",
  interests = {
	 EventInterest {
		Constraint { "event.type", "=", "node-added" },
		Constraint { "media.class", "=", "Stream/Input/Audio" },
		Constraint { "node.virtual", "!", "true" }
	 }
  },
  execute = function(event)
	  mic_tracker_state.stream_count = mic_tracker_state.stream_count + 1
    if mic_tracker_state.stream_count == 1 then
      updateMicSmartFilters(event)
    end
  end
}:register()

SimpleEventHook {
  name = "mic-stream-removed",
  interests = {
	 EventInterest {
		Constraint { "event.type", "=", "node-removed" },
		Constraint { "media.class", "=", "Stream/Input/Audio" },
		Constraint { "node.virtual", "!", "true" }
	 }
  },
  execute = function(event)
    mic_tracker_state.stream_count = math.max(0, mic_tracker_state.stream_count - 1)
    updateMicSmartFilters(event)
  end
}:register()

SimpleEventHook {
  name = "mic-filters/defaults-changed",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "metadata-changed" },
      Constraint { "metadata.name", "=", "default" },
      Constraint { "event.subject.key", "c", "default.audio.source", "default.audio.sink" }
    }
  },
  execute = function(event)
    selectMicSmartFilters(event)
  end
}:register()

SimpleEventHook {
  name = "mic-filters/settings-changed",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "metadata-changed" },
      Constraint { "metadata.name", "=", "steamos-filters" },
    }
  },
  execute = function (event)
    local props = event:get_properties ()
    local mic_name = props ["event.subject.key"]
    local value = props ["event.subject.value"]

    saveEnabledMicFilters (mic_name, value)

    if mic_name == mic_tracker_state.default_source_name then
      updateMicSmartFilters (event)
    end
  end
}:register ()

-- Populate metadata on load
local metadata_om = ObjectManager {
  Interest { type = "metadata", Constraint { "metadata.name", "=", "steamos-filters" } }
}
metadata_om:connect ("object-added", function (om, metadata)
  for mic_name, value in pairs (state_table) do
    metadata:set (0, mic_name, "Spa:String:JSON", value)
  end
end)
metadata_om:activate ()
