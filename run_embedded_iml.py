import os,re,importlib.util as IU;Z=(IU.find_spec("isal")and __import__("isal.isal_zlib",fromlist=["x"]))or __import__("zlib")
from concurrent.futures import ProcessPoolExecutor
import iris
R=re.compile(rb"^[^,]+,(\d+),")
F=lambda b,P=re.compile(rb"-?\d+\.?\d*(?:[eE][+-]?\d+)?"): (lambda v:(min(v),max(v),len(v))if v else(0,0,0))([float(x)for x in P.findall(b)])
def S(p):
 try:raw=Z.decompress(open(p,"rb").read(),47)
 except:return []
 pos=0;N=len(raw);sk=False;out=[]
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
 return out
D=os.environ.get("GAIA_CACHE","/app/.data/in");D=D if os.path.isdir(D)else"/opt/irisapp/data/gaia_cache"
O=os.environ.get("GAIA_OUT","/app/.data/out");ps=sorted(os.path.join(D,f)for f in os.listdir(D)if"EpochPhotometry"in f and f.endswith(".gz"))
rows=[r for rs in ProcessPoolExecutor(max_workers=min(len(ps),(os.cpu_count()or 4)*3)).map(S,ps)for r in rs]
for sql in("DROP TABLE IF EXISTS GaiaFluxStats","CREATE TABLE GaiaFluxStats (source_id BIGINT,bp_min DOUBLE,bp_max DOUBLE,rp_min DOUBLE,rp_max DOUBLE,n_bp INTEGER,n_rp INTEGER,pct_change DOUBLE,is_variable INTEGER)"):
 iris.sql.exec(sql)
stmt=iris.sql.prepare("INSERT INTO GaiaFluxStats VALUES (?,?,?,?,?,?,?,?,?)")
for r in rows:stmt.execute(r[0],r[1],r[2],r[3],r[4],r[5],r[6],r[7],1 if r[7]>100 else 0)
trained={r[0]for r in iris.sql.exec("SELECT * FROM INFORMATION_SCHEMA.ML_TRAINED_MODELS")}
if"GaiaVariability"not in trained:iris.sql.exec("TRAIN MODEL GaiaVariability")
rs=iris.sql.exec("SELECT source_id,bp_min,bp_max,rp_min,rp_max,pct_change,PREDICT(GaiaVariability) AS p FROM GaiaFluxStats ORDER BY pct_change DESC")
out=[r for r in rs if r[6]==1]
hdr="source_id,bp_min_flux,bp_max_flux,rp_min_flux,rp_max_flux,percentage_change\n"
buf=hdr+"".join(f"{r[0]},{float(r[1]):.6f},{float(r[2]):.6f},{float(r[3]):.6f},{float(r[4]):.6f},{float(r[5]):.4f}\n"for r in out)
os.makedirs(O,exist_ok=True);open(os.path.join(O,"result.csv"),"w").write(buf);print(buf,end="")
