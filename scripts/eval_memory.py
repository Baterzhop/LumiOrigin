#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
import tempfile

from lumi_core.memory import MemoryService, MemoryStore
from lumi_core.rag.embeddings import HashEmbeddingProvider
from lumi_core.rag.eval import recall_at_k, reciprocal_rank
from lumi_core.storage.database import Database


ROOT = Path(__file__).resolve().parents[1]


async def run() -> dict:
    corpus = json.loads((ROOT / "evals/memory/corpus.json").read_text(encoding="utf-8"))
    queries = json.loads((ROOT / "evals/memory/queries.json").read_text(encoding="utf-8"))

    with tempfile.TemporaryDirectory(prefix="lumi-memory-eval-") as temporary:
        database = Database(Path(temporary) / "lumi.sqlite3")
        database.migrate()
        store = MemoryStore(database)
        service = MemoryService(
            store,
            embedder=HashEmbeddingProvider(dimensions=96),
            embedding_model="deterministic-memory-v1",
        )

        ids: dict[str, str] = {}
        for item in corpus:
            created = await service.create(
                item["content"],
                kind=item["kind"],
                title=item["title"],
                source="eval",
            )
            ids[item["key"]] = created["id"]

        cases: list[dict] = []
        for case in queries:
            hits = await service.search(case["query"], k=3)
            retrieved = [hit.memory_id for hit in hits]
            relevant = {ids[case["relevant"]]}
            cases.append(
                {
                    "query": case["query"],
                    "recall_at_3": recall_at_k(retrieved, relevant, 3),
                    "reciprocal_rank": reciprocal_rank(retrieved, relevant),
                    "top_memory": retrieved[0] if retrieved else None,
                }
            )

    count = max(len(cases), 1)
    return {
        "name": "deterministic-memory-regression",
        "cases": cases,
        "mean_recall_at_3": sum(item["recall_at_3"] for item in cases) / count,
        "mean_reciprocal_rank": sum(item["reciprocal_rank"] for item in cases) / count,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Lumi deterministic durable-memory regression benchmark.")
    parser.add_argument("--assert-thresholds", action="store_true")
    args = parser.parse_args()
    result = asyncio.run(run())
    print(json.dumps(result, indent=2, ensure_ascii=False))

    if args.assert_thresholds:
        minimums = {
            "mean_recall_at_3": 0.95,
            "mean_reciprocal_rank": 0.85,
        }
        failed = {key: (result[key], minimum) for key, minimum in minimums.items() if result[key] < minimum}
        if failed:
            print("Memory regression gate failed:", failed)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
