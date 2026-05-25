from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DefApiBrowserExtensionsInventory",
    schedule_setting="Schedule_DefApiBrowserExtensionsInventory",
    function_name="DefApiBrowserExtensionsInventory",
)
