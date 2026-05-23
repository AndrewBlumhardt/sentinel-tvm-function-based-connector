from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DeviceTvmInfoGatheringKB",
    schedule_setting="Schedule_DeviceTvmInfoGatheringKB",
    function_name="DeviceTvmInfoGatheringKB",
)
