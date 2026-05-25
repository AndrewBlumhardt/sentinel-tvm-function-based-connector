from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DefApiSoftwareVulnerabilitiesByMachine",
    schedule_setting="Schedule_DefApiSoftwareVulnerabilitiesByMachine",
    function_name="DefApiSoftwareVulnerabilitiesByMachine",
)
