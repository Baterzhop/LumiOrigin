# Lumi V4 M2 — Knowledge / RAG

M2 adds a measurable retrieval pipeline instead of treating prompt context as an in-memory string list.

## Ingestion

Supported first-wave formats:

- UTF-8 text
- Markdown
- PDF text extraction via `pypdf`

`POST /v1/knowledge/upload` stores a content-hashed document and deterministic chunks in SQLite. Re-uploading identical bytes deduplicates the document. Upload size is bounded by `LUMI_MAX_UPLOAD_BYTES` (25 MiB by default).

## Sparse retrieval

SQLite FTS5 is the local sparse index. Chunk IDs and document IDs remain stable and are returned with every hit.

## Dense retrieval

When `LUMI_RAG_DENSE=1` (default), Lumi uses Ollama's `/api/embed` endpoint and stores vectors keyed by chunk + embedding model. The default model name is `embeddinggemma` and can be changed with `LUMI_EMBEDDING_MODEL`.

Dense similarity is currently exact cosine over locally stored vectors. This is intentionally simple and correct for the alpha. If corpus size makes O(N) vector scans material, the vector storage boundary will be replaced by an ANN index without changing the retrieval contract.

## Fusion

Sparse and dense rankings are combined with weighted Reciprocal Rank Fusion (RRF), avoiding invalid arithmetic between BM25 and cosine score scales.

## Reranking

Set `LUMI_RERANKER_MODEL` to enable a lazy cached `sentence-transformers` CrossEncoder. Install `lumi-core[rerank]` first. Reranker failures degrade to fused results instead of failing chat.

## Grounding and prompt-injection boundary

Retrieved documents are explicitly rendered as untrusted data, never as system instructions. Each chunk receives a source token `[S1]`, `[S2]`, etc. API responses also return structured citation metadata so the client does not need to infer sources from generated prose.

## Evaluation

`lumi_core.rag.eval` contains baseline Recall@k, reciprocal rank, and nDCG@k metrics. M2 tests use a deterministic fake embedder so CI does not require network access or a model download.

## Current limits

- PDF OCR is not part of M2; scanned PDFs require a later OCR pipeline.
- Dense exact scan is not an ANN index yet.
- The CrossEncoder is opt-in because installing transformer runtimes would make the default local core significantly heavier.
- Language detection and advanced structure-aware chunking are future work.
