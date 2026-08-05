declare name "valve_boulder_speaker_tuning";
declare description "speaker tuning for the boulder product";

valve = library("valve_dsp.lib");

process = _,_ : valve.boulder_speaker_tuning(IN_GAINM_DB,BASSM_FREQ, BASSM_GAIN_DB) : 
_,_ 
with
{
    IN_GAINM_DB = 0.0;  // -2.0
    BASSM_FREQ = 120.0;  
    BASSM_GAIN_DB = -12.0;
};
