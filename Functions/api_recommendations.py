from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="ApiRecommendations",
    schedule_setting="Schedule_ApiRecommendations",
    function_name="ApiRecommendations",
)
