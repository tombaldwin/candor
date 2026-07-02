import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt, matplotlib.patches as mp
INK="#1f2933"; MUTE="#7b8794"; CANDOR="#0f9d8f"; ALONE="#e8833a"
plt.rcParams.update({"font.family":"DejaVu Sans","font.size":12,"text.color":INK,"figure.dpi":160})
fig,ax=plt.subplots(figsize=(9.5,4.8))
fig.subplots_adjust(top=0.74,bottom=0.14,left=0.13,right=0.97)
metrics=["Tokens","Tool calls","Wall-clock"]; mult=[17,50,38]
y=list(range(len(metrics)))[::-1]
ax.barh(y,mult,color=ALONE,alpha=0.22,height=0.5,zorder=2)
ax.barh(y,[1]*len(metrics),color=CANDOR,height=0.5,zorder=3)
for yi,m in zip(y,mult): ax.text(m+1.3,yi,f"{m}× more",va="center",fontsize=13,color=ALONE,fontweight="bold")
ax.set_yticks(y); ax.set_yticklabels(metrics,fontsize=13)
ax.set_xlim(0,62); ax.set_ylim(-0.6,2.6); ax.set_xticks([]); ax.tick_params(length=0)
for s in ["top","right","bottom","left"]: ax.spines[s].set_visible(False)
ax.legend([mp.Patch(color=CANDOR),mp.Patch(color=ALONE,alpha=0.22)],
          ["agent + candor (baseline, 1×)","agent alone"],loc="upper right",frameon=False,fontsize=10.5,
          bbox_to_anchor=(1.0,1.18))
fig.text(0.012,0.93,"The cost of one “what does this touch?” answer",fontsize=16,fontweight="bold",color=INK)
fig.text(0.012,0.855,"how much more an unaided agent spends re-deriving the call graph vs one candor query",fontsize=10.8,color=MUTE)
fig.text(0.012,0.02,"candor's single query ≈ 24k tokens · 1 tool call · ~8 s.  Bars = the unaided-agent multiple (blast-radius question, measured).",fontsize=9.5,color=MUTE)
fig.savefig("efficiency.svg",bbox_inches="tight"); fig.savefig("efficiency.png",bbox_inches="tight",dpi=170)
print("regenerated")
