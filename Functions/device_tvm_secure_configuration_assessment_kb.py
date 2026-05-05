from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DeviceTvmSecureConfigurationAssessmentKB",
    schedule_setting="Schedule_DeviceTvmSecureConfigurationAssessmentKB",
    function_name="DeviceTvmSecureConfigurationAssessmentKBTimer",
)
