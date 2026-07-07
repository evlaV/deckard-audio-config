#!/usr/bin/env bash

fixup_temperature() {
  #
  # The temperature value from the EEPROM is divided by 10.
  #
  echo "[audiosetup] dividing temperature from EEPROM by 10"
  temp_deci_c=$(( temp_deci_c / 10 ))
}

fixup_resistance() {
  #
  # vendor OW: If resistance  is not between 420 and 664, then set to the default value of 553.
  # vendor FG: If resistance  is not between 420 and 664, then set to the default value of 538.
  #
  if [ "$resistance" -lt 420 ] || [ "$resistance" -gt 664 ]; then
    if [[ "$module_vendor" == "Forgrand" ]]; then
      resistance=538
      echo "[audiosetup] updating resistance to $resistance"
    elif [[ "$module_vendor" == "Olewolff" ]]; then
      resistance=553
      echo "[audiosetup] updating resistance to $resistance"
    fi
  fi
}

error_exit() {
  echo "[audiosetup] ERROR exit, disabling audio playback!"
  amixer -c$SOUNDCARD sset 'Speaker Left Digital' 0
  amixer -c$SOUNDCARD sset 'Speaker Right Digital' 0
  exit 1
}

SCRIPT=$(realpath ${BASH_SOURCE})
export SCRIPT_PATH=$(dirname $SCRIPT)

SOUNDCARDSTR=$(aplay -l | grep SM8250 | cut -c 6-6 | head -n 1)
if [ -z "$SOUNDCARDSTR" ]; then
  export SOUNDCARD=0
  echo "[audiosetup] soundcard not found"
  error_exit
else
   export SOUNDCARD=$SOUNDCARDSTR
fi

EEPROM_CONSOLE=/usr/lib/deckard-eeprom/eeprom_console

# Read the audio module vendor from EEPROM.
dsm_bin=""
Digital=0
module_vendor=$( $EEPROM_CONSOLE get audio_module_vendor 2>/dev/null )
module_ret_code=$?
if [ $module_ret_code -eq 0 ]; then
  echo "[audiosetup] audio_module_vendor is $module_vendor"
  if [[ "$module_vendor" == "Forgrand" ]]; then
      dsm_bin="dsm_param_FG_2018b.bin"
      Digital=127
  elif [[ "$module_vendor" == "Olewolff" ]]; then
      dsm_bin="dsm_param_OW_2018b.bin"
      Digital=127
  elif [[ "${module_vendor,,}" == "ggec" ]]; then
    dsm_bin="dsm_param_GG.bin"
    Digital=112
  else
    echo "[audiosetup] unsupported module vendor"
    error_exit
  fi
else
  echo "[audiosetup] module vendor not set in eeprom"
  error_exit
fi

# Link filter chain files.
rm -f /etc/pipewire/pipewire.conf.d/microphone-filter-chain*
ln -s "/etc/pipewire/microphone-filter-chain/microphone-filter-chain-echo-cancel.conf" /etc/pipewire/pipewire.conf.d/microphone-filter-chain-echo-cancel.conf
rm -f /etc/pipewire/pipewire.conf.d/filter-chain*
# Choose speaker filter chain based on audio module vendor.
if [[ "${module_vendor,,}" == "ggec" ]]; then
  echo "[audiosetup] linking Boulder filter chain"
  ln -s "/etc/pipewire/filter-chains/filter-chain-boulder.conf" /etc/pipewire/pipewire.conf.d/filter-chain.conf
else
  echo "[audiosetup] linking Denver filter chain"
  ln -s "/etc/pipewire/filter-chains/filter-chain-denver.conf" /etc/pipewire/pipewire.conf.d/filter-chain.conf
fi

echo "[audiosetup] loading dsm param file $dsm_bin"

# Load DSM param bin file to amps.
if [ -e "/usr/lib/firmware/$dsm_bin" ]; then
  MAX98390DEVICES=$(find /sys/devices -name "max98390")

  for i in $MAX98390DEVICES; do
      echo -n "$dsm_bin" > "$i"/firmware
      echo -n "load" > "$i"/load
  done
