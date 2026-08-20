#!/usr/bin/env python3
from __future__ import annotations
import importlib.util, json, socket, time, urllib.parse
from importlib.machinery import SourceFileLoader
from pathlib import Path

CORE=Path.home()/'.local/bin/bc250-relay-v3.3-core'
_loader=SourceFileLoader('bc250_relay_v33_core',str(CORE))
_spec=importlib.util.spec_from_loader(_loader.name,_loader)
if not _spec or not _spec.loader: raise SystemExit(f'cannot load {CORE}')
v33=importlib.util.module_from_spec(_spec); _spec.loader.exec_module(v33)

class QueueAwareHandler(v33.v32.Handler):
    def do_GET(self):
        p=urllib.parse.urlparse(self.path)
        if p.path!='/health':return super().do_GET()
        t=self.server.transport.tstatus(); active=self.server.runner.snapshot()
        qage=t.get('queue_last_ok_age_s')
        # Queue reachability is the core liveness signal. A manually PAUSED/STOPPED
        # session is not unhealthy; a stale queue/claim is.
        queue_ok=qage is not None and qage < 45
        ok=queue_ok and not t.get('stale_claims')
        body={'ok':ok,'protocol':v33.v32.PROTOCOL,'relay_version':v33.VERSION,'host':socket.gethostname(),
              'active':active,'sessions':self.server.sessions.snap(),'transport':t}
        return self.sendj(200 if ok else 503,body)

v33.v32.Handler=QueueAwareHandler
v33.main()
