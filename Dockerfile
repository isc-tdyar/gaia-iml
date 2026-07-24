ARG IRIS_IMAGE=docker.iscinternal.com/docker-intersystems/intersystems/irishealth-community:2026.2.0AI.162.0
FROM ${IRIS_IMAGE}
USER root
RUN apt-get update && apt-get install -y --no-install-recommends gcc g++ && rm -rf /var/lib/apt/lists/*
RUN /usr/irissys/bin/irispython -m pip install --no-cache-dir \
    --index-url https://registry.intersystems.com/pypi/simple \
    --target /usr/irissys/mgr/python \
    intersystems-iris-automl isal
COPY RunScript.mac /app/RunScript.mac
COPY run_embedded_iml.py /app/run_embedded_iml.py
COPY gaia_variability_iris_model.py /app/gaia_variability_iris_model.py
COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/
USER irisowner
ENTRYPOINT ["/tini", "--", "/docker-entrypoint.sh"]
