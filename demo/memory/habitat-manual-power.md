# Habitat Manual: Power

Ares Base, Habitat Module 1. Revision 5. Covers the solar array, batteries and load shedding.

## Power budget
Solar array: 28 kW peak at local noon in clear sky.
Average daytime output: 16 kW. Night output: 0 kW.
Battery bank: 240 kWh usable.
Average habitat load: 9 kW by day, 6 kW by night.
A full battery bank carries the night load for 40 hours.

## Dust storm procedure
If array output stays under 8 kW at noon for two sols in a row:
1. Shed the lab freezer B and the greenhouse grow lights.
2. Drop cabin heat from 21 C to 18 C.
3. Brush the array panels at first light if wind is under 10 m/s.
4. Log battery state of charge every 4 hours.
5. Report to Mission Control if state of charge falls under 40 percent.

## Load shedding order
Shed loads in this order, first to last:
1. Greenhouse grow lights (2.1 kW)
2. Lab freezer B (0.8 kW)
3. Rover charging (3.0 kW)
4. Water recycler, for at most 12 hours (1.1 kW)
Never shed: CO2 scrubber (0.6 kW), oxygen generation (1.8 kW), comms (0.4 kW).

## Battery limits
Normal state of charge: 40 to 95 percent.
Do not discharge below 20 percent. Cell damage starts at 15 percent.
Battery bay temperature must stay between 5 C and 35 C.
If a cell string reads over 45 C, open breaker B-3 and vent the bay.

## Breaker panel P-1
B-1: life support. B-2: comms. B-3: battery strings. B-4: lab. B-5: greenhouse. B-6: rover dock.
To reset a tripped breaker, switch it fully off, wait 30 seconds, then switch it on.
If the same breaker trips twice in one sol, leave it off and log it.

## Scrubber power check
The CO2 scrubber draws 0.6 kW on breaker B-1.
If the scrubber fan is silent, check B-1 before opening the scrubber housing.
