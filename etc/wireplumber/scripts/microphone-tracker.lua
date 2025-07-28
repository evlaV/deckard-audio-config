local mic_tracker_state = {
   stream_count = 0,
}

function set_mic_filters_disabled(event, is_disabled)
   local source = event:get_source ()
   local node_om = source:call ("get-object-manager", "node")
   local metadata_om = source:call ("get-object-manager", "metadata")
   local metadata =
         metadata_om:lookup { Constraint { "metadata.name", "=", "filters" } }

  for node in node_om:iterate() do
    local test = node.properties["steamos.mic_filter"] == "true"
    local node_id = node.properties["object.id"]
    if test then
      metadata:set(node_id, "filter.smart.disabled", "Spa:String:JSON", is_disabled)
      -- print("-> Set " .. node_id .. " to " .. is_disabled)
    end
  end
end

-- TODO: Use node-added hooks to update anythin
SimpleEventHook {
  name = "mic-smart-filter-added",
  interests = {
	 EventInterest {
		Constraint { "event.type", "=", "node-added" },
		--Constraint { "steamos.mic_filter", "=", "true" },
	 }
  },
  execute = function(event)
	 local node = event:get_subject()
	 local test = node.properties["steamos.mic_filter"] == "true"
	 local node_id = node.properties["object.id"]

	 if test then
		-- print("Smart filter " .. node_id .. " added")
		-- TODO: Set metadata as needed for filter nodes set in runtime
	end
  end
}:register()

SimpleEventHook {
  name = "mic-stream-added",
  interests = {
	 EventInterest {
		Constraint { "event.type", "=", "node-added" },
		Constraint { "media.class", "=", "Stream/Input/Audio" },
		Constraint { "media.category", "=", "Capture" }
	 }
  },
  execute = function(event)
	if mic_tracker_state.stream_count == 0 then
		set_mic_filters_disabled(event, "false")
	end

	mic_tracker_state.stream_count = mic_tracker_state.stream_count + 1
  end
}:register()

SimpleEventHook {
  name = "mic-stream-removed",
  interests = {
	 EventInterest {
		Constraint { "event.type", "=", "node-removed" },
		Constraint { "media.class", "=", "Stream/Input/Audio" },
		Constraint { "media.category", "=", "Capture" }
	 }
  },
  execute = function(event)
	if mic_tracker_state.stream_count == 1 then
		set_mic_filters_disabled(event, "true")
	end

	mic_tracker_state.stream_count = math.max(0, mic_tracker_state.stream_count - 1)
  end
}:register()
