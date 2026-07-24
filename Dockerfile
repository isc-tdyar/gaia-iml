# AI Hub (%AI.Agent + %AI.Tools.SQL) only ships in the 2026.3 AI preview images,
# which are not on Docker Hub. This tag is the community edition, so no license
# key is needed; ISC employees can pull it directly. Anyone else: see the README
# for the evaluation.intersystems.com tar download, then override with
#   docker compose build --build-arg IMAGE=<your local tag>
ARG IMAGE=docker.iscinternal.com/docker-intersystems/intersystems/irishealth-community:2026.3.0AI.126.0
FROM $IMAGE

WORKDIR /home/irisowner/dev
COPY . .

## Embedded Python environment
ENV IRISUSERNAME="_SYSTEM"
ENV IRISPASSWORD="SYS"
ENV IRISNAMESPACE="USER"
ENV PYTHON_PATH=/usr/irissys/bin/
ENV PATH="/usr/irissys/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/irisowner/bin"

## intersystems-iris-automl supplies the IRISModel custom-classifier contract;
## isal is SIMD-accelerated gzip (inflate is ~70% of the scan). Verify the isal
## import at build time rather than silently falling back at runtime.
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc g++ \
 && rm -rf /var/lib/apt/lists/* \
 && /usr/irissys/bin/irispython -m pip install --no-cache-dir \
        --index-url https://registry.intersystems.com/pypi/simple \
        --target /usr/irissys/mgr/python \
        intersystems-iris-automl isal \
 && /usr/irissys/bin/irispython -c "from isal import isal_zlib; print('isal OK')" \
 && chown -R irisowner:irisowner /home/irisowner/dev

## Install the custom IRISModel classifier while still root — the Classifiers dir
## is root-owned, so the later irisowner build step cannot write into it.
RUN CDIR=$(/usr/irissys/bin/irispython -c "import os,iris_automl;print(os.path.join(os.path.dirname(iris_automl.__file__),'Classifiers'))") \
 && cp /home/irisowner/dev/gaia_variability_iris_model.py "$CDIR/" \
 && echo "custom classifier installed to $CDIR"
USER irisowner

## Compile the routine + agent class, then pre-train GaiaVariability so the
## contest run only pays for ingest + PREDICT, not the ~33s training.
RUN --mount=type=bind,src=.,dst=. \
    iris start IRIS && \
    iris merge IRIS merge.cpf && \
    iris session IRIS < iris.script && \
    /usr/irissys/bin/irispython /home/irisowner/dev/pretrain_gaia_model.py && \
    iris stop IRIS quietly safely
