from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() not in {"0", "false", "no", "off"}


def _env_optional_path(name: str) -> Path | None:
    raw = os.getenv(name, "").strip()
    return Path(raw).expanduser() if raw else None


@dataclass(frozen=True, slots=True)
class Settings:
    database_path: Path
    ollama_url: str
    ollama_model: str
    model_timeout_seconds: float
    ollama_embed_url: str
    embedding_model: str
    rag_dense_enabled: bool
    reranker_model: str | None
    max_upload_bytes: int
    tool_workspace_root: Path
    tool_max_read_bytes: int
    context_max_input_tokens: int
    context_recent_tokens: int
    context_summary_tokens: int
    memory_recall_k: int
    developer_repo_root: Path | None
    developer_base_branch: str
    developer_max_read_bytes: int
    developer_command_timeout_seconds: int
    developer_allow_local_checks: bool
    developer_github_repository: str | None
    developer_github_token: str | None

    @classmethod
    def from_env(cls) -> "Settings":
        data_dir = Path(os.getenv("LUMI_DATA_DIR", ".lumi-data")).expanduser()
        reranker = os.getenv("LUMI_RERANKER_MODEL", "").strip() or None
        workspace = Path(os.getenv("LUMI_TOOL_WORKSPACE", str(data_dir / "workspace"))).expanduser()
        github_repository = os.getenv("LUMI_DEV_GITHUB_REPOSITORY", "").strip() or None
        github_token = os.getenv("LUMI_DEV_GITHUB_TOKEN", "").strip() or None
        return cls(
            database_path=Path(os.getenv("LUMI_DATABASE_PATH", str(data_dir / "lumi.sqlite3"))).expanduser(),
            ollama_url=os.getenv("LUMI_OLLAMA_URL", "http://127.0.0.1:11434/api/chat"),
            ollama_model=os.getenv("LUMI_OLLAMA_MODEL", "llama3.2"),
            model_timeout_seconds=float(os.getenv("LUMI_MODEL_TIMEOUT", "45")),
            ollama_embed_url=os.getenv("LUMI_OLLAMA_EMBED_URL", "http://127.0.0.1:11434/api/embed"),
            embedding_model=os.getenv("LUMI_EMBEDDING_MODEL", "embeddinggemma"),
            rag_dense_enabled=_env_bool("LUMI_RAG_DENSE", True),
            reranker_model=reranker,
            max_upload_bytes=int(os.getenv("LUMI_MAX_UPLOAD_BYTES", str(25 * 1024 * 1024))),
            tool_workspace_root=workspace,
            tool_max_read_bytes=int(os.getenv("LUMI_TOOL_MAX_READ_BYTES", str(512 * 1024))),
            context_max_input_tokens=int(os.getenv("LUMI_CONTEXT_MAX_INPUT_TOKENS", "6000")),
            context_recent_tokens=int(os.getenv("LUMI_CONTEXT_RECENT_TOKENS", "3500")),
            context_summary_tokens=int(os.getenv("LUMI_CONTEXT_SUMMARY_TOKENS", "800")),
            memory_recall_k=int(os.getenv("LUMI_MEMORY_RECALL_K", "4")),
            developer_repo_root=_env_optional_path("LUMI_DEV_REPO_ROOT"),
            developer_base_branch=os.getenv("LUMI_DEV_BASE_BRANCH", "main").strip() or "main",
            developer_max_read_bytes=int(os.getenv("LUMI_DEV_MAX_READ_BYTES", str(256 * 1024))),
            developer_command_timeout_seconds=int(os.getenv("LUMI_DEV_COMMAND_TIMEOUT", "180")),
            developer_allow_local_checks=_env_bool("LUMI_DEV_ALLOW_LOCAL_CHECKS", False),
            developer_github_repository=github_repository,
            developer_github_token=github_token,
        )
