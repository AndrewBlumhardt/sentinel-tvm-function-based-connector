from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="ApiHardwareFirmwareAssessment",
    schedule_setting="Schedule_ApiHardwareFirmwareAssessment",
    function_name="ApiHardwareFirmwareAssessmentTimer",
)
