#!/usr/bin/env bash

echo "Waiting until pw-metadata lists the default audio sink..."
until [[ ! -z $(pw-metadata 0 'default.audio.sink' | grep 'value' | sed "s/.* value:'//;s/' type:.*$//;" | jq .name) ]]
do
    echo "Sleeping until pw-metadata gives us something..."
    sleep 2
done

if [[ ! -f "home/steamos/.local/state/wireplumber/default_volume" ]]; then
    echo "Setting default volumes and writing sentinel file."
    wpctl set-volume @DEFAULT_AUDIO_SINK@ 0.60 || true
    wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 1.0 || true
    date > /home/steamos/.local/state/wireplumber/default_volume
else
    echo "Found sentinel file at /home/steamos/.local/state/wireplumber/default_volume. Not modifying default volumes."
fi

# Always run the pipewire graph at 10ms quant
pw-metadata -n settings 0 clock.force-quantum 480

wpctl status || true

