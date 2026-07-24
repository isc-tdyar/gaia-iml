import os,re,importlib.util as IU;Z=(IU.find_spec("isal")and __import__("isal.isal_zlib",fromlist=["x"]))or __import__("zlib")
import multiprocessing as MP
from concurrent.futures import ProcessPoolExecutor
import iris
# fork, not spawn: spawn re-imports this module in every child, which re-runs the
# top-level pipeline recursively. Linux defaults to fork, macOS to spawn, so pin it.
FK=MP.get_context("fork")
R=re.compile(rb"^[^,]+,(\d+),")
# v==v drops NaN: the challenge says to ignore missing/null/NaN flux values, and
# min()/max() propagate NaN unpredictably if they are left in.
F=lambda b,Q=re.compile(rb"-?\d+\.?\d*(?:[eE][+-]?\d+)?"): (lambda v:(min(v),max(v),len(v))if v else(0,0,0))([f for f in map(float,Q.findall(b))if f==f])

# Stream the inflate in 4MB chunks. Holding a whole decompressed file in every
# worker at once exhausts RAM and the pool dies with BrokenProcessPool; only the
# trailing partial line needs to be carried between chunks.
def S(p):
 d=Z.decompressobj(47);sk=False;out=[];tail=b""
 with open(p,"rb")as fh:
  while 1:
   blk=fh.read(1<<22)
   if not blk:break
   buf=tail+d.decompress(blk);nl=buf.rfind(b"\n")
   if nl<0:tail=buf;continue
   tail=buf[nl+1:];sk,got=P(buf[:nl],sk);out+=got
 if tail:sk,got=P(tail,sk);out+=got
 return out

# Parses a run of complete lines; sk tracks whether the CSV header was consumed.
def P(raw,sk):
 pos=0;N=len(raw);out=[]
 while pos<N:
  nl=raw.find(b"\n",pos);nl=N if nl<0 else nl;lb=raw[pos:nl];pos=nl+1
  if not lb or lb[0]==35:continue
  if not sk:sk=True;continue
  if b"["not in lb or not(m:=R.match(lb)):continue
  sid=int(m.group(1));bp=-1;[bp:=lb.find(b"[",bp+1)for _ in range(9)]
  if bp<0:continue
  e=lb.find(b"]",bp);BB=lb[bp+1:e];bp=e;[bp:=lb.find(b"[",bp+1)for _ in range(5)]
  if bp<0:continue
  e=lb.find(b"]",bp);RB=lb[bp+1:e];bn,bx,nb=F(BB);rn,rx,nr=F(RB)
  if nb<2 and nr<2:continue
  pct=max(c for c in((bx-bn)/abs(bn)*100 if nb>=2 and bn else None,(rx-rn)/abs(rn)*100 if nr>=2 and rn else None)if c is not None)if(nb>=2 or nr>=2)else 0
  out.append((sid,bn,bx,rn,rx,int(nb),int(nr),round(pct,4)))
 return sk,out
D=os.environ.get("GAIA_CACHE","/home/irisowner/dev/data/in")
O=os.environ.get("GAIA_OUT","/home/irisowner/dev/data/out")
# The benchmark is the first 20 archive files: EpochPhotometry_000000-003111
# through EpochPhotometry_020985-021233. Excludes any *_test.csv.gz fixture.
ps=sorted(os.path.join(D,f)for f in os.listdir(D)if f.startswith("EpochPhotometry_0")and f.endswith(".csv.gz"))[:20]
# One worker per core: this is CPU-bound (inflate + float parsing), so
# oversubscribing just adds context-switching and memory pressure.
rows=[r for rs in ProcessPoolExecutor(max_workers=max(1,min(len(ps),os.cpu_count()or 4)),mp_context=FK).map(S,ps)for r in rs]
for sql in("DROP TABLE IF EXISTS GaiaFluxStats","CREATE TABLE GaiaFluxStats (source_id BIGINT,bp_min DOUBLE,bp_max DOUBLE,rp_min DOUBLE,rp_max DOUBLE,n_bp INTEGER,n_rp INTEGER,pct_change DOUBLE,is_variable INTEGER)"):
 iris.sql.exec(sql)
stmt=iris.sql.prepare("INSERT INTO GaiaFluxStats VALUES (?,?,?,?,?,?,?,?,?)")
for r in rows:stmt.execute(r[0],r[1],r[2],r[3],r[4],r[5],r[6],r[7],1 if r[7]>100 else 0)
trained={r[0]for r in iris.sql.exec("SELECT * FROM INFORMATION_SCHEMA.ML_TRAINED_MODELS")}
if"GaiaVariability"not in trained:iris.sql.exec("TRAIN MODEL GaiaVariability")
# result.csv is the deterministic answer to the challenge: every source whose
# relative flux swing exceeds 100%. PREDICT() runs alongside it rather than
# gating it — the model is a learned approximation of that rule and drops ~1% of
# true positives, so filtering on it would emit a subtly wrong answer.
rs=iris.sql.exec("SELECT source_id,bp_min,bp_max,rp_min,rp_max,pct_change,PREDICT(GaiaVariability) AS p FROM GaiaFluxStats WHERE pct_change>100 ORDER BY pct_change DESC")
out=list(rs)
hdr="source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change\n"
buf=hdr+"".join(f"{r[0]},{float(r[1]):.6f},{float(r[2]):.6f},{float(r[3]):.6f},{float(r[4]):.6f},{float(r[5]):.4f}\n"for r in out)
os.makedirs(O,exist_ok=True);open(os.path.join(O,"result.csv"),"w").write(buf)
agree=sum(1 for r in out if int(r[6])==1)
print(f"{len(out)} variable sources -> {O}/result.csv")
print(f"PREDICT(GaiaVariability) recall on them: {agree}/{len(out)} ({100.0*agree/max(1,len(out)):.2f}%)")
