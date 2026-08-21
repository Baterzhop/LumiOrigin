from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
import os
import re
from urllib.parse import urlparse


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() not in {"0", "false", "no", "off"}


def _env_optional_path(name: str) -> Path | None:
    raw = os.getenv(name, "").strip()
    return Path(raw).expanduser() if raw else None


def _env_csv(name: str, default: tuple[str, ...] = ()) -> tuple[str, ...]:
    raw = os.getenv(name)
    if raw is None:
        return default
    return tuple(item.strip() for item in raw.split(",") if item.strip())


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
    api_key: str | None = field(repr=False)
    api_docs_enabled: bool
    trusted_hosts: tuple[str, ...]
    cors_origins: tuple[str, ...]
    backup_before_migrate: bool
    backup_dir: Path
    backup_keep: int
    developer_repo_root: Path | None
    developer_base_branch: str
    developer_max_read_bytes: int
    developer_command_timeout_seconds: int
    developer_allow_local_checks: bool
    developer_github_repository: str | None
    developer_github_token: str | None = field(repr=False)

    @classmethod
    def from_env(cls) -> "Settings":
        data_dir = Path(os.getenv("LUMI_DATA_DIR", ".lumi-data")).expanduser()
        reranker = os.getenv("LUMI_RERANKER_MODEL", "").strip() or None
        workspace = Path(os.getenv("LUMI_TOOL_WORKSPACE", str(data_dir / "workspace"))).expanduser()
        github_repository = os.getenv("LUMI_DEV_GITHUB_REPOSITORY", "").strip() or None
        github_token = os.getenv("LUMI_DEV_GITHUB_TOKEN", "").strip() or None
        api_key = os.getenv("LUMI_API_KEY", "").strip() or None
        settings = cls(
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
            api_key=api_key,
            api_docs_enabled=_env_bool("LUMI_API_DOCS", False),
            trusted_hosts=_env_csv("LUMI_TRUSTED_HOSTS", ("localhost", "127.0.0.1", "testserver")),
            cors_origins=_env_csv("LUMI_CORS_ORIGINS"),
            backup_before_migrate=_env_bool("LUMI_BACKUP_BEFORE_MIGRATE", True),
            backup_dir=Path(os.getenv("LUMI_BACKUP_DIR", str(data_dir / "backups"))).expanduser(),
            backup_keep=int(os.getenv("LUMI_BACKUP_KEEP", "10")),
            developer_repo_root=_env_optional_path("LUMI_DEV_REPO_ROOT"),
            developer_base_branch=os.getenv("LUMI_DEV_BASE_BRANCH", "main").strip() or "main",
            developer_max_read_bytes=int(os.getenv("LUMI_DEV_MAX_READ_BYTES", str(256 * 1024))),
            developer_command_timeout_seconds=int(os.getenv("LUMI_DEV_COMMAND_TIMEOUT", "180")),
            developer_allow_local_checks=_env_bool("LUMI_DEV_ALLOW_LOCAL_CHECKS", False),
            developer_github_repository=github_repository,
            developer_github_token=github_token,
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        for name, value in {
            "LUMI_OLLAMA_URL": self.ollama_url,
            "LUMI_OLLAMA_EMBED_URL": self.ollama_embed_url,
        }.items():
            parsed = urlparse(value)
            if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                raise ValueError(f"{name} must be an absolute http(s) URL")

        if self.api_key is not None and len(self.api_key) < 24:
            raise ValueError("LUMI_API_KEY must contain at least 24 characters")
        if not self.trusted_hosts:
            raise ValueError("LUMI_TRUSTED_HOSTS must contain at least one host")
        if "*" in self.trusted_hosts and self.api_key is None:
            raise ValueError("wildcard trusted hosts require LUMI_API_KEY")
        if any(origin == "*" for origin in self.cors_origins):
            raise ValueError("wildcard CORS origins are not permitted")

        if not 1 <= self.model_timeout_seconds <= 600:
            raise ValueError("LUMI_MODEL_TIMEOUT must be between 1 and 600 seconds")
        if not 1_024 <= self.max_upload_bytes <= 1_073_741_824:
            raise ValueError("LUMI_MAX_UPLOAD_BYTES is outside the supported range")
        if not 1_024 <= self.tool_max_read_bytes <= 64 * 1024 * 1024:
            raise ValueError("LUMI_TOOL_MAX_READ_BYTES is outside the supported range")
        if not 1_000 <= self.context_max_input_tokens <= 1_000_000:
            raise ValueError("LUMI_CONTEXT_MAX_INPUT_TOKENS is outside the supported range")
        if not 256 <= self.context_recent_tokens < self.context_max_input_tokens:
            raise ValueError("LUMI_CONTEXT_RECENT_TOKENS must be smaller than the max input budget")
        if not 128 <= self.context_summary_tokens < self.context_max_input_tokens:
            raise ValueError("LUMI_CONTEXT_SUMMARY_TOKENS is outside the supported range")
        if not 0 <= self.memory_recall_k <= 20:
            raise ValueError("LUMI_MEMORY_RECALL_K must be between 0 and 20")
        if not 1 <= self.backup_keep <= 100:
            raise ValueError("LUMI_BACKUP_KEEP must be between 1 and 100")
        if not 8_192 <= self.developer_max_read_bytes <= 64 * 1024 * 1024:
            raise ValueError("LUMI_DEV_MAX_READ_BYTES is outside the supported range")
        if not 5 <= self.developer_command_timeout_seconds <= 900:
            raise ValueError("LUMI_DEV_COMMAND_TIMEOUT must be between 5 and 900 seconds")
        if self.developer_github_repository and not re.fullmatch(
            r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+",
            self.developer_github_repository,
        ):
            raise ValueError("LUMI_DEV_GITHUB_REPOSITORY must use owner/repository form")
