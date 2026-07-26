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

# Every array-valued column is a bracketed segment, in file order. The first is
# transit_id (column 3), so array k corresponds to column k+2:
#   bp_flux=11 -> 9   bp_flux_error=12 -> 10   rp_flux=16 -> 14
#   rp_flux_error=17 -> 15   variability_flag_bp_reject=46 -> 44
#   variability_flag_rp_reject=47 -> 45
A_BP,A_BPE,A_RP,A_RPE,A_BREJ,A_RREJ=9,10,14,15,44,45
NEED=A_RREJ

# Slice out the bracketed segments up to the highest index we need, rather than
# re-scanning from the start for each one.
def segs(lb,upto=NEED):
 out={};pos=-1
 for k in range(1,upto+1):
  pos=lb.find(b"[",pos+1)
  if pos<0:break
  e=lb.find(b"]",pos)
  if e<0:break
  out[k]=lb[pos+1:e];pos=e
 return out

# Mean and population stddev of the finite values, for the SNR/CV features.
def MS(b,Q=re.compile(rb"-?\d+\.?\d*(?:[eE][+-]?\d+)?")):
 v=[f for f in map(float,Q.findall(b))if f==f]
 if not v:return 0.0,0.0,0
 m=sum(v)/len(v)
 return m,(sum((x-m)**2 for x in v)/len(v))**.5,len(v)

# Fraction of epochs ESA's variability pipeline rejected. This is the ML target:
# it is ESA's own curation, not anything derivable from the flux summary stats.
def RF(b):
 n=b.count(b"rue")+b.count(b"alse")
 return (b.count(b"rue")/n if n else 0.0),n

# Parses a run of complete lines; sk tracks whether the CSV header was consumed.
def P(raw,sk):
 pos=0;N=len(raw);out=[]
 while pos<N:
  nl=raw.find(b"\n",pos);nl=N if nl<0 else nl;lb=raw[pos:nl];pos=nl+1
  if not lb or lb[0]==35:continue
  if not sk:sk=True;continue
  if b"["not in lb or not(m:=R.match(lb)):continue
  sid=int(m.group(1));S=segs(lb)
  if A_RP not in S:continue
  BB=S[A_BP];RB=S[A_RP];bn,bx,nb=F(BB);rn,rx,nr=F(RB)
  if nb<2 and nr<2:continue
  pct=max(c for c in((bx-bn)/abs(bn)*100 if nb>=2 and bn else None,(rx-rn)/abs(rn)*100 if nr>=2 and rn else None)if c is not None)if(nb>=2 or nr>=2)else 0
  # Quality features: SNR is flux/error, CV is the scatter relative to the mean.
  bm,bs,_=MS(BB);rm,rs,_=MS(RB)
  be,_,_=MS(S.get(A_BPE,b""));re_,_,_=MS(S.get(A_RPE,b""))
  brf,bn2=RF(S.get(A_BREJ,b""));rrf,rn2=RF(S.get(A_RREJ,b""))
  rej=(brf*bn2+rrf*rn2)/(bn2+rn2)if(bn2+rn2)else 0.0
  out.append((sid,bn,bx,rn,rx,int(nb),int(nr),round(pct,4),
              round(bm/be if be else 0,4),round(rm/re_ if re_ else 0,4),
              round(bs/bm if bm else 0,4),round(rs/rm if rm else 0,4),
              round(rej,4),bn2+rn2))
 return sk,out
