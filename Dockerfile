# The 2026.3 AI preview community image, which carries both halves of this entry:
# embedded Python, IntegratedML and the %ML.AutoML.Provider the custom IRISModel
# regressors plug into, plus AI Hub (%AI.Agent, %AI.Tool) for the four analysis
# reports. Built this way, every documented command works with no flags.
#
# ISC employees pull this tag from docker.iscinternal.com; everyone else
# downloads the tarball from evaluation.intersystems.com and `docker load`s it.
#
# Fallback, verified and fully supported: the public community image needs no
# login, no VPN and no license key, and runs the whole contest pipeline. It has
# no AI Hub, so `Gaia.Install` skips the four analysis classes and says which
# ones -- ^RunScript, result.csv and quality.csv are unaffected.
#   docker compose build \
#     --build-arg IMAGE=containers.intersystems.com/intersystems/iris-community:2026.1
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
 && /usr/irissys/bin/irispython -m pip install --no-cache-dir \
        --target /usr/irissys/mgr/python ngboost \
 && /usr/irissys/bin/irispython -c "from isal import isal_zlib; print('isal OK')" \
 && /usr/irissys/bin/irispython -c "from ngboost import NGBRegressor; print('ngboost OK')" \
 && chown -R irisowner:irisowner /home/irisowner/dev

## Install the custom IRISModel regressors while still root - the Regressors
## dir is root-owned, so the later irisowner build step cannot write into it.
##
## Regressors/, not Classifiers/. AutoML loads the two pools via separate USING
## keys (pathtoregressors / pathtoclassifiers), and a regression target never
## looks in Classifiers at all - it just reports NoEstimatorChosen.
##
## The mean and sigma heads are separate files in separate directories because
## load_models() imports every .py in the directory handed to it, and because
## AutoML forwards only isc_models_disabled/n_jobs/problem_type/random_state/
## verbose into IRISModel(**kwargs) and drops any extra USING keys, so the head
## cannot be chosen by parameter. Their shared estimator goes on the embedded
## Python path so both can import it.
##
## GaiaVariableType goes in Classifiers/ for the same reason in reverse: its
## target is categorical, so AutoML only ever searches the classifier pool. Its
## feature-extraction module goes on the embedded Python path because both the
## pre-training step and the ingest pipeline import it.
RUN ADIR=$(/usr/irissys/bin/irispython -c "import os,iris_automl;print(os.path.dirname(iris_automl.__file__))") \
 && mkdir -p "$ADIR/Regressors/gaia_quality_mean" \
             "$ADIR/Regressors/gaia_quality_sigma" \
             "$ADIR/Classifiers/gaia_variable_type" \
 && cp /home/irisowner/dev/gaia_quality_mean_model.py  "$ADIR/Regressors/gaia_quality_mean/" \
 && cp /home/irisowner/dev/gaia_quality_sigma_model.py "$ADIR/Regressors/gaia_quality_sigma/" \
 && cp /home/irisowner/dev/gaia_variable_type_model.py "$ADIR/Classifiers/gaia_variable_type/" \
 && cp /home/irisowner/dev/gaia_quality_estimator.py /usr/irissys/mgr/python/ \
 && cp /home/irisowner/dev/gaia_lightcurve_features.py /usr/irissys/mgr/python/ \
 && cp /home/irisowner/dev/gaia_variable_type_model.py /usr/irissys/mgr/python/ \
 && echo "custom models installed under $ADIR"
USER irisowner

## Compile the routine + agent classes, then pre-train the quality models so
## the contest run only pays for ingest + PREDICT, not the training.
RUN --mount=type=bind,src=.,dst=. \
    iris start IRIS && \
    iris merge IRIS merge.cpf && \
    iris session IRIS < iris.script && \
    /usr/irissys/bin/irispython /home/irisowner/dev/pretrain_gaia_model.py && \
    /usr/irissys/bin/irispython /home/irisowner/dev/pretrain_variable_type.py && \
    iris stop IRIS quietly safely
