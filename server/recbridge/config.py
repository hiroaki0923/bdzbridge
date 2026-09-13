from __future__ import annotations

import secrets
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="RECBRIDGE_", env_file=".env", extra="ignore")

    recorder_host: str = ""             # empty = use the host saved via the API, else start unconfigured
    scan_networks: str = ""             # comma-separated CIDRs to scan; default: the primary interface's /24
    api_token: str = ""                 # empty = generate one at startup and print it
    db_path: str = "data/recbridge.sqlite3"
    epg_refresh_hours: float = 3.0
    epg_refresh_on_start: bool = True
    default_quality: str = "LSR"        # DR/XR/XSR/SR/LSR/LR/ER/EER
    default_repeat: str = "none"
    static_dir: str = ""                # built web app to serve at "/"; default: ../web/dist next to this package if present
    bind_host: str = "127.0.0.1"
    bind_port: int = 8000

    def ensure_token(self) -> str:
        if not self.api_token:
            self.api_token = secrets.token_urlsafe(24)
            print(f"[recbridge] RECBRIDGE_API_TOKEN not set; generated one for this run: {self.api_token}")
        return self.api_token

    def ensure_db_dir(self) -> None:
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
