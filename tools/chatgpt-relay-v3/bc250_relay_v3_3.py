#!/usr/bin/env python3
from __future__ import annotations
import hashlib, importlib.util, json, os, secrets, socket, subprocess, threading, time
from importlib.machinery import SourceFileLoader
from pathlib import Path

HOME=Path.home()
V32_PATH=HOME/'.local/bin/bc250-relay-v3.2'
_loader=SourceFileLoader('bc250_relay_v32',str(V32_PATH))
_spec=importlib.util.spec_from_loader(_loader.name,_loader)
if not _spec or not _spec.loader: raise SystemExit(f'cannot load {V32_PATH}')
v32=importlib.util.module_from_spec(_spec); _spec.loader.exec_module(v32)

VERSION='3.3'
INSTANCE=f'{os.getpid()}-{secrets.token_hex(5)}'
STATE_DIR=v32.DATA/'job-state-v33'
STATE_DIR.mkdir(parents=True,exist_ok=True)

_ORIG_PUT=v32.base.gh_put
_ORIG_DELETE=v32.base.gh_delete

def _run_gh(args,timeout=30):
    return subprocess.run(['gh','api',*args],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout,check=False)

def _is_404(p):
    s=(p.stderr or '')+' '+(p.stdout or '')
    return p.returncode!=0 and ('HTTP 404' in s or 'Not Found' in s)

def gh_list_strict(repo,path,retries=3):
    last=''
    for i in range(retries):
        try:
            p=_run_gh([f'repos/{repo}/contents/{path}?per_page=100'],30)
            if p.returncode==0:
                x=json.loads(p.stdout)
                if isinstance(x,list): return x
                raise RuntimeError(f'non-list response for {path}')
            last=(p.stderr or p.stdout or '').strip()
        except Exception as e:last=f'{type(e).__name__}: {e}'
        time.sleep(0.4*(2**i))
    raise RuntimeError(f'GitHub LIST {path} failed: {last[:500]}')

def gh_get_strict(repo,path,retries=3):
    last=''
    for i in range(retries):
        try:
            p=_run_gh([f'repos/{repo}/contents/{path}','-H','Accept: application/vnd.github.raw'],30)
            if p.returncode==0:return p.stdout
            if _is_404(p):return None
            last=(p.stderr or p.stdout or '').strip()
        except Exception as e:last=f'{type(e).__name__}: {e}'
        time.sleep(0.4*(2**i))
    raise RuntimeError(f'GitHub GET {path} failed: {last[:500]}')

def gh_put_retry(repo,path,obj,message,retries=3):
    last=None
    for i in range(retries):
        try:
            _ORIG_PUT(repo,path,obj,message); return
        except Exception as e:last=e; time.sleep(0.5*(2**i))
    raise RuntimeError(f'GitHub PUT {path} failed: {last}')

def gh_delete_retry(repo,path,sha,message,retries=3):
    last=None
    for i in range(retries):
        try:
            _ORIG_DELETE(repo,path,sha,message); return
        except Exception as e:
            last=e
            try:
                if gh_get_strict(repo,path,retries=1) is None:return
            except Exception:pass
            time.sleep(0.5*(2**i))
    raise RuntimeError(f'GitHub DELETE {path} failed: {last}')

v32.base.gh_list=gh_list_strict
v32.base.gh_get_text=gh_get_strict
v32.base.gh_put=gh_put_retry
v32.base.gh_delete=gh_delete_retry
v32.VERSION=VERSION

def _key(s,jid):return f'{s}--{jid}'
def _state_path(s,jid):
    safe=hashlib.sha256(_key(s,jid).encode()).hexdigest()
    return STATE_DIR/f'{safe}.json'
def _read_state(s,jid):return v32.readj(_state_path(s,jid),None)
def _write_state(s,jid,obj):
    obj=dict(obj); obj.update(session=s,job_id=jid,updated_unix=int(time.time()))
    v32.writej(_state_path(s,jid),obj)

def _payload_hash(raw):return hashlib.sha256(raw.encode()).hexdigest()

