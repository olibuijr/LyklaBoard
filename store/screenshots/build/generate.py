#!/usr/bin/env python3
"""
Lyklaborð — App Store screenshot generator.

Emits one standalone, exact-pixel HTML file per (screenshot x locale) into
build/html/, ready to be rendered to PNG by render.sh (headless Chrome).

Design source of truth:
  - Palette + typography copied verbatim from the live site (lyklabord.solberg.is
    CSS custom properties) so the store assets match the marketing site.
  - Keyboard layout recreated faithfully from the real Icelandic layout:
      row1: q w e r t y u i o p ð
      row2: a s d f g h j k l æ ö
      row3: [shift] z x c v b n m þ [backspace]
      row4: [123] [🌐] [space] [.] [return]
  - The suggestion bar always carries the literal token you typed, quoted, as
    the escape hatch (README: "the literal token you typed always sits in the
    suggestion bar (quoted)").

Nothing here uploads or automates a GUI. render.sh uses `chrome --headless
--screenshot`, which captures the rendered page natively (no html2canvas, no
file:// canvas-taint problem).
"""

import html
import pathlib

W, H = 1260, 2736  # iPhone 6.9" required size (per app-store-screenshots skill)

OUT = pathlib.Path(__file__).parent / "html"
OUT.mkdir(parents=True, exist_ok=True)
ASSETS = "../../../assets"  # relative from build/html/ to store/assets/

# ---------------------------------------------------------------- palette ----
# Verbatim from the site's :root custom properties (light theme).
BG        = "#faf9f6"
BG_RAISED = "#f1efe9"
INK       = "#1c1b1a"
INK_SOFT  = "#55524d"
RULE      = "#e3e0d8"
PLASTIC   = "#d7d2c8"

# Realistic iOS light keyboard (in-device UI, not brand chrome).
KB_BG        = "#d4d7dd"
KEY          = "#ffffff"
KEY_DARK     = "#abb0ba"
KEY_SHADOW   = "#898d96"
KB_TEXT      = "#1c1b1a"
SUGGEST_HI   = "#ffffff"   # highlighted (accepted) suggestion pill
ACCENT       = "#0a7cff"   # iMessage blue (host-app content only)

FONT = ("ui-sans-serif, system-ui, -apple-system, 'SF Pro Text', 'Segoe UI', "
        "Roboto, 'Helvetica Neue', Arial, sans-serif")
MONO = "ui-monospace, SFMono-Regular, Menlo, monospace"

# ------------------------------------------------------------- keyboard -------
ROW1 = list("qwertyuiopð")
ROW2 = list("asdfghjklæö")
ROW3 = list("zxcvbnmþ")


def keycap(ch, cls=""):
    return f'<div class="key {cls}">{html.escape(ch)}</div>'


def wide(label, cls, extra=""):
    return f'<div class="key wide {cls}" {extra}>{label}</div>'


def keyboard(suggest_left, suggest_mid, suggest_right, shift_on=False):
    """suggest_mid is the highlighted/accepted candidate (center pill)."""
    r1 = "".join(keycap(c) for c in ROW1)
    r2 = "".join(keycap(c) for c in ROW2)
    r3 = (wide("&#x21E7;", "mod" + (" shift-on" if shift_on else ""))
          + "".join(keycap(c) for c in ROW3)
          + wide("&#x232B;", "mod"))
    bottom = (
        wide("123", "mod small")
        + wide("&#x1F310;", "mod globe")
        + '<div class="key space">space</div>'
        + wide(".", "punct")
        + wide("return", "mod ret small")
    )
    sug = f'''
      <div class="suggest">
        <div class="sug-cell"><span class="sug-lit">&#x201C;{html.escape(suggest_left)}&#x201D;</span></div>
        <div class="sug-div"></div>
        <div class="sug-cell hi"><span>{html.escape(suggest_mid)}</span></div>
        <div class="sug-div"></div>
        <div class="sug-cell"><span>{html.escape(suggest_right)}</span></div>
      </div>'''
    return f'''
    <div class="keyboard">
      {sug}
      <div class="krow">{r1}</div>
      <div class="krow indent">{r2}</div>
      <div class="krow">{r3}</div>
      <div class="krow">{bottom}</div>
      <div class="homebar"></div>
    </div>'''


