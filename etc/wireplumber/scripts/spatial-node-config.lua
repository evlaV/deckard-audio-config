log = Log.open_topic ("s-node")

steamaudioloadermodule = LocalModule("vraudioloadermodule", "vraudio.samplerate=48000", nil)

spatializers = {}

loopbackStereo = nil
loopback71 = nil

-- returns true if the current default sink is the built-in speakers
function isDefaultSinkBuiltIn(event)
    local source = event:get_source()
    local metadata_om = source:call("get-object-manager", "metadata")
    local defaults = metadata_om:lookup{ Constraint{ "metadata.name", "=", "default" } }
    local obj = defaults:find(0, "default.audio.sink")
    if not obj then
        return false
    end

    local json = Json.Raw(obj)
    local default_sink_name = json:parse().name

    if string.find(default_sink_name, "alsa_output.platform-sound.HiFi__Speaker__sink", 1, true) ~= nil then
        return true
    else
        return false
    end
end

-- returns true if we should spatialize the node
function shouldSpatialize(node)
    -- only spatialize if the relevant wireplumber setting is enabled
    if not Settings.get_boolean("node.stream.spatial-audio") then
      return false
    end

    -- for now, spatialize every output stream...
    if string.find(node.properties["media.class"], "Audio") and string.find(node.properties["media.class"], "Output") then
        -- ...except nodes that are part of the spatializer filter chains or device filter chains themselves
        if string.find(node.properties["node.name"], "filter") and string.find(node.properties["node.name"], "chain") then
            return false
        elseif string.find(node.properties["node.name"], "virtual") and string.find(node.properties["node.name"], "sink") then
            return false
        elseif string.find(node.properties["node.name"], ".spatialize_filter_chain") then
            return false
        elseif string.find(node.properties["node.name"], "^alsa_loopback_") then
            return false
        elseif string.find(node.properties["node.name"], "pw-audio-namespace", 1, true) then
            return false
        else
            return true
        end
    else
        return false
    end
end

-- returns true if we currently support spatializing audio streams with the given number of channels
function canSpatialize(numChannels)
    if numChannels == 1 or numChannels == 2 or numChannels == 4 or numChannels == 6 or numChannels == 8 then
        return true
    else
        return false
    end
end

-- builds the string that contains the ladspa plugin name to use for a given channel count
function getLADSPAPluginName(numChannels)
    if numChannels == 2 then
        return "spatialize_stereo"
    elseif numChannels == 4 then
        return "spatialize_quad"
    elseif numChannels == 6 then
        return "spatialize_51"
    elseif numChannels == 8 then
        return "spatialize_71"
    else
        return ""
    end
end

-- builds the string that describes the input channel map for a given channel count
function getChannelPositions(numChannels)
    if numChannels == 2 then
        return "[ FL FR ]"
    elseif numChannels == 4 then
        return "[ FL FR RL RR ]"
    elseif numChannels == 6 then
        return "[ FL FR FC LFE RL RR ]"
    elseif numChannels == 8 then
        return "[ FL FR FC LFE RL RR SL SR ]"
    else
        return ""
    end
end

