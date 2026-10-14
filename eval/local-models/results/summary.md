419 distinct screens Jev judged on the day (175 still reach a model under today's rules), 21 smoke screens; 169 must-pass screens reach a model.

| Model | Agreement with Jev (hard screens) | Must-pass | Confident and wrong | p50 / p95 warm | Peak memory | Download | Cold start | Bar |
|---|---|---|---|---|---|---|---|---|
| `mlx-community/Ministral-3-3B-Instruct-2512-4bit` | 95.4% (175) | 165/169 | 4 (2.3%) | 1022 / 2162 ms (quiet) | 2.66 GB | 2.78 GB | 4.5 s | misses: agreement, must-pass, p95 |
| `mlx-community/Qwen3.5-4B-MLX-4bit` | 93.7% (175) | 161/169 | 4 (2.3%) | 1426 / 3841 ms (quiet) | 3.48 GB | 3.06 GB | 5.8 s | misses: agreement, must-pass, p95, memory, cold start |
| `mlx-community/Qwen3-4B-Instruct-2507-4bit` | 91.4% (175) | 155/169 | 14 (8.0%) | 1355 / 3523 ms (quiet) | 3.07 GB | 2.28 GB | 5.0 s | misses: agreement, must-pass, p95, memory, cold start |
| `mlx-community/gemma-4-e2b-it-4bit` | 81.7% (175) | 138/169 | 28 (16.0%) | 293 / 1965 ms (quiet) | 3.58 GB | 3.58 GB | 4.7 s | misses: agreement, must-pass, p95, memory |
| `mlx-community/Qwen3.5-2B-MLX-4bit` | 67.4% (175) | 117/169 | 7 (4.0%) | 533 / 2046 ms (quiet) | 2.04 GB | 1.75 GB | 4.9 s | misses: agreement, must-pass, p95 |
| `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ + logistic regression` | 62.3% (175) | 108/169 | 0 (0.0%) | 301 / 1159 ms | 1.12 GB | 0.35 GB | 5.9 s | misses: agreement, must-pass, p95, cold start |
| `mlx-community/granite-4.1-3b-4bit` | 59.4% (175) | 106/169 | 57 (32.6%) | 2727 / 4968 ms (quiet) | 2.90 GB | 2.13 GB | 4.7 s | misses: agreement, must-pass, p95 |
| Jev (reference) | 100% (itself) | 167/169 | n/a | ~500 ms (network) | 0 | 0 | 0 | |

Jev's current answers agree with its live verdicts on 83.4% of the hard screens (the question changed during the day); live Jev passed 131/160 must-pass screens.
Jev's own must-pass misses: Telegram (Claude, Telegram, Cursor, chatgpt.com, acme.example working) ×2
- mlx-community/Ministral-3-3B-Instruct-2512-4bit: sure (p ≥ 0.95 or ≤ 0.05) on 66.9% of the hard screens, agreeing with Jev on 97.4% of those; 2 sure must-pass misses
- mlx-community/Qwen3.5-4B-MLX-4bit: sure (p ≥ 0.95 or ≤ 0.05) on 74.3% of the hard screens, agreeing with Jev on 97.7% of those; 1 sure must-pass misses
- mlx-community/Qwen3-4B-Instruct-2507-4bit: sure (p ≥ 0.95 or ≤ 0.05) on 97.1% of the hard screens, agreeing with Jev on 92.4% of those; 12 sure must-pass misses
- mlx-community/gemma-4-e2b-it-4bit: sure (p ≥ 0.95 or ≤ 0.05) on 94.3% of the hard screens, agreeing with Jev on 83.0% of those; 27 sure must-pass misses
- mlx-community/Qwen3.5-2B-MLX-4bit: sure (p ≥ 0.95 or ≤ 0.05) on 13.1% of the hard screens, agreeing with Jev on 100.0% of those; 0 sure must-pass misses
- mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ + logistic regression: sure (p ≥ 0.95 or ≤ 0.05) on 0.0% of the hard screens, agreeing with Jev on n/a of those; 0 sure must-pass misses
- mlx-community/granite-4.1-3b-4bit: sure (p ≥ 0.95 or ≤ 0.05) on 81.1% of the hard screens, agreeing with Jev on 61.3% of those; 47 sure must-pass misses
- mlx-community/Ministral-3-3B-Instruct-2512-4bit must-pass misses: Telegram (Claude, Telegram, Cursor, chatgpt.com, acme.example working) ×3, acme.example (Claude, Telegram, Cursor, chatgpt.com, acme.example working) ×1
- mlx-community/Qwen3.5-4B-MLX-4bit must-pass misses: youtube.com (YouTube (home and every video) drifting) ×6, Telegram (Claude, Telegram, Cursor, chatgpt.com, acme.example working) ×1, WhatsApp (personal WhatsApp chats drifting) ×1
- mlx-community/Qwen3-4B-Instruct-2507-4bit must-pass misses: youtube.com (YouTube (home and every video) drifting) ×11, Telegram (Claude, Telegram, Cursor, chatgpt.com, acme.example working) ×2, WhatsApp (personal WhatsApp chats drifting) ×1
- mlx-community/gemma-4-e2b-it-4bit must-pass misses: youtube.com (YouTube (home and every video) drifting) ×24, WhatsApp (personal WhatsApp chats drifting) ×5, Telegram (Claude, Telegram, Cursor, chatgpt.com, acme.example working) ×2
- mlx-community/Qwen3.5-2B-MLX-4bit must-pass misses: WhatsApp (personal WhatsApp chats drifting) ×30, youtube.com (YouTube (home and every video) drifting) ×22
- mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ + logistic regression must-pass misses: WhatsApp (personal WhatsApp chats drifting) ×28, acme.example (Claude, Telegram, Cursor, chatgpt.com, acme.example working) ×18, Telegram (Claude, Telegram, Cursor, chatgpt.com, acme.example working) ×8, youtube.com (YouTube (home and every video) drifting) ×3, ats.example (smoke: the 4 HR screens → one hiring thread) ×1, linkedin.com (smoke: LinkedIn profile → working) ×1, acme.example (smoke: job descriptions → working, career, a job-search phrase) ×1, linkedin.com (smoke: job descriptions → working, career, a job-search phrase) ×1
- mlx-community/granite-4.1-3b-4bit must-pass misses: Telegram (Claude, Telegram, Cursor, chatgpt.com, acme.example working) ×50, acme.example (Claude, Telegram, Cursor, chatgpt.com, acme.example working) ×12, youtube.com (smoke: Morris traversal tutorial → working on DSA, learning) ×1
