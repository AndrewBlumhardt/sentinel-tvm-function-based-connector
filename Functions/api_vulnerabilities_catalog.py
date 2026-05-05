from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="ApiVulnerabilitiesCatalog",
    schedule_setting="Schedule_ApiVulnerabilitiesCatalog",
    function_name="ApiVulnerabilitiesCatalogTimer",
)
