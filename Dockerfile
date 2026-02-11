FROM python:3.11-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        libcurl4-openssl-dev \
        libssl-dev \
        python3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

RUN python -m pip install --upgrade pip \
    && git clone --depth=1 https://github.com/blawar/nut /opt/nut \
    && pip install requests pillow \
    && pip install -r /opt/nut/requirements.txt

COPY scripts/build_media_db.sh scripts/export_offline_db.py /usr/local/bin/
RUN chmod +x /usr/local/bin/build_media_db.sh /usr/local/bin/export_offline_db.py

ENTRYPOINT ["/usr/local/bin/build_media_db.sh"]