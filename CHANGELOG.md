
## Unreleased Changes
Adaptive Control + RBMK Heater (HEATEX) map support + Flux + Unattended-safe AUTO
### Changed

### Fixed

### Added
<!-- THREE LINES OF SPACE BETWEEN RELEASES

-->
## OpenRBMK 14.20.00 - 2026-03-19

### Changed
- Flux SCRAM now uses max-per-rod flux
- AUTO authority clamp is temperature-based
- Removed flux-based AUTO authority clamp

### Fixed
- Corrected flux return unpack assignment
- FLUX[] now displays average core flux instead of individual rod flux
- Fixed GLOBAL AUTO path using undefined variable
<!-- THREE LINES OF SPACE BETWEEN RELEASES


-->
## OpenRBMK 14.19.00 - 2026-03-18

### Changed
- Refactored flux handling to separate per-rod and aggregate calculations
- Updated display pipeline to support variable core sizes
- Normalized internal data structures for Any-Core scalability

### Fixed
- Corrected rod indexing issues in non-standard reactor layouts
- Fixed display/data desynchronization under dynamic core configurations

### Added
- Any-Core monitoring support (no fixed rod count assumptions)
- Dynamic rod indexing (removed static array dependence)
- Support for heterogeneous reactor layouts


<!-- THREE LINES OF SPACE BETWEEN RELEASES


-->
## OpenRBMK 14.18.00 - 2026-03-17

### Changed
- Separated control logic from display loop
- Introduced temperature influence into AUTO control response

### Fixed
- Reduced control oscillation under rapid flux changes
- Corrected timing inconsistencies in control updates

### Added
- AUTO control mode (initial implementation)
- Control authority scaling system


<!-- THREE LINES OF SPACE BETWEEN RELEASES


-->
## OpenRBMK 14.17.00 - 2026-03-16

### Changed
- Centralized safety logic into unified control path
- Transitioned system from passive monitoring to active protection

### Fixed
- Corrected SCRAM state failing to latch
- Prevented reactor restart after unsafe conditions

### Added
- SCRAM system (first stable implementation)
- Threshold-based shutdown triggers


<!-- THREE LINES OF SPACE BETWEEN RELEASES


-->
## OpenRBMK 14.16.00 - 2026-03-15

### Changed
- Stabilized main update loop (~0.1s execution target)
- Improved sensor polling consistency

### Fixed
- Corrected inconsistent sensor read timing
- Fixed occasional nil values in flux calculations

### Added
- Core-level flux monitoring
- Initial derived calculations (thermal estimation groundwork)