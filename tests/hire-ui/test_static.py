# -*- coding: utf-8 -*-
"""Garde-fous statiques de l'interface « Worker a l'unite » (assistant d'installation, embauche, Mes Workers installes), sans navigateur.

  - dashboard/app.js, i18n-en-app.js : syntaxe valide (node --check) ; fins de ligne CRLF conservees ;
  - tous les identifiants HTML utilises par le code existent dans index.html ;
  - toutes les routes appelees par l'interface existent dans dashboard/server.py (et reciproquement, le contrat de docs/HIRE-API.md est couvert) ;
  - honnetete : aucun prix, aucun numero de telephone / WhatsApp / e-mail presente comme disponible, jamais d'« Autonome » sans test de risque ;
  - securite : tout texte de serveur ou de client passe par escapeHtml avant d'entrer dans innerHTML ;
  - anglais : chaque texte francais statique de l'interface a une traduction dans i18n-en-app.js (les textes venant des profils restent en francais) ;
  - petits ecrans : l'assistant passe en plein ecran sous 720 px et reste sous la fenetre « Connecter un outil » ;
  - un chemin d'ecriture unique : aucune activation ni suppression sans geste du client (pas d'appel automatique a /status ou /delete au chargement).

Lancer : python tests/hire-ui/test_static.py      (python 3 ; node facultatif pour la verification de syntaxe et du dictionnaire)
"""
import json
import os
import re
import shutil
import subprocess
import sys

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
D = os.path.join(REPO, "dashboard")
failures = []


