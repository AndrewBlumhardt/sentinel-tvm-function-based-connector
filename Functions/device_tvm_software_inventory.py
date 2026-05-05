from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DeviceTvmSoftwareInventory",
    schedule_setting="Schedule_DeviceTvmSoftwareInventory",
    function_name="DeviceTvmSoftwareInventoryTimer",
)
