"""Canal WhatsApp (2026-09-25) : parler a Chloé depuis WhatsApp.

Fonctionnement (WhatsApp Business Cloud API de Meta) :
  1. Le client clique "Lier mon WhatsApp" dans l'application : un code a 6
     chiffres est genere et WhatsApp s'ouvre avec le message "LIER 123456"
     deja ecrit, adresse au numero BK-AI-WORKERS.
  2. Il envoie ce message : son numero est rattache a SON compte.
  3. Ensuite chaque message texte qu'il envoie est traite comme une mission
     confiee a Chloé (memes credits, memes regles, meme validation humaine
     des actions sensibles) et la reponse revient sur WhatsApp.

Securite : chaque appel de Meta est authentifie par la signature HMAC
(X-Hub-Signature-256, secret d'application) — sans elle, rien n'est traite.
Les secrets viennent uniquement de l'environnement (.env), jamais du code.

Variables d'environnement (voir deploy/set-whatsapp-secrets.py) :
  WHATSAPP_VERIFY_TOKEN, WHATSAPP_ACCESS_TOKEN, WHATSAPP_PHONE_NUMBER_ID,
  WHATSAPP_APP_SECRET, WHATSAPP_DISPLAY_NUMBER (ex. 41791234567, chiffres seuls)
"""
import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import time
import urllib.request
import urllib.error
import datetime

GRAPH_VERSION = "v21.0"
CODE_TTL_SECONDS = 15 * 60
MAX_MSGS_PER_HOUR = 30
MAX_INBOUND_CHARS = 2000
WA_MAX_CHARS = 3800

_LOCK = threading.Lock()
_SEEN_IDS = []          # anti-doublon (Meta renvoie parfois un message deux fois)
_RATE = {}              # phone -> [timestamps]


def _env(name):
    return (os.environ.get(name) or "").strip()


def is_enabled():
    return all(_env(n) for n in ("WHATSAPP_VERIFY_TOKEN", "WHATSAPP_ACCESS_TOKEN",
                                 "WHATSAPP_PHONE_NUMBER_ID", "WHATSAPP_APP_SECRET"))


def display_number():
    return re.sub(r"\D", "", _env("WHATSAPP_DISPLAY_NUMBER"))


class Store:
    def __init__(self, path, load_json):
        self.path = path
        self._load_json = load_json

    def _read(self):
        data = self._load_json(self.path, {}) or {}
        data.setdefault("links", {})
        data.setdefault("codes", {})
        return data

    def _write(self, data):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp, self.path)

    def create_code(self, client_id):
        with _LOCK:
            data = self._read()
            now = time.time()
            data["codes"] = {c: v for c, v in data["codes"].items()
                             if v["expiry"] > now and v["clientId"] != client_id}
            code = "".join(secrets.choice("0123456789") for _ in range(6))
            while code in data["codes"]:
                code = "".join(secrets.choice("0123456789") for _ in range(6))
            data["codes"][code] = {"clientId": client_id, "expiry": now + CODE_TTL_SECONDS}
            self._write(data)
            return code

    def redeem(self, code, phone):
        with _LOCK:
            data = self._read()
            entry = data["codes"].pop(code, None)
            if not entry or entry["expiry"] < time.time():
                self._write(data)
                return None
            # un client = un numero : on remplace l'ancien rattachement
            data["links"] = {p: v for p, v in data["links"].items() if v["clientId"] != entry["clientId"]}
            data["links"][phone] = {"clientId": entry["clientId"],
                                    "atUtc": datetime.datetime.utcnow().isoformat() + "Z"}
            self._write(data)
            return entry["clientId"]

    def client_for(self, phone):
        return (self._read()["links"].get(phone) or {}).get("clientId")

    def phone_for(self, client_id):
        for phone, v in self._read()["links"].items():
            if v["clientId"] == client_id:
                return phone
        return None

    def unlink_client(self, client_id):
        with _LOCK:
            data = self._read()
            data["links"] = {p: v for p, v in data["links"].items() if v["clientId"] != client_id}
            self._write(data)

    def unlink_phone(self, phone):
        with _LOCK:
            data = self._read()
            removed = data["links"].pop(phone, None)
            self._write(data)
            return removed is not None


def mask_phone(phone):
    return ("+" + phone[:2] + " ••• •• " + phone[-2:]) if phone and len(phone) > 6 else "•••"


def verify_signature(raw_body, header):
    secret = _env("WHATSAPP_APP_SECRET")
    if not secret or not header or not header.startswith("sha256="):
        return False
    expected = hmac.new(secret.encode("utf-8"), raw_body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header[len("sha256="):])


def verify_challenge(query):
    """GET de verification lors de l'enregistrement du webhook chez Meta."""
    mode = (query.get("hub.mode") or [""])[0]
    token = (query.get("hub.verify_token") or [""])[0]
    challenge = (query.get("hub.challenge") or [""])[0]
    expected = _env("WHATSAPP_VERIFY_TOKEN")
    if mode == "subscribe" and expected and hmac.compare_digest(token, expected):
        return challenge
    return None


def to_whatsapp_format(text):
    """Markdown des Workers -> mise en forme WhatsApp (*gras*, _italique_)."""
    t = str(text or "")
    t = re.sub(r"^#{1,6}\s*(.+)$", r"*\1*", t, flags=re.M)
    t = re.sub(r"\*\*(.+?)\*\*", r"*\1*", t)
    t = re.sub(r"^\s*[-•]\s+", "• ", t, flags=re.M)
    return t.strip()


