import json
import os
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from apify_client import ApifyClient
from googletrans import Translator

# 1. 환경 설정 및 인코딩 방지
if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

APIFY_TOKEN = os.environ.get("APIFY_TOKEN", "")
IG_COOKIE = os.environ.get("IG_COOKIE", "")
TW_COOKIE = os.environ.get("TW_COOKIE", "")
OUT_PATH = Path(__file__).parent / "calendar_data.json"

ACTOR_IG = "apify/instagram-scraper"
ACTOR_TW = "katerinahronik/twitter-scraper"

# 번역기 초기화
translator = Translator()

# 브랜드 로테이션 그룹 (3일 텀)
BRANDS_GROUPS = {
    0: [
        {"name": "ROJITA", "ig": "rojita__official", "tw": "ROJITA__jp", "color": "#C41055", "emoji": "🖤"},
        {"name": "Ank Rouge", "ig": "ankrouge_official", "tw": "AnkRouge", "color": "#C41055", "emoji": "🎀"},
        {"name": "LIZ LISA", "ig": "lizlisa_official_japan", "tw": "lizlisaofficial", "color": "#C41055", "emoji": "🌸"}
    ],
    1: [
        {"name": "Secret Honey", "ig": "secrethoney_official", "tw": "SecretHoney_HB", "color": "#C41055", "emoji": "🐰"},
        {"name": "pium", "ig": "", "tw": "pium__official", "color": "#AA7020", "emoji": "🌸"},
        {"name": "Honey Cinnamon", "ig": "", "tw": "honeyc0214", "color": "#C41055", "emoji": "🍯"}
    ],
    2: [
        {"name": "NOEMIE", "ig": "noemie_official_", "tw": "Noemie_shop", "color": "#C41055", "emoji": "🩷"},
        {"name": "MA*RS", "ig": "marsofficialjapan", "tw": "mars_amoebamars", "color": "#C41055", "emoji": "♦️"},
        {"name": "DearMyLove", "ig": "dearmylove_official", "tw": "dearmylove_yume", "color": "#C41055", "emoji": "💕"},
        {"name": "DimMoire", "ig": "", "tw": "_DimMoire_", "color": "#7733BB", "emoji": "🌑"}
    ]
}

def translate_to_korean(text: str) -> str:
    """텍스트를 한국어로 번역합니다."""
    try:
        return translator.translate(text, dest='ko').text
    except:
        return text

def parse_date(text: str) -> str:
    today = datetime.now()
    text = text.replace("今日", today.strftime("%m/%d")).replace("明日", (today + timedelta(days=1)).strftime("%m/%d"))
    patterns = [
        (r'(\d{4})[./\-](\d{1,2})[./\-](\d{1,2})', "ymd"),
        (r'(\d{1,2})月(\d{1,2})日', "md_jp"),
        (r'(June|July|May)\s+(\d{1,2})', "en_month")
    ]
    for pat, fmt in patterns:
        m = re.search(pat, text, re.IGNORECASE)
        if m:
            g = m.groups()
            if fmt == "en_month":
                month_map = {"May": 5, "June": 6, "July": 7}
                mo, d = month_map[g[0].capitalize()], int(g[1])
            else:
                mo, d = int(g[1]), int(g[2])
            y = today.year if datetime(today.year, mo, d) >= today.replace(hour=0, minute=0, second=0, microsecond=0) else today.year + 1
            return datetime(y, mo, d).strftime("%Y-%m-%d")
    return (today + timedelta(days=7)).strftime("%Y-%m-%d")

def apify_instagram(client, ig_handle):
    try:
        run = client.actor(ACTOR_IG).call(run_input={
            "directUrls": [f"https://www.instagram.com/{ig_handle}/"], 
            "resultsLimit": 5,
            "cookies": [{"name": "sessionid", "value": IG_COOKIE}] if IG_COOKIE else []
        })
        return [item.get("caption") or item.get("text") or "" for item in client.dataset(run.default_dataset_id).iterate_items()]
    except: return []

def apify_twitter(client, x_handle):
    try:
        run = client.actor(ACTOR_TW).call(run_input={
            "handles": [x_handle.lstrip("@")], 
            "tweetsDesired": 5,
            "cookies": [{"name": "auth_token", "value": TW_COOKIE}] if TW_COOKIE else []
        })
        return [item.get("text") or "" for item in client.dataset(run.default_dataset_id).iterate_items() if not (item.get("text") or "").startswith("RT ")]
    except: return []

def main():
    client = ApifyClient(APIFY_TOKEN) if APIFY_TOKEN else None
    group_idx = datetime.now().day % 3
    target_brands = BRANDS_GROUPS.get(group_idx, [])
    
    all_events = json.loads(OUT_PATH.read_text(encoding="utf-8")) if OUT_PATH.exists() else []
    
    for brand in target_brands:
        print(f"▶ 처리 중: {brand['name']}")
        texts = []
        if client:
            if brand["ig"]: texts.extend(apify_instagram(client, brand["ig"]))
            if brand["tw"]: texts.extend(apify_twitter(client, brand["tw"]))
        
        # 기존 데이터 삭제 후 병합
        all_events = [e for e in all_events if e["br"] != brand["name"]]
        
        for text in texts:
            if text and isinstance(text, str) and any(trig in text for trig in ["発売", "新作", "drop", "예약", "팝업"]):
                all_events.append({
                    "dt": parse_date(text), 
                    "br": brand["name"], 
                    "d": translate_to_korean(text[:50]), 
                    "c": brand["color"], 
                    "e": brand["emoji"]
                })
        time.sleep(15)

    OUT_PATH.write_text(json.dumps(all_events, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"✅ 그룹 {group_idx} 수집 및 번역 완료.")

if __name__ == "__main__":
    main()
