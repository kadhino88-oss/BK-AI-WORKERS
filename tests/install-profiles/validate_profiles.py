#!/usr/bin/env python3
"""Validateur des profils d'installation : workers/<id>/install-profile.json (17 fichiers).

Un profil decrit comment un Worker est VENDU SEUL et INSTALLE chez un client selon ses
competences (voir docs/INSTALL-PROFILES.md). Ce script verifie que chaque profil :
  - existe, est du JSON UTF-8 valide et contient toutes les cles obligatoires ;
  - ne reference que des competences, des connecteurs et des operations qui EXISTENT
    (contrats de competences du Worker, catalogue des connecteurs, table
    core/integrations/Connector-Dispatch.ps1) ;
  - respecte la loi de la plateforme : rien qui ENVOIE, PUBLIE, PAIE, SUPPRIME ou APPELLE
    n'est jamais en mode "auto" ; risque moyen/eleve jamais "auto" ;
  - ne promet pas comme "disponible" un canal qui n'existe pas encore ;
  - ne contient aucun nom interdit.

Usage : python tests/install-profiles/validate_profiles.py [--quiet] [--only alex,nora]
Code de sortie : 0 si tout est valide, 1 sinon (la liste des erreurs est affichee).
"""
import json
import os
import re
import sys
import unicodedata

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

# Les 17 Workers commerciaux (Atlas est hors catalogue ; Chloe est l'orchestratrice, sans profil vendable).
WORKER_IDS = [
    "alex", "amina", "clara", "dario", "emma", "ines", "lea", "lucas", "maya",
    "noah", "nora", "rayan", "sam", "seoya", "sophie", "thomas", "yanis",
]

TOP_REQUIRED = ["workerId", "displayName", "tagline", "idealFor", "services",
                "channelSupport", "plannedCapabilities", "installationSteps"]
TOP_ALLOWED = set(TOP_REQUIRED) | {"schema"}

SERVICE_REQUIRED = ["id", "label", "description", "skills", "requiredConnectors",
                    "optionalConnectors", "channels", "knowledgeFields", "autonomyRules",
                    "testScenario", "recommendedLevel"]
SERVICE_OPTIONAL = {"requiredAnyOf", "connectorOperations", "suggestedFrequencyMinutes"}

FIELD_KEYS = ["key", "label", "help", "required", "example"]
RULE_REQUIRED = ["category", "label", "examples", "risk", "defaultMode", "maxAutoPerDay"]
RULE_OPTIONAL = {"operations"}

CHANNELS = ["email", "phone", "whatsapp", "web", "schedule"]
SUPPORT_VALUES = {"available", "planned", "no"}
# Ce qui existe REELLEMENT aujourd'hui (a relire a chaque evolution de la plateforme) :
#   web      : missions lancees depuis l'application                       -> available
#   schedule : automatisations (mission recurrente, core/automation)       -> available
#   email    : traitement automatique d'une boite de reception (reponse)    -> pas encore
#   phone    : agent telephonique (dashboard/phone_agent.py) : compte proprietaire seulement -> pas encore pour un client
#   whatsapp : numero WhatsApp propre au client                             -> pas encore
CHANNEL_MAX_SUPPORT = {"email": "planned", "phone": "planned", "whatsapp": "planned",
                       "web": "available", "schedule": "available"}
REQUIRED_AVAILABLE = {"web": "available", "schedule": "available"}

LEVELS = {"rapide", "equilibre", "approfondi"}
RISKS = {"low", "medium", "high"}
MODES = {"draft", "ask", "auto", "off"}

SLUG_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
KEY_RE = re.compile(r"^[a-z][a-z0-9_]*$")
OP_REF_RE = re.compile(r"^([a-z0-9_]+(?:\.controlled)?):([A-Z_]+)$")

FORBIDDEN_RE = re.compile(r"kader|sweltr|saveurs|afrik", re.IGNORECASE)
PLACEHOLDER_RE = re.compile(r"\b(todo|tbd|lorem|xxx|a completer|à compléter)\b|\[\.\.\.\]", re.IGNORECASE)

