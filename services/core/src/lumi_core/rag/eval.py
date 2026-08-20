from __future__ import annotations

import math


def recall_at_k(retrieved: list[str], relevant: set[str], k: int) -> float:
    if not relevant:
        return 1.0
    return len(set(retrieved[:k]) & relevant) / len(relevant)


def reciprocal_rank(retrieved: list[str], relevant: set[str]) -> float:
    for rank, item in enumerate(retrieved, start=1):
        if item in relevant:
            return 1.0 / rank
    return 0.0


def ndcg_at_k(retrieved: list[str], gains: dict[str, float], k: int) -> float:
    def dcg(items: list[str]) -> float:
        total = 0.0
        for rank, item in enumerate(items[:k], start=1):
            gain = float(gains.get(item, 0.0))
            total += (2.0**gain - 1.0) / math.log2(rank + 1.0)
        return total

    actual = dcg(retrieved)
    ideal_items = [item for item, _ in sorted(gains.items(), key=lambda pair: pair[1], reverse=True)]
    ideal = dcg(ideal_items)
    return actual / ideal if ideal > 0 else 1.0
