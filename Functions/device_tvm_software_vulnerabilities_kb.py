from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DeviceTvmSoftwareVulnerabilitiesKB",
    schedule_setting="Schedule_DeviceTvmSoftwareVulnerabilitiesKB",
    function_name="DeviceTvmSoftwareVulnerabilitiesKBTimer",
)
