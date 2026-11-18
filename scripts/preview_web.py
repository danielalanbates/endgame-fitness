# Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
# Local QA only. This server never creates an authenticated session.
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import json
root=Path(__file__).resolve().parent.parent/'Web'/'local-app'
class Handler(SimpleHTTPRequestHandler):
 def __init__(self,*a,**kw):super().__init__(*a,directory=str(root),**kw)
 def do_GET(self):
  if self.path.startswith('/api/endgame/'):
   name=self.path.split('?')[0].rsplit('/',1)[-1]
   body={'providers':['google','apple'],'provider':'batesai-membership'} if name=='config' else {'error':'Sign in with your BatesAI account to continue'}
   self.send_response(200 if name=='config' else 401);self.send_header('Content-Type','application/json');self.end_headers();self.wfile.write(json.dumps(body).encode());return
  super().do_GET()
ThreadingHTTPServer(('127.0.0.1',4318),Handler).serve_forever()
