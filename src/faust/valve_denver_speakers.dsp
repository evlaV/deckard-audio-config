declare name "valve_denver_speaker_tuning";
declare description "speaker tuning for the denver product";

valve = library("valve_dsp.lib");

process = _,_ : valve.denver_speaker_tuning(IN_GAIN_DB, IN_HP_FREQ, IN_COMP_STRENGTH, IN_COMP_THRESHOLD, IN_COMP_ATTACK, IN_COMP_RELEASE, IN_COMP_KNEE, IN_COMP_STEREO_LINK, BASS_FREQ, BASS_GAIN_DB) : 
_,_ 
with
{
    IN_GAIN_DB = 7.5;  // 0.0 13.5f;
    IN_COMP_STRENGTH = 0.45; //0.0 0.45; 
    IN_COMP_THRESHOLD = -30.0;
    IN_COMP_ATTACK = 0.001;
    IN_COMP_RELEASE = 0.1;
    IN_COMP_KNEE = 10.0;
    IN_COMP_STEREO_LINK = 1.0;

    IN_HP_FREQ = 20.0;

    BASS_FREQ = 120.0;
    BASS_GAIN_DB = 0.0;

};
