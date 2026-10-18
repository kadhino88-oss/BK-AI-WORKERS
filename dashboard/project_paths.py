# -*- coding: utf-8 -*-
"""Chemins sûrs de l'espace de travail d'un projet (docs/AUTONOMY-ENGINE.md, section 3.4).

Un chemin d'espace de travail est valide si et seulement si : relatif, séparateur « / », longueur <= 180, au plus 8 segments, chaque segment
correspond à ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ (donc ni segment vide, ni « . » ni « .. », ni fichier caché, ni espace, ni caractère de
contrôle, ni « \\ »), extension dans la liste autorisée. Contrôle en profondeur : le realpath du résultat reste sous le realpath de
l'espace de travail, AUCUN composant existant n'est un lien symbolique (ni une jonction Windows), et l'écriture se fait dans un fichier
temporaire du même dossier puis os.replace.

Ce module est PUR (aucune dépendance au serveur) : les outils, les contrôles typés, les téléchargements de l'API et l'import de fichiers du
bac à sable passent tous par ici, pour que le chemin sûr soit codé et testé UNE seule fois.
"""
import hashlib
import os
import re
import secrets

SEG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}\Z")
MAX_PATH_CHARS = 180
MAX_SEGMENTS = 8
_WINDOWS_DEVICE = re.compile(r"^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?\Z", re.IGNORECASE)

# Extensions que le modèle peut ÉCRIRE (texte) ; celles qui ne peuvent qu'ENTRER par le bac à sable ou par le client (binaires).
WRITE_EXT = frozenset("html htm css js mjs json md txt csv tsv svg xml yml yaml ics".split())
IMPORT_EXT = WRITE_EXT | frozenset("png jpg jpeg webp gif ico woff2 pdf docx xlsx pptx zip".split())
IMAGE_EXT = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif"}

MAX_FILES = 400
MAX_DEPTH_DIRS = 40

_FILE_ATTRIBUTE_REPARSE_POINT = 0x400


class PathError(Exception):
    """Erreur de chemin ou de plafond : code stable (PATH_INVALID, WORKSPACE_FULL, TOO_LARGE, EXT_NOT_ALLOWED, EXISTS, NOT_FOUND) + message."""

    def __init__(self, code, detail):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def ext_of(name):
    base = str(name or "").rsplit("/", 1)[-1]
    return base.rsplit(".", 1)[-1].lower() if "." in base else ""


def split_rel(path, allow_trailing_slash=False, allow_empty=False):
    """Liste des segments d'un chemin relatif valide, sinon PathError(PATH_INVALID)."""
    if not isinstance(path, str):
        raise PathError("PATH_INVALID", "Le chemin doit être une chaîne de caractères.")
    if allow_empty and path in ("", "."):
        return []
    if not path:
        raise PathError("PATH_INVALID", "Chemin vide.")
    if len(path) > MAX_PATH_CHARS:
        raise PathError("PATH_INVALID", f"Chemin trop long (maximum {MAX_PATH_CHARS} caractères).")
    if any(ord(c) < 32 or ord(c) == 127 for c in path):
        raise PathError("PATH_INVALID", "Le chemin contient un caractère de contrôle.")
    if "\\" in path:
        raise PathError("PATH_INVALID", "Utilisez « / » comme séparateur, jamais « \\ ».")
    if path.startswith("/"):
        raise PathError("PATH_INVALID", "Le chemin doit être relatif à l'espace de travail (pas de « / » initial).")
    p = path
    if allow_trailing_slash and p.endswith("/") and len(p) > 1:
        p = p[:-1]
    parts = p.split("/")
    if len(parts) > MAX_SEGMENTS:
        raise PathError("PATH_INVALID", f"Chemin trop profond (maximum {MAX_SEGMENTS} niveaux).")
    for seg in parts:
        if not SEG_RE.match(seg) or _WINDOWS_DEVICE.match(seg):
            raise PathError("PATH_INVALID", "Chaque nom doit commencer par une lettre ou un chiffre et ne contenir que lettres, chiffres, « . », « _ » et « - » "
                            "(64 caractères au plus ; pas d'espace, pas de fichier caché, pas de « .. »).")
    return parts


def _is_link_or_reparse(path):
    try:
        st = os.lstat(path)
    except OSError:
        return False
    import stat as _stat
    if _stat.S_ISLNK(st.st_mode):
        return True
    return bool(getattr(st, "st_file_attributes", 0) & _FILE_ATTRIBUTE_REPARSE_POINT)


