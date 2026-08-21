#!/usr/bin/env python3
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
import tempfile

from lumi_core.rag.embeddings import HashEmbeddingProvider
from lumi_core.rag.eval import ndcg_at_k, recall_at_k, reciprocal_rank
from lumi_core.rag.ingestion import IngestionService
from lumi_core.rag.retrieval import HybridRetriever
from lumi_core.storage.database import Database


ROOT = Path(__file__).resolve().parents[1]


async def run() -> dict:
    corpus = json.loads((ROOT / "evals/rag/corpus.json").read_text(encoding="utf-8"))
    queries = json.loads((ROOT / "evals/rag/queries.json").read_text(encoding="utf-8"))

    with tempfile.TemporaryDirectory(prefix="lumi-rag-eval-") as temporary:
        database = Database(Path(temporary) / "lumi.sqlite3")
        database.migrate()
        embedder = HashEmbeddingProvider(dimensions=96)
        ingestion = IngestionService(
            database,
            embedder=embedder,
            embedding_model="deterministic-regression-v1",
            chunk_words=100,
            overlap_words=10,
        )
        document_ids: dict[str, str] = {}
        for item in corpus:
            result = await ingestion.ingest_bytes(
                filename=item["filename"],
                title=item["title"],
                data=item["text"].encode("utf-8"),
                source=f"eval:{item['key']}",
            )
            document_ids[item["key"]] = result.document_id

        retriever = HybridRetriever(
            database,
            embedder=embedder,
            embedding_model="deterministic-regression-v1",
        )
        cases: list[dict] = []
        for case in queries:
            hits = await retriever.retrieve(case["query"], k=3)
            retrieved = [hit.chunk_id for hit in hits]
            relevant_rows = database.get_chunks_for_document(document_ids[case["relevant"]])
            relevant = {row["id"] for row in relevant_rows}
            gains = {chunk_id: 1.0 for chunk_id in relevant}
            cases.append(
                {
                    "query": case["query"],
                    "recall_at_3": recall_at_k(retrieved, relevant, 3),
                    "reciprocal_rank": reciprocal_rank(retrieved, relevant),
                    "ndcg_at_3": ndcg_at_k(retrieved, gains, 3),
                    "top_document": hits[0].document_id if hits else None,
                }
            )

    count = max(len(cases), 1)
    return {
        "name": "deterministic-rag-regression",
        "cases": cases,
        "mean_recall_at_3": sum(case["recall_at_3"] for case in cases) / count,
        "mean_reciprocal_rank": sum(case["reciprocal_rank"] for case in cases) / count,
        "mean_ndcg_at_3": sum(case["ndcg_at_3"] for case in cases) / count,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Run Lumi deterministic RAG regression benchmark.")
    parser.add_argument("--assert-thresholds", action="store_true")
    args = parser.parse_args()
    result = asyncio.run(run())
    print(json.dumps(result, indent=2, ensure_ascii=False))

    if args.assert_thresholds:
        minimums = {
            "mean_recall_at_3": 0.95,
            "mean_reciprocal_rank": 0.85,
            "mean_ndcg_at_3": 0.85,
        }
        failed = {key: (result[key], minimum) for key, minimum in minimums.items() if result[key] < minimum}
        if failed:
            print("RAG regression gate failed:", failed)
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
