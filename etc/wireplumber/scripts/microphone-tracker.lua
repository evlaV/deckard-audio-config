log = Log.open_topic("m-node")

local mic_tracker_state = {
   stream_count = 0,
   default_source_name = "",
   default_sink_name = "",
}

local BUILTIN_SOURCE_NAME = "alsa_input.platform-sound.HiFi__Mic__source"
local BUILTIN_SINK_NAME   = "alsa_output.platform-sound.HiFi__Speaker__sink"

local BUILTIN_SOURCE_LOOPACK_NAME = "alsa_loopback_device." .. BUILTIN_SOURCE_NAME
local BUILTIN_SINK_LOOPACK_NAME   = "alsa_loopback_device.stereo." .. BUILTIN_SINK_NAME -- nocheckin: should handle the 7.1 loopback as well

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

  for node in node_om:iterate() do
    if node.properties["steamos.mic_filter"] == "true" then
      local should_enable = false
      if node.properties["node.name"] == "eq_source" then
        if mic_tracker_state.default_source_name == BUILTIN_SOURCE_LOOPACK_NAME then
          should_enable = true
        end
      elseif node.properties["node.name"] == "echo_cancel_source" or node.properties["node.name"] == "echo_cancel_sink" then
        if mic_tracker_state.default_source_name == BUILTIN_SOURCE_LOOPACK_NAME and mic_tracker_state.default_sink_name == BUILTIN_SINK_LOOPACK_NAME then
          should_enable = true
        end
      elseif node.properties["node.name"] == "echo_cancel_fallback_source" or node.properties["node.name"] == "echo_cancel_fallback_sink" then
        if mic_tracker_state.default_source_name ~= BUILTIN_SOURCE_LOOPACK_NAME or mic_tracker_state.default_sink_name ~= BUILTIN_SINK_LOOPACK_NAME then
          should_enable = true
        end
      elseif node.properties["node.name"] == "ns_source" then
        if mic_tracker_state.default_source_name == BUILTIN_SOURCE_LOOPACK_NAME and mic_tracker_state.default_sink_name == BUILTIN_SINK_LOOPACK_NAME then
          should_enable = true
        end
      end

      if is_any_stream_active and should_enable then
        metadata:set(node.properties["object.id"], "filter.smart.disabled", "Spa:String:JSON", "false")
        log:warning("ENABLING MIC FILTER: " .. node.properties["node.name"])
      else
        metadata:set(node.properties["object.id"], "filter.smart.disabled", "Spa:String:JSON")
        log:warning("DISABLING MIC FILTER: " .. node.properties["node.name"])
      end
    end
  end
end

function selectMicSmartFilters(event)
  -- get the default source/sink pair
  local event_source = event:get_source()
  local metadata_om = event_source:call("get-object-manager", "metadata")
  local defaults = metadata_om:lookup{ Constraint{ "metadata.name", "=", "default" } }
  local default_source_name = Json.Raw(defaults:find(0, "default.audio.source")):parse().name
  local default_sink_name = Json.Raw(defaults:find(0, "default.audio.sink")):parse().name
  log:warning("DEFAULTS UPDATED: " .. default_source_name .. " / " .. default_sink_name)

  -- if either the source or the sink is built-in, but without the loopback, stop
  if default_source_name == BUILTIN_SOURCE_NAME or default_sink_name == BUILTIN_SINK_NAME then
    log:warning("LOOPBACK MISSING, NOT DOING ANYTHING YET")
    return
  end

  -- if the defaults didn't actually change, stop
  if default_source_name == mic_tracker_state.default_source_name and default_sink_name == mic_tracker_state.default_sink_name then
    log:warning("DEFAULTS UNCHANGED, NO WORK NEEDED")
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
        log:warning("RESET FALLBACK AEC SOURCE TARGET")
      else
        filters:set(fallback_aec_source.properties["object.id"], "filter.smart.target", "Spa:String:JSON", "{ node.name = \"" .. default_source_name .. "\" }")
        log:warning("SET FALLBACK AEC SOURCE TARGET: " .. default_source_name)
      end
    end

    local fallback_aec_sink = node_om:lookup{ Constraint{ "node.name", "=", "echo_cancel_fallback_sink" } }
    if fallback_aec_sink ~= nil then
      if default_sink_name == BUILTIN_SINK_LOOPACK_NAME then
        filters:set(fallback_aec_sink.properties["object.id"], "filter.smart.target", "Spa:String:JSON")
        log:warning("RESET FALLBACK AEC SINK TARGET")
      else
        filters:set(fallback_aec_sink.properties["object.id"], "filter.smart.target", "Spa:String:JSON", "{ node.name = \"" .. default_sink_name .. "\" }")
        log:warning("SET FALLBACK AEC SINK TARGET: " .. default_sink_name)
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
