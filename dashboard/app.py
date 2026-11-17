"""PRISM-Gate live dashboard: streamlit run dashboard/app.py"""
import httpx
import pandas as pd
import streamlit as st

BRAIN = "http://127.0.0.1:8090"
st.set_page_config(page_title="PRISM-Gate", layout="wide")
st.title("PRISM-Gate: healthcare LLM traffic")

try:
    s = httpx.get(f"{BRAIN}/stats", timeout=3).json()
except Exception as e:
    st.error(f"Brain service not reachable: {e}")
    st.stop()

c = s["counters"]
r = s["router"]
k1, k2, k3, k4 = st.columns(4)
k1.metric("Requests routed", c["requests"])
k2.metric("PHI kept local", c["phi_kept_local"])
k3.metric("Bandit updates", r["updates"])
k4.metric("Mean reward", f"{r['mean_reward']:.3f}" if r["mean_reward"] is not None else "-")

left, right = st.columns(2)
with left:
    st.subheader("Requests by priority")
    st.bar_chart(pd.Series(c["by_priority"], name="requests"))
    st.subheader("Arm pulls (learned routing)")
    st.bar_chart(pd.Series(r["pulls"], name="pulls"))
    if r["disabled"]:
        st.warning("Arms out of rotation: " + ", ".join(r["disabled"]))
with right:
    st.subheader("Learning curve (rolling mean reward)")
    if r["recent"]:
        h = pd.DataFrame(r["recent"])
        st.line_chart(h.set_index("n")["reward"].rolling(20, min_periods=1).mean())
    st.subheader("Latest decisions")
    if s["recent"]:
        d = pd.DataFrame(s["recent"])[["priority", "phi", "provider", "model", "reason", "decide_ms"]]
        st.dataframe(d.iloc[::-1], use_container_width=True, height=300)

st.divider()
st.subheader("Freshness Check (Tavily + Bifrost)")
answer = st.text_area("Paste an AI answer to check", height=140,
                      placeholder="e.g. Drug X costs Rs 500 per pack and is approved by DRAP for children over 2.")
if st.button("Check freshness") and answer.strip():
    with st.spinner("Extracting claims, searching live sources, judging..."):
        res = httpx.post(f"{BRAIN}/verify", json={"answer": answer}, timeout=180)
    if res.status_code != 200:
        st.error(res.text)
    else:
        out = res.json()
        st.metric("Overall freshness score", out["overall_score"] if out["overall_score"] is not None else "-")
        for cl in out["claims"]:
            icon = {"current": "🟢", "check": "🟡", "stale": "🔴"}.get(cl["label"], "⚪")
            with st.expander(f"{icon} {cl['text']}  ({cl['category']}, score {cl['score']})"):
                st.write(f"Verdict: **{cl['verdict']}**")
                if cl["correction"]:
                    st.write(f"Current fact: {cl['correction']}")
                for src in cl["sources"]:
                    st.markdown(f"- [{src['title'] or src['url']}]({src['url']}) {src['published'] or ''}")