def send_text(to_phone, text):
    url = f"https://graph.facebook.com/{GRAPH_VERSION}/{_env('WHATSAPP_PHONE_NUMBER_ID')}/messages"
    text = to_whatsapp_format(text) or "…"
    chunks = [text[i:i + WA_MAX_CHARS] for i in range(0, len(text), WA_MAX_CHARS)][:4]
    for chunk in chunks:
        payload = json.dumps({"messaging_product": "whatsapp", "to": to_phone, "type": "text",
                              "text": {"body": chunk, "preview_url": False}}).encode("utf-8")
        req = urllib.request.Request(url, data=payload, method="POST", headers={
            "Authorization": "Bearer " + _env("WHATSAPP_ACCESS_TOKEN"),
            "Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req, timeout=20).read()
        except (urllib.error.URLError, OSError):
            return False
    return True


def _rate_ok(phone):
    now = time.time()
    recent = [t for t in _RATE.get(phone, []) if now - t < 3600]
    if len(recent) >= MAX_MSGS_PER_HOUR:
        _RATE[phone] = recent
        return False
    _RATE[phone] = recent + [now]
    return True


def _handle_message(phone, text, store, deps):
    upper = text.strip().upper()
    m = re.match(r"^(LIER|LINK|VINCULAR)\s+(\d{6})$", upper)
    if m:
        client_id = store.redeem(m.group(2), phone)
        if client_id:
            deps["log_activity"]("whatsapp", clientId=client_id)
            send_text(phone, "✅ WhatsApp lié à votre compte BK-AI-WORKERS. Écrivez-moi ce que vous voulez confier à l'équipe — j'y réponds ici. Envoyez STOP pour délier.")
        else:
            send_text(phone, "Ce code est invalide ou expiré. Générez-en un nouveau depuis l'application (Automatisations → WhatsApp).")
        return
    if upper in ("STOP", "DELIER", "UNLINK"):
        send_text(phone, "Votre WhatsApp a été délié de votre compte." if store.unlink_phone(phone)
                  else "Ce numéro n'est lié à aucun compte.")
        return
    client_id = store.client_for(phone)
    if not client_id:
        send_text(phone, "Bonjour ! Pour me parler ici, liez d'abord votre compte : dans l'application BK-AI-WORKERS, ouvrez Automatisations → WhatsApp → « Lier mon WhatsApp ».")
        return
    if not _rate_ok(phone):
        send_text(phone, "Vous envoyez beaucoup de messages : patientez un peu avant de continuer.")
        return
    block = deps["subscription_blocks_mission"](client_id)
    if block:
        send_text(phone, "Votre abonnement ne permet pas de lancer cette mission pour le moment : " + str(block))
        return
    result = deps["submit_task"](text[:MAX_INBOUND_CHARS], worker_id="chloe", client_id=client_id)
    result = deps["attach_pending_action"](result)
    # Offre "Worker a l'unite" : le Worker demande n'est pas embauche -> on le dit clairement plutot que "reessayez" (aucune mission lancee).
    if isinstance(result, dict) and (result.get("error") == "WORKER_NOT_INCLUDED" or result.get("Status") == "WORKER_NOT_INCLUDED"):
        send_text(phone, str(result.get("detail") or result.get("FinalSynthesis") or "Ce Worker ne fait pas partie de votre forfait.")[:1500])
        return
    if not isinstance(result, dict) or result.get("error") or result.get("Status") != "SUCCESS":
        send_text(phone, "Je n'ai pas pu traiter cette demande pour le moment. Réessayez dans un instant.")
        return
    reply = result.get("FinalSynthesis") or "Mission terminée."
    if result.get("pendingAction"):
        reply += "\n\n⚠️ Une action sensible attend votre confirmation dans l'application avant d'être exécutée."
    send_text(phone, reply)


def handle_webhook_payload(payload, store, deps):
    """Extrait les messages texte et les traite en arriere-plan (Meta exige
    une reponse HTTP rapide ; une mission peut durer plusieurs dizaines de s)."""
    for entry in (payload.get("entry") or []):
        for change in (entry.get("changes") or []):
            value = change.get("value") or {}
            for msg in (value.get("messages") or []):
                mid, phone = msg.get("id"), re.sub(r"\D", "", msg.get("from") or "")
                if not mid or not phone:
                    continue
                with _LOCK:
                    if mid in _SEEN_IDS:
                        continue
                    _SEEN_IDS.append(mid)
                    del _SEEN_IDS[:-500]
                if msg.get("type") != "text":
                    threading.Thread(target=send_text, args=(phone, "Pour l'instant je ne lis que les messages texte."), daemon=True).start()
                    continue
                body = ((msg.get("text") or {}).get("body") or "").strip()
                if body:
                    threading.Thread(target=_safe_handle, args=(phone, body, store, deps), daemon=True).start()


def _safe_handle(phone, body, store, deps):
    try:
        _handle_message(phone, body, store, deps)
    except Exception:
        try:
            send_text(phone, "Une erreur est survenue de mon côté. Réessayez dans un instant.")
        except Exception:
            pass
