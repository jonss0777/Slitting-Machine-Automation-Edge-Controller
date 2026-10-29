  VAR_GLOBAL
    State : INT AT %MW0 := 1;
    AutoStep : INT AT %MW1 := 0;
    i_SystemReset : BOOL AT %IX0.0;
    i_SafetiesOK : BOOL AT %IX0.1;
    i_StartCycle : BOOL AT %IX0.2;
    i_JamDetected : BOOL AT %IX0.3;
    i_EStopPressed : BOOL AT %IX0.4;
    i_ManualMode : BOOL AT %IX0.5;
    i_TwoHandPB1 : BOOL AT %IX0.6;
    i_TwoHandPB2 : BOOL AT %IX0.7;
    q_FaultLight : BOOL AT %QX0.0;
    q_Offload : BOOL AT %QX0.1;
    q_Conveyor : BOOL AT %QX0.2;
    q_Pneumatics : BOOL AT %QX0.3;
    q_Slitting : BOOL AT %QX0.4;
    di_SuccessfulRunCount : DINT AT %MD2 := 0;
    di_FailedRunCount : DINT AT %MD4 := 0;
    i_HmiCounterReset : BOOL AT %MX0.0;
    b_WasRunning : BOOL;
  END_VAR
  VAR
    ton_Reset : TON;
    ton_Safeties : TON;
    ton_Start : TON;
    ton_Jam : TON;
    ton_EStop : TON;
    ton_Manual : TON;
    ton_PB1 : TON;
    ton_PB2 : TON;
    b_Reset : BOOL;
    b_SafetiesOK : BOOL;
    b_StartCycle : BOOL;
    b_JamDetected : BOOL;
    b_EStopPressed : BOOL;
    b_ManualMode : BOOL;
    b_PB1 : BOOL;
    b_PB2 : BOOL;
    ton_StepTimer : TON;
  END_VAR

