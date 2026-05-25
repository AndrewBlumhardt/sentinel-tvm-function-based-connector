from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DefApiSoftwareInventoryByMachine",
    schedule_setting="Schedule_DefApiSoftwareInventoryByMachine",
    function_name="DefApiSoftwareInventoryByMachine",
)