def _confine(workspace, parts):
    """Chemin absolu confiné : aucun composant EXISTANT n'est un lien, le realpath reste sous celui de l'espace de travail."""
    real_ws = os.path.realpath(workspace)
    if _is_link_or_reparse(workspace):
        raise PathError("PATH_INVALID", "Espace de travail invalide.")
    cur = real_ws
    for seg in parts:
        cur = os.path.join(cur, seg)
        if os.path.lexists(cur) and _is_link_or_reparse(cur):
            raise PathError("PATH_INVALID", "Les liens symboliques sont interdits dans l'espace de travail.")
    final = os.path.realpath(cur)
    if final != real_ws and not final.startswith(real_ws + os.sep):
        raise PathError("PATH_INVALID", "Le chemin sort de l'espace de travail.")
    return cur


def resolve(workspace, path, kind=None, must_exist=False, allowed_ext=None, allow_trailing_slash=False, allow_empty=False):
    """Chemin absolu sûr d'un chemin d'espace de travail.

    kind : None, "file" ou "dir" ; must_exist : le chemin doit exister (PathError NOT_FOUND sinon) ; allowed_ext : ensemble d'extensions
    (sans point) imposé aux fichiers (EXT_NOT_ALLOWED sinon)."""
    parts = split_rel(path, allow_trailing_slash=allow_trailing_slash, allow_empty=allow_empty)
    if not parts:
        return os.path.realpath(workspace)
    if allowed_ext is not None and kind != "dir" and not (allow_trailing_slash and path.endswith("/")):
        ext = ext_of(parts[-1])
        if ext not in allowed_ext:
            raise PathError("EXT_NOT_ALLOWED", f"Extension « .{ext} » non autorisée ici (autorisées : {', '.join(sorted(allowed_ext))}).")
    full = _confine(workspace, parts)
    if must_exist and not os.path.lexists(full):
        raise PathError("NOT_FOUND", f"Introuvable : {path}")
    if kind == "file" and os.path.lexists(full) and not os.path.isfile(full):
        raise PathError("PATH_INVALID", f"« {path} » n'est pas un fichier.")
    if kind == "dir" and os.path.lexists(full) and not os.path.isdir(full):
        raise PathError("PATH_INVALID", f"« {path} » n'est pas un dossier.")
    return full


def rel_of(workspace, full):
    """Chemin relatif « / » d'un chemin absolu de l'espace de travail."""
    rel = os.path.relpath(full, os.path.realpath(workspace))
    return rel.replace(os.sep, "/")


def usage(workspace):
    """(nombre de fichiers, octets) de l'espace de travail ; les liens ne sont jamais suivis ni comptés comme fichiers."""
    files = 0
    total = 0
    for dirpath, dirnames, filenames in os.walk(workspace, followlinks=False):
        dirnames[:] = [d for d in dirnames if not _is_link_or_reparse(os.path.join(dirpath, d))]
        for fn in filenames:
            fp = os.path.join(dirpath, fn)
            if _is_link_or_reparse(fp):
                continue
            try:
                total += os.path.getsize(fp)
                files += 1
            except OSError:
                continue
    return files, total


def count_dirs(workspace):
    n = 0
    for _dirpath, dirnames, _f in os.walk(workspace, followlinks=False):
        n += len(dirnames)
    return n


def atomic_write_bytes(full, data):
    """Écriture atomique : fichier temporaire du même dossier puis os.replace (jamais de fichier à moitié écrit)."""
    d = os.path.dirname(full)
    os.makedirs(d, exist_ok=True)
    tmp = os.path.join(d, ".tmp-" + secrets.token_hex(6))
    try:
        with open(tmp, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, full)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def sha256_file(full):
    h = hashlib.sha256()
    with open(full, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def walk_files(workspace, limit=2000):
    """Liste (chemin relatif, taille, mtime) des fichiers réguliers, tri par chemin ; ne suit jamais un lien."""
    out = []
    real = os.path.realpath(workspace)
    for dirpath, dirnames, filenames in os.walk(real, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if not _is_link_or_reparse(os.path.join(dirpath, d)) and not d.startswith("."))
        for fn in sorted(filenames):
            if fn.startswith("."):
                continue
            fp = os.path.join(dirpath, fn)
            if _is_link_or_reparse(fp):
                continue
            try:
                st = os.stat(fp)
            except OSError:
                continue
            out.append((rel_of(real, fp), st.st_size, st.st_mtime))
            if len(out) >= limit:
                return out
    return out
