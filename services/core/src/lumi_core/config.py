from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import os


@dataclass(frozen=True, slots=True)
class Settings:
    database_path: Path
    ollama_url: str
    ollama_model: str
    model_timeout_seconds: float

    @classmethod
    def from_env(cls) -> "Settings":
        data_dir = Path(os.getenv("LUMI_DATA_DIR", ".lumi-data")).expanduser()
        return cls(
            database_path=Path(os.getenv("LUMI_DATABASE_PATH", str(data_dir / "lumi.sqlite3"))).expanduser(),
            ollama_url=os.getenv("LUMI_OLLAMA_URL", "http://127.0.0.1:11434/api/chat"),
            ollama_model=os.getenv("LUMI_OLLAMA_MODEL", "llama3.2"),
            model_timeout_seconds=float(os.getenv("LUMI_MODEL_TIMEOUT", "45")),
        )
