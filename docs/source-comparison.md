# Source Comparison Notes

This connector is designed to let you ingest both raw Advanced Hunting TVM tables and curated Defender REST datasets at the same time.

Use raw Advanced Hunting datasets when you want table-level parity with Defender hunting data and direct KQL access patterns.

Use Defender REST datasets when the endpoint provides a cleaner object model, better pagination, or a more durable contract for high-volume collection.

The intended operating model is:

1. Enable both source families for the domains you care about.
2. Compare the resulting custom tables in Sentinel.
3. Disable the dataset family you no longer need.
