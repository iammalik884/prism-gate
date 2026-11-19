"""Builds docs/PRISM-Gate.pptx (python docs/make_deck.py). Numbers come from eval/results of 18 Nov 2026."""
from pptx import Presentation
from pptx.dml.color import RGBColor
from pptx.enum.shapes import MSO_SHAPE
from pptx.enum.text import MSO_ANCHOR, PP_ALIGN
from pptx.util import Inches, Pt

NAVY, TEAL, INK, GREY, LIGHT, RED = (RGBColor(0x12, 0x23, 0x3D), RGBColor(0x0E, 0x8C, 0x8C),
                                     RGBColor(0x1F, 0x29, 0x37), RGBColor(0x5B, 0x64, 0x70),
                                     RGBColor(0xE8, 0xF4, 0xF4), RGBColor(0xB4, 0x23, 0x18))
prs = Presentation()
prs.slide_width, prs.slide_height = Inches(13.333), Inches(7.5)
BLANK = prs.slide_layouts[6]


def text(slide, x, y, w, h, lines, size=18, color=INK, bold=False, align=PP_ALIGN.LEFT):
    tb = slide.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    for i, line in enumerate(lines if isinstance(lines, list) else [lines]):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.text, p.alignment = line, align
        p.font.size, p.font.color.rgb, p.font.bold = Pt(size), color, bold
        p.space_after = Pt(8)
    return tb


def page(title, subtitle=None):
    s = prs.slides.add_slide(BLANK)
    bar = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, 0, prs.slide_width, Inches(1.1))
    bar.fill.solid(); bar.fill.fore_color.rgb = NAVY; bar.line.fill.background()
    text(s, 0.5, 0.18, 12.3, 0.8, title, 30, RGBColor(0xFF, 0xFF, 0xFF), True)
    if subtitle:
        text(s, 0.5, 1.25, 12.3, 0.6, subtitle, 18, TEAL, True)
    return s


def box(s, x, y, w, h, title, body, fill=LIGHT, edge=TEAL):
    r = s.shapes.add_shape(MSO_SHAPE.ROUNDED_RECTANGLE, Inches(x), Inches(y), Inches(w), Inches(h))
    r.fill.solid(); r.fill.fore_color.rgb = fill; r.line.color.rgb = edge; r.line.width = Pt(1.5)
    tf = r.text_frame; tf.word_wrap = True; tf.vertical_anchor = MSO_ANCHOR.TOP
    tf.margin_left = tf.margin_right = Inches(0.2); tf.margin_top = Inches(0.15)
    p = tf.paragraphs[0]; p.text = title; p.font.size = Pt(19 if h > 1.5 else 15); p.font.bold = True
    p.font.color.rgb = INK; p.alignment = PP_ALIGN.LEFT
    for line in (body.split("\n") if body else []):
        q = tf.add_paragraph(); q.text = line; q.font.size = Pt(16 if h > 1.5 else 12)
        q.font.color.rgb = GREY; q.alignment = PP_ALIGN.LEFT; q.space_before = Pt(6)
    return r


def arrow(s, x1, y1, x2, y2):
    c = s.shapes.add_connector(1, Inches(x1), Inches(y1), Inches(x2), Inches(y2))
    c.line.color.rgb = GREY; c.line.width = Pt(1.5)
    c.line._get_or_add_ln().append(c.line._get_or_add_ln().makeelement(
        '{http://schemas.openxmlformats.org/drawingml/2006/main}tailEnd', {'type': 'triangle'}))


# 1 Title
s = prs.slides.add_slide(BLANK)
bg = s.shapes.add_shape(MSO_SHAPE.RECTANGLE, 0, 0, prs.slide_width, prs.slide_height)
bg.fill.solid(); bg.fill.fore_color.rgb = NAVY; bg.line.fill.background()
text(s, 0.8, 1.6, 11.5, 1.2, "PRISM-Gate", 60, RGBColor(0xFF, 0xFF, 0xFF), True)
text(s, 0.8, 2.8, 11.5, 1.2, "Privacy- and priority-aware RL routing for healthcare LLM traffic, "
     "with live stale-answer detection", 26, RGBColor(0xBF, 0xE6, 0xE6))
text(s, 0.8, 4.6, 11.5, 1.6, ["Global AI Hackathon 2026 (Geek Room)  |  Bifrost PS-04 + Tavily PS-06",
                              "Usama Manzoor  |  MS IT, University of Sargodha",
                              "github.com/iammalik884/prism-gate"], 18, RGBColor(0xFF, 0xFF, 0xFF))

