"""Outbound notifications: e-mail over SMTP and/or a JSON webhook (ntfy, Slack-style hooks, anything that takes a POST)."""
from __future__ import annotations

import asyncio
import logging
import smtplib
from email.message import EmailMessage

import httpx

from .config import Settings

log = logging.getLogger("recbridge.notify")


class Notifier:
    def __init__(self, settings: Settings, http: httpx.AsyncClient | None = None):
        self.s = settings
        self.http = http

    @property
    def email_configured(self) -> bool:
        return bool(self.s.smtp_host and self.s.notify_to)

    @property
    def webhook_configured(self) -> bool:
        return bool(self.s.notify_webhook)

    @property
    def configured(self) -> bool:
        return self.email_configured or self.webhook_configured

    def _send_mail(self, subject: str, body: str) -> None:
        msg = EmailMessage()
        msg["Subject"] = subject
        msg["From"] = self.s.smtp_from or self.s.smtp_user or f"recbridge@{self.s.smtp_host}"
        msg["To"] = ", ".join(a.strip() for a in self.s.notify_to.split(",") if a.strip())
        msg.set_content(body)
        if self.s.smtp_port == 465:
            server = smtplib.SMTP_SSL(self.s.smtp_host, self.s.smtp_port, timeout=20)
        else:
            server = smtplib.SMTP(self.s.smtp_host, self.s.smtp_port, timeout=20)
        with server:
            if self.s.smtp_port != 465 and self.s.smtp_starttls:
                server.starttls()
            if self.s.smtp_user:
                server.login(self.s.smtp_user, self.s.smtp_password)
            server.send_message(msg)

    async def send(self, subject: str, body: str) -> list[str]:
        """Deliver through every configured channel; returns the names of the channels that succeeded."""
        done: list[str] = []
        if self.email_configured:
            try:
                await asyncio.to_thread(self._send_mail, subject, body)
                done.append("email")
            except Exception as e:
                log.warning("mail failed: %s", e)
        if self.webhook_configured:
            try:
                http = self.http or httpx.AsyncClient(timeout=15)
                r = await http.post(self.s.notify_webhook, json={"subject": subject, "body": body, "title": subject, "message": body})
                r.raise_for_status()
                done.append("webhook")
                if self.http is None:
                    await http.aclose()
            except Exception as e:
                log.warning("webhook failed: %s", e)
        return done