# Verbes/noms d'actions qui sortent de la plateforme : jamais dans le texte d'une regle "auto".
# (Liste volontairement explicite : "publicite", "appel d'offres", "commandes" ne sont pas des actions.
# Pour parler de lecture d'encaissements, ecrire "reglements" plutot que "paiements".)
_SENSITIVE_TOKENS = [
    "envoyer", "envoie", "envoies", "envoient", "envoyez", "envoi", "envois", "expédier", "expedier", "expédie",
    "publier", "publie", "publiez", "publient", "poster", "postez",
    "payer", "paie", "paye", "payez", "paiement", "paiements",
    "rembourser", "rembourse", "remboursez", "remboursement", "remboursements",
    "virer", "virement", "virements", "verser",
    "supprimer", "supprime", "supprimez", "suppression", "suppressions", "effacer", "efface", "effacez",
    "appeler", "appelle", "appelez", "signer", "signez",
    r"pass(?:er|e|ez)\s+(?:un|des)\s+appels?", r"lancer\s+(?:un|des)\s+appels?",
]
SENSITIVE_RE = re.compile(r"\b(" + "|".join(_SENSITIVE_TOKENS) + r")\b", re.IGNORECASE)
# Ces categories (actions qui sortent, engagent ou modifient) ne sont jamais en mode "auto".
SENSITIVE_CATEGORY_RE = re.compile(
    r"^(envoi|publication|paiement|suppression|appel|engagement|ecriture|modification|signature|contact)")
# Un scenario d'essai doit annoncer qu'aucune action reelle n'est faite.
SAFE_TEST_RE = re.compile(
    r"(aucune?\s+(action|envoi|publication|ecriture|écriture|appel|paiement)|"
    r"rien\s+n['’]est\s+(envoy|publi|pay|supprim|modifi|écrit|ecrit)|"
    r"ne\s+(rien|pas)\s+(envoy|publi|pay|supprim|modifi|appel))",
    re.IGNORECASE)

# Connecteurs qu'un client ne peut PAS encore connecter lui-meme (voir la memoire projet "bk-connector-connect") :
#   salesforce / google_ads : application OAuth cote fournisseur pas encore enregistree ;
#   stripe / paypal / quickbooks / xero : financiers, non configurables par un client, ecritures toujours manuelles.
# -> a decrire dans plannedCapabilities, jamais comme connecteur requis/optionnel.
NOT_CLIENT_CONNECTABLE = {"salesforce", "google_ads", "stripe", "paypal", "quickbooks", "xero"}
# Connecteur de lecture seule autorise dans les profils : jamais d'ecriture financiere.
# Operations "brouillon" reelles de la plateforme (core/ai/adapters/ANTHROPIC-ADAPTER.ps1 : $AutoApproveSafeOps).
TRUE_DRAFT_OPS = {"gmail:DRAFT_MESSAGE", "outlook_mail:DRAFT_MESSAGE", "wordpress:CREATE_DRAFT",
                  "wordpress:UPDATE_DRAFT", "zendesk:DRAFT_REPLY", "intercom:DRAFT_REPLY"}
# Operations qui font sortir quelque chose chez un tiers malgre leur nom (revue 2026-10-11).
OUTBOUND_OPS = {"slack:POST_MESSAGE", "slack:DRAFT_MESSAGE", "teams:DRAFT_MESSAGE", "whatsapp_business:DRAFT_MESSAGE",
                "linkedin:CREATE_DRAFT_POST", "instagram:CREATE_DRAFT_POST", "facebook:CREATE_DRAFT_POST",
                "tiktok:CREATE_DRAFT_POST", "x_twitter:CREATE_DRAFT_POST", "twilio:PLACE_CALL"}
MONEY_OPS = {"stripe:CREATE_REFUND", "stripe:CREATE_PAYOUT", "paypal:CREATE_REFUND", "paypal:CREATE_PAYOUT",
             "quickbooks:CREATE_PAYMENT", "xero:CREATE_PAYMENT"}

errors = []


def err(where, msg):
    errors.append(f"{where}: {msg}")


def load_json(path):
    with open(path, "rb") as f:
        raw = f.read()
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ValueError("BOM UTF-8 interdit (ecrire en UTF-8 sans BOM)")
    return json.loads(raw.decode("utf-8")), raw.decode("utf-8")


def load_catalog():
    with open(os.path.join(ROOT, "core", "runtime", "controlled-connectors", "CONTROLLED-CONNECTOR-CATALOG.json"),
              encoding="utf-8-sig") as f:
        cat = json.load(f)
    ids = {c["connectorId"]: c for c in cat["connectors"]}
    return ids