# --------------------------------------------------------- host-app views -----
def messages_view(sent_bubbles, typed_text, cursor=True, callout=None):
    bubbles = ""
    for who, text in sent_bubbles:
        cls = "sent" if who == "me" else "recv"
        bubbles += f'<div class="bubble {cls}">{html.escape(text)}</div>'
    cur = '<span class="caret"></span>' if cursor else ''
    call = ""
    if callout:
        call = f'<div class="callout">{callout}</div>'
    return f'''
    <div class="hostbar">
      <div class="hb-back">&#x2039;</div>
      <div class="hb-title"><div class="hb-avatar">A</div><span>Anna</span></div>
      <div class="hb-spacer"></div>
    </div>
    <div class="convo">
      {bubbles}
      {call}
    </div>
    <div class="composebar">
      <div class="compose-field"><span class="compose-text">{html.escape(typed_text)}</span>{cur}</div>
    </div>'''


def dictionary_view():
    def row(word, sub, extra=""):
        return f'''<div class="dl-row {extra}">
            <div><div class="dl-word">{html.escape(word)}</div><div class="dl-sub">{html.escape(sub)}</div></div>
            {"<div class='dl-del'>Eyða</div>" if extra=="swipe" else "<div class='dl-lang'>"+sub_lang(sub)+"</div>"}
          </div>'''
    def sub_lang(_):
        return ""
    learned = [
        ("stef&aacute;n", "IS"), ("deploy", "EN"), ("bj&oacute;rl&iacute;ki", "IS"),
    ]
    mine = [("Lyklabor&eth;", "IS"), ("Reykjav&iacute;k", "IS")]
    def lrow(word, lang, swipe=False):
        if swipe:
            return f'''<div class="dl-row swipe">
            <div class="dl-word">{word}</div>
            <div class="dl-del">Eyða</div>
          </div>'''
        return f'''<div class="dl-row">
            <div class="dl-word">{word}</div>
            <div class="dl-lang">{lang}</div>
          </div>'''
    return f'''
    <div class="hostbar app">
      <div class="hb-spacer"></div>
      <div class="hb-title"><span>Orðasafn</span></div>
      <div class="hb-spacer"></div>
    </div>
    <div class="dict">
      <div class="dl-search">Leita að orði</div>
      <div class="dl-section">LÆRÐ ORÐ</div>
      {lrow("stefán", "IS")}
      {lrow("deploy", "EN")}
      {lrow("bjórlíki", "IS", swipe=True)}
      <div class="dl-section">MÍN ORÐ</div>
      {lrow("Lyklaborð", "IS")}
      {lrow("Reykjavík", "IS")}
      <div class="dl-import">
        <div class="imp-icon">&#x2193;</div>
        <div><div class="imp-t">Flytja inn úr SwiftKey</div>
        <div class="imp-s">vocabulary.txt · þín eyðing gildir</div></div>
      </div>
    </div>'''


def privacy_view():
    return f'''
    <div class="proof">
      <div class="term">
        <div class="term-bar"><span class="dot r"></span><span class="dot y"></span><span class="dot g"></span>
          <span class="term-title">KeyboardExt — netkóði?</span></div>
        <div class="term-body">
<span class="p">$</span> grep -rn "URLSession\\|Network\\|http" KeyboardExt/
<span class="ok">0 niðurstöður</span>

<span class="p">$</span> grep -rn "URLSession\\|Network\\|http" Packages/TypeEngine/
<span class="ok">0 niðurstöður</span>

<span class="c"># Viðbótin getur ekki hringt heim.</span>
<span class="c"># Kóðinn til þess er ekki til.</span>
        </div>
      </div>
      <div class="proof-tags">
        <span class="tag">MIT-leyfi</span>
        <span class="tag">Opinn á GitHub</span>
        <span class="tag">Data Not Collected</span>
      </div>
    </div>'''