class ReliableTransport(v32.Transport):
    def __init__(self,cfg,runner,sessions):
        super().__init__(cfg,runner,sessions)
        self.last_queue_ok=0; self.last_control_ok=0; self.api_errors=0; self.last_api_error=''; self.recovered_jobs=0
    def api_ok(self,kind):
        now=int(time.time())
        if kind=='queue':self.last_queue_ok=now
        else:self.last_control_ok=now
        self.api_errors=0; self.last_api_error=''; self.ok()
    def api_error(self,e):
        self.api_errors+=1; self.last_api_error=f'{type(e).__name__}: {e}'; self.last_error=self.last_api_error
    def tstatus(self):
        x=super().tstatus(); now=int(time.time())
        x.update(queue_last_ok_unix=self.last_queue_ok,
                 queue_last_ok_age_s=None if not self.last_queue_ok else now-self.last_queue_ok,
                 control_last_ok_unix=self.last_control_ok,
                 consecutive_api_errors=self.api_errors,
                 last_api_error=self.last_api_error,
                 recovered_jobs=self.recovered_jobs)
        return x
    def hello(self):
        gh_put_retry(self.repo,f'{self.prefix}/status/hello.json',{
            'protocol':v32.PROTOCOL,'relay_version':VERSION,'token':self.cfg['token'],'host':socket.gethostname(),
            'allowed_roots':self.cfg['allowed_roots'],'http_port':self.cfg.get('http_port',8765),
            'sessions':list(v32.SESSIONS),'job_filename':'<session>--<job_id>.json','result_filename':'<session>--<job_id>.json','version':3.3,
            'durable_job_state':True},'relay v3.3 hello')
        self.ok()
    def _publish_confirmed(self,s,jid,result,item,name):
        path=self.result_path(s,jid)
        gh_put_retry(self.repo,path,result,f'relay {s} result {jid}')
        remote=gh_get_strict(self.repo,path)
        if remote is None:raise RuntimeError(f'result verification failed: {path}')
        try:
            parsed=json.loads(remote)
            if str(parsed.get('job_id'))!=str(jid):raise RuntimeError('result verification job_id mismatch')
        except json.JSONDecodeError as e:raise RuntimeError(f'result verification JSON failed: {e}')
        gh_delete_retry(self.repo,f'{self.prefix}/jobs/{name}',str(item.get('sha','')),f'relay consumed {s} {jid}')
        _write_state(s,jid,{'state':'published','result':result,'published_unix':int(time.time())})
        self.ok()
    def worker(self,item,name,raw):
        s='fsr4'; jid=name[:-5]; start=time.time(); result=None; state=None
        try:
            job=json.loads(raw)
            if job.get('protocol')!=v32.PROTOCOL:raise ValueError('wrong protocol')
            if not secrets.compare_digest(str(job.get('token','')),str(self.cfg['token'])):raise PermissionError('token mismatch')
            s=v32.session_of(job,name); job['session']=s
            raw_jid=str(job.get('job_id') or jid); jid=v32.normalize_job_id(s,raw_jid); job['job_id']=jid
            if '--' in name and not name.startswith(s+'--'):raise ValueError('filename/session mismatch')
            if name.startswith(s+'--'):
                file_jid=v32.normalize_job_id(s,name[:-5])
                if file_jid!=jid:raise ValueError(f'filename/job_id mismatch: {file_jid} != {jid}')
            state=_read_state(s,jid)
            if state and state.get('payload_hash') not in (None,_payload_hash(raw)):
                raise RuntimeError('job_id reused with different payload')
            if state and state.get('state') in ('done','published') and state.get('result'):
                result=state['result']; self.recovered_jobs+=1
                self._publish_confirmed(s,jid,result,item,name); return
            if state and state.get('state')=='running' and state.get('instance')!=INSTANCE:
                result={'protocol':v32.PROTOCOL,'relay_version':VERSION,'job_id':jid,'session':s,'host':socket.gethostname(),
                        'status':'error','error':'interrupted_previous_relay_instance; command was not re-executed','result':{},'control':self.sessions.snap(s)}
                _write_state(s,jid,{'state':'done','payload_hash':_payload_hash(raw),'result':result})
                self._publish_confirmed(s,jid,result,item,name); return
            remote=gh_get_strict(self.repo,self.result_path(s,jid))
            if remote is not None:
                gh_delete_retry(self.repo,f'{self.prefix}/jobs/{name}',str(item.get('sha','')),f'relay duplicate consumed {s} {jid}')
                v32.history_add({'unix':int(time.time()),'session':s,'job_id':jid,'status':'duplicate','duration_s':round(time.time()-start,2)})
                return
            allowed,reason=self.sessions.allowed(s)
            result={'protocol':v32.PROTOCOL,'relay_version':VERSION,'job_id':jid,'session':s,'host':socket.gethostname(),'control':self.sessions.snap(s)}
            if not allowed:
                result.update(status='blocked',error=reason,result={})
            else:
                _write_state(s,jid,{'state':'running','instance':INSTANCE,'payload_hash':_payload_hash(raw),'started_unix':int(time.time())})
                try:result.update(status='ok',result=self.runner.execute(job))
                except Exception as e:result.update(status='error',error=f'{type(e).__name__}: {e}',result={})
            _write_state(s,jid,{'state':'done','instance':INSTANCE,'payload_hash':_payload_hash(raw),'result':result})
            self._publish_confirmed(s,jid,result,item,name)
        except Exception as e:
            self.api_error(e)
            if result is not None:
                try:_write_state(s,jid,{'state':'done','instance':INSTANCE,'payload_hash':_payload_hash(raw),'result':result})
                except Exception:pass
        finally:
            v32.history_add({'unix':int(time.time()),'session':s,'job_id':jid,'status':(result or {}).get('status','transport-error'),'duration_s':round(time.time()-start,2)})
            with self.lock:self.inflight.discard(name); self.claimed.discard(s)
    def controls(self):
        items=gh_list_strict(self.repo,f'{self.prefix}/control')
        self.api_ok('control')
        for item in items:
            name=item.get('name','')
            if not name.endswith('.json'):continue
            try:
                raw=gh_get_strict(self.repo,f'{self.prefix}/control/{name}')
                if raw is None:continue
                x=json.loads(raw)
                if x.get('protocol')!=v32.PROTOCOL or not secrets.compare_digest(str(x.get('token','')),str(self.cfg['token'])):raise PermissionError('bad control auth')
                s=v32.session_of(x,name); action=str(x.get('action','')).upper(); msg=self.sessions.apply(s,action,str(x.get('text','')),source='github-control')
                if action=='STOP':self.runner.cancel_session(s)
                gh_put_retry(self.repo,f'{self.prefix}/control-results/{name}',{'protocol':v32.PROTOCOL,'relay_version':VERSION,'status':'ok','session':s,'control':msg,'state':self.sessions.snap(s)},f'relay control {s} {action}')
                gh_delete_retry(self.repo,f'{self.prefix}/control/{name}',str(item.get('sha','')),f'relay consumed control {s}')
            except Exception as e:self.api_error(e)
    def jobs(self):
        self.reconcile_claims()
        items=gh_list_strict(self.repo,f'{self.prefix}/jobs')
        self.last_poll=int(time.time()); self.api_ok('queue')
        launched=0
        for item in items:
            name=item.get('name','')
            if not name.endswith('.json'):continue
            with self.lock:
                if name in self.inflight:continue
            try:
                raw=gh_get_strict(self.repo,f'{self.prefix}/jobs/{name}')
                if raw is None:continue
                s=v32.session_of(json.loads(raw),name)
            except Exception as e:
                self.api_error(e); continue
            with self.lock:
                if s in self.claimed:continue
                self.inflight.add(name); self.claimed.add(s)
            threading.Thread(target=self.worker,args=(item,name,raw),daemon=True,name=f'relay-{s}').start(); launched+=1
        return launched
    def loop(self):
        self.hello(); hb=0; ctl=0
        while True:
            now=time.time()
            if now-ctl>=6:
                try:self.controls()
                except Exception as e:self.api_error(e)
                ctl=now
            try:self.jobs()
            except Exception as e:self.api_error(e)
            now=time.time()
            if now-hb>float(self.cfg.get('heartbeat_seconds',300)):
                try:self.status()
                except Exception as e:self.api_error(e)
                hb=now
            time.sleep(float(self.cfg.get('poll_seconds',3)))