def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + (f"  [{detail}]" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def read(path):
    with open(path, "rb") as f:
        return f.read().decode("utf-8")


APP = read(os.path.join(D, "app.js"))
HTML = read(os.path.join(D, "index.html"))
CSS = read(os.path.join(D, "style.css"))
I18N = read(os.path.join(D, "i18n-en-app.js"))
SERVER = read(os.path.join(D, "server.py"))
A = APP.index("// ===== HIRE-UI BEGIN")
B = APP.index("// ===== HIRE-UI END")
BLOCK = APP[A:B].replace("\r\n", "\n")


# ------------------------------------------------------------------ outils d'analyse
def js_strings(code):
    """Litteraux de chaines JS ('...', "...", `...`) du code (commentaires ignores) : liste de (type, contenu brut). Les gabarits sont rendus sans
    leurs ${...} (les expressions imbriquees sont analysees a part, comme des gabarits a part entiere)."""
    out = []
    i, n = 0, len(code)

    def scan_template(i):
        """i pointe apres le ` ouvrant ; renvoie (indice apres le ` fermant, texte statique)."""
        buf = []
        while i < n:
            c = code[i]
            if c == "\\":
                buf.append(code[i:i + 2])
                i += 2
            elif c == "`":
                return i + 1, "".join(buf)
            elif c == "$" and code[i + 1:i + 2] == "{":
                buf.append("\x00")
                depth, i = 1, i + 2
                while i < n and depth:
                    ch = code[i]
                    if ch in "\"'":
                        q, i = ch, i + 1
                        while i < n and code[i] != q:
                            i += 2 if code[i] == "\\" else 1
                        i += 1
                    elif ch == "`":
                        i, inner = scan_template(i + 1)
                        out.append(("tpl", inner))
                    else:
                        depth += 1 if ch == "{" else (-1 if ch == "}" else 0)
                        i += 1
            else:
                buf.append(c)
                i += 1
        return i, "".join(buf)

    while i < n:
        c = code[i]
        if code.startswith("//", i):
            i = code.find("\n", i)
            i = n if i < 0 else i
        elif code.startswith("/*", i):
            i = code.find("*/", i) + 2
        elif c in "\"'":
            j = i + 1
            while j < n and code[j] != c:
                j += 2 if code[j] == "\\" else 1
            out.append(("str", code[i + 1:j]))
            i = j + 1
        elif c == "`":
            i, text = scan_template(i + 1)
            out.append(("tpl", text))
        elif c == "/" and re.match(r"/[^/*\s].*?/[gimsuy]*[.,;)\s]", code[i:i + 200]) and re.search(r"[(=,:!&|?]\s*$", code[max(0, i - 3):i]):
            m = re.match(r"/(?:\\.|\[[^\]]*\]|[^/\\\n])+/[gimsuy]*", code[i:])
            i += m.end() if m else 1
        else:
            i += 1
    return out


def unescape_js(s):
    return re.sub(r"\\(.)", r"\1", s)


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


FRENCH = re.compile(r"[À-ÿœ]|\b(?:le|la|les|vous|votre|vos|ce|cette|des|une|un|pas|pour|sans|avec|dans|est|sont|ne|du|au|aux|de|et|ou)\b", re.I)
TAG_TEXT = re.compile(r">([^<>\x00]*)(?=<)")


def ui_strings(code):
    """Textes francais statiques visibles : texte entre balises des gabarits HTML + litteraux (affectes a textContent, toasts, titres...)."""
    found = set()
    for kind, raw in js_strings(code):
        text = unescape_js(raw)
        if kind == "tpl" or "<" in text:
            for m in TAG_TEXT.finditer(text.replace("\x00", "\x00")):
                t = norm(m.group(1))
                if t and re.search(r"[A-Za-zÀ-ÿ]{3,}", t):
                    found.add(t)
            # texte en tete ou en queue d'un gabarit sans balise autour
            head = norm(re.split(r"<|\x00", text)[0])
            if kind == "tpl" and "<" not in text and head and re.search(r"[A-Za-zÀ-ÿ]{3,}", head):
                found.add(head)
        else:
            t = norm(text)
            if " " in t and FRENCH.search(t) and not re.search(r"[#.\[\]=/_]|^\s*$|^[A-Z_]+$", t.split(" ")[0]):
                found.add(t)
    return found


# ------------------------------------------------------------------ 1. syntaxe et fins de ligne
node = shutil.which("node")
if node:
    for name in ("app.js", "i18n-en-app.js"):
        p = subprocess.run([node, "--check", os.path.join(D, name)], capture_output=True)
        check(f"dashboard/{name} : syntaxe valide (node --check)", p.returncode == 0, p.stderr.decode("utf-8", "replace")[:200])
else:
    print("  SKIP  node absent : syntaxe non verifiee")
for name in ("app.js", "index.html", "style.css", "i18n-en-app.js"):
    raw = open(os.path.join(D, name), "rb").read()
    check(f"dashboard/{name} : fins de ligne CRLF conservees (aucune ligne LF seule)", raw.count(b"\n") == raw.count(b"\r\n"))
    check(f"dashboard/{name} : pas de BOM", not raw.startswith(b"\xef\xbb\xbf"))

# ------------------------------------------------------------------ 2. identifiants HTML
ids_used = set(re.findall(r"getElementById\(\"([a-z0-9-]+)\"\)", BLOCK))
ids_in_html = set(re.findall(r'id="([A-Za-z0-9_-]+)"', HTML))
ids_made_by_js = set(re.findall(r'\bid="(iw-[a-z0-9-]+)"', BLOCK)) | set(re.findall(r"\.id = \"(iw-[a-z0-9-]+)\"", BLOCK)) | set(re.findall(r"\bid=\"(iw-[a-z0-9-]+)\"", BLOCK))
missing = sorted(i for i in ids_used if i not in ids_in_html and i not in ids_made_by_js and not i.startswith("iw-"))
check("identifiants lus par l'interface presents dans index.html", not missing, str(missing))
for must in ("install-block", "install-title", "install-panel", "installed-workers-section", "installed-workers-summary", "installed-workers-list", "admin-hire-list", "admin-grant-card"):
    check(f"index.html : #{must}", f'id="{must}"' in HTML)
check("« Mes Workers installes » est dans le contenu de la page Facturation (sous #billing-content)",
      HTML.index('id="installed-workers-section"') > HTML.index('id="billing-content"') and HTML.index('id="installed-workers-section"') < HTML.index('id="admin-view"'))
check("la liste survit au remplacement du contenu du proprietaire (loadBilling re-ajoute la section)", "appendChild(installedSection)" in APP)

# ------------------------------------------------------------------ 3. routes
called = set(re.findall(r"[`\"'](/api/(?:installations|workers|admin/grant-workers)[^`\"'?]*)", BLOCK))
norm_routes = set()
for r in called:
    r = re.sub(r"\$\{[^}]*\}", "<id>", r)
    norm_routes.add(r)
expected = {"/api/installations", "/api/installations/status", "/api/installations/delete", "/api/workers/hired", "/api/workers/hire",
            "/api/workers/<id>/install-profile", "/api/workers/<id>/hire-request", "/api/admin/grant-workers"}
check("l'interface appelle toutes les routes du contrat docs/HIRE-API.md", expected <= norm_routes, str(sorted(expected - norm_routes)))
server_paths = ['"/api/installations"', '"/api/installations/status"', '"/api/installations/delete"', '"/api/workers/hired"', '"/api/workers/hire"',
                '"/api/admin/grant-workers"', 'endswith("/hire-request")', 'endswith("/install-profile")']
check("ces routes existent dans dashboard/server.py", all(p in SERVER for p in server_paths), str([p for p in server_paths if p not in SERVER]))
check("les missions passent par le chemin existant (/task/async puis /api/missions/async/<job>)",
      '"/task"' in BLOCK or "/task`" in BLOCK or "/task\"" in BLOCK)
check("l'essai a blanc et la fiche du Worker partagent submitMissionAndWait", APP.count("submitMissionAndWait(") >= 3, str(APP.count("submitMissionAndWait(")))

# ------------------------------------------------------------------ 4. honnetete
check("aucun prix ni devise dans l'interface d'installation/embauche (la page Tarifs n'affiche pas Solo/Trio)", not re.search(r"CHF|€|EUR\b|\$\d|\b\d+\s?(?:/ ?mois|par mois)", BLOCK))
check("jamais de « priceChf » lu par l'interface", "priceChf" not in APP and "workerPlans" not in APP)
for word in ("téléphone", "whatsapp"):
    for kind, raw in js_strings(BLOCK):
        t = unescape_js(raw).lower()
        if word in t and kind != "tpl" or (kind == "tpl" and word in t):
            ok = "pas encore" in t or "bientôt" in t or "prévu" in t or t.strip() == word       # libelle de canal seul (IW_CHANNEL_LABELS)
            check(f"« {word} » n'apparait que dans une phrase « pas encore disponible » ou comme libelle de canal « bientôt »", ok, raw[:120])
check("un canal prevu est toujours marque « bientôt » (jamais present comme disponible)", "iw-chip-soon" in BLOCK and "<em>bientôt</em>" in BLOCK)
check("seuls les canaux reellement disponibles sont envoyes au serveur", "iwLiveChannelsOf(def, profile, liveChannels)" in BLOCK and 'support[c] === "available"' in BLOCK)
check("« Autonome » (auto) est filtre sur le risque faible", 'm.id !== "auto" || (rule && rule.risk === "low")' in BLOCK)
check("l'interface affiche la regle de la plateforme (envoyer, publier, payer, supprimer, appeler)", "envoyer, publier, payer, supprimer et appeler demandent toujours votre validation" in BLOCK)
check("l'interface ne promet pas de reponse du proprietaire (« recontacte », « revient vers vous »)", not re.search(r"recontacte|revient vers vous|sous 24|rapidement", BLOCK))
check("aucun mot de certification (garde-fou tests/trust)", not re.search(r"certifi|audité|conforme (?:au|à) (?:rgpd|iso|soc)|ISO ?27001|SOC ?2", BLOCK, re.I))
check("aucun avis, temoignage ou nombre de clients invente", not re.search(r"témoignage|clients? nous font confiance|\b\d+\s+clients\b", BLOCK, re.I))
check("l'activation exige un geste (aucun appel a /status au chargement) : iwSetStatus n'est appele que depuis des gestionnaires",
      all(re.search(r"(addEventListener|=>\s*\{|async function|function )", ctx) for ctx in re.findall(r".{0,200}iwSetStatus\(", BLOCK, re.S)))
check("la suppression d'une installation demande une confirmation", "confirm(iwT(" in BLOCK)

# ------------------------------------------------------------------ 5. securite : escapeHtml
def strip_escape_calls(expr):
    out, i = [], 0
    while i < len(expr):
        if expr.startswith("escapeHtml(", i):
            depth, i = 1, i + len("escapeHtml(")
            while i < len(expr) and depth:
                depth += 1 if expr[i] == "(" else (-1 if expr[i] == ")" else 0)
                i += 1
            out.append("ESC")
        else:
            out.append(expr[i])
            i += 1
    return "".join(out)


def interpolations(code):
    res, i = [], 0
    while True:
        j = code.find("${", i)
        if j < 0:
            return res
        depth, k = 1, j + 2
        while k < len(code) and depth:
            depth += 1 if code[k] == "{" else (-1 if code[k] == "}" else 0)
            k += 1
        res.append(code[j + 2:k - 1])
        i = j + 2 if False else k


# valeurs qui ne vont que dans un toast (textContent) : jamais interpretees comme du HTML
TOAST_ONLY = {"r.planName", "clientLabel"}
RISKY = re.compile(r"\.(label|description|help|example|message|detail|tagline|idealFor|workerName|clientLabel|email|notes|error|title|text|msg|field|svc|what|requestId|planName|category|provider)\b|\bnotes\b|\blabel\b|\bmsg\b|\bd\.label\b")
bad = []
for expr in interpolations(BLOCK):
    rest = strip_escape_calls(expr)
    # les gabarits imbriques sont analyses a part (leurs propres ${...}) : on retire leurs litteraux
    rest = re.sub(r"`[^`]*`", "``", rest)
    rest = re.sub(r"[\w.]+(?:\s*\|\|\s*[\w.]+)?\s*(?:\?|&&)", " ", rest)          # une condition (« x.tagline ? ... ») n'affiche rien
    if expr.strip() in TOAST_ONLY:
        continue
    if RISKY.search(rest):
        bad.append(expr.strip()[:90])
check("aucun texte de serveur / de client n'entre dans un gabarit HTML sans escapeHtml", not bad, str(bad[:5]))
check("le message du client dans la vue proprietaire est echappe", "escapeHtml(r.message)" in BLOCK)
check("le nom de l'entreprise (libelle de client) est echappe dans la liste des comptes de la vue proprietaire", "escapeHtml(c.label)" in APP and "${c.label}" not in APP)
check("aucun eval / document.write / insertAdjacentHTML dans le bloc", not re.search(r"\beval\(|document\.write|insertAdjacentHTML|new Function", BLOCK))
check("aucun secret conserve dans le navigateur (localStorage de la fiche interdit)", not re.search(r"localStorage\.setItem\([^)]*(?:knowledge|state|installation|fiche)", BLOCK))
check("l'identifiant de retour OAuth ne contient que le Worker et l'etape (sessionStorage)", re.search(r"sessionStorage\.setItem\(IW_RETURN_KEY, JSON\.stringify\(\{ workerId: iw\.workerId, step: 3 \}\)\)", BLOCK) is not None)

# ------------------------------------------------------------------ 6. anglais
if node:
    js = ("const vm=require('vm'),fs=require('fs');const c={window:{}};c.window.BK_EN={};vm.createContext(c);"
          "for(const f of ['i18n-en.js','i18n-en-legal.js','i18n-en-app.js'])vm.runInContext(fs.readFileSync(process.argv[1]+'/'+f,'utf8'),c);"
          "process.stdout.write(JSON.stringify(Object.keys(c.window.BK_EN)))")
    p = subprocess.run([node, "-e", js, D], capture_output=True)
    keys = set(norm(k) for k in json.loads(p.stdout.decode("utf-8"))) if p.returncode == 0 else set()
    # textes que le dictionnaire n'a pas a couvrir : valeurs dynamiques, textes d'API, libelles deja traduits sous une autre forme
    EXEMPT = {"Dites", "obligatoire"}
    cands = ui_strings(BLOCK)
    html_added = {"Mes Workers installés", "Demandes d'embauche de Workers"}
    cands |= html_added
    for chunk in re.findall(r'class="iw-installed-sub">([^<]+)<', HTML) + re.findall(r'<p class="iw-installed-sub">([^<]+)</p>', HTML):
        cands.add(norm(chunk))
    # textes ajoutes en dehors du bloc : notice d'automatisation, boutons du proprietaire
    cands |= {"Voir ce Worker pour l'embaucher", "Attribuer des Workers (Solo / Trio)"}
    miss = sorted(c for c in cands if c not in keys and c not in EXEMPT and FRENCH.search(c) and not re.fullmatch(r"[\d/ .:%,()-]+", c))
    check(f"chaque texte francais statique de l'interface a une traduction anglaise ({len(cands)} textes verifies)", not miss, "; ".join(m[:70] for m in miss[:6]) + (f" ... (+{len(miss) - 6})" if len(miss) > 6 else ""))
    check("le dictionnaire anglais contient les textes cles de l'offre", all(k in keys for k in ("Installer ce Worker", "Embaucher ce Worker", "Essai à blanc", "Ne jamais", "Demander d'abord", "Préparer et attendre ma validation", "Autonome")))
else:
    print("  SKIP  node absent : dictionnaire non verifie")

# ------------------------------------------------------------------ 7. petits ecrans
def z(selector):
    m = re.search(re.escape(selector) + r"\s*\{[^}]*z-index:\s*(\d+)", CSS)
    return int(m.group(1)) if m else None


check("l'assistant est au-dessus de la bulle de Chloe et sous la fenetre « Connecter un outil »", z(".iw-overlay") and z(".cg-overlay") and 2000 < z(".iw-overlay") < z(".cg-overlay"), f"{z('.iw-overlay')} / {z('.cg-overlay')}")
mobile = CSS[CSS.rindex("@media (max-width: 720px) {\r\n  .iw-overlay"):] if "@media (max-width: 720px) {\r\n  .iw-overlay" in CSS else ""
check("sous 720 px l'assistant occupe tout l'ecran", ".iw-box { width: 100%;" in mobile and "border-radius: 0" in mobile)
check("sous 720 px seul le libelle de l'etape courante est affiche (cinq etapes tiennent sur 375 px)", ".iw-step-item:not(.is-current) .iw-step-label { display: none; }" in mobile)
check("polices de champs a 16 px sur mobile (pas de zoom automatique)", "font-size: 16px" in mobile)
check("l'en-tete, le pied et la barre d'etapes ne se compriment pas", all(re.search(re.escape(s) + r" \{ flex: none;", CSS) for s in (".iw-head", ".iw-steps", ".iw-foot")))
check("pas de largeur fixe en pixels superieure a 375 sur les elements de l'assistant", not re.findall(r"\.iw-[a-z-]+ \{[^}]*\bwidth:\s*(?:3[8-9]\d|[4-9]\d\d)px", CSS[CSS.index("HIRE-UI"):]))
check("la barre du haut ne deborde plus a 375 px une fois connecte (libelle du compte sur deux lignes)", "#topbar-account-btn { white-space: normal; max-width: 104px;" in CSS)
check("accessibilite : boite de dialogue, titre, etapes, annonces", all(s in BLOCK for s in ('role="dialog"', 'aria-modal="true"', 'aria-labelledby="iw-title"', 'aria-current="step"', 'role="alert"', 'aria-live="polite"')))
check("accessibilite : fermeture au clavier (Echap), piege du focus, focus rendu a la fermeture", all(s in BLOCK for s in ('e.key === "Escape"', 'e.key !== "Tab"', "target.focus()")))
check("accessibilite : champs relies a leur etiquette, aide et erreur", all(s in BLOCK for s in ('for="${id}"', "aria-describedby", "aria-invalid", 'aria-required="true"')))

print("\n" + ("TOUT PASSE" if not failures else f"{len(failures)} ECHEC(S)"))
sys.exit(0 if not failures else 1)