# ------------------------------------------------------------------ page -------
def page(title_lines, subtitle, body_html, *, hero=False, dark_caption=False):
    title = "".join(f"<span>{l}</span>" for l in title_lines)
    hero_cls = " hero" if hero else ""
    return f'''<!doctype html><html lang="is"><head><meta charset="utf-8">
<style>
  *{{margin:0;padding:0;box-sizing:border-box}}
  html,body{{width:{W}px;height:{H}px;overflow:hidden}}
  body{{background:{BG};color:{INK};font-family:{FONT};-webkit-font-smoothing:antialiased}}
  .screen{{position:relative;width:{W}px;height:{H}px;overflow:hidden;
    background:radial-gradient(120% 90% at 50% 0%, {BG_RAISED} 0%, {BG} 55%)}}
  .caption{{position:absolute;top:0;left:0;right:0;padding:150px 96px 0;text-align:center;z-index:5}}
  .caption h1{{font-weight:700;letter-spacing:-3px;line-height:1.02;font-size:112px}}
  .caption h1 span{{display:block}}
  .caption p{{margin-top:34px;font-size:46px;font-weight:450;letter-spacing:-.5px;
    line-height:1.32;color:{INK_SOFT}}}
  .caption code{{font-family:{MONO};font-size:.86em;background:{BG_RAISED};
    padding:.06em .3em;border-radius:.28em;white-space:nowrap}}

  /* device */
  .stage{{position:absolute;left:50%;transform:translateX(-50%);bottom:-64px;
    width:940px;z-index:2}}
  .phone{{position:relative;width:940px;height:2010px;border-radius:96px;
    background:#0c0c0d;padding:20px;
    box-shadow:0 40px 90px rgba(28,27,26,.22), inset 0 0 0 3px #2a2a2c;
    border:2px solid #3a3a3d}}
  .glass{{position:relative;width:100%;height:100%;border-radius:78px;overflow:hidden;
    background:#fff;display:flex;flex-direction:column}}
  .island{{position:absolute;top:26px;left:50%;transform:translateX(-50%);
    width:200px;height:52px;background:#0c0c0d;border-radius:30px;z-index:20}}

  /* host bars */
  .hostbar{{height:150px;display:flex;align-items:flex-end;padding:0 40px 16px;
    background:#f7f7f8;border-bottom:1px solid #e4e4e7;gap:16px}}
  .hostbar.app{{background:#f7f7f8}}
  .hb-back{{font-size:56px;color:{ACCENT};line-height:.7}}
  .hb-title{{display:flex;align-items:center;gap:14px;font-size:34px;font-weight:600}}
  .hb-title span{{font-weight:600}}
  .hb-avatar{{width:56px;height:56px;border-radius:50%;background:{PLASTIC};color:{INK};
    display:flex;align-items:center;justify-content:center;font-size:30px;font-weight:600}}
  .hb-spacer{{flex:1}}

  .convo{{flex:1;padding:40px 40px 24px;display:flex;flex-direction:column;
    gap:26px;background:#fff;overflow:hidden}}
  .bubble{{max-width:74%;padding:26px 34px;border-radius:40px;font-size:40px;line-height:1.28}}
  .bubble.sent{{align-self:flex-end;background:{ACCENT};color:#fff;border-bottom-right-radius:14px}}
  .bubble.recv{{align-self:flex-start;background:#e9e9eb;color:{INK};border-bottom-left-radius:14px}}
  .callout{{align-self:center;margin-top:14px;background:{INK};color:{BG};
    padding:22px 34px;border-radius:28px;font-size:34px;font-weight:500;
    box-shadow:0 18px 40px rgba(28,27,26,.28);text-align:center;line-height:1.3}}
  .callout b{{color:#fff}}
  .callout .was{{opacity:.55;text-decoration:line-through}}
  .callout .now{{color:#ffd9a0}}

  .composebar{{padding:22px 34px 30px;background:#fff;border-top:1px solid #ececee}}
  .compose-field{{min-height:74px;border:2px solid #d7d7db;border-radius:38px;
    padding:16px 32px;display:flex;align-items:center;font-size:40px;color:{INK}}}
  .compose-text{{white-space:pre}}
  .caret{{display:inline-block;width:3px;height:44px;background:{ACCENT};
    margin-left:3px;animation:none}}

  /* keyboard */
  .keyboard{{margin-top:auto;background:{KB_BG};padding:14px 10px 0;
    display:flex;flex-direction:column;gap:0}}
  .suggest{{display:flex;align-items:stretch;height:104px;margin:0 -10px 12px;
    padding:0 8px;background:{KB_BG}}}
  .sug-cell{{flex:1;display:flex;align-items:center;justify-content:center;
    font-size:38px;color:{INK};padding:0 8px;min-width:0}}
  .sug-cell span{{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
  .sug-cell.hi{{background:{SUGGEST_HI};border-radius:14px;margin:12px 0;font-weight:600;
    box-shadow:0 1px 2px rgba(0,0,0,.16)}}
  .sug-lit{{color:{INK_SOFT}}}
  .sug-div{{width:1px;background:#b6bac2;margin:26px 0}}
  .krow{{display:flex;gap:14px;justify-content:center;margin-bottom:20px}}
  .krow.indent{{padding:0 42px}}
  .key{{flex:1;height:118px;background:{KEY};border-radius:12px;
    box-shadow:0 3px 0 {KEY_SHADOW};display:flex;align-items:center;justify-content:center;
    font-size:46px;color:{KB_TEXT};font-weight:400}}
  .key.wide{{flex:1.5;font-size:40px}}
  .key.mod{{background:{KEY_DARK};font-size:44px}}
  .key.mod.small{{font-size:32px;font-weight:500}}
  .key.mod.ret{{flex:2;font-size:32px;font-weight:500}}
  .key.mod.globe{{flex:1.1}}
  .key.mod.shift-on{{background:#fff;color:{ACCENT}}}
  .key.punct{{flex:1;font-weight:600}}
  .key.space{{flex:6;height:118px;background:{KEY};border-radius:12px;
    box-shadow:0 3px 0 {KEY_SHADOW};display:flex;align-items:center;justify-content:center;
    font-size:36px;color:#9a9ea7}}
  .homebar{{height:40px;background:{KB_BG};position:relative}}
  .homebar:after{{content:"";position:absolute;bottom:14px;left:50%;transform:translateX(-50%);
    width:300px;height:9px;border-radius:6px;background:#1c1b1a;opacity:.32}}

  /* dictionary */
  .dict{{flex:1;background:#f1f1f3;padding:22px 30px;overflow:hidden}}
  .dl-search{{background:#e4e4e7;border-radius:26px;padding:22px 32px;color:#8a8a90;
    font-size:36px;margin-bottom:30px}}
  .dl-section{{font-size:28px;color:#8a8a90;font-weight:600;letter-spacing:1px;
    margin:26px 8px 14px}}
  .dl-row{{background:#fff;border-radius:22px;margin-bottom:12px;
    display:flex;align-items:center;justify-content:space-between;font-size:44px;
    overflow:hidden}}
  .dl-row>.dl-word{{padding:34px}}
  .dl-row .dl-lang{{margin-right:34px}}
  .dl-row.swipe{{padding:0}}
  .dl-lang{{font-size:26px;color:#8a8a90;font-weight:600;border:2px solid #dcdce0;
    border-radius:10px;padding:4px 14px}}
  .dl-del{{align-self:stretch;display:flex;align-items:center;background:#ff453a;
    color:#fff;font-size:38px;font-weight:600;padding:0 46px}}
  .dl-import{{margin-top:34px;background:{INK};color:{BG};border-radius:26px;
    padding:34px;display:flex;align-items:center;gap:26px}}
  .imp-icon{{width:76px;height:76px;border-radius:20px;background:{PLASTIC};color:{INK};
    display:flex;align-items:center;justify-content:center;font-size:48px;font-weight:700}}
  .imp-t{{font-size:40px;font-weight:600}}
  .imp-s{{font-size:30px;opacity:.7;margin-top:6px}}

  /* privacy proof */
  .proof{{flex:1;background:#fff;display:flex;flex-direction:column;
    justify-content:center;align-items:center;padding:60px 46px;gap:56px}}
  .term{{width:100%;border-radius:34px;overflow:hidden;background:#1c1b1a;
    box-shadow:0 30px 70px rgba(28,27,26,.3)}}
  .term-bar{{background:#2a2926;padding:26px 32px;display:flex;align-items:center;gap:16px}}
  .dot{{width:26px;height:26px;border-radius:50%}}
  .dot.r{{background:#ff5f57}}.dot.y{{background:#febc2e}}.dot.g{{background:#28c840}}
  .term-title{{margin-left:16px;color:#a5a19a;font-size:30px;font-family:{MONO}}}
  .term-body{{padding:44px 40px;font-family:{MONO};font-size:34px;line-height:1.7;
    color:#e8e5e0;white-space:pre-wrap}}
  .term-body .p{{color:#7fd88f}}
  .term-body .ok{{color:#7fd88f;font-weight:700}}
  .term-body .c{{color:#a5a19a}}
  .proof-tags{{display:flex;gap:22px;flex-wrap:wrap;justify-content:center}}
  .tag{{background:{BG_RAISED};border:2px solid {RULE};border-radius:999px;
    padding:20px 36px;font-size:36px;font-weight:600;color:{INK}}}

  /* hero */
  .screen.hero{{display:flex;flex-direction:column;align-items:center;
    justify-content:center;text-align:center;padding:0 90px}}
  .hero-keycap{{width:760px;height:760px;object-fit:contain;
    filter:drop-shadow(0 60px 90px rgba(28,27,26,.22));margin-bottom:20px}}
  .hero-word{{font-size:150px;font-weight:700;letter-spacing:-5px;line-height:1}}
  .hero-pitch{{font-size:58px;color:{INK_SOFT};margin-top:34px;letter-spacing:-1px;
    line-height:1.2;font-weight:450}}
  .hero-meta{{margin-top:60px;display:flex;gap:26px;align-items:center;
    font-size:34px;color:{INK_SOFT};letter-spacing:.5px;flex-wrap:wrap;justify-content:center}}
  .hero-meta .dotsep{{opacity:.5}}
</style></head>
<body>
{body_html}
</body></html>'''