// -----------------------------------------------------------------------------
// 1. INPUT DEBOUNCING (50ms TON Timers for mechanical switch bounce)
// -----------------------------------------------------------------------------
ton_Reset(IN := i_SystemReset, PT := T#50ms, Q => b_Reset);
ton_Safeties(IN := i_SafetiesOK, PT := T#50ms, Q => b_SafetiesOK);
ton_Start(IN := i_StartCycle, PT := T#50ms, Q => b_StartCycle);
ton_Jam(IN := i_JamDetected, PT := T#50ms, Q => b_JamDetected);
ton_EStop(IN := i_EStopPressed, PT := T#50ms, Q => b_EStopPressed);
ton_Manual(IN := i_ManualMode, PT := T#50ms, Q => b_ManualMode);
ton_PB1(IN := i_TwoHandPB1, PT := T#50ms, Q => b_PB1);
ton_PB2(IN := i_TwoHandPB2, PT := T#50ms, Q => b_PB2);

// -----------------------------------------------------------------------------
// 2. GLOBAL FAULT OVERRIDES & FAILED RUN TRACKING
// -----------------------------------------------------------------------------
// Set a helper flag if the machine is actively inside an Auto Run step
b_WasRunning := (State = 3) AND (AutoStep > 0);

IF b_EStopPressed THEN
    // If we are forcing an E-Stop and a cycle was actively running, count it as a failure
    IF (State <> 5) AND b_WasRunning THEN
        di_FailedRunCount := di_FailedRunCount + 1;
    END_IF;
    State := 5; // Direct trip to E-STOP / FAULT

ELSIF b_JamDetected AND (State = 3) THEN
    // If a Jam trips the Auto Run sequence, count it as a failure
    IF State <> 4 THEN
        di_FailedRunCount := di_FailedRunCount + 1;
    END_IF;
    State := 4; // Jam Recovery triggered during AUTO RUN
END_IF;

// -----------------------------------------------------------------------------
// 3. MAIN STATE MACHINE
// -----------------------------------------------------------------------------
CASE State OF

    1: // STOPPED STATE
        AutoStep := 0;
        IF b_SafetiesOK THEN
            State := 2; // Transition to READY
        END_IF;
        

    2: // READY STATE
        AutoStep := 0;
        IF b_StartCycle THEN
            State := 3; // Transition to AUTO RUN
            AutoStep := 1; // Start Step A
        ELSIF b_ManualMode THEN
            State := 6; // Transition to MANUAL / JOG
        END_IF;

    3: // AUTO RUN STATE (Sequential Steps A -> B -> C -> D with 3s Delays)
        CASE AutoStep OF
            1: // Step A: AGV Delivery & Robot Arm Load
                ton_StepTimer(IN := TRUE, PT := T#3S);
                IF ton_StepTimer.Q THEN
                    ton_StepTimer(IN := FALSE, PT := T#3S); // Reset Timer
                    AutoStep := 2; // Move to Step B
                END_IF;

            2: // Step B: Conveyor Feed & Alignment
                ton_StepTimer(IN := TRUE, PT := T#3S);
                IF ton_StepTimer.Q THEN
                    ton_StepTimer(IN := FALSE, PT := T#3S); // Reset Timer
                    AutoStep := 3; // Move to Step C
                END_IF;

            3: // Step C: Pneumatic Down-Clamp & Arbor Slitting
                ton_StepTimer(IN := TRUE, PT := T#3S);
                IF ton_StepTimer.Q THEN
                    ton_StepTimer(IN := FALSE, PT := T#3S); // Reset Timer
                    AutoStep := 4; // Move to Step D
                END_IF;

            4: // Step D: Exit Sensing & Stacking Offload
                ton_StepTimer(IN := TRUE, PT := T#3S);
                IF ton_StepTimer.Q THEN
                    ton_StepTimer(IN := FALSE, PT := T#3S); // Reset Timer
                    
                    // --- SUCCESSFUL RUN COUNTER INCREMENT ---
                    di_SuccessfulRunCount := di_SuccessfulRunCount + 1;
                    
                    State := 2; // Sequence Complete -> Return to READY
                END_IF;
        END_CASE;

    4: // JAM RECOVERY STATE
        AutoStep := 0;
        IF b_Reset THEN
            State := 1;
        END_IF;

    5: // E-STOP / FAULT STATE
        AutoStep := 0;
        IF b_Reset THEN
            State := 1; // Return to STOPPED
        END_IF;

    6: // MANUAL / JOG STATE
        AutoStep := 0;
       // Transition out of Manual Mode using Reset or turning off Manual Mode
        IF b_Reset THEN
            State := 1; // Return to STOPPED
        END_IF;
    ELSE
        (* Force invalid/uninitialized state 0 back to STOPPED *)
        State := 1;
        AutoStep := 0;

END_CASE;

// Ensure timer resets if leaving state 3 prematurely
IF State <> 3 THEN
    ton_StepTimer(IN := FALSE, PT := T#3S);
END_IF;

// -----------------------------------------------------------------------------
// 4. OUTPUT MAPPING CONTROL
// -----------------------------------------------------------------------------
// Default outputs to FALSE
q_Offload    := FALSE;
q_Conveyor   := FALSE;
q_Pneumatics := FALSE;
q_Slitting   := FALSE;
q_FaultLight := FALSE;

CASE State OF
    3: // Outputs active sequentially based on AutoStep
        q_Offload    := (AutoStep = 1);
        q_Conveyor   := (AutoStep = 2);
        q_Pneumatics := (AutoStep = 3);
        q_Slitting   := (AutoStep = 4);

    4: // Jam Recovery: Release pneumatics
        q_Pneumatics := FALSE;
        q_FaultLight := TRUE; // Flash/Turn on fault indicator

    5: // E-Stop: Lock out system outputs, activate Fault Light
        q_FaultLight := TRUE;

    6: // Manual Control: Both PB1 and PB2 must be concurrently held
        IF b_PB1 AND b_PB2 THEN
            q_Slitting := TRUE; // Drives Arbor Slitting Machine
        END_IF;
END_CASE;

// -----------------------------------------------------------------------------
// 5. OPERATOR / HMI SHIFT STATISTICS RESET
// -----------------------------------------------------------------------------
IF i_HmiCounterReset THEN
    di_SuccessfulRunCount := 0;
    di_FailedRunCount     := 0;
END_IF;
