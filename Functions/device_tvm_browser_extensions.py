from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DeviceTvmBrowserExtensions",
    schedule_setting="Schedule_DeviceTvmBrowserExtensions",
    function_name="DeviceTvmBrowserExtensionsTimer",
)
