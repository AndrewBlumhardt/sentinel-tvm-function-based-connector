from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="NistCpeConfigurations",
    schedule_setting="Schedule_NistCpeConfigurations",
    function_name="NistCpeConfigurationsTimer",
)
