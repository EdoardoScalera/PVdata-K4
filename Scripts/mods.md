modify shelly_load_control_scenario. 

Goals
Prevent the battery voltage from repeatedly crossing the inverter’s hard disconnect threshold (48 V).
Avoid rapid Wi‑Fi reconnect cycles on the Shelly smart strip that trigger safety mode and require factory reset.
Proactively shed load before the battery gets too low, then restore it only when the system is clearly in a safe, stable state.
Keep the logic compatible with your existing shelly_load_control_scenario system.
Constraints / known values
Inverter behavior (from your description):
Load disconnect when battery < 48.0 V.
Load reconnect (and Shelly back online) when battery ≥ 50.5 V (48 V + 2.5 V hysteresis).
New control thresholds:
Operative (load‑off) threshold: 49.0 V.
Safe operation (load‑on) threshold: 50.5 V.

Filtering:
Moving average over the last 5 voltage readings.

Additional refinement:
Require conditions to hold for N consecutive readings (e.g., 2–3) before changing state, to reduce chatter.


Currently the system is working as follow:
when the battery is charged and above a threshold (48V) the inverter is supplied with power and can turn on the LED. The shelly_load_control_scenario then control and manages the different scenario based on the user interests. This system has a flaw: when the battery charge is lower than the threshold and the inverter disconnect the load, the shelly smart strip disconnects from wifi, and the load cannot be controlled anymore.
The inverter will bring the smart strip online (reconnect to wifi) only when the battery reaches 50.5V (threshold 48V + hysteresis 2.5V), but it happened that the battery is discharged/charged so fast in a loop that the strip will continously try to ocnnect to wifi and if it does that too many times, then it enters the safety mode and won't be able to connect to wifi anymore, necessitating a factory reset. 
To avoid this occurrence, the script must ensure that the battery is always above the disconnection threshold 48V (safety threshold), and if the battery is discharging and approaching the threshold, it must turn off the load. 
Introduce a second threshold level (load-off or operative threshold) at 49V
To do so implement a moving average over the last 5 reading of battery voltage. If the voltage is dropping approaching the operative threshold then turn off the load connected to the socket. This will allow the battery to recharge. The load will be turned back on,respecting the selected scenario, when the battery voltage is again in the "safe operation range", above 50.5V. The load will be turned on by monitoring that the moving average is increasing and moving upwards to the 50.5V level.



Voltage (V)
  |
  |     (battery charging)  _________  (battery discharging)
  |                        /         \
  |                       /           \
50.5|--------------------/-------------\------------------  Reconnect / safe operation threshold
  |                     /               \
  |                    /                 \
49.0|-----------------/-------------------\--------------  Operative (load-off) threshold
  |                  /                     \
  |                 /                       \
48.0|--------------/-------------------------\-----------  Inverter hard disconnect (safety) threshold
  |               /                           \
  |______________/                             \_______
  |
  +----------------------------------------------------> time

Typical sequence:

1) Battery charging:
   - Voltage rises, moving average crosses 50.5 V while rising.
   - Controller allows load ON (scenario-based control via Shelly).

2) Load draws power, battery starts discharging:
   - Voltage slowly falls.
   - When moving average ≤ 49.0 V and falling:
       → Controller turns load OFF.
       → Battery can recover/charge without load.

3) Battery recharges:
   - Voltage rises again.
   - Only when moving average ≥ 50.5 V and clearly rising:
       → Controller allows load ON again.

V_DISCONNECT_HARD      = 48.0   # V – inverter hard disconnect (safety)
V_OPERATIVE_LOW        = 49.0   # V – load-off threshold (soft)
V_SAFE_HIGH            = 50.5   # V – load-on threshold (recovery)

N_WINDOW               = 5      # samples for moving average
N_CONFIRM_LOW_FALLING  = 2      # consecutive readings to confirm load-off
N_CONFIRM_HIGH_RISING  = 2      # consecutive readings to confirm load-on

DV_DEADBAND            = 0.05   # V – deadband for "rising/falling" detection

This keeps the system operating in the “safe band” between ~49–50.5+ V,
never letting it repeatedly hit the 48 V hard disconnect.


Inputs

V_raw: latest battery voltage reading (from your logger / BMS / inverter).

t_now: timestamp of the reading.

Optional: I_batt, P_batt, or SOC if available (for diagnostics, not strictly required for control).

Derived signals

V_avg: moving average of the last 5 V_raw samples.

dV: simple trend indicator:

dV > 0 → voltage rising (e.g., V_avg higher than previous V_avg_prev).

dV < 0 → voltage falling.

Can also use a small deadband around 0 to avoid noise (e.g., |dV| < 0.05 V → “flat”).

Internal state

control_state: one of:

SAFE_HIGH – battery clearly in safe, high region; load allowed.

SAFE_LOW – battery approaching low region; load forced off.

HOLD_OFF – intermediate region; keep load off until clearly safe again.

load_allowed_by_controller: boolean output to your scenario logic.

Counters for confirmation:

count_low_falling: how many consecutive readings satisfy “low & falling” condition.

count_high_rising: how many consecutive readings satisfy “high & rising” condition.


