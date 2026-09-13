import asyncio
import logging
import sys

import httpx
import uvicorn

from .api.app import create_app
from .config import Settings
from .recorder import discovery

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


async def _discover(settings: Settings) -> int:
    async with httpx.AsyncClient() as http:
        found = await discovery.discover(http, networks=settings.scan_networks)
    if not found:
        print("no Sony recorder found (tried SSDP and a scan of the local subnet)")
        return 1
    for c in found:
        print(f"{c.host}\t{c.friendly_name}\t{c.product}\tEPG={'yes' if c.epg_capable else 'no'}\tvia {c.via}\t{c.udn}")
    return 0


def main() -> None:
    settings = Settings()
    if len(sys.argv) > 1 and sys.argv[1] == "discover":
        raise SystemExit(asyncio.run(_discover(settings)))
    uvicorn.run(create_app(settings), host=settings.bind_host, port=settings.bind_port)


if __name__ == "__main__":
    main()
