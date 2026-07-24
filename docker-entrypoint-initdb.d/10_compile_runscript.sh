#!/bin/bash
set -e
IRIS_INSTANCE=${ISC_PACKAGE_INSTANCENAME:-IRIS}
MAC_FILE="/app/RunScript.mac"

echo "=== Compiling RunScript.mac ==="
WRITE_SCRIPT=$(python3 -c "
lines = open('$MAC_FILE').read().rstrip('\n').split('\n')
print(' set r = ##class(%Routine).%New(\"RunScript\")')
for line in lines:
    esc = line.replace('\"', '\"\"')
    print(f' do r.WriteLine(\"{esc}\")')
print(' set sc = r.%Save() write \"save:\",sc,!')
print(' set sc = r.Compile() write \"compile:\",sc,!')
print(' halt')
")
echo "$WRITE_SCRIPT" | iris session "$IRIS_INSTANCE" -U USER > /proc/1/fd/1 2>&1

echo "=== Pre-training GaiaVariability model ==="
/usr/irissys/bin/irispython /docker-entrypoint-initdb.d/05_pretrain_gaia_model.py > /proc/1/fd/1 2>&1

echo "=== Setup complete ==="
