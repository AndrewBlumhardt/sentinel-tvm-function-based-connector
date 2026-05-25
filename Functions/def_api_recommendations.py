from Functions.common import build_timer_blueprint


blueprint = build_timer_blueprint(
    dataset_name="DefApiRecommendations",
    schedule_setting="Schedule_DefApiRecommendations",
    function_name="DefApiRecommendations",
)
