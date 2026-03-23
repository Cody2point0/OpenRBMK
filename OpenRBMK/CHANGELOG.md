## OpenRBMK 14.20.02 - 2026-03-19 (UNRELEASED)

### Changed
- Map renderer now uses cached cell updates instead of full redraws (eliminates display flicker)
- Reactor map no longer enforces strict geometric spacing; prioritizes stable visualization over exact coordinate gaps

### Fixed
- Eliminated map flickering caused by full-frame clears and redraw cycles
- Prevented redundant GPU fill operations on unchanged cells

### Added
- Per-cell framebuffer cache for map rendering
- Dirty-state tracking for layout-triggered full redraws only

<br>

## OpenRBMK 14.20.01 - 2026-03-19

### Changed
- Map renderer draws non-addressable segments as middle gray 0x555555

### Fixed
- Reactor map now properly enforces geometric spacing

### Added
- Nothing!

<br>

## OpenRBMK 14.20.00 - 2026-03-19

### Changed
- Flux SCRAM now uses max-per-rod flux
- AUTO authority clamp is temperature-based
- Removed flux-based AUTO authority clamp

### Fixed
- Corrected flux return unpack assignment
- FLUX[] now displays average core flux instead of individual rod flux
- Fixed GLOBAL AUTO path using undefined variable

<br>

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

<br>

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

<br>

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

<br>

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