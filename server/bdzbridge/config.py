from __future__ import annotations

import secrets
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

# The token .env.example carries. Accepting it would leave a server copied from the example, and never edited,
# locked with a word anybody can read in the repository.
PLACEHOLDER_TOKEN = "change-me"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="BDZBRIDGE_", env_file=".env", extra="ignore")

    recorder_host: str = ""             # empty = use the host saved via the API, else start unconfigured
    recorder_mac: str = ""              # for Wake-on-LAN; default: learned from the ARP table when the recorder is selected
    scan_networks: str = ""             # comma-separated CIDRs to scan; default: the primary interface's /24
    api_token: str = ""                 # empty (or the example's placeholder) = generate one at startup and print it
    db_path: str = "data/bdzbridge.sqlite3"
    epg_refresh_hours: float = 3.0
    epg_refresh_on_start: bool = True
    default_quality: str = "LSR"        # DR/XR/XSR/SR/LSR/LR/ER/EER
    default_repeat: str = "none"
    static_dir: str = ""                # built web app to serve at "/"; default: ../web/dist next to this package if present
    bind_host: str = "127.0.0.1"
    bind_port: int = 8000
    # notifications for auto-reservation: e-mail over SMTP and/or a JSON webhook (both optional)
    smtp_host: str = ""
    smtp_port: int = 587                # 465 = implicit TLS, otherwise STARTTLS when smtp_starttls is on
    smtp_starttls: bool = True
    smtp_user: str = ""
    smtp_password: str = ""
    smtp_from: str = ""                 # default: smtp_user
    notify_to: str = ""                 # comma-separated recipients
    notify_webhook: str = ""            # POST {"subject", "body", "title", "message"} as JSON (ntfy, chat hooks, ...)
    notify_free_gb: float = 50.0        # warn once when the HDD's free space drops below this (0 = never)

    def ensure_token(self) -> str:
        if self.api_token in ("", PLACEHOLDER_TOKEN):
            why = f"is still the example's {PLACEHOLDER_TOKEN!r}, which is not accepted" if self.api_token else "not set"
            self.api_token = secrets.token_urlsafe(24)
            print(f"[bdzbridge] BDZBRIDGE_API_TOKEN {why}; generated one for this run: {self.api_token}")
        return self.api_token

    def ensure_db_dir(self) -> None:
        Path(self.db_path).parent.mkdir(parents=True, exist_ok=True)
