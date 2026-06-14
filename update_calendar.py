import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path
from apify_client import ApifyClient

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

APIFY_TOKEN = os.environ.get("APIFY_TOKEN", "")
OUT_PATH = Path(__file__).parent / "calendar_data.json"

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

def get_today_group():
    return datetime.now().day % 3

def apify_instagram(client, ig_handle):
    try:
        run = client.actor("apify/instagram-scraper").call(run_input={
            "directUrls": [f"https://www.instagram.com/{ig_handle}/"], "resultsLimit": 5
        })
        # .get() 뒤에 or ""를 추가하여 None인 경우 빈 문자열로 처리
        return [item.get("caption") or item.get("text") or "" for item in client.dataset(run.default_dataset_id).iterate_items()]
    except: return []

def apify_twitter(client, x_handle):
    try:
        run = client.actor("katerinahronik/twitter-scraper").call(run_input={
            "handles": [x_handle.lstrip("@")], "tweetsDesired": 5
        })
        # 여기도 빈 문자열 체크 추가
        return [item.get("text") or "" for item in client.dataset(run.default_dataset_id).iterate_items() if not (item.get("text") or "").startswith("RT ")]
    except: return []

def main():
    client = ApifyClient(APIFY_TOKEN) if APIFY_TOKEN else None
    today_group_idx = get_today_group()
    target_brands = BRANDS_GROUPS.get(today_group_idx, [])
    
    print(f"📅 오늘은 그룹 {today_group_idx} 수집일입니다.")
    all_events = json.loads(OUT_PATH.read_text(encoding="utf-8")) if OUT_PATH.exists() else []
    
    for brand in target_brands:
        print(f"▶ 처리 중: {brand['name']}")
        texts = []
        if client:
            if brand["ig"]: texts.extend(apify_instagram(client, brand["ig"]))
            if brand["tw"]: texts.extend(apify_twitter(client, brand["tw"]))
        
        all_events = [e for e in all_events if e["br"] != brand["name"]]
        
        for text in texts:
            # 방어 코드: text가 None이거나 비어있으면 루프를 돌지 않음
            if text and isinstance(text, str):
                if any(trig in text for trig in ["発売", "新作", "drop", "예약", "팝업"]):
                    all_events.append({
                        "dt": datetime.now().strftime("%Y-%m-%d"), "br": brand["name"], "d": text[:50]
                    })
        time.sleep(15)

    OUT_PATH.write_text(json.dumps(all_events, ensure_ascii=False, indent=2), encoding="utf-8")
    print("✅ 완료.")

if __name__ == "__main__":
    main()