def load_guide_providers():
    with open(os.path.join(ROOT, "core", "integrations", "connect-guides.json"), encoding="utf-8-sig") as f:
        g = json.load(f)
    return {k for k in g if not k.startswith("_")}


# Cle du guide de connexion -> id de catalogue (quand ils different : voir dashboard/server.py).
PROVIDER_TO_CATALOG = {"uptimerobot": "monitoring.controlled", "bamboohr": "calendar_hr.controlled",
                       "google_calendar": "calendar.controlled"}


def load_dispatch_ops():
    """Operations REELLES par connecteur (id de base), lues dans Connector-Dispatch.ps1."""
    path = os.path.join(ROOT, "core", "integrations", "Connector-Dispatch.ps1")
    ops = {}
    current = None
    with open(path, encoding="utf-8-sig") as f:
        for line in f:
            if line.lstrip().startswith("#"):
                continue
            m = re.match(r'^ {4}"([a-z0-9_]+)" = @\{', line)
            if m:
                current = m.group(1)
                ops.setdefault(current, set())
                continue
            m = re.match(r'^ {12}"([A-Z_]+)"\s*=\s*\{', line)
            if m and current:
                ops[current].add(m.group(1))
    # Cas geres a part dans Invoke-ConnectorAction (hors de la table).
    ops.setdefault("slack", set()).update({"POST_MESSAGE", "DRAFT_MESSAGE"})
    ops.setdefault("instagram", set()).add("CREATE_DRAFT_POST")
    ops.setdefault("twilio", set()).add("PLACE_CALL")
    return ops


def fold(text):
    """Minuscules sans accents : \"Lea\" et \"Léa\" designent le meme Worker."""
    return "".join(c for c in unicodedata.normalize("NFKD", str(text).lower()) if not unicodedata.combining(c))


def base_id(connector_id):
    return connector_id[: -len(".controlled")] if connector_id.endswith(".controlled") else connector_id


def is_read_op(op):
    return op.startswith("READ_") or op.startswith("SEARCH_")


def check_text(where, value):
    if FORBIDDEN_RE.search(value):
        err(where, f"mot interdit present : {FORBIDDEN_RE.search(value).group(0)!r}")
    if PLACEHOLDER_RE.search(value):
        err(where, "texte provisoire (TODO / a completer / lorem)")


def nonempty_str(where, value, min_len=1, max_len=None, oneline=False):
    if not isinstance(value, str) or len(value.strip()) < min_len:
        err(where, f"chaine non vide attendue (>= {min_len} caracteres)")
        return False
    if max_len and len(value) > max_len:
        err(where, f"trop long ({len(value)} > {max_len} caracteres)")
    if oneline and "\n" in value:
        err(where, "doit tenir sur une seule ligne")
    return True


def resolve_connector(where, cid, catalog, providers, dispatch):
    """Renvoie l'id de catalogue normalise, ou None (erreur deja enregistree)."""
    if not isinstance(cid, str):
        err(where, f"id de connecteur invalide : {cid!r}")
        return None
    norm = cid
    if cid not in catalog:
        if cid in providers or cid in PROVIDER_TO_CATALOG:
            norm = PROVIDER_TO_CATALOG.get(cid, cid + ".controlled")
        if norm not in catalog:
            err(where, f"connecteur inconnu (ni catalogue ni guides de connexion) : {cid!r}")
            return None
    entry = catalog[norm]
    if not entry.get("realAdapter"):
        err(where, f"{norm} est une categorie generique sans vrai adaptateur : ne pas la proposer au client")
        return None
    b = base_id(norm)
    if b in NOT_CLIENT_CONNECTABLE:
        err(where, f"{norm} n'est pas encore connectable par un client : le decrire dans plannedCapabilities")
        return None
    if b not in dispatch:
        err(where, f"{norm} n'a aucune operation reelle dans Connector-Dispatch.ps1")
        return None
    return norm