class ReliableHandler(v32.Handler):
    def do_GET(self):
        if self.path.split('?',1)[0]=='/health':
            t=self.server.transport.tstatus()
            qage=t.get('queue_last_ok_age_s')
            queue_ok=(qage is not None and qage < 30)
            ok=queue_ok and not t.get('stale_claims')
            return self.sendj(200 if ok else 503,{'ok':ok,'protocol':v32.PROTOCOL,'relay_version':VERSION,'host':socket.gethostname(),'active':self.server.runner.snapshot(),'sessions':self.server.sessions.snap(),'transport':t})
        return super().do_GET()

def main():
    cfg=v32.readj(v32.CFG_PATH)
    if not cfg:raise SystemExit(f'missing {v32.CFG_PATH}')
    cfg['poll_seconds']=min(int(cfg.get('poll_seconds',3)),3)
    cfg['heartbeat_seconds']=int(cfg.get('heartbeat_seconds',300))
    if os.environ.get('BC250_RELAY_HTTP_PORT'):cfg['http_port']=int(os.environ['BC250_RELAY_HTTP_PORT'])
    if os.environ.get('BC250_RELAY_QUEUE_PREFIX'):cfg['queue_prefix']=os.environ['BC250_RELAY_QUEUE_PREFIX']
    if not cfg.get('dashboard_key'):cfg['dashboard_key']=secrets.token_urlsafe(18); v32.writej(v32.CFG_PATH,cfg)
    sessions=v32.Sessions(); runner=v32.Runner(cfg,sessions); transport=ReliableTransport(cfg,runner,sessions)
    http=v32.ThreadingHTTPServer((cfg.get('http_host','127.0.0.1'),int(cfg.get('http_port',8765))),ReliableHandler)
    http.cfg=cfg; http.runner=runner; http.sessions=sessions; http.transport=transport
    threading.Thread(target=http.serve_forever,daemon=True).start(); transport.loop()

if __name__=='__main__':main()