def framed(caption_title, caption_sub, inner_html):
    body = f'''
  <div class="screen">
    <div class="caption"><h1>{"".join(f"<span>{l}</span>" for l in caption_title)}</h1>
      <p>{caption_sub}</p></div>
    <div class="stage"><div class="phone"><div class="island"></div>
      <div class="glass">{inner_html}</div></div></div>
  </div>'''
    return page(caption_title, caption_sub, body)


# ------------------------------------------------------------- content ---------
# Per-locale caption + subtitle text. Story arc fixed; only text swaps.
CONTENT = {
    "is-IS": {
        1: (["Lyklaborðið sem", "kann íslensku"],
            "Frítt. Opinn hugbúnaður. Ekkert netsamband."),
        2: (["Skrifaðu", "broddlaust"],
            "Að sleppa broddum er innsláttaraðferð, ekki villa — <code>flytjum i bud</code> verður <code>flytjum í búð</code>."),
        3: (["Íslenska og enska,", "blandað"],
            "Stakar slettur trufla ekkert. Lyklaborðið hrifsar aldrei völdin í miðri setningu."),
        4: (["Skilur", "beygingar"],
            "Byggt á öllum 3 milljón orðmyndum úr BÍN — „frá“ kallar á þágufall, og lyklaborðið veit það."),
        5: (["Orðaforðinn þinn —", "í alvöru þinn"],
            "Lært á tækinu sjálfu. Þitt að skoða, eyða — og flytja inn úr SwiftKey."),
        6: (["Ekkert", "netsamband"],
            "Lyklaborðsviðbótin inniheldur engan netkóða. Sannreynanlegt í frumkóðanum, ekki bara loforð."),
    },
    "en-US": {
        1: (["The keyboard that", "knows Icelandic"],
            "Free. Open source. No network access."),
        2: (["Type", "accent-naked"],
            "Dropping accents is an input method, not a typo — <code>flytjum i bud</code> becomes <code>flytjum í búð</code>."),
        3: (["Icelandic and", "English, blended"],
            "One-off English words never derail you. The keyboard never hijacks your language mid-sentence."),
        4: (["It understands", "inflection"],
            "Built on all 3 million BÍN word forms — “frá” takes the dative, and the keyboard knows it."),
        5: (["Your vocabulary,", "truly yours"],
            "Learned on-device. Yours to inspect, delete — and import from SwiftKey."),
        6: (["Zero", "networking code"],
            "The keyboard extension contains no network code at all. Verifiable in the source — not just a promise."),
    },
}


