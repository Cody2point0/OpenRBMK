A collection of all the code I have made for anything even remotely related to OpenComputers.


# Programs List
## OpenRBMK

OpenRBMK is a real-time monitoring and control system for RBMK-style reactors built for OpenComputers and HBM Nuclear Tech.

It is designed to emulate structured reactor control systems with deterministic behavior, fast update rates, and safety-first logic.

<br>

### Overview

OpenRBMK provides continuous reactor telemetry, derived physics calculations, automated safety systems, and a GPU-rendered interface.

The system operates on a fixed update loop (~0.1s) and is designed for full-core monitoring with stable, predictable output.

<br>

### Features

#### Monitoring
- Core temperature (per rod + aggregate)
- Neutron flux (average + per-rod max)
- Control level and target level
- Fuel depletion and xenon poisoning

#### Calculations
- Thermal power estimation
- k-effective (k_eff)
- Flux averaging and peak detection

#### Safety
- Automatic SCRAM system
- Temperature-based protection
- Flux-based emergency detection (per-rod max)
- Latched shutdown state
- AUTO authority limiting based on temperature

#### Display
- GPU-rendered interface (OpenComputers)
- Structured layout for critical data
- ~10 Hz refresh rate

<br>

### Architecture

Single-file system:

- OpenRBMK.lua → main loop, monitoring, calculations, safety, and rendering

Design goals:
- Deterministic execution
- Fail-safe defaults
- Minimal dependencies

<br>

### Requirements

- Minecraft (modded)
- OpenComputers
- HBM Nuclear Tech (RBMK reactor)
- GPU + screen (Tier 2+ recommended)
- Keyboard

<br>

### Installation

<br>

### Data Model

Raw inputs:
- getTemp()
- getFlux()
- getLevel()
- getTargetLevel()

Derived:
- Average core flux
- Maximum rod flux (SCRAM basis)
- Thermal power
- k_eff estimate

<br>

### Safety Logic

SCRAM triggers when:
- Temperature exceeds limits
- Flux instability occurs
- Unsafe reactor state detected

Behavior:
- Immediate shutdown
- Latched state (manual reset required)
- AUTO control limited by temperature

<br>

### Changes (v14.20)

Changed:
- Corrected flux return unpack assignment
- FLUX[] now uses average core flux
- SCRAM now uses max per-rod flux
- AUTO authority now temperature-based
- Removed flux-based AUTO magnitude

Fixed:
- GLOBAL AUTO undefined variable reference

<br>

### Versioning

Current format:
v14.20

Optional extended format:
14.20.00(a)

<br>

### License

Not specified

<br>

### Disclaimer

This project is a simulation system for modded environments. It is not intended for real-world reactor control.