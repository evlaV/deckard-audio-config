declare name "Valve Denver Speakers";
declare description "Speaker tuning for the Denver product.";

valve = library("valve_dsp.lib");

process = _,_ : valve.denver_speaker_tuning(IN_GAIN_DB, IN_COMP_STRENGTH, IN_COMP_THRESHOLD, IN_COMP_ATTACK, IN_COMP_RELEASE, IN_COMP_KNEE, IN_COMP_STEREO_LINK,
                                     lowPsych_f1_order, lowPsych_f2_freq, lowPsych_linGain, BASS_FREQ, BASS_GAIN_DB) : 

          _,_ 
with
{
    IN_GAIN_DB = 0.0f;  // 0.0 10.5f;
    IN_COMP_STRENGTH = 0.0; //0.0 0.45; 
    IN_COMP_THRESHOLD = -40.0;
    IN_COMP_ATTACK = 0.001;
    IN_COMP_RELEASE = 0.1;
    IN_COMP_KNEE = 10.0;
    IN_COMP_STEREO_LINK = 1.0;

    lowPsych_f1_order = 2;
    lowPsych_f2_freq = 100.0;
    lowPsych_linGain = 1.0; // 0.63 1.0

    BASS_FREQ = 150.0;
    BASS_GAIN_DB = 4.0;

};
