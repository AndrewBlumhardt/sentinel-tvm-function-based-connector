from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="ApiNonCpeSoftwareInventory",
    schedule_setting="Schedule_ApiNonCpeSoftwareInventory",
    function_name="ApiNonCpeSoftwareInventory",
)
