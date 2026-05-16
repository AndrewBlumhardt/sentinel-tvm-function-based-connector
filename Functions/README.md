# Functions folder

This folder contains the Azure Function timer-trigger entry points.

## Purpose

- Each dataset has its own timer trigger module.
- Triggers are intentionally thin: they call shared orchestration code from `Shared/`.
- Schedules are read from app settings (for example `%Schedule_DeviceTvmSoftwareInventory%`).

## Files

- `datasets.json`: dataset catalog and runtime defaults.
- `common.py`: shared helper that builds timer-trigger blueprints to avoid repeated boilerplate.
- `__init__.py`: package marker.

### Advanced Hunting dataset triggers

- `device_tvm_software_inventory.py`
- `device_tvm_software_vulnerabilities.py`
- `device_tvm_software_vulnerabilities_kb.py`
- `device_tvm_secure_configuration_assessment.py`
- `device_tvm_secure_configuration_assessment_kb.py`
- `device_tvm_software_evidence_beta.py`
- `device_tvm_browser_extensions.py`
- `device_tvm_browser_extensions_kb.py`
- `device_tvm_certificate_info.py`
- `device_tvm_hardware_firmware.py`
- `device_tvm_info_gathering.py`
- `device_tvm_info_gathering_kb.py`

### Defender REST dataset triggers

- `api_machines.py`
- `api_software_vulnerabilities_by_machine.py`
- `api_software_inventory_by_machine.py`
- `api_non_cpe_software_inventory.py`
- `api_recommendations.py`
- `api_secure_configuration_assessment_by_machine.py`
- `api_vulnerabilities_catalog.py`
- `api_browser_extensions_inventory.py`
- `api_browser_extension_permissions.py`
- `api_certificate_inventory_assessment.py`
- `api_hardware_firmware_assessment.py`

### NIST dataset triggers

- `nist_cve_catalog.py`
- `nist_cpe_configurations.py`

## Notes

- Business logic does not live here; it is centralized in `Shared/dataset_runner.py`.
- To add a new dataset, create a new timer trigger module and add a matching dataset entry in `Functions/datasets.json`.