def validate_fields(where, fields):
    if not isinstance(fields, list) or not fields:
        err(where, "knowledgeFields : liste non vide attendue")
        return
    keys = set()
    n_required = 0
    for i, fld in enumerate(fields):
        w = f"{where}.knowledgeFields[{i}]"
        if not isinstance(fld, dict):
            err(w, "objet attendu")
            continue
        for k in FIELD_KEYS:
            if k not in fld:
                err(w, f"cle manquante : {k}")
        extra = set(fld) - set(FIELD_KEYS)
        if extra:
            err(w, f"cles inconnues : {sorted(extra)}")
        key = fld.get("key")
        if not isinstance(key, str) or not KEY_RE.match(key):
            err(w, f"key invalide (snake_case attendu) : {key!r}")
        elif key in keys:
            err(w, f"key en double : {key}")
        else:
            keys.add(key)
        nonempty_str(w + ".label", fld.get("label"), 3, 120, True)
        nonempty_str(w + ".help", fld.get("help"), 10, 300)
        nonempty_str(w + ".example", fld.get("example"), 2, 300)
        if not isinstance(fld.get("required"), bool):
            err(w, "required doit etre un booleen")
        elif fld["required"]:
            n_required += 1
    if n_required < 1:
        err(where, "au moins un champ knowledgeFields doit etre required=true")


def validate_rules(where, rules, svc_connectors, dispatch, catalog):
    """Renvoie l'ensemble des operations non-lecture couvertes par une regle."""
    covered = set()
    if not isinstance(rules, list) or not rules:
        err(where, "autonomyRules : liste non vide attendue")
        return covered
    cats = set()
    for i, rule in enumerate(rules):
        w = f"{where}.autonomyRules[{i}]"
        if not isinstance(rule, dict):
            err(w, "objet attendu")
            continue
        for k in RULE_REQUIRED:
            if k not in rule:
                err(w, f"cle manquante : {k}")
        extra = set(rule) - set(RULE_REQUIRED) - RULE_OPTIONAL
        if extra:
            err(w, f"cles inconnues : {sorted(extra)}")
        cat = rule.get("category")
        if not isinstance(cat, str) or not SLUG_RE.match(cat):
            err(w, f"category invalide (slug attendu) : {cat!r}")
            cat = ""
        elif cat in cats:
            err(w, f"category en double dans le service : {cat}")
        cats.add(cat)
        label = rule.get("label")
        nonempty_str(w + ".label", label, 3, 140, True)
        ex = rule.get("examples")
        if not isinstance(ex, list) or not ex or not all(isinstance(e, str) and e.strip() for e in ex):
            err(w, "examples : liste non vide de textes attendue")
            ex = []
        risk, mode = rule.get("risk"), rule.get("defaultMode")
        if risk not in RISKS:
            err(w, f"risk invalide : {risk!r}")
        if mode not in MODES:
            err(w, f"defaultMode invalide : {mode!r}")
        cap = rule.get("maxAutoPerDay")
        if mode == "auto":
            if not (isinstance(cap, int) and not isinstance(cap, bool) and cap >= 1):
                err(w, "un mode auto doit avoir un plafond maxAutoPerDay (entier >= 1)")
        elif cap is not None:
            err(w, "maxAutoPerDay doit etre null hors mode auto")
        # Loi de la plateforme.
        if mode == "auto":
            if risk in ("medium", "high"):
                err(w, f"risque {risk} ne peut jamais etre en mode auto")
            if SENSITIVE_CATEGORY_RE.match(cat):
                err(w, f"la categorie {cat!r} (action qui sort ou modifie) ne peut jamais etre en mode auto")
            text = " ; ".join([label if isinstance(label, str) else ""] + [e for e in ex])
            m = SENSITIVE_RE.search(text)
            if m:
                err(w, f"regle auto mais le texte evoque une action sensible (envoyer/publier/payer/supprimer/appeler) : {m.group(0)!r}")
        if re.match(r"^(paiement|suppression)", cat) and risk != "high":
            err(w, f"{cat} doit etre de risque high")
        if re.match(r"^(appel|envoi|publication|engagement|signature)", cat) and risk == "low":
            err(w, f"{cat} (action qui sort ou engage) ne peut pas etre de risque low")
        if re.match(r"^paiement", cat) and mode != "off":
            err(w, "toute regle de paiement doit etre defaultMode=off (seul le client valide un paiement)")
        # Operations de connecteur reliees a la regle.
        ops = rule.get("operations", [])
        if "operations" in rule and not isinstance(ops, list):
            err(w, "operations doit etre une liste")
            ops = []
        for ref in ops:
            m = OP_REF_RE.match(ref) if isinstance(ref, str) else None
            if not m:
                err(w, f"operations : format 'connecteur:OPERATION' attendu, recu {ref!r}")
                continue
            cid, op = m.group(1), m.group(2)
            norm = cid if cid.endswith(".controlled") else cid + ".controlled"
            if norm not in svc_connectors:
                err(w, f"operation {ref} : connecteur absent des listes du service")
                continue
            b = base_id(norm)
            if op not in dispatch.get(b, set()):
                err(w, f"operation {ref} : n'existe pas dans Connector-Dispatch.ps1")
                continue
            key = f"{b}:{op}"
            if is_read_op(op):
                continue
            covered.add(key)
            if mode == "auto":
                err(w, f"{ref} ecrit/agit chez un tiers : jamais en mode auto")
            if key in MONEY_OPS and (mode != "off" or risk != "high"):
                err(w, f"{ref} fait sortir de l'argent : defaultMode=off et risk=high obligatoires")
            if key in OUTBOUND_OPS and mode not in ("ask", "off"):
                err(w, f"{ref} sort chez un tiers (malgre son nom) : defaultMode ask ou off obligatoire")
            if key not in TRUE_DRAFT_OPS and key not in OUTBOUND_OPS and key not in MONEY_OPS and mode not in ("ask", "off"):
                err(w, f"{ref} ecrit dans l'outil du client : defaultMode ask ou off obligatoire")
    return covered