D=os.environ.get("GAIA_CACHE","/home/irisowner/dev/data/in")
O=os.environ.get("GAIA_OUT","/home/irisowner/dev/data/out")
# The benchmark is the first 20 archive files: EpochPhotometry_000000-003111
# through EpochPhotometry_020985-021233. Excludes any *_test.csv.gz fixture.
ps=sorted(os.path.join(D,f)for f in os.listdir(D)if f.startswith("EpochPhotometry_0")and f.endswith(".csv.gz"))[:20]
# One worker per core: this is CPU-bound (inflate + float parsing), so
# oversubscribing adds context-switching and memory pressure for nothing.
rows=[r for rs in ProcessPoolExecutor(max_workers=max(1,min(len(ps),os.cpu_count()or 4)),mp_context=FK).map(S,ps)for r in rs]
for sql in("DROP TABLE IF EXISTS GaiaFluxStats","CREATE TABLE GaiaFluxStats (source_id BIGINT,bp_min DOUBLE,bp_max DOUBLE,rp_min DOUBLE,rp_max DOUBLE,n_bp INTEGER,n_rp INTEGER,pct_change DOUBLE)"):
 iris.sql.exec(sql)
stmt=iris.sql.prepare("INSERT INTO GaiaFluxStats VALUES (?,?,?,?,?,?,?,?)")
for r in rows:stmt.execute(r[0],r[1],r[2],r[3],r[4],r[5],r[6],r[7])
# GaiaQualityStats feeds the NGBoost custom model. reject_fraction comes from
# ESA's own per-epoch variability_flag_*_reject arrays, so it is not derivable
# from the columns we train on - there is something real to learn. Sources with no flag data at all are excluded: a target of 0.0 there
# would mean "ESA rejected nothing", not "ESA said nothing".
for sql in("DROP TABLE IF EXISTS GaiaQualityStats","CREATE TABLE GaiaQualityStats (source_id BIGINT,n_bp INTEGER,n_rp INTEGER,bp_snr DOUBLE,rp_snr DOUBLE,bp_cv DOUBLE,rp_cv DOUBLE,bp_min DOUBLE,bp_max DOUBLE,rp_min DOUBLE,rp_max DOUBLE,pct_change DOUBLE,reject_fraction DOUBLE)"):
 iris.sql.exec(sql)
qs=iris.sql.prepare("INSERT INTO GaiaQualityStats VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)")
nq=0
for r in rows:
 if r[13]:qs.execute(r[0],r[5],r[6],r[8],r[9],r[10],r[11],r[1],r[2],r[3],r[4],r[7],r[12]);nq+=1
print(f"{nq} sources with ESA epoch-quality flags -> GaiaQualityStats")
# result.csv is the challenge answer: every source whose relative flux swing
# exceeds 100%. This is a SQL predicate, exactly computable, so there is nothing
# to predict - the IntegratedML work is the quality models below, which target
# something a WHERE clause cannot produce.
rs=iris.sql.exec("SELECT source_id,bp_min,bp_max,rp_min,rp_max,pct_change FROM GaiaFluxStats WHERE pct_change>100 ORDER BY pct_change DESC")
out=list(rs)
hdr="source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change\n"
buf=hdr+"".join(f"{r[0]},{float(r[1]):.6f},{float(r[2]):.6f},{float(r[3]):.6f},{float(r[4]):.6f},{float(r[5]):.4f}\n"for r in out)
os.makedirs(O,exist_ok=True)
with open(os.path.join(O,"result.csv"),"w")as fh:fh.write(buf)
print(f"{len(out)} variable sources -> {O}/result.csv")