-- builds the string that should be set as the "args" parameter when instantiating the spatializer filter
-- chain for the given node
function getSpatializerArgs(node)
    local args
    local pid
    local numChannels

    -- figure out the pid from the node's properties
    pid = 0
    if node.properties["application.process.id"] ~= nil then
        pid = tonumber(node.properties["application.process.id"])
        -- log:warning(pid .. " : " .. tostring(node.properties["application.process.binary"]) .. " : " .. tostring(node.properties["application.name"]))
    end

    -- todo: what is the "correct" way to get at the channel format requested by the stream?
    numChannels = 2
    for pod in node:iterate_params("EnumFormat") do
        local pod_parsed = pod:parse()
        if pod_parsed ~= nil then
            numChannels = tonumber(pod_parsed.properties.channels)
            break
        end
    end

    local cutoff_frequency = 80
    local q = 0.707

    local nodes = Json.Array{}

    if numChannels == 6 or numChannels == 8 then
        nodes = nodes:merge(Json.Array{
            Json.Object{ type = "builtin", name = "copy_fl", label = "copy" },
            Json.Object{ type = "builtin", name = "copy_fr", label = "copy" },
            Json.Object{ type = "builtin", name = "copy_fc", label = "copy" },
            Json.Object{ type = "builtin", name = "copy_lfe", label = "copy" },
            Json.Object{ type = "builtin", name = "copy_rl", label = "copy" },
            Json.Object{ type = "builtin", name = "copy_rr", label = "copy" }
        })
        if numChannels == 8 then
            nodes = nodes:merge(Json.Array{
                Json.Object{ type = "builtin", name = "copy_sl", label = "copy" },
                Json.Object{ type = "builtin", name = "copy_sr", label = "copy" }
            })
        end

        nodes = nodes:merge(Json.Array{
            Json.Object{
                type = "builtin",
                name = "lowpass",
                label = "param_eq",
                config = Json.Object{
                    filters = Json.Array{
                        Json.Object{ type = "bq_lowpass", freq = cutoff_frequency, q = q },
                        Json.Object{ type = "bq_lowpass", freq = cutoff_frequency, q = q }
                    }
                }
            },
            Json.Object{
                type = "builtin",
                name = "highpass",
                label = "param_eq",
                config = Json.Object{
                    filters = Json.Array{
                        Json.Object{ type = "bq_highpass", freq = cutoff_frequency, q = q },
                        Json.Object{ type = "bq_highpass", freq = cutoff_frequency, q = q }
                    }
                }
            },
            Json.Object{ type = "builtin", name = "mixer_lfe", label = "mixer" },
            Json.Object{ type = "builtin", name = "mixer_fl", label = "mixer" },
            Json.Object{ type = "builtin", name = "mixer_fr", label = "mixer" }
        })
    end

    nodes = nodes:merge(Json.Array{Json.Object{
        type = "ladspa",
        name = "spatialize",
        plugin = "/usr/lib/ladspa/vraudiocompositor.so",
        label = getLADSPAPluginName(numChannels),
        control = Json.Object{
            ["PID"] = pid
        }
    }})

    local links = Json.Array{}

    if numChannels == 6 or numChannels == 8 then
        links = links:merge(Json.Array{
            Json.Object{ output = "copy_fl:Out", input = "lowpass:In 1" },
            Json.Object{ output = "copy_fr:Out", input = "lowpass:In 2" },
            Json.Object{ output = "copy_fc:Out", input = "lowpass:In 3" },
            Json.Object{ output = "copy_lfe:Out", input = "lowpass:In 4" },
            Json.Object{ output = "copy_rl:Out", input = "lowpass:In 5" },
            Json.Object{ output = "copy_rr:Out", input = "lowpass:In 6" },

            Json.Object{ output = "copy_fl:Out", input = "highpass:In 1" },
            Json.Object{ output = "copy_fr:Out", input = "highpass:In 2" },
            Json.Object{ output = "copy_fc:Out", input = "highpass:In 3" },
            Json.Object{ output = "copy_lfe:Out", input = "highpass:In 4" },
            Json.Object{ output = "copy_rl:Out", input = "highpass:In 5" },
            Json.Object{ output = "copy_rr:Out", input = "highpass:In 6" },

            Json.Object{ output = "lowpass:Out 1", input = "mixer_lfe:In 1" },
            Json.Object{ output = "lowpass:Out 2", input = "mixer_lfe:In 2" },
            Json.Object{ output = "lowpass:Out 3", input = "mixer_lfe:In 3" },
            Json.Object{ output = "lowpass:Out 4", input = "mixer_lfe:In 4" },
            Json.Object{ output = "lowpass:Out 5", input = "mixer_lfe:In 5" },
            Json.Object{ output = "lowpass:Out 6", input = "mixer_lfe:In 6" },

            Json.Object{ output = "highpass:Out 1", input = "mixer_fl:In 1" },
            Json.Object{ output = "highpass:Out 4", input = "mixer_fl:In 2" },

            Json.Object{ output = "highpass:Out 2", input = "mixer_fr:In 1" },
            Json.Object{ output = "highpass:Out 4", input = "mixer_fr:In 2" },

            Json.Object{ output = "mixer_fl:Out", input = "spatialize:In_FL" },
            Json.Object{ output = "mixer_fr:Out", input = "spatialize:In_FR" },
            Json.Object{ output = "highpass:Out 3", input = "spatialize:In_FC" },
            Json.Object{ output = "mixer_lfe:Out", input = "spatialize:In_LFE" },
            Json.Object{ output = "highpass:Out 5", input = "spatialize:In_RL" },
            Json.Object{ output = "highpass:Out 6", input = "spatialize:In_RR" }
        })
        if numChannels == 8 then
            links = links:merge(Json.Array{
                Json.Object{ output = "copy_sl:Out", input = "lowpass:In 7" },
                Json.Object{ output = "copy_sr:Out", input = "lowpass:In 8" },

                Json.Object{ output = "copy_sl:Out", input = "highpass:In 7" },
                Json.Object{ output = "copy_sr:Out", input = "highpass:In 8" },

                Json.Object{ output = "lowpass:Out 7", input = "mixer_lfe:In 7" },
                Json.Object{ output = "lowpass:Out 8", input = "mixer_lfe:In 8" },

                Json.Object{ output = "highpass:Out 7", input = "spatialize:In_SL" },
                Json.Object{ output = "highpass:Out 8", input = "spatialize:In_SR" }
            })
        end
    end

    local inputs = {}

    if numChannels == 6 or numChannels == 8 then
        inputs = Json.Array{ "copy_fl:In", "copy_fr:In", "copy_fc:In", "copy_lfe:In", "copy_rl:In", "copy_rr:In" }
        if numChannels == 8 then
            inputs = inputs:merge(Json.Array{"copy_sl:In", "copy_sr:In"})
        end
    else
        inputs = Json.Array{ "spatialize:In_FL", "spatialize:In_FR" }
        if numChannels == 4 then
            inputs = inputs:merge(Json.Array{"spatialize:In_RL", "spatialize:In_RR"})
        end
    end

    local captureAudioPosition = Json.Array{"FL", "FR"}
    if numChannels == 6 or numChannels == 8 then
        captureAudioPosition = captureAudioPosition:merge(Json.Array{"FC", "LFE", "RL", "RR"})
        if numChannels == 8 then
            captureAudioPosition = captureAudioPosition:merge(Json.Array{"SL", "SR"})
        end
    elseif numChannels == 4 then
        captureAudioPosition = captureAudioPosition:merge(Json.Array{"RL", "RR"})
    end

    local args = {
        ["node.description"] = node.properties["node.name"] .. ".spatialize_filter_chain",
        ["media.name"] = node.properties["node.name"] .. ".spatialize_filter_chain",
        ["filter.graph"] = Json.Object{
            ["nodes"] = nodes,
            ["links"] = links,
            ["inputs"] = inputs,
            ["outputs"] = Json.Array{ "spatialize:Out_FL", "spatialize:Out_FR" }
        },
        ["capture.props"] = Json.Object{
            ["node.name"] = node.properties["node.name"] .. ".spatialize_filter_chain.capture",
            ["media.class"] = "Audio/Sink",
            ["audio.channels"] = numChannels,
            ["audio.position"] = captureAudioPosition,
            ["spatialize.node"] = node.id
        },
        ["playback.props"] = Json.Object{
            ["node.name"] = node.properties["node.name"] .. ".spatialize_filter_chain.playback",
            ["node.passive"] = true,
            ["audio.channels"] = 2,
            ["audio.position"] = Json.Array{"FL", "FR"}
        }
    }

    return Json.Object(args):get_data()
