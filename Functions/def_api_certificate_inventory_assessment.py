from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DefApiCertificateInventoryAssessment",
    schedule_setting="Schedule_DefApiCertificateInventoryAssessment",
    function_name="DefApiCertificateInventoryAssessment",
)
