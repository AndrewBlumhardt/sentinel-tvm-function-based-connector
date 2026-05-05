from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="ApiBrowserExtensionPermissions",
    schedule_setting="Schedule_ApiBrowserExtensionPermissions",
    function_name="ApiBrowserExtensionPermissionsTimer",
)
