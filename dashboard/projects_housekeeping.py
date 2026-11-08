# -*- coding: utf-8 -*-
"""Entretien du moteur de projets (docs/AUTONOMY-ENGINE.md, sections 2.8, 6.6, 6.7) : conservation (90 jours), espace disque par client, plafond
d'étapes par projet, alerte de dépense anormale, nettoyage des fichiers orphelins chez le fournisseur d'IA.

Mixin de ProjectService (projects.py). Rien ici ne tourne dans le chemin d'une requête : le superviseur appelle `housekeeping_tick` à chaque passe, et
la fonction ne travaille qu'une fois par heure (nettoyage des fichiers distants : une fois par demi-heure).
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

import project_paths as pp
import projects_config as cfg
import projects_store as ps

HOUSEKEEPING_EVERY_SEC = 3600.0
FILES_REAP_EVERY_SEC = 1800.0
FILES_ORPHAN_AGE_SEC = 900.0
SPEND_ALERT_MIN_CHF = 2.0
FILES_CLEANUP_SCRIPT = os.path.join("core", "ai", "adapters", "Project-FilesCleanup.ps1")


class HousekeepingMixin:
    # ------------------------------------------------------------------ plafond d'étapes par projet
    def steps_room(self, st, n=1):
        """Vrai s'il reste de la place pour `n` étapes de plus dans ce projet (maxStepsPerProject, 120 par défaut)."""
        return len(st.get("steps") or {}) + n <= int(self.limits["step"]["maxStepsPerProject"])

    # ------------------------------------------------------------------ espace disque d'un client
    def client_disk_bytes(self, client_id, ttl=60.0):
        """Octets occupés par tous les projets du client (mis en cache `ttl` secondes : le parcours coûte)."""
        hit = self._disk_cache.get(client_id)
        t = self.now()
        if hit and t - hit[0] < ttl:
            return hit[1]
        total = 0
        try:
            base = self.store.client_dir(client_id)
        except ps.ProjectError:
            return 0
        for _rel, size, _mt in pp.walk_files(base, limit=200000):
            total += size
        self._disk_cache[client_id] = (t, total)
        return total

    def check_client_disk(self, client_id, plan_id):
        mb = cfg.plan_value(self.limits["clientDiskMb"], plan_id, 1024)
        if mb and self.client_disk_bytes(client_id) >= int(mb) * 1024 * 1024:
            raise ps.ProjectError("WORKSPACE_FULL", "Votre espace de stockage de projets est plein : téléchargez puis supprimez d'anciens projets avant d'en créer un nouveau.",
                                  limitMb=int(mb), upgrade=self.upgrade_hint(client_id))

    # ------------------------------------------------------------------ passe horaire
    def housekeeping_tick(self, now):
        if now - self._last_housekeeping >= HOUSEKEEPING_EVERY_SEC:
            self._last_housekeeping = now
            try:
                self.retention_sweep(now)
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"projects retention: {type(e).__name__}: {e}\n")
            try:
                self.spend_spike_sweep(now)
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"projects spend spike: {type(e).__name__}: {e}\n")
        if now - self._last_files_reap >= FILES_REAP_EVERY_SEC:
            self._last_files_reap = now
            try:
                self.reap_files_api()
            except Exception as e:  # noqa: BLE001
                sys.stderr.write(f"projects files reap: {type(e).__name__}: {e}\n")

    # ------------------------------------------------------------------ conservation
    def retention_sweep(self, now=None):
        """Projet terminé ou échoué : l'espace de travail est supprimé après `retentionDays` (90) ; annulé : après `cancelledDownloadDays` (7).
        L'état, le journal, le rapport final et le registre des livrables restent (traçabilité et facturation). Renvoie le nombre de projets purgés."""
        now = now or self.now()
        lim = self.limits["lifecycle"]
        n = 0
        for pid, _cid in list(self.store.all_ids()):
            try:
                st = self.store.state(pid)
            except ps.ProjectError:
                continue
            if st.get("status") not in ps.TERMINAL or st.get("workspacePurgedUtc"):
                continue
            since = ps.parse_iso(st.get("finishedUtc")) or ps.parse_iso(st.get("updatedUtc")) or now
            days = float(lim["cancelledDownloadDays"] if st.get("status") == "CANCELLED" else lim["retentionDays"])
            if now - since < days * 86400:
                continue
            if self.purge_workspace(pid):
                n += 1
        try:
            import site_preview
            site_preview.SitePreview(self.root).sweep()
        except Exception as e:  # noqa: BLE001
            sys.stderr.write(f"projects preview sweep: {type(e).__name__}: {e}
")
        return n

    def purge_workspace(self, pid):
        proj = self.store.project_dir(pid)
        for sub in ("workspace", "spool"):
            shutil.rmtree(os.path.join(proj, sub), ignore_errors=True)
        steps_dir = os.path.join(proj, "steps")
        for dp, dirs, _files in os.walk(steps_dir):
            for d in list(dirs):
                if d in ("downloads", "fetches"):
                    shutil.rmtree(os.path.join(dp, d), ignore_errors=True)
        try:
            with self.store.txn(pid) as t:
                t.state["workspacePurgedUtc"] = self.now_iso()
                t.event("status_changed", "Les fichiers de ce projet ont été supprimés (durée de conservation écoulée). Le rapport final reste consultable.",
                        reason="RETENTION")
        except ps.ProjectError:
            return False
        self._disk_cache.pop(self.store.client_of(pid), None)
        return True

    # ------------------------------------------------------------------ dépense anormale
    def spend_spike_sweep(self, now=None):
        """Alerte le propriétaire si un client dépense en 24 h plus de `spendSpikeFactor` fois sa moyenne quotidienne des 7 jours précédents
        (plancher : 2 CHF ; une alerte par client et par jour)."""
        if not self.owner_alert:
            return 0
        now = now or self.now()
        factor = float(self.limits["abuse"]["spendSpikeFactor"])
        alerted = 0
        for cid in sorted({c for _p, c in self.store.all_ids()}):
            last, prior = 0.0, 0.0
            for pid in self.store.ids_of_client(cid):
                for rec in self.store.read_jsonl(pid, "cost-ledger.jsonl"):
                    ts = ps.parse_iso(rec.get("ts"))
                    if ts is None:
                        continue
                    age = now - ts
                    chf = float(rec.get("chf") or 0)
                    if age <= 86400:
                        last += chf
                    elif age <= 8 * 86400:
                        prior += chf
            mean = prior / 7.0
            if last >= SPEND_ALERT_MIN_CHF and last > factor * max(mean, 0.01):
                if now - self._spike_alerted.get(cid, 0) < 86400:
                    continue
                self._spike_alerted[cid] = now
                alerted += 1
                try:
                    self.owner_alert(f"Dépense anormale : le client {cid} a consommé {last:.2f} CHF en projets sur 24 h (moyenne des 7 jours précédents : {mean:.2f} CHF).")
                except Exception:  # noqa: BLE001
                    pass
        return alerted

    # ------------------------------------------------------------------ fichiers distants orphelins (API Files)
    def _orphan_file_ids(self, now):
        """{chemin du fichier files-api.json: [identifiants]} des étapes qui ne tournent plus et dont le nettoyage n'a pas eu lieu."""
        found = {}
        for pid, _cid in list(self.store.all_ids()):
            sd = os.path.join(self.store.project_dir(pid), "steps")
            if not os.path.isdir(sd):
                continue
            with self._procs_lock:
                running = {sid for (p, sid) in self._procs if p == pid}
            for step in os.listdir(sd):
                if step in running:
                    continue
                for att in os.listdir(os.path.join(sd, step)):
                    path = os.path.join(sd, step, att, "files-api.json")
                    try:
                        mt = os.path.getmtime(path)
                    except OSError:
                        continue
                    if now - mt < FILES_ORPHAN_AGE_SEC:
                        continue
                    data = cfg.read_json(path, {}) or {}
                    ids = [i for i in (data.get("uploaded") or []) + (data.get("produced") or []) if isinstance(i, str) and i.startswith("file_")]
                    if ids:
                        found[path] = ids
        return found

    def _files_cleanup_argv(self, ids_path):
        if self.files_cleanup_cmd:
            return list(self.files_cleanup_cmd(ids_path))
        return [*self.ps_cmd, "-File", os.path.join(self.root, FILES_CLEANUP_SCRIPT), "-IdsFile", ids_path]

    def reap_files_api(self):
        """Supprime chez le fournisseur d'IA les fichiers d'étapes interrompues (plantage entre l'envoi et le nettoyage). La clé reste côté PowerShell :
        Python ne la lit jamais. Renvoie le nombre d'identifiants traités."""
        if not self.enabled:
            return 0
        found = self._orphan_file_ids(self.now())
        if not found:
            return 0
        ids = sorted({i for v in found.values() for i in v})
        fd, tmp = tempfile.mkstemp(prefix="bk-files-", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump({"ids": ids}, f)
            proc = subprocess.run(self._files_cleanup_argv(tmp), capture_output=True, text=True, timeout=180, cwd=self.root,
                                  env=dict(os.environ, BK_ROOT=self.root))
            done = proc.returncode == 0
        except (OSError, subprocess.SubprocessError) as e:
            sys.stderr.write(f"projects files cleanup: {type(e).__name__}\n")
            done = False
        finally:
            try:
                os.remove(tmp)
            except OSError:
                pass
        if done:
            for path in found:
                try:
                    pp.atomic_write_bytes(path, json.dumps({"uploaded": [], "produced": []}).encode("utf-8"))
                except OSError:
                    pass
        return len(ids) if done else 0
