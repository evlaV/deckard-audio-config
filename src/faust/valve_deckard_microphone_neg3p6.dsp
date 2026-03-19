declare name "deckard_mic_tuning";
declare description "";

valve = library("valve_mic_dsp.lib");

process = _, _ :
          valve.mic_tuning(IN_GAIN_DB, HP_FREQ, LP_FREQ, LP0, FP0, Q0, LP1, FP1, Q1, LP2, FP2, Q2, LP3, FP3, Q3, LP4, FP4, Q4, COMP_STRENGTH, COMP_THRESHOLD, COMP_ATTACK, COMP_RELEASE, COMP_KNEE), 
          valve.mic_tuning(IN_GAIN_DB, HP_FREQ, LP_FREQ, LP0, FP0, Q0, LP1, FP1, Q1, LP2, FP2, Q2, LP3, FP3, Q3, LP4, FP4, Q4, COMP_STRENGTH, COMP_THRESHOLD, COMP_ATTACK, COMP_RELEASE, COMP_KNEE) : 
          _, _
with
{
    IN_GAIN_DB = -3.6;

    HP_FREQ = 70.0;
    LP_FREQ = 16500.0;

    LP0 = 5.5;
    FP0 = 90.0;
    Q0 = 1.0;
    LP1 = -3.0;
    FP1 = 5000.0;
    Q1 = 0.7;
    LP2 = 0.7;
    FP2 = 1850.0;
    Q2 = 2.0;
    LP3 = 0.0;
    FP3 = 1500.0;
    Q3 = 1.0;
    LP4 = 0.0;
    FP4 = 100.0;
    Q4 = 1.0;

    COMP_STRENGTH = 0.0;
    COMP_THRESHOLD = -0.1;
    COMP_ATTACK = 0.05;
    COMP_RELEASE = 0.2;
    COMP_KNEE = 0.5;
};
