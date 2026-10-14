# Local model evaluation (results only)

How Moku's offline fallback model was chosen (Ministral 3B on llama.cpp): candidate models judged the same labelled
screens that Jev judged, and `results/` holds what they scored. The harness that produced them ran on the TypeScript
brain and was removed with it on 2026-10-01; it's in git history (`git log -- eval/local-models`).
