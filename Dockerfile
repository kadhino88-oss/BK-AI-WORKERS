# BK-AI-WORKERS — image Linux (PowerShell 7 + Python 3)
# PowerShell >= 7.5 requis (ConvertFrom-Json -DateKind, utilise par le moteur). Teste avec 7.6.
FROM mcr.microsoft.com/powershell:ubuntu-24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 rsync ca-certificates tzdata \
 && rm -rf /var/lib/apt/lists/*

ENV TZ=Europe/Zurich \
    PYTHONUNBUFFERED=1 \
    BK_ROOT=/data/app \
    BK_PWSH=pwsh \
    BK_PORT=8787

# Le code vit dans /opt/bk (immuable) ; au demarrage il est synchronise vers
# /data/app (volume persistant) sans ecraser l'etat (state/, data/, runtime/...).
WORKDIR /opt/bk
COPY . /opt/bk
RUN chmod +x /opt/bk/deploy/entrypoint.sh && sed -i 's/\r$//' /opt/bk/deploy/entrypoint.sh

EXPOSE 8787
ENTRYPOINT ["/opt/bk/deploy/entrypoint.sh"]
