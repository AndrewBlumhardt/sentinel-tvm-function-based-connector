from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DeviceTvmSecureConfigurationAssessment",
    schedule_setting="Schedule_DeviceTvmSecureConfigurationAssessment",
    function_name="DeviceTvmSecureConfigurationAssessmentTimer",
)
