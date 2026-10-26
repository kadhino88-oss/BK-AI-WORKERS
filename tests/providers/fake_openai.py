# -*- coding: utf-8 -*-
"""Faux serveur OpenAI-compatible (bibliotheque standard) pour tester l'adaptateur et le routeur SANS reseau externe et SANS cout.

    srv = FakeOpenAI(script=[...], token=None, supports_tools=True)   # demarre sur 127.0.0.1:<port libre>
    srv.url          -> "http://127.0.0.1:PORT"      (l'adaptateur ajoute /v1)
    srv.requests     -> corps JSON de chaque POST /v1/chat/completions recu (+ "_auth": True/False selon l'en-tete, jamais le jeton)
    srv.stop()

`script` : liste de reponses consommees dans l'ordre pour chaque POST (la derniere est repetee quand la liste est epuisee, sauf "once") :
    {"content": "texte"}                                           reponse finale
    {"tool_calls": [{"name": "web_fetch", "arguments": {...}}]}    appel d'outil NATIF (arguments en chaine JSON, comme OpenAI)
    {"tool_calls_object_args": [...]}                              idem avec arguments en OBJET (certains serveurs)
    {"tool_calls_raw": [{"name": "x", "arguments": "{pas du json"}]}   arguments illisibles
    {"content": "{\\"tool\\": ...}"}                                 appel d'outil ECRIT en texte (modele sans appel natif)
    {"status": 402, "error": "..."}                                erreur HTTP avec corps JSON
    {"sleep": 2.0, ...}                                            attend avant de repondre (delai)
    {"raw": "<corps brut>", "status": 200}                         corps non JSON
    {"usage": [prompt, completion]}                                jetons annonces
Les requetes recues sont journalisees ; GET /v1/models et /api/tags renvoient la liste `models`.
"""
import http.server
import json
import threading
import time


class FakeOpenAI:
    def __init__(self, script=None, token=None, supports_tools=True, models=None, host="127.0.0.1", port=0, search_results=None):
        self.script = list(script or [{"content": "ok"}])
        self.token = token
        self.supports_tools = supports_tools
        self.models = models or ["fake-model:latest"]
        self.search_results = search_results if search_results is not None else [
            {"title": "Mairie de Lyon", "url": "https://www.lyon.fr/", "content": "Horaires d'ouverture de la mairie."}]
        self.requests = []
        self.gets = []
        self._i = 0
        self._lock = threading.Lock()
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _send(self, status, payload, raw=None):
                body = raw.encode("utf-8") if raw is not None else json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except OSError:
                    pass

            def _authorized(self):
                if outer.token is None:
                    return True
                return self.headers.get("Authorization", "") == "Bearer " + outer.token

            def do_GET(self):
                outer.gets.append({"path": self.path, "_auth": self._authorized()})
                if not self._authorized():
                    self._send(401, {"error": {"message": "Incorrect API key provided"}})
                elif self.path.startswith("/search?"):
                    self._send(200, {"results": outer.search_results})
                elif self.path.rstrip("/") in ("/v1/models", "/api/tags", "/openai/v1/models"):
                    self._send(200, {"object": "list", "data": [{"id": m, "object": "model"} for m in outer.models],
                                     "models": [{"name": m} for m in outer.models]})
                else:
                    self._send(404, {"error": "nf"})

            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0) or 0)
                raw = self.rfile.read(length) if length else b"{}"
                try:
                    body = json.loads(raw.decode("utf-8"))
                except ValueError:
                    body = {}
                body["_auth"] = self._authorized()
                body["_path"] = self.path
                rejected = bool(body.get("tools")) and not outer.supports_tools and body["_auth"]
                with outer._lock:
                    outer.requests.append(body)
                    idx = outer._i
                    if not rejected:                  # une requete refusee (« n'accepte pas les outils ») ne consomme pas le scenario
                        outer._i += 1
                if not body["_auth"]:
                    self._send(401, {"error": {"message": "Incorrect API key provided", "type": "invalid_request_error"}})
                    return
                if not self.path.endswith("/chat/completions"):
                    self._send(404, {"error": "nf"})
                    return
                if rejected:
                    self._send(400, {"error": {"message": "registry.ollama.ai/library/%s does not support tools" % body.get("model", "x"),
                                               "type": "invalid_request_error"}})
                    return
                step = outer.script[min(idx, len(outer.script) - 1)]
                if step.get("sleep"):
                    time.sleep(float(step["sleep"]))
                if step.get("status") and int(step["status"]) >= 400:
                    self._send(int(step["status"]), {"error": {"message": step.get("error", "boom"), "type": "x"}})
                    return
                if "raw" in step:
                    self._send(int(step.get("status", 200)), None, raw=step["raw"])
                    return
                message = {"role": "assistant", "content": step.get("content", "")}
                finish = "stop"
                calls = step.get("tool_calls") or step.get("tool_calls_object_args") or step.get("tool_calls_raw")
                if calls:
                    out = []
                    for n, c in enumerate(calls):
                        args = c.get("arguments", {})
                        if "tool_calls_raw" in step:
                            arg_val = args
                        elif "tool_calls_object_args" in step:
                            arg_val = args
                        else:
                            arg_val = json.dumps(args)
                        out.append({"id": c.get("id", "call_%d_%d" % (idx, n)), "type": "function", "function": {"name": c["name"], "arguments": arg_val}})
                    message = {"role": "assistant", "content": step.get("content") or None, "tool_calls": out}
                    finish = "tool_calls"
                usage = step.get("usage") or [120, 30]
                self._send(200, {"id": "chatcmpl-%d" % idx, "object": "chat.completion", "created": int(time.time()), "model": body.get("model", "fake"),
                                 "choices": [{"index": 0, "message": message, "finish_reason": finish}],
                                 "usage": {"prompt_tokens": usage[0], "completion_tokens": usage[1], "total_tokens": usage[0] + usage[1]}})

        self.httpd = http.server.ThreadingHTTPServer((host, port), H)
        self.httpd.daemon_threads = True
        self.port = self.httpd.server_address[1]
        self.url = "http://%s:%d" % (host, self.port)
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def chat_requests(self):
        return [r for r in self.requests if r.get("_path", "").endswith("/chat/completions")]
