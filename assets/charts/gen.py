import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib import font_manager as fm

INK="#1f2933"; MUTE="#7b8794"; GRID="#e4e7eb"
CANDOR="#0f9d8f"   # teal — agent + candor
ALONE="#e8833a"    # amber — agent alone
plt.rcParams.update({
  "font.family":"DejaVu Sans","font.size":12,"text.color":INK,
  "axes.edgecolor":MUTE,"axes.labelcolor":INK,"xtick.color":INK,"ytick.color":INK,
  "axes.spines.top":False,"axes.spines.right":False,"figure.dpi":160,
})
tiers=["Haiku 4.5","Sonnet 4.6","Opus 4.8","Fable 5"]
x=range(len(tiers))
delta_ctl=[60.4,90.6,97.3,99.0]; delta_tx=[100,100,100,100]
bot_ctl=[81.7,99.5,99.5,100.0]; bot_tx=[99.0,100,100,100]

# ---------- Chart 1: completeness gradient, 2 panels ----------
fig,axes=plt.subplots(1,2,figsize=(11,4.6),sharey=True)
for ax,(name,ctl,tx) in zip(axes,[("git-delta · 61-fn deep tree",delta_ctl,delta_tx),
                                   ("bottom · 26-fn greppable tree",bot_ctl,bot_tx)]):
    ax.fill_between(x,ctl,tx,color=CANDOR,alpha=0.07,zorder=1)
    ax.plot(x,tx,"-o",color=CANDOR,lw=2.6,ms=7,zorder=3,label="agent + candor")
    ax.plot(x,ctl,"-o",color=ALONE,lw=2.6,ms=7,zorder=3,label="agent alone")
    ax.set_title(name,fontsize=12.5,color=INK,pad=10,loc="left",fontweight="bold")
    ax.set_xticks(list(x)); ax.set_xticklabels(tiers,fontsize=10.5)
    ax.set_ylim(50,103); ax.set_yticks([60,70,80,90,100])
    ax.grid(axis="y",color=GRID,lw=1); ax.set_axisbelow(True)
    ax.tick_params(length=0)
    for xi,(c,t) in enumerate(zip(ctl,tx)):
        ax.annotate(f"{c:.0f}",(xi,c),textcoords="offset points",xytext=(0,-15),ha="center",fontsize=9,color=ALONE)
axes[0].set_ylabel("% of true blast radius found")
axes[0].legend(loc="lower right",frameon=False,fontsize=11)
fig.suptitle("A cheap model + candor matches a frontier model on “what does this change touch?”",
             x=0.012,ha="left",fontsize=15,fontweight="bold",y=1.02)
fig.text(0.012,0.955,"% of the true transitive blast radius found, by model capability — two real ≈30k-LOC codebases, N=8/tier",
         ha="left",fontsize=10.5,color=MUTE)
fig.text(0.012,-0.04,"candor's answer is one deterministic query, so it's complete at every tier; an unaided agent's completeness tracks model strength.",
         ha="left",fontsize=9.5,color=MUTE)
fig.tight_layout(rect=[0,0,1,0.93])
fig.savefig("completeness.svg",bbox_inches="tight"); fig.savefig("completeness.png",bbox_inches="tight",dpi=170)
plt.close(fig)

# ---------- Chart 2: efficiency (one blast-radius answer) ----------
fig,ax=plt.subplots(figsize=(9,3.8))
metrics=["Tokens","Tool calls","Wall-clock"]
mult=[17,50,38]   # how much MORE the unaided agent spends (x)
cand_abs=["~24k tokens","1 query","~8 s"]
y=range(len(metrics))[::-1]
ax.barh(list(y),[1]*len(metrics),color=CANDOR,height=0.55,zorder=3,label="agent + candor")
ax.barh(list(y),mult,color=ALONE,alpha=0.22,height=0.55,zorder=2,label="agent alone")
for yi,m,c in zip(list(y),mult,cand_abs):
    ax.text(1.4,yi+0.0,f"{m}× more",va="center",fontsize=11.5,color=ALONE,fontweight="bold")
    ax.text(0.0-0.4,yi,c,va="center",ha="right",fontsize=10,color=CANDOR)
ax.set_yticks(list(y)); ax.set_yticklabels(metrics,fontsize=12)
ax.set_xlim(0,55); ax.set_xticks([]); ax.tick_params(length=0)
for s in ["top","right","bottom"]: ax.spines[s].set_visible(False)
ax.spines["left"].set_visible(False)
ax.set_title("The cost of one “what does this touch?” answer",fontsize=15,fontweight="bold",loc="left",pad=24)
fig.text(0.012,0.88,"candor = baseline (1×); an unaided agent re-deriving the call graph spends multiples more",ha="left",fontsize=10.5,color=MUTE)
ax.legend(loc="lower right",frameon=False,fontsize=10.5)
fig.tight_layout()
fig.savefig("efficiency.svg",bbox_inches="tight"); fig.savefig("efficiency.png",bbox_inches="tight",dpi=170)
plt.close(fig)
print("wrote:", __import__("os").listdir("."))
