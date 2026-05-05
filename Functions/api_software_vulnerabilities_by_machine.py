from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="ApiSoftwareVulnerabilitiesByMachine",
    schedule_setting="Schedule_ApiSoftwareVulnerabilitiesByMachine",
    function_name="ApiSoftwareVulnerabilitiesByMachineTimer",
)
