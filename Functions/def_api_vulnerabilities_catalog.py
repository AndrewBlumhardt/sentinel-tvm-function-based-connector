from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DefApiVulnerabilitiesCatalog",
    schedule_setting="Schedule_DefApiVulnerabilitiesCatalog",
    function_name="DefApiVulnerabilitiesCatalog",
)
