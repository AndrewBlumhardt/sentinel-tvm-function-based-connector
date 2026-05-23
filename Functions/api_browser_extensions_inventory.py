from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="ApiBrowserExtensionsInventory",
    schedule_setting="Schedule_ApiBrowserExtensionsInventory",
    function_name="ApiBrowserExtensionsInventory",
)