end


-- helper function for adding a session item for a spatialized output stream node
function addSpatializedItem(node, id)
    local spatializer
    local args

    -- create the filter chain
    args = getSpatializerArgs(node)
    spatializer = LocalModule("libpipewire-module-filter-chain", args)
    if spatializer == nil then
        log:warning("failed to create spatializer filter chain for node: " .. node.properties["node.name"])
        return
    end

    -- keep track of the filter chain, so we can destroy it when the stream node is destroyed
    spatializers[node.id] = spatializer
end

SimpleEventHook {
  name = "spatial-node/create-item",
  before = "node/create-item",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "media.class", "#", "Stream/*", type = "pw-global" },
    },
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "media.class", "#", "Video/*", type = "pw-global" },
    },
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "media.class", "#", "Audio/*", type = "pw-global" },
      Constraint { "wireplumber.is-virtual", "-", type = "pw" },
    },
  },
   execute = function (event)
     local node = event:get_subject ()
     local id = node.id

     -- if we should spatialize this node, create the filter chain
     if isDefaultSinkBuiltIn(event) and shouldSpatialize(node) then
         addSpatializedItem(node, id)
         local extra_si_properties = {
           ["target.object"] = node.properties["node.name"] .. ".spatialize_filter_chain.capture",
           ["node.dont-fallback"] = true,
           ["node.linger"] = true
         }
         event:set_data ("extra-si-properties", extra_si_properties)
     end
   end
}:register ()

