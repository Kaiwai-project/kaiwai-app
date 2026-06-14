import json
import os
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from apify_client import ApifyClient

# 인코딩 설정
if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

# ─────────────────────────────────────────────────────────
# 환경 설정
# ─────────────────────────────────────────────────────────
APIFY_TOKEN = os.environ.get("APIFY_TOKEN", "")
OUT_PATH = Path(__file__).parent / "calendar_data.json"

ACTOR_IG = "apify/instagram-scraper"
ACTOR_TW = "katerinahronik/twitter-scraper"

# 브랜드 마스터 데이터 (10개)
BRANDS = [
    {"name": "ROJITA", "ig": "rojita__official", "tw": "ROJITA__jp", "color": "#C41055", "emoji": "🖤"},
    {"name": "Ank Rouge", "ig": "ankrouge_official", "tw": "AnkRouge", "color": "#C41055", "emoji": "🎀"},
    {"name": "LIZ LISA", "ig": "lizlisa_official_japan", "tw": "lizlisaofficial", "color": "#C41055", "emoji": "🌸"},
    {"name": "Secret Honey", "ig": "secrethoney_official", "tw": "SecretHoney_HB", "color": "#C41055", "emoji": "🐰"},
    {"name": "pium", "ig": "", "tw": "pium__official", "color": "#AA7020", "emoji": "🌸"},
    {"name": "Honey Cinnamon", "ig": "", "tw": "honeyc0214", "color": "#C41055", "emoji": "🍯"},
    {"name": "NOEMIE", "ig": "noemie_official_", "tw": "Noemie_shop", "color": "#C41055", "emoji": "🩷"},
    {"name": "MA*RS", "ig": "marsofficialjapan", "tw": "mars_amoebamars", "color": "#C41055", "emoji": "♦️"},
    {"name": "DearMyLove", "ig": "dearmylove_official", "tw": "dearmylove_yume", "color": "#C41055", "emoji": "💕"},
    {"name": "DimMoire", "ig": "", "tw": "_DimMoire_", "color": "#7733BB", "emoji": "🌑"},
]

# 키워드
TYPE_KEYWORDS = {"팝업": ["popup", "팝업"], "수주": ["受注", "수주"], "예약": ["予約", "예약"], "신상": ["新作", "신상", "drop"]}
EVENT_TRIGGERS = ["発売", "新作", "drop", "release", "受注", "予約", "팝업", "신상"]

# ─────────────────────────────────────────────────────────
# 유틸리티 함수
# ─────────────────────────────────────────────────────────
def parse_date(text: str) -> str:
    today = datetime.now()
    text = text.replace("今日", today.strftime("%m/%d")).replace("明日", (today + timedelta(days=1)).strftime("%m/%d"))
    patterns = [(r'(\d{4})[./\-](\d{1,2})[./\-](\d{1,2})', "ymd"), (r'(\d{1,2})月(\d{1,2})日', "md_jp"), (r'(\d{1,2})/(\d{1,2})', "md_slash")]
    for pat, fmt in patterns:
        m = re.search(pat, text)
        if m:
            g = m.groups()
            y, mo, d = (int(g[0]), int(g[1]), int(g[2])) if fmt == "ymd" else (today.year, int(g[0]), int(g[1]))
            if fmt != "ymd":
                target = datetime(today.year, mo, d)
                y = today.year if target >= today.replace(hour=0, minute=0, second=0, microsecond=0) else today.year + 1
            return datetime(y, mo, d).strftime("%Y-%m-%d")
    return (today + timedelta(days=7)).strftime("%Y-%m-%d")

def apify_instagram(client, ig_handle):
    try:
        run = client.actor(ACTOR_IG).call(run_input={"directUrls": [f"https://www.instagram.com/{ig_handle}/"], "resultsLimit": 5})
        return [item.get("caption") or item.get("text") for item in client.dataset(run["defaultDatasetId"]).iterate_items()]
    except: return []

def apify_twitter(client, x_handle):
    try:
        run = client.actor(ACTOR_TW).call(run_input={"handles": [x_handle.lstrip("@")], "tweetsDesired": 5})
        return [item.get("full_text") or item.get("text") for item in client.dataset(run["defaultDatasetId"]).iterate_items() if not item.get("text", "").startswith("RT ")]
    except: return []

# ─────────────────────────────────────────────────────────
# 메인 실행
# ─────────────────────────────────────────────────────────
def main():
    client = ApifyClient(APIFY_TOKEN) if APIFY_TOKEN else None
    all_events = []
    
    for brand in BRANDS:
        print(f"▶ 처리 중: {brand['name']}")
        texts = []
        if brand["ig"] and client: texts.extend(apify_instagram(client, brand["ig"]))
        if brand["tw"] and client: texts.extend(apify_twitter(client, brand["tw"]))
        
        for text in texts:
            if any(trig in text for trig in EVENT_TRIGGERS):
                all_events.append({
                    "dt": parse_date(text), "br": brand["name"], "tp": "이벤트", 
                    "d": text[:50], "c": brand["color"], "e": brand["emoji"]
                })
        time.sleep(15) # 보호 대기

    OUT_PATH.write_text(json.dumps(all_events, ensure_ascii=False, indent=2), encoding="utf-8")
    print("✅ 완료.")

if __name__ == "__main__":
    main()
