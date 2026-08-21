#!/usr/bin/env python3
from __future__ import annotations
import hashlib, importlib.util, json, secrets, socket, threading, time, urllib.parse
from importlib.machinery import SourceFileLoader
from pathlib import Path

HOME = Path.home()
V33_PATH = HOME / '.local/bin/bc250-relay-v3.3-core'
_loader = SourceFileLoader('bc250_relay_v33_core_for_v34', str(V33_PATH))
_spec = importlib.util.spec_from_loader(_loader.name, _loader)
if not _spec or not _spec.loader:
    raise SystemExit(f'cannot load {V33_PATH}')
v33 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(v33)

VERSION = '3.4'
v33.VERSION = VERSION
v33.v32.VERSION = VERSION


def _short_error(e: Exception) -> str:
    return f'{type(e).__name__}: {e}'[:500]


class QueueIndexedTransport(v33.ReliableTransport):
    def __init__(self, cfg, runner, sessions):
        super().__init__(cfg, runner, sessions)
        self._queue_manifest_fp = None
        self.malformed_quarantined = 0
        self.queue_manifest_updates = 0

    def tstatus(self):
        x = super().tstatus()
        x.update(
            malformed_quarantined=self.malformed_quarantined,
            queue_manifest_updates=self.queue_manifest_updates,
            queue_manifest_path=f'{self.prefix}/status/queue.json',
        )
        return x

    def hello(self):
        # Status files must never echo the relay token. Authentication belongs only
        # in job/control payloads.
        v33.gh_put_retry(self.repo, f'{self.prefix}/status/hello.json', {
            'protocol': v33.v32.PROTOCOL,
            'relay_version': VERSION,
            'host': socket.gethostname(),
            'allowed_roots': self.cfg['allowed_roots'],
            'http_port': self.cfg.get('http_port', 8765),
            'sessions': list(v33.v32.SESSIONS),
            'job_filename': '<session>--<job_id>.json',
            'result_filename': '<session>--<job_id>.json',
            'queue_manifest': f'{self.prefix}/status/queue.json',
            'durable_job_state': True,
            'malformed_job_quarantine': True,
        }, 'relay v3.4 hello')
        self.ok()

    def status(self):
        x = {
            'protocol': v33.v32.PROTOCOL,
            'relay_version': VERSION,
            'host': socket.gethostname(),
            'unix': int(time.time()),
            'active_jobs': self.runner.snapshot(),
            'sessions': self.sessions.snap(),
            'transport': self.tstatus(),
        }
        v33.gh_put_retry(self.repo, f'{self.prefix}/status/heartbeat.json', x, 'relay v3.4 heartbeat')
        v33.gh_put_retry(self.repo, f'{self.prefix}/status/sessions.json', {
            'protocol': v33.v32.PROTOCOL,
            'relay_version': VERSION,
            'unix': int(time.time()),
            'sessions': self.sessions.snap(),
        }, 'relay v3.4 sessions')
        self.ok()

    def _infer_filename_identity(self, name: str):
        stem = name[:-5] if name.endswith('.json') else name
        session = None
        jid = stem
        for s in v33.v32.SESSIONS:
            p = s + '--'
            if stem.startswith(p):
                session = s
                jid = stem[len(p):]
                break
        if session is None:
            try:
                session = v33.v32.session_of({}, name)
            except Exception:
                session = 'fsr4'
        try:
            jid = v33.v32.normalize_job_id(session, jid)
        except Exception:
            jid = hashlib.sha256(name.encode()).hexdigest()[:16]
        return session, jid

    def _quarantine_malformed(self, item, name: str, error: Exception):
        session, jid = self._infer_filename_identity(name)
        result_path = self.result_path(session, jid)
        if v33.gh_get_strict(self.repo, result_path) is None:
            result = {
                'protocol': v33.v32.PROTOCOL,
                'relay_version': VERSION,
                'job_id': jid,
                'session': session,
                'host': socket.gethostname(),
                'status': 'error',
                'error': f'malformed_job_json: {_short_error(error)}',
                'result': {},
                'source_filename': name,
                'control': self.sessions.snap(session),
            }
            v33.gh_put_retry(self.repo, result_path, result, f'relay {session} malformed result {jid}')
            check = v33.gh_get_strict(self.repo, result_path)
            if check is None:
                raise RuntimeError(f'malformed result verification failed: {result_path}')
            parsed = json.loads(check)
            if parsed.get('status') != 'error' or parsed.get('job_id') != jid:
                raise RuntimeError(f'malformed result verification mismatch: {result_path}')
        v33.gh_delete_retry(
            self.repo,
            f'{self.prefix}/jobs/{name}',
            str(item.get('sha', '')),
            f'relay quarantined malformed {session} {jid}',
        )
        self.malformed_quarantined += 1
        v33.v32.history_add({
            'unix': int(time.time()),
            'session': session,
            'job_id': jid,
            'status': 'malformed-quarantined',
            'duration_s': 0,
        })

    def _publish_queue_manifest(self, entries, malformed):
        with self.lock:
            inflight = sorted(self.inflight)
            claimed = sorted(self.claimed)
        active = self.runner.snapshot()
        semantic = {
            'pending': entries,
            'malformed': malformed,
            'inflight_jobs': inflight,
            'claimed_sessions': claimed,
            'active_jobs': [
                {'job_id': x.get('job_id'), 'session': x.get('session')}
                for x in active
            ],
            'sessions': {
                s: {'mode': self.sessions.snap(s).get('mode')}
                for s in v33.v32.SESSIONS
            },
        }
        fp = hashlib.sha256(json.dumps(semantic, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
        if fp == self._queue_manifest_fp:
            return
        body = {
            'protocol': v33.v32.PROTOCOL,
            'relay_version': VERSION,
            'host': socket.gethostname(),
            'unix': int(time.time()),
            **semantic,
        }
        v33.gh_put_retry(self.repo, f'{self.prefix}/status/queue.json', body, 'relay v3.4 queue index')
        self._queue_manifest_fp = fp
        self.queue_manifest_updates += 1

    def jobs(self):
        self.reconcile_claims()
        items = v33.gh_list_strict(self.repo, f'{self.prefix}/jobs')
        self.last_poll = int(time.time())
        self.api_ok('queue')

        parsed = []
        malformed = []
        launched = 0

        for item in items:
            name = item.get('name', '')
            if not name.endswith('.json'):
                continue

            try:
                raw = v33.gh_get_strict(self.repo, f'{self.prefix}/jobs/{name}')
                if raw is None:
                    continue
                job = json.loads(raw)
                session = v33.v32.session_of(job, name)
                raw_jid = str(job.get('job_id') or name[:-5])
                jid = v33.v32.normalize_job_id(session, raw_jid)
            except Exception as e:
                rec = {'filename': name, 'error': _short_error(e)}
                try:
                    session, jid = self._infer_filename_identity(name)
                    rec.update(session=session, job_id=jid)
                    self._quarantine_malformed(item, name, e)
                    rec['state'] = 'quarantined'
                except Exception as qe:
                    rec['state'] = 'quarantine-failed'
                    rec['quarantine_error'] = _short_error(qe)
                    self.api_error(qe)
                    malformed.append(rec)
                continue

            with self.lock:
                already_inflight = name in self.inflight
                session_claimed = session in self.claimed

            parsed.append({
                'filename': name,
                'session': session,
                'job_id': jid,
                'state': 'inflight' if already_inflight else ('waiting-session' if session_claimed else 'queued'),
                'sha': str(item.get('sha', '')),
            })

            if already_inflight or session_claimed:
                continue

            with self.lock:
                if name in self.inflight or session in self.claimed:
                    continue
                self.inflight.add(name)
                self.claimed.add(session)
            threading.Thread(
                target=self.worker,
                args=(item, name, raw),
                daemon=True,
                name=f'relay-{session}',
            ).start()
            launched += 1

        # Refresh states after launching workers so ChatGPT sees the same scheduler
        # state the relay is actually using.
        with self.lock:
            inflight_now = set(self.inflight)
            claimed_now = set(self.claimed)
        for rec in parsed:
            if rec['filename'] in inflight_now:
                rec['state'] = 'inflight'
            elif rec['session'] in claimed_now:
                rec['state'] = 'waiting-session'
            else:
                rec['state'] = 'queued'

        try:
            self._publish_queue_manifest(parsed, malformed)
        except Exception as e:
            self.api_error(e)
        return launched


class V34Handler(v33.v32.Handler):
    def do_GET(self):
        p = urllib.parse.urlparse(self.path)
        if p.path != '/health':
            return super().do_GET()
        t = self.server.transport.tstatus()
        active = self.server.runner.snapshot()
        qage = t.get('queue_last_ok_age_s')
        queue_ok = qage is not None and qage < 45
        api_ok = int(t.get('consecutive_api_errors') or 0) < 3
        ok = queue_ok and api_ok and not t.get('stale_claims')
        body = {
            'ok': ok,
            'protocol': v33.v32.PROTOCOL,
            'relay_version': VERSION,
            'host': socket.gethostname(),
            'active': active,
            'sessions': self.server.sessions.snap(),
            'transport': t,
            'health_basis': 'queue+api+claims',
        }
        return self.sendj(200 if ok else 503, body)


def main():
    cfg = v33.v32.readj(v33.v32.CFG_PATH)
    if not cfg:
        raise SystemExit(f'missing {v33.v32.CFG_PATH}')
    cfg['poll_seconds'] = min(int(cfg.get('poll_seconds', 3)), 3)
    cfg['heartbeat_seconds'] = int(cfg.get('heartbeat_seconds', 300))
    import os
    if os.environ.get('BC250_RELAY_HTTP_PORT'):
        cfg['http_port'] = int(os.environ['BC250_RELAY_HTTP_PORT'])
    if os.environ.get('BC250_RELAY_QUEUE_PREFIX'):
        cfg['queue_prefix'] = os.environ['BC250_RELAY_QUEUE_PREFIX']
    if not cfg.get('dashboard_key'):
        cfg['dashboard_key'] = secrets.token_urlsafe(18)
        v33.v32.writej(v33.v32.CFG_PATH, cfg)

    sessions = v33.v32.Sessions()
    runner = v33.v32.Runner(cfg, sessions)
    transport = QueueIndexedTransport(cfg, runner, sessions)
    http = v33.v32.ThreadingHTTPServer(
        (cfg.get('http_host', '127.0.0.1'), int(cfg.get('http_port', 8765))),
        V34Handler,
    )
    http.cfg = cfg
    http.runner = runner
    http.sessions = sessions
    http.transport = transport
    threading.Thread(target=http.serve_forever, daemon=True).start()
    transport.loop()


if __name__ == '__main__':
    main()
