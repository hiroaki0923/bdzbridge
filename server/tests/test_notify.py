import asyncio
from typing import ClassVar

import pytest

from bdzbridge.config import Settings
from bdzbridge.notify import Notifier


class FakeSMTP:
    instances: ClassVar[list] = []

    def __init__(self, host, port, timeout=None):
        self.host, self.port, self.started, self.login_as, self.messages = host, port, False, None, []
        FakeSMTP.instances.append(self)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def starttls(self):
        self.started = True

    def login(self, user, password):
        self.login_as = (user, password)

    def send_message(self, msg):
        self.messages.append(msg)


def test_unconfigured_notifier_sends_nothing():
    n = Notifier(Settings(api_token="t"))
    assert not n.configured
    assert asyncio.run(n.send("s", "b")) == []


def test_mail_goes_through_smtp(monkeypatch):
    monkeypatch.setattr("bdzbridge.notify.smtplib.SMTP", FakeSMTP)
    FakeSMTP.instances.clear()
    s = Settings(api_token="t", smtp_host="smtp.example.com", smtp_port=587, smtp_user="me@example.com",
                 smtp_password="pw", notify_to="a@example.com, b@example.com")
    n = Notifier(s)
    assert n.email_configured and not n.webhook_configured
    assert asyncio.run(n.send("[bdzbridge] 自動予約 1 件", "本文\n")) == ["email"]
    smtp = FakeSMTP.instances[-1]
    assert (smtp.host, smtp.port, smtp.started, smtp.login_as) == ("smtp.example.com", 587, True, ("me@example.com", "pw"))
    msg = smtp.messages[0]
    assert msg["To"] == "a@example.com, b@example.com" and msg["From"] == "me@example.com"
    assert msg["Subject"] == "[bdzbridge] 自動予約 1 件" and msg.get_content().startswith("本文")


@pytest.mark.parametrize("port,starttls", [(465, False), (25, False)])
def test_mail_transport_variants(monkeypatch, port, starttls):
    monkeypatch.setattr("bdzbridge.notify.smtplib.SMTP", FakeSMTP)
    monkeypatch.setattr("bdzbridge.notify.smtplib.SMTP_SSL", FakeSMTP)
    FakeSMTP.instances.clear()
    s = Settings(api_token="t", smtp_host="h", smtp_port=port, smtp_starttls=starttls, notify_to="a@example.com")
    assert asyncio.run(Notifier(s).send("s", "b")) == ["email"]
    assert FakeSMTP.instances[-1].started is False and FakeSMTP.instances[-1].login_as is None