def validate_service(wid, idx, svc, catalog, providers, dispatch, skills, ch_support):
    where = f"{wid}.services[{idx}]"
    if not isinstance(svc, dict):
        err(where, "objet attendu")
        return None
    for k in SERVICE_REQUIRED:
        if k not in svc:
            err(where, f"cle manquante : {k}")
    extra = set(svc) - set(SERVICE_REQUIRED) - SERVICE_OPTIONAL
    if extra:
        err(where, f"cles inconnues : {sorted(extra)}")
    sid = svc.get("id")
    if not isinstance(sid, str) or not SLUG_RE.match(sid):
        err(where, f"id invalide (slug attendu) : {sid!r}")
    where = f"{wid}.{sid if isinstance(sid, str) else idx}"
    nonempty_str(where + ".label", svc.get("label"), 5, 120, True)
    nonempty_str(where + ".description", svc.get("description"), 60, 700)
    # Competences.
    sk = svc.get("skills")
    if not isinstance(sk, list):
        err(where, "skills : liste attendue (peut etre vide)")
    else:
        if len(set(sk)) != len(sk):
            err(where, "skills : doublons")
        for s in sk:
            if s not in skills:
                err(where, f"competence inconnue pour {wid} (absente de skills/contracts) : {s!r}")
    # Connecteurs.
    declared = set()
    normalized = {"requiredConnectors": [], "optionalConnectors": []}
    for field in ("requiredConnectors", "optionalConnectors"):
        lst = svc.get(field)
        if not isinstance(lst, list):
            err(where, f"{field} : liste attendue")
            continue
        for cid in lst:
            norm = resolve_connector(f"{where}.{field}", cid, catalog, providers, dispatch)
            if norm:
                if norm in declared:
                    err(where, f"connecteur en double dans le service : {norm}")
                declared.add(norm)
                normalized[field].append(norm)
    req = set(normalized["requiredConnectors"])
    any_of = svc.get("requiredAnyOf", [])
    if "requiredAnyOf" in svc:
        if not isinstance(any_of, list) or not all(isinstance(g, list) and len(g) >= 2 for g in any_of):
            err(where, "requiredAnyOf : liste de groupes (>= 2 connecteurs alternatifs chacun) attendue")
        else:
            for g in any_of:
                for cid in g:
                    norm = resolve_connector(f"{where}.requiredAnyOf", cid, catalog, providers, dispatch)
                    if norm:
                        if norm in declared:
                            err(where, f"{norm} figure deja dans une autre liste de connecteurs du service")
                        declared.add(norm)
    # Operations du service.
    covered_needed = set()
    cops = svc.get("connectorOperations", {})
    if "connectorOperations" in svc:
        if not isinstance(cops, dict):
            err(where, "connectorOperations : objet attendu")
            cops = {}
        for cid, oplist in cops.items():
            norm = cid if cid.endswith(".controlled") else cid + ".controlled"
            if norm not in declared:
                err(where, f"connectorOperations : {cid} absent des listes de connecteurs du service")
                continue
            if not isinstance(oplist, list) or not oplist:
                err(where, f"connectorOperations[{cid}] : liste non vide attendue")
                continue
            for op in oplist:
                if op not in dispatch.get(base_id(norm), set()):
                    err(where, f"operation {cid}:{op} inexistante dans Connector-Dispatch.ps1")
                elif not is_read_op(op):
                    covered_needed.add(f"{base_id(norm)}:{op}")
    listed = {(c if c.endswith(".controlled") else c + ".controlled") for c in cops}
    for norm in sorted(declared - listed):
        err(where, f"connectorOperations doit lister les operations utilisees pour {norm}")
    # Canaux.
    chans = svc.get("channels")
    if not isinstance(chans, list) or not chans:
        err(where, "channels : liste non vide attendue")
        chans = []
    for c in chans:
        if c not in CHANNELS:
            err(where, f"canal inconnu : {c!r}")
        elif ch_support.get(c) == "no":
            err(where, f"canal {c} utilise alors que channelSupport.{c} = 'no'")
    if len(set(chans)) != len(chans):
        err(where, "channels : doublons")
    if "web" not in chans:
        err(where, "tout service doit etre utilisable depuis l'application (canal 'web')")
    freq = svc.get("suggestedFrequencyMinutes")
    if "schedule" in chans:
        if not (isinstance(freq, int) and not isinstance(freq, bool) and freq >= 60):
            err(where, "un service 'schedule' doit avoir suggestedFrequencyMinutes (entier >= 60)")
    elif "suggestedFrequencyMinutes" in svc:
        err(where, "suggestedFrequencyMinutes sans canal 'schedule'")
    # Champs de connaissance, regles d'autonomie, scenario, niveau.
    validate_fields(where, svc.get("knowledgeFields"))
    covered = validate_rules(where, svc.get("autonomyRules"), declared, dispatch, catalog)
    for key in sorted(covered_needed - covered):
        err(where, f"l'operation {key} est utilisee mais aucune autonomyRule ne la gouverne (champ operations)")
    ts = svc.get("testScenario")
    if not isinstance(ts, dict) or set(ts) != {"objective", "expectedChecks"}:
        err(where, "testScenario : objet {objective, expectedChecks} attendu")
    else:
        if nonempty_str(where + ".testScenario.objective", ts["objective"], 40, 900):
            if not SAFE_TEST_RE.search(ts["objective"]):
                err(where, "testScenario.objective doit preciser qu'aucune action reelle n'est faite "
                           "(ex. \"Essai : rien n'est envoye, publie ni modifie.\")")
        chk = ts["expectedChecks"]
        if not isinstance(chk, list) or len(chk) < 2 or not all(isinstance(c, str) and len(c.strip()) > 8 for c in chk):
            err(where, "testScenario.expectedChecks : au moins 2 verifications (textes) attendues")
    if svc.get("recommendedLevel") not in LEVELS:
        err(where, f"recommendedLevel invalide : {svc.get('recommendedLevel')!r}")
    return sid


