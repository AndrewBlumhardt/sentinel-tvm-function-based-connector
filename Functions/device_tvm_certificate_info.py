from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DeviceTvmCertificateInfo",
    schedule_setting="Schedule_DeviceTvmCertificateInfo",
    function_name="DeviceTvmCertificateInfoTimer",
)
