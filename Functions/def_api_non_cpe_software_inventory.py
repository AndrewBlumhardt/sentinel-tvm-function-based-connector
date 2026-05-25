from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DefApiNonCpeSoftwareInventory",
    schedule_setting="Schedule_DefApiNonCpeSoftwareInventory",
    function_name="DefApiNonCpeSoftwareInventory",
)