def validate_profile(wid, catalog, providers, dispatch):
    path = os.path.join(ROOT, "workers", wid, "install-profile.json")
    if not os.path.isfile(path):
        err(wid, f"fichier manquant : workers/{wid}/install-profile.json")
        return
    try:
        prof, raw = load_json(path)
    except Exception as e:
        err(wid, f"JSON illisible : {e}")
        return
    check_profile_data(wid, prof, raw, catalog, providers, dispatch)


def check_profile_data(wid, prof, raw, catalog, providers, dispatch):
    """Controle un profil deja charge (utilisable depuis les tests avec un dict modifie)."""
    if not isinstance(prof, dict):
        err(wid, "objet JSON attendu")
        return
    check_text(wid, raw)
    for k in TOP_REQUIRED:
        if k not in prof:
            err(wid, f"cle manquante : {k}")
    extra = set(prof) - TOP_ALLOWED
    if extra:
        err(wid, f"cles inconnues : {sorted(extra)}")
    if prof.get("workerId") != wid:
        err(wid, f"workerId doit etre {wid!r} (recu {prof.get('workerId')!r})")
    # Nom d'affichage = nom de l'identite du Worker.
    try:
        with open(os.path.join(ROOT, "workers", wid, "identity", "identity.json"), encoding="utf-8-sig") as f:
            ident = json.load(f)
        if fold(prof.get("displayName", "")) != fold(ident.get("name", "")):
            err(wid, f"displayName {prof.get('displayName')!r} different de l'identite {ident.get('name')!r}")
    except Exception as e:
        err(wid, f"identity.json illisible : {e}")
    nonempty_str(wid + ".tagline", prof.get("tagline"), 15, 160, True)
    nonempty_str(wid + ".idealFor", prof.get("idealFor"), 30, 360)
    if isinstance(prof.get("idealFor"), str) and prof["idealFor"].count("\n") > 1:
        err(wid, "idealFor : 2 lignes maximum")
    # Canaux.
    cs = prof.get("channelSupport")
    if not isinstance(cs, dict) or set(cs) != set(CHANNELS):
        err(wid, f"channelSupport : cles exactes attendues {CHANNELS}")
        cs = {}
    for ch in CHANNELS:
        v = cs.get(ch)
        if v is None:
            continue
        if v not in SUPPORT_VALUES:
            err(wid, f"channelSupport.{ch} invalide : {v!r}")
        elif v == "available" and CHANNEL_MAX_SUPPORT[ch] != "available":
            err(wid, f"channelSupport.{ch} ne peut pas etre 'available' : ce canal n'existe pas encore pour un client")
        elif ch in REQUIRED_AVAILABLE and v != REQUIRED_AVAILABLE[ch]:
            err(wid, f"channelSupport.{ch} doit etre {REQUIRED_AVAILABLE[ch]!r} (canal existant)")
    # Capacites a venir et etapes.
    pc = prof.get("plannedCapabilities")
    if not isinstance(pc, list) or not pc or not all(isinstance(x, str) and len(x.strip()) > 10 for x in pc):
        err(wid, "plannedCapabilities : liste non vide de textes attendue")
    steps = prof.get("installationSteps")
    if not isinstance(steps, list) or not (5 <= len(steps) <= 9) or not all(isinstance(x, str) and 10 < len(x) <= 260 for x in steps):
        err(wid, "installationSteps : 5 a 9 etapes courtes (10-260 caracteres) attendues")
    # Services.
    services = prof.get("services")
    if not isinstance(services, list) or not (4 <= len(services) <= 8):
        err(wid, f"services : 4 a 8 services attendus (recu {len(services) if isinstance(services, list) else 'n/a'})")
        return
    skills_dir = os.path.join(ROOT, "workers", wid, "skills", "contracts")
    skills = {f[:-5] for f in os.listdir(skills_dir) if f.endswith(".json")} if os.path.isdir(skills_dir) else set()
    ids, labels = set(), set()
    for i, svc in enumerate(services):
        sid = validate_service(wid, i, svc, catalog, providers, dispatch, skills, cs)
        if isinstance(sid, str):
            if sid in ids:
                err(wid, f"id de service en double : {sid}")
            ids.add(sid)
        lab = svc.get("label") if isinstance(svc, dict) else None
        if isinstance(lab, str):
            if lab.lower() in labels:
                err(wid, f"label de service en double : {lab}")
            labels.add(lab.lower())
    # Au moins un canal "available" par service (deja assure par 'web'), et un profil doit annoncer
    # ses canaux planifies de facon coherente.
    used = {c for s in services if isinstance(s, dict) for c in (s.get("channels") or [])}
    for ch in ("email", "phone", "whatsapp"):
        if cs.get(ch) == "no" and ch in used:
            err(wid, f"canal {ch} 'no' mais utilise par un service")