SimpleEventHook {
  name = "spatial-node/destroy-item",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-removed" },
      Constraint { "media.class", "#", "Stream/*", type = "pw-global" },
    },
    EventInterest {
      Constraint { "event.type", "=", "node-removed" },
      Constraint { "media.class", "#", "Video/*", type = "pw-global" },
    },
    EventInterest {
      Constraint { "event.type", "=", "node-removed" },
      Constraint { "media.class", "#", "Audio/*", type = "pw-global" },
      Constraint { "wireplumber.is-virtual", "-", type = "pw" },
    },
  },
  execute = function (event)
    local node = event:get_subject ()
    if spatializers[node.id] then
        spatializers[node.id] = nil
    end
  end
}:register ()

function getLoopbackStereoArgs(device_id, cpd)
    args =
        "{ " ..
            "node.name = alsa_loopback_stereo " ..
            "capture.props = { " ..
                "node.name = alsa_loopback_stereo.capture " ..
                "media.class = Audio/Sink " ..
                "audio.channels = 2 " ..
                "audio.position = [ FL FR ] " ..
                "priority.session = 1000 " ..
                "alsa.loopback = true " ..
                "device.id = " .. device_id .. " " ..
                "card.profile.device = " .. cpd .. " " ..
            "} " ..
            "playback.props = { " ..
                "node.name = alsa_loopback_stereo.playback " ..
                "node.passive = true " ..
                "audio.channels = 2 " ..
                "audio.position = [ FL FR ] " ..
                "node.target = \"filter-chain-sink\" " ..
                "alsa.loopback = true " ..
            "} " ..
        "}"

    return args
end

function getLoopback71Args(device_id, cpd)
    args =
        "{ " ..
            "node.name = alsa_loopback_71 " ..
            "capture.props = { " ..
                "node.name = alsa_loopback_71.capture " ..
                "media.class = Audio/Sink " ..
                "audio.channels = 8 " ..
                "audio.position = [ FL FR FC LFE RL RR SL SR ] " ..
                "priority.session = 1000 " ..
                "alsa.loopback = true " ..
                "device.id = " .. device_id .. " " ..
                "card.profile.device = " .. cpd .. " " ..
            "} " ..
            "playback.props = { " ..
                "node.name = alsa_loopback_71.playback " ..
                "node.passive = true " ..
                "audio.channels = 2 " ..
                "audio.position = [ FL FR ] " ..
                "node.target = \"filter-chain-sink\" " ..
                "alsa.loopback = true " ..
            "} " ..
        "}"

    return args