def build_locale(loc):
    c = CONTENT[loc]

    # SS1 — hero (keycap marketing art)
    t1, s1 = c[1]
    meta = ("Opinn hugbúnaður · Ekkert netsamband · Væntanlegt í App Store"
            if loc == "is-IS" else
            "Open source · No network access · Coming to the App Store")
    hero_word = "Lyklaborð"
    hero_pitch = ("Íslenskt lyklaborð sem kann íslensku."
                  if loc == "is-IS" else
                  "The Icelandic keyboard that actually knows Icelandic.")
    hero_body = f'''
  <div class="screen hero">
    <img class="hero-keycap" src="{ASSETS}/keycap-float.png" alt="Ð keycap">
    <div class="hero-word">{hero_word}</div>
    <div class="hero-pitch">{hero_pitch}</div>
    <div class="hero-meta">{meta.replace(" · ", '<span class="dotsep">·</span>')}</div>
  </div>'''
    (OUT / f"01_hero_{loc}.html").write_text(page(t1, s1, hero_body))

    # SS2 — accent restoration
    t2, s2 = c[2]
    call2 = ('<span class="was">flytjum i bud</span> &nbsp;&#8594;&nbsp; '
             '<b class="now">flytjum í búð</b>')
    inner2 = messages_view(
        sent_bubbles=[("them", "Ertu að koma?"),
                      ("me", "Já — flytjum í búð fyrst")],
        typed_text="flytjum i bud",
        callout=call2) + keyboard("bud", "búð", "Búð")
    (OUT / f"02_accents_{loc}.html").write_text(framed(t2, s2, inner2))

    # SS3 — two-lane blending (English sletta kept, not corrected)
    t3, s3 = c[3]
    inner3 = messages_view(
        sent_bubbles=[("them", "Hvað ertu að gera?"),
                      ("me", "ég er að deploya nýju síðuna á Vercel")],
        typed_text="ég er að deploya",
        callout=None) + keyboard("deploya", "deploya", "deploy")
    (OUT / f"03_blend_{loc}.html").write_text(framed(t3, s3, inner3))

    # SS4 — BÍN case-aware (frá hest -> hesti, dative)
    t4, s4 = c[4]
    call4 = ('„frá“ &nbsp;&#8594;&nbsp; <b class="now">þágufall</b>'
             if loc == "is-IS" else
             '“frá” &nbsp;&#8594;&nbsp; <b class="now">dative</b>')
    inner4 = messages_view(
        sent_bubbles=[("me", "hann kemur ríðandi frá hesti")],
        typed_text="…frá hest",
        callout=call4) + keyboard("hest", "hesti", "hestur")
    (OUT / f"04_bin_{loc}.html").write_text(framed(t4, s4, inner4))

    # SS5 — Orðasafn (dictionary + SwiftKey import)
    t5, s5 = c[5]
    (OUT / f"05_dictionary_{loc}.html").write_text(framed(t5, s5, dictionary_view()))

    # SS6 — privacy proof
    t6, s6 = c[6]
    (OUT / f"06_privacy_{loc}.html").write_text(framed(t6, s6, privacy_view()))


for loc in ("is-IS", "en-US"):
    build_locale(loc)

print("generated", len(list(OUT.glob("*.html"))), "html files in", OUT)