def main():
    quiet = "--quiet" in sys.argv
    catalog = load_catalog()
    providers = load_guide_providers()
    dispatch = load_dispatch_ops()
    if len(dispatch) < 30 or "gmail" not in dispatch or "READ_MESSAGES" not in dispatch["gmail"]:
        print("ERREUR INTERNE : la table de Connector-Dispatch.ps1 n'a pas pu etre lue", file=sys.stderr)
        return 2
    only = None
    if "--only" in sys.argv:
        only = set(sys.argv[sys.argv.index("--only") + 1].split(","))
    for wid in WORKER_IDS:
        if only and wid not in only:
            continue
        if not os.path.isdir(os.path.join(ROOT, "workers", wid)):
            err(wid, "dossier workers/<id> introuvable")
            continue
        validate_profile(wid, catalog, providers, dispatch)
    if errors:
        print(f"{len(errors)} erreur(s) :", file=sys.stderr)
        for e in errors:
            print("  - " + e, file=sys.stderr)
        return 1
    if not quiet:
        total = 0
        checked = [w for w in WORKER_IDS if not only or w in only]
        for wid in checked:
            prof, _ = load_json(os.path.join(ROOT, "workers", wid, "install-profile.json"))
            total += len(prof["services"])
        print(f"OK : {len(checked)} profil(s) d'installation valide(s), {total} services.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