end

function createLoopback(node, isSurround)
    local name = node.properties ["node.name"]
    local desc = node.properties ["node.description"]
    local device_media_class = node.properties ["media.class"]
    local dev_id = node.properties ["device.id"]
    local channels = node.properties ["audio.channels"]
    local position = node.properties ["audio.position"]
    local pri_driver = node.properties ["priority.driver"]
    local pri_session = node.properties ["priority.session"]
    local cpd = node.properties ["card.profile.device"]
    local stream_media_class = "Stream/Output/Audio"
    local stream_props = nil
    local device_props = nil
    local args = nil

    local prefixed_name = string.format("stereo.%s", name)
    if isSurround then
        prefixed_name = string.format("71.%s", name)
    end

    local device_audio_channels = 2
    if isSurround then
        device_audio_channels = 8
    end

    local device_audio_position = "[FL FR]"
    if isSurround then
        device_audio_position = "[FL FR FC LFE RL RR SL SR]"
    end

    -- Set stream props
    stream_props = Json.Object {
      ["node.name"] = string.format ("alsa_loopback_stream.%s", prefixed_name),
      ["node.description"] =
          string.format ("ALSA internal stream for %s", desc),
      ["media.class"] = stream_media_class,
      ["audio.channels"] = channels,
      ["audio.position"] = position,
      ["alsa.loopback"] = true,
      ["stream.dont-remix"] = true,
      ["node.passive"] = true,
      ["node.dont-fallback"] = true,
      ["node.linger"] = true,
      ["target.object"] = name
    }

    -- Set device props
    device_props = Json.Object {
      ["node.name"] = string.format ("alsa_loopback_device.%s", prefixed_name),
      ["node.description"] = desc,
      ["media.class"] = device_media_class,
      ["audio.channels"] = device_audio_channels,
      ["audio.position"] = device_audio_position,
      ["alsa.loopback"] = true,
      ["device.id"] = dev_id,
      ["card.profile.device"] = cpd,
      ["priority.driver"] = tonumber(pri_driver) + 1,
      ["priority.session"] = tonumber(pri_session) + 1
    }

    args = Json.Object {
      ["playback.props"] = stream_props,
      ["capture.props"] = device_props
    }

    -- Load loopback
    return LocalModule("libpipewire-module-loopback", args:get_data(), {})
end

SimpleEventHook {
    name = "spatial-node/setup-71-loopback",
    interests = {
        EventInterest {
            Constraint { "event.type", "=", "rescan-for-default-nodes" }
        },
        EventInterest {
            Constraint { "event.type", "=", "metadata-changed" },
            Constraint { "metadata.name", "=", "sm-settings" },
            Constraint { "event.subject.key", "c", "node.stream.spatial-audio", "node.stream.spatial-audio-surround" }
        }
    },
    execute = function (event)
        local source = event:get_source()
        local metadata_om = source:call("get-object-manager", "metadata")
        local settings = metadata_om:lookup{ Constraint{ "metadata.name", "=", "sm-settings" } }

        -- find the actual built-in audio node, and get its device.id
        local node_om = source:call("get-object-manager", "node")
        local node = node_om:lookup{ Constraint{ "node.name", "=", "alsa_output.platform-sound.HiFi__Speaker__sink" } }
        if not node then
            return
        end

        if settings:find(0, "node.stream.spatial-audio") == "true" and settings:find(0, "node.stream.spatial-audio-surround") == "true" then
            if loopbackStereo then
                loopbackStereo = nil
            end
            if not loopback71 then
                loopback71 = createLoopback(node, true)
            end
        else
            if loopback71 then
                loopback71 = nil
            end
            if not loopbackStereo then
                loopbackStereo = createLoopback(node, false)
            end
        end
    end
}:register()
