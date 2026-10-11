import sys, numpy as np
sys.path.insert(0,"/Users/lichtcui/Documents/playground/tts/p3/harness")
from runlib import load_audio
p=sys.argv[1]
x,sr=load_audio(p)
x=np.asarray(x,dtype=np.float64)
W=int(0.3*sr); hop=int(0.05*sr)
m=(len(x)-W)//hop
X=np.stack([x[k*hop:k*hop+W:4] for k in range(m)]).astype(np.float32)
nrm=np.linalg.norm(X,axis=1,keepdims=True)
X=X/(nrm+1e-12)
idx=np.arange(m)*hop/sr
G=X@X.T
lag=np.abs(np.subtract.outer(idx,idx))
G[lag<0.5]=-1
k=np.argsort(G,axis=None)[-10:]
print(f"{p} dur={len(x)/sr:.2f}s")
seen=set()
for ii in k[::-1]:
    p_,q_=np.unravel_index(ii,G.shape)
    key=(min(p_,q_),max(p_,q_))
    if key in seen: continue
    seen.add(key)
    print(f"  sim={G[p_,q_]:.6f} t_a={idx[p_]:7.2f} t_b={idx[q_]:7.2f} lag={abs(idx[p_]-idx[q_]):6.2f}")
