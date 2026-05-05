from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DeviceTvmSoftwareVulnerabilities",
    schedule_setting="Schedule_DeviceTvmSoftwareVulnerabilities",
    function_name="DeviceTvmSoftwareVulnerabilitiesTimer",
)