# 2 Problem
s = page("The problem", "Hospitals want LLMs, but four gaps stop them")
items = [("Privacy", "Prompts carry patient names, CNIC and MR numbers. They must not reach a cloud model. PII guardrails are Enterprise-only in Bifrost."),
         ("Priority", "An emergency question waits in the same queue as a nightly batch job. Open-source Bifrost has no request priority."),
         ("Cost and reliability", "Static routing sends everything to one model and fails when it hits rate limits. Adaptive routing is Enterprise-only."),
         ("Stale answers", "Models state old drug approvals, prices and guidelines as current. In medicine that can cause harm.")]
for i, (t, b) in enumerate(items):
    box(s, 0.5 + (i % 2) * 6.3, 2.0 + (i // 2) * 2.5, 6.0, 2.2, t, b)

# 3 Solution
s = page("The solution: PRISM-Gate", "An open-source Bifrost plugin plus a small Python brain")
items = [("PHI Guard", "Presidio + Pakistani CNIC / MRN / phone rules. Patient data is pinned to a local Ollama model; cloud fallbacks removed. Fail-closed rules also run inside the Go plugin."),
         ("Priority Gate", "Emergency / Clinical / Routine / Batch. Reserved capacity for Emergency inside the plugin (PreLLMHook)."),
         ("RL Router", "LinUCB contextual bandit chooses provider and model per request type. Reward = success, latency and cost, weighted by priority. Circuit breaker on failures."),
         ("Freshness Check", "Extract claims (LLM via Bifrost) -> live sources (Tavily) -> verdict (LLM via Bifrost) -> freshness score 0-100 with citations.")]
for i, (t, b) in enumerate(items):
    box(s, 0.5 + (i % 2) * 6.3, 2.0 + (i // 2) * 2.5, 6.0, 2.2, t, b)

# 4 Architecture
s = page("Architecture", "Every model call goes through Bifrost; Tavily supplies live evidence")
box(s, 0.5, 2.0, 3.0, 1.0, "Hospital app / EHR", "x-prism-priority header")
box(s, 4.3, 1.8, 4.0, 4.6, "Bifrost gateway (Go)", "", fill=RGBColor(0xFF, 0xFF, 0xFF), edge=GREY)
box(s, 4.5, 2.6, 3.6, 1.0, "PRISM-Gate plugin", "PreRequest / PreLLM / PostLLM hooks")
box(s, 4.5, 3.8, 3.6, 1.0, "Priority Gate", "reserved slots for Emergency")
box(s, 4.5, 5.0, 3.6, 1.1, "Fallbacks, routing rules", "built into Bifrost, reused", fill=RGBColor(0xF3, 0xF4, 0xF6), edge=GREY)
box(s, 9.2, 1.8, 3.6, 3.4, "Brain (Python, FastAPI)", "PHI Guard\nRL Router (LinUCB)\nFreshness Check", fill=RGBColor(0xFF, 0xFF, 0xFF))
box(s, 9.2, 5.5, 3.6, 0.9, "Tavily Search API", "live sources per claim", fill=RGBColor(0xF3, 0xF4, 0xF6), edge=GREY)
box(s, 0.5, 4.2, 3.0, 0.9, "Ollama, local", "PHI never leaves", fill=RGBColor(0xF3, 0xF4, 0xF6), edge=GREY)
box(s, 0.5, 5.4, 3.0, 0.9, "Groq / Gemini", "cloud arms", fill=RGBColor(0xF3, 0xF4, 0xF6), edge=GREY)
arrow(s, 3.5, 2.5, 4.5, 3.0); arrow(s, 8.1, 3.1, 9.2, 3.1); arrow(s, 4.3, 4.7, 3.5, 4.7)
arrow(s, 4.3, 5.6, 3.5, 5.8); arrow(s, 11.0, 5.2, 11.0, 5.5)
text(s, 0.5, 6.6, 12.3, 0.6, "Built on Bifrost release v2.5.1 with a native Go plugin (.so). The plugin never blocks on the brain: 150 ms budget, local PHI rules as fallback.", 13, GREY)

# 5 Bifrost + Tavily
s = page("How Bifrost and Tavily each contribute")
box(s, 0.5, 1.6, 6.0, 4.8, "Bifrost (PS-04: feature the OSS gateway is missing)",
    "- Public plugin hooks: HTTPTransportPreHook, PreRequestHook, PreLLMHook, PostLLMHook\n"
    "- Sets provider / model / fallbacks per request\n- Carries every model call, including the Freshness Check's own\n"
    "- Adds to OSS what is Enterprise-only today: PII-aware routing and adaptive routing, plus request priority")
box(s, 6.8, 1.6, 6.0, 4.8, "Tavily (PS-06: stale-answer detector)",
    "- Live web search for each time-sensitive claim\n- Source URL and date feed the freshness score\n"
    "- Trusted domains (WHO, FDA, NIH, DRAP, NICE) raise confidence\n- Answer text is PHI-masked before it is sent")

# 6 Results
s = page("Results: 200 synthetic requests per mode", "18 Nov 2026, free tiers, 4 parallel workers, outage on one arm at request 100")
rows = [("Metric", "Static (one model)", "PRISM-Gate"),
        ("Successful answers", "17 / 200 (8.5%)", "181 / 200 (90.5%)"),
        ("PHI requests sent to a cloud model", "46 / 46", "0 / 46"),
        ("PHI requests caught (recall)", "n/a", "46 / 46"),
        ("False alarms (sent local, no real PHI)", "n/a", "18 of 64 local"),
        ("Emergency without PHI, median latency", "1.8 s (1 succeeded)", "2.2 s (7 succeeded)"),
        ("Emergency with PHI, latency", "6.0 s (cloud)", "32 s (local CPU model)")]
tbl = s.shapes.add_table(len(rows), 3, Inches(0.5), Inches(2.0), Inches(12.3), Inches(3.6)).table
for r, row in enumerate(rows):
    for c, v in enumerate(row):
        cell = tbl.cell(r, c); cell.text = v
        para = cell.text_frame.paragraphs[0]; para.font.size = Pt(15); para.font.bold = r == 0
text(s, 0.5, 5.8, 12.3, 1.5, ["Honest reading: 183 static failures were HTTP 429 rate limits on one free model; PRISM-Gate wins mainly by spreading load. "
                              "Privacy is the strongest result. Emergency + PHI is slow on a CPU-only local model; a GPU removes this trade-off."], 13, GREY)

# 7 Freshness example
s = page("Freshness Check in action", "Input: an AI answer about a withdrawn drug")
box(s, 0.5, 1.9, 12.3, 1.0, "\"Ranitidine (Zantac) is approved by the FDA and widely sold over the counter in the US. Paracetamol is used to reduce fever.\"", "")
rows = [("Claim", "Verdict", "Score", "Label"),
        ("Zantac is widely sold over the counter in the US", "contradicted", "10", "stale"),
        ("Zantac is approved by the FDA", "supported (source must be read by a human)", "90", "current"),
        ("Paracetamol is used to reduce fever", "not time-sensitive", "-", "stable")]
tbl = s.shapes.add_table(4, 4, Inches(0.5), Inches(3.2), Inches(12.3), Inches(2.4)).table
for r, row in enumerate(rows):
    for c, v in enumerate(row):
        cell = tbl.cell(r, c); cell.text = v
        para = cell.text_frame.paragraphs[0]; para.font.size = Pt(15); para.font.bold = r == 0
text(s, 0.5, 5.9, 12.3, 1.0, "6.7 seconds end to end: 2 LLM calls through Bifrost + Tavily search per claim. Every score comes with its source URL.", 14, GREY)

# 8 Safety by design
s = page("Safety by design: what testing caught")
items = [("Fail-open gap found and fixed", "First test: brain answered in 58 ms against a 50 ms budget, so a CNIC prompt kept its cloud route. Now the Go plugin runs local PHI rules on every request (fail-closed)."),
         ("False positives found and fixed", "Presidio tagged a drug name as a person and slowed the checker. Checker input is now PHI-masked and its own calls bypass rerouting."),
         ("Reproducible build", "Plugin compiled inside Bifrost's own module (same go.mod / go.sum / Go 1.27.3), so the .so always matches the binary. Pinned to release v2.5.1."),
         ("Tested", "Go unit tests (priority gate, PHI rules, brain timeout) and 7 Python tests run in the build.")]
for i, (t, b) in enumerate(items):
    box(s, 0.5 + (i % 2) * 6.3, 1.6 + (i // 2) * 2.7, 6.0, 2.4, t, b)

# 9 Limits and next
s = page("Limits and next steps")
text(s, 0.5, 1.6, 6.0, 5.0, ["Limits (stated honestly)", "- All data is synthetic", "- Bandit reward does not grade answer quality yet",
                             "- Costs are relative units, not USD", "- Baseline hit free-tier rate limits", "- Not a medical device"], 18)
text(s, 6.8, 1.6, 6.0, 5.0, ["Next", "- Fair baseline at matched request rate", "- Quality signal: LLM-judge sample in the reward",
                             "- Upstream PR to Bifrost examples/plugins", "- Link to my MS research: MAPPO priority-aware scheduling at the edge",
                             "", "github.com/iammalik884/prism-gate"], 18)

prs.save("docs/PRISM-Gate.pptx")
print("saved docs/PRISM-Gate.pptx", len(prs.slides), "slides")
