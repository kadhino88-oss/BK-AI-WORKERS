"""Envoi d'emails transactionnels (mot de passe oublie...).

Ordre :
  1. SMTP dedie si BK_SMTP_HOST est defini (recommande en production :
     une adresse du type contact@votre-domaine). Variables : BK_SMTP_HOST,
     BK_SMTP_PORT (587 par defaut, STARTTLS), BK_SMTP_USER, BK_SMTP_PASSWORD,
     BK_SMTP_FROM.
  2. Sinon, l'API Gmail via le compte Google du proprietaire (bridge
     PowerShell Mailer-Bridge.ps1), deja connecte.
Ne leve jamais d'exception : renvoie (ok, erreur).
"""
import os
import re
import smtplib
import ssl
from email.message import EmailMessage
from email.utils import formataddr, formatdate, make_msgid

_ADDR = re.compile(r"^[^@\s<>\",;]+@[^@\s<>\",;]+\.[^@\s<>\",;]{2,}$")
FROM_NAME = "BK-AI-WORKERS"


def is_valid_address(addr):
    return bool(addr) and bool(_ADDR.match(addr)) and len(addr) <= 254


def _send_smtp(to, subject, html, text):
    host = os.environ.get("BK_SMTP_HOST", "").strip()
    port = int(os.environ.get("BK_SMTP_PORT", "587") or 587)
    user = os.environ.get("BK_SMTP_USER", "").strip()
    password = os.environ.get("BK_SMTP_PASSWORD", "")
    sender = os.environ.get("BK_SMTP_FROM", "").strip() or user
    if not is_valid_address(sender):
        return False, "SMTP_FROM_INVALID"
    msg = EmailMessage()
    msg["From"] = formataddr((FROM_NAME, sender))
    msg["To"] = to
    msg["Subject"] = subject
    msg["Date"] = formatdate(localtime=False)
    msg["Message-ID"] = make_msgid(domain=sender.split("@")[-1])
    msg.set_content(text or re.sub(r"<[^>]+>", "", html))
    msg.add_alternative(html, subtype="html")
    ctx = ssl.create_default_context()
    try:
        if port == 465:
            with smtplib.SMTP_SSL(host, port, context=ctx, timeout=20) as s:
                if user:
                    s.login(user, password)
                s.send_message(msg)
        else:
            with smtplib.SMTP(host, port, timeout=20) as s:
                s.starttls(context=ctx)
                if user:
                    s.login(user, password)
                s.send_message(msg)
        return True, None
    except (smtplib.SMTPException, OSError) as e:
        return False, "SMTP_" + type(e).__name__


def send_email(to, subject, html, text=None, gmail_bridge=None):
    if not is_valid_address(to):
        return False, "INVALID_RECIPIENT"
    subject = re.sub(r"[\r\n]+", " ", subject or "")[:200]
    if os.environ.get("BK_SMTP_HOST"):
        return _send_smtp(to, subject, html, text)
    if gmail_bridge is None:
        return False, "NO_MAIL_TRANSPORT"
    res = gmail_bridge({"to": to, "subject": subject, "html": html, "fromName": FROM_NAME})
    return bool(res.get("ok")), (None if res.get("ok") else str(res.get("error") or "MAIL_FAILED")[:80])


def brand_email(title, intro_html, button_label=None, button_url=None, footer_html=""):
    """Gabarit HTML sobre aux couleurs du site (or sur fond sombre)."""
    button = ""
    if button_label and button_url:
        button = (f'<p style="margin:26px 0"><a href="{button_url}" style="background:#c8973a;color:#fff;'
                  f'text-decoration:none;padding:13px 26px;border-radius:999px;font-weight:700;display:inline-block">'
                  f'{button_label}</a></p>')
    return f"""<!doctype html><html><body style="margin:0;background:#f6f5f1;font-family:Arial,Helvetica,sans-serif;color:#1a1a1f">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0"><tr><td align="center" style="padding:28px 12px">
<table role="presentation" width="560" cellpadding="0" cellspacing="0" style="max-width:560px;width:100%;background:#fff;border-radius:18px;overflow:hidden">
<tr><td style="background:#14151a;padding:22px 28px;color:#e2b254;font-weight:700;letter-spacing:.04em">BK-AI-WORKERS</td></tr>
<tr><td style="padding:30px 28px;line-height:1.6;font-size:15px"><h1 style="font-size:21px;margin:0 0 14px">{title}</h1>{intro_html}{button}
<p style="color:#7a7d86;font-size:12.5px;margin-top:22px">{footer_html}</p></td></tr></table></td></tr></table></body></html>"""