# Second output: the IntegratedML deliverable proper. Both PREDICT() calls are
# backed by the same NGBoost model file - one returns the distribution mean, the
# other its standard deviation - so each row carries its own error bar. This is
# a separate file on purpose: result.csv is the challenge answer and must not
# change shape.
try:
 # No ORDER BY PREDICT(...): sorting on a model call re-invokes it per comparison
 # and never returns - measured, 2,000 rows alone did not finish in 100s, while
 # the same two PREDICT()s in the SELECT list take 0.2s. Sort the small result in
 # Python instead.
 # source_id breaks ties: thousands of rows share a predicted value at 4 decimal
 # places, so sorting on pred alone leaves their order down to however SQL
 # returned them and the file reshuffles between runs for no real reason.
 qr=sorted(iris.sql.exec("SELECT source_id,reject_fraction,PREDICT(GaiaDataQuality) AS pred,PREDICT(GaiaQualityUncertainty) AS sigma,n_bp,n_rp,pct_change FROM GaiaQualityStats"),key=lambda r:(-float(r[2]),int(r[0])))
 qb="source_id,esa_reject_fraction,predicted_reject_fraction,prediction_sigma,n_bp,n_rp,percentage_change\n"+"".join(f"{r[0]},{float(r[1]):.4f},{float(r[2]):.4f},{float(r[3]):.4f},{r[4]},{r[5]},{float(r[6]):.4f}\n"for r in qr)
 # Context manager, not a bare open(...).write(...): the implicit close there is
 # left to the garbage collector, so a full or read-only volume surfaces as a
 # truncated CSV with no error rather than an exception at the write.
 with open(os.path.join(O,"quality.csv"),"w")as fh:fh.write(qb)
 # Materialize the two predictions into stored columns, as GaiaQualityScored. The
 # RLM analyst slices this table with aggregates, and PREDICT() inside an
 # aggregate or ORDER BY is re-evaluated per row-comparison and effectively never
 # returns; as stored columns the same scans are milliseconds.
 #
 # INSERT...SELECT, not UPDATE...SET pred=PREDICT(...). Measured on all 74,998
 # rows: this INSERT takes 3.9s, whereas the equivalent UPDATE moved roughly two
 # rows per second - it would need hours, and because it also takes a row lock per
 # row it overflows the lock table and dies with SQLCODE -110 partway through,
 # leaving a half-scored table that every later AVG() silently averages over.
 # PREDICT() in a SELECT list is the fast path (~0.1 ms/row after model load).
 for sql in("DROP TABLE IF EXISTS GaiaQualityScored","CREATE TABLE GaiaQualityScored (source_id BIGINT,n_bp INTEGER,n_rp INTEGER,bp_snr DOUBLE,rp_snr DOUBLE,bp_cv DOUBLE,rp_cv DOUBLE,bp_min DOUBLE,bp_max DOUBLE,rp_min DOUBLE,rp_max DOUBLE,pct_change DOUBLE,reject_fraction DOUBLE,pred_reject DOUBLE,pred_sigma DOUBLE)","INSERT INTO GaiaQualityScored SELECT source_id,n_bp,n_rp,bp_snr,rp_snr,bp_cv,rp_cv,bp_min,bp_max,rp_min,rp_max,pct_change,reject_fraction,PREDICT(GaiaDataQuality),PREDICT(GaiaQualityUncertainty) FROM GaiaQualityStats"):
  iris.sql.exec(sql)
 # Assert the materialization is complete. A partial fill is invisible in every
 # aggregate that follows it, so it has to be caught here rather than surfacing as
 # a confidently wrong report.
 nfill=list(iris.sql.exec("SELECT COUNT(*),COUNT(pred_reject) FROM GaiaQualityScored"))[0]
 if int(nfill[1])!=int(nfill[0]) or int(nfill[0])!=len(qr):raise RuntimeError(f"scored {nfill[1]} of {nfill[0]} rows, expected {len(qr)}")
 print(f"{nfill[1]} rows scored -> GaiaQualityScored (pred_reject, pred_sigma)")
 err=[abs(float(r[1])-float(r[2]))for r in qr];sg=[float(r[3])for r in qr]
 # Hoist the mean out of the comprehension: recomputing it per row is O(n^2) and
 # takes minutes at 75k rows.
 obs=[float(r[1])for r in qr];mu=sum(obs)/len(obs)
 mae=sum(err)/len(err);base=sum(abs(o-mu)for o in obs)/len(obs)
 print(f"{len(qr)} sources -> {O}/quality.csv")
 print(f"NGBoost reject_fraction MAE {mae:.4f} vs {base:.4f} predicting the mean ({100*(1-mae/base):.0f}% better)")
 print(f"mean predicted sigma {sum(sg)/len(sg):.4f}")
except Exception as e:
 print(f"quality.csv skipped: {e}")
