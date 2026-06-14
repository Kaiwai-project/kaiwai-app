import json
import os
import re
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from apify_client import ApifyClient

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

APIFY_TOKEN = os.environ.get("APIFY_TOKEN", "")
OUT_PATH = Path(__file__).parent / "calendar_data.json"

# 공식 액터 경로 (가장 표준적인 경로)
ACTOR_IG = "apify/instagram-scraper"
ACTOR_TW = "katerinahronik/twitter-scraper"

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

def apify_instagram(client, ig_handle):
    try:
        run = client.actor(ACTOR_IG).call(run_input={"directUrls": [f"https://www.instagram.com/{ig_handle}/"], "resultsLimit": 5})
        # 에러 해결: 속성 접근 방식 사용 (run.default_dataset_id)
        return [item.get("caption") or item.get("text") for item in client.dataset(run.default_dataset_id).iterate_items()]
    except Exception as e:
        print(f"  ⚠️ IG 에러 ({ig_handle}): {e}")
        return []

def apify_twitter(client, x_handle):
    try:
        run = client.actor(ACTOR_TW).call(run_input={"handles": [x_handle.lstrip("@")], "tweetsDesired": 5})
        return [item.get("text") for item in client.dataset(run.default_dataset_id).iterate_items() if not item.get("text", "").startswith("RT ")]
    except Exception as e:
        print(f"  ⚠️ TW 에러 (@{x_handle}): {e}")
        return []

def main():
    client = ApifyClient(APIFY_TOKEN) if APIFY_TOKEN else None
    all_events = []
    
    for brand in BRANDS:
        print(f"▶ 수집 중: {brand['name']}")
        texts = []
        if client:
            if brand["ig"]: texts.extend(apify_instagram(client, brand["ig"]))
            if brand["tw"]: texts.extend(apify_twitter(client, brand["tw"]))
        
        for text in texts:
            # 캘린더용 데이터 추출
            all_events.append({
                "dt": datetime.now().strftime("%Y-%m-%d"), 
                "br": brand["name"], 
                "d": text[:50]
            })
        time.sleep(15)

    OUT_PATH.write_text(json.dumps(all_events, ensure_ascii=False, indent=2), encoding="utf-8")
    print("✅ 성공적으로 수집 완료.")

if __name__ == "__main__":
    main()
