from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DeviceTvmInfoGathering",
    schedule_setting="Schedule_DeviceTvmInfoGathering",
    function_name="DeviceTvmInfoGathering",
)
