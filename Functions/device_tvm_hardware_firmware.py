from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DeviceTvmHardwareFirmware",
    schedule_setting="Schedule_DeviceTvmHardwareFirmware",
    function_name="DeviceTvmHardwareFirmwareTimer",
)