else
  echo "[audiosetup] dsm param file /usr/lib/firmware/$dsm_bin not found"
  error_exit
fi

# amixer configuration for lpass with MAX98390 I2S smart amps.

# Load DSM settings for left audio amp from EEPROM.
temp_deci_c=$( $EEPROM_CONSOLE get left_audio_temp 2>/dev/null )
temp_ret_code=$?
if [ $temp_ret_code -eq 0 ]; then
  fixup_temperature
  printf "[audiosetup] left eeprom temp after fixup: %d\n" $temp_deci_c
else
  echo "[audiosetup] left_audio_temp not set in eeprom"
  error_exit
fi
resistance=$( $EEPROM_CONSOLE get left_audio_resistance 2>/dev/null )
resist_ret_code=$?
if [ $resist_ret_code -eq 0 ]; then
  fixup_resistance
  printf "[audiosetup] left eeprom resistance after fixup: %d\n" $resistance
else
  echo "[audiosetup] left_audio_resistance not set in eeprom"
  error_exit
fi

if [[ "${module_vendor,,}" == "ggec" ]]; then
  echo "[audiosetup] using hard-coded Left RDC Protection, 5.8 Ohms for GGEC"
  temp_reg=1024
  admittance=$(( 268435456 / 406 ))
else
  # Valid Left Channel Calibration
  # Convert Temperature in deciC to Register
  temp_reg=$(( (temp_deci_c * 1000 + 122) / 244 ))
  admittance=$(( 268435456 / resistance ))
  rdc_integer=$(( resistance * 937  / 65536 ))
  rdc_factor=$(( ((resistance * 937 * 100) / 65536) - (rdc_integer * 100) ))
  printf "[audiosetup] Left Resistance: %d.%02d ohm\n" $rdc_integer $rdc_factor
fi
amixer -c$SOUNDCARD sset 'Speaker Left DSM Ambient Temp' $temp_reg
amixer -c$SOUNDCARD sset 'Speaker Left DSM Rdc' $admittance

amixer -c$SOUNDCARD sset 'Speaker Left Digital' $Digital

# Load DSM settings for right audio amp from EEPROM.
temp_deci_c=$( $EEPROM_CONSOLE get right_audio_temp 2>/dev/null )
temp_ret_code=$?
if [ $temp_ret_code -eq 0 ]; then
  fixup_temperature
  printf "[audiosetup] right eeprom temp after fixup: %d\n" $temp_deci_c
else
  echo "[audiosetup] right_audio_temp not set in eeprom"
  error_exit
fi
resistance=$( $EEPROM_CONSOLE get right_audio_resistance 2>/dev/null )
resist_ret_code=$?
if [ $resist_ret_code -eq 0 ]; then
  fixup_resistance
  printf "[audiosetup] right eeprom resistance after fixup: %d\n" $resistance
else
  echo "[audiosetup] right_audio_resistance not set in eeprom"
  error_exit
fi

if [[ "${module_vendor,,}" == "ggec" ]]; then
  echo "[audiosetup] using hard-coded Right RDC Protection, 5.8 Ohms for GGEC"
  temp_reg=1024
  admittance=$(( 268435456 / 406 ))
else
  # Valid Left Channel Calibration
  # Convert Temperature in deciC to Register
  temp_reg=$(( (temp_deci_c * 1000 + 122) / 244 ))
  admittance=$(( 268435456 / resistance ))
  rdc_integer=$(( resistance * 937  / 65536 ))
  rdc_factor=$(( ((resistance * 937 * 100) / 65536) - (rdc_integer * 100) ))
  printf "[audiosetup] Right Resistance: %d.%02d ohm\n" $rdc_integer $rdc_factor
fi
amixer -c$SOUNDCARD sset 'Speaker Right DSM Ambient Temp' $temp_reg
amixer -c$SOUNDCARD sset 'Speaker Right DSM Rdc' $admittance

amixer -c$SOUNDCARD sset 'Speaker Right Digital' $Digital

# Remaining mixer settings are sent by UCM. See /usr/share/alsa/ucm2/codecs/sm8250-lpass/
