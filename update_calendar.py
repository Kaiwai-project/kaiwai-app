import json
import os
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from apify_client import ApifyClient
from google import genai

if sys.stdout.encoding and sys.stdout.encoding.lower() != "utf-8":
    sys.stdout.reconfigure(encoding="utf-8")

APIFY_TOKEN = os.environ.get("APIFY_TOKEN", "")
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "")
IG_COOKIE = os.environ.get("IG_COOKIE", "")
TW_COOKIE = os.environ.get("TW_COOKIE", "")
OUT_PATH = Path(__file__).parent / "calendar_data.json"

ACTOR_IG = "apify/instagram-scraper"
ACTOR_TW = "apify/twitter-scraper"

BRANDS_GROUPS = {
    0: [
        {"name": "ROJITA",      "ig": "rojita__official",       "tw": "ROJITA__jp",      "color": "#C41055", "emoji": "🖤"},
        {"name": "Ank Rouge",   "ig": "ankrouge_official",      "tw": "AnkRouge",         "color": "#C41055", "emoji": "🎀"},
        {"name": "LIZ LISA",    "ig": "lizlisa_official_japan", "tw": "lizlisaofficial",  "color": "#C41055", "emoji": "🌸"},
    ],
    1: [
        {"name": "Secret Honey",    "ig": "secrethoney_official", "tw": "SecretHoney_HB", "color": "#C41055", "emoji": "🐰"},
        {"name": "pium",            "ig": "",                     "tw": "pium__official",  "color": "#AA7020", "emoji": "🌸"},
        {"name": "Honey Cinnamon",  "ig": "",                     "tw": "honeyc0214",      "color": "#C41055", "emoji": "🍯"},
    ],
    2: [
        {"name": "NOEMIE",      "ig": "noemie_official_",    "tw": "Noemie_shop",       "color": "#C41055", "emoji": "🩷"},
        {"name": "MA*RS",       "ig": "marsofficialjapan",   "tw": "mars_amoebamars",   "color": "#C41055", "emoji": "♦️"},
        {"name": "DearMyLove",  "ig": "dearmylove_official", "tw": "dearmylove_yume",   "color": "#C41055", "emoji": "💕"},
        {"name": "DimMoire",    "ig": "",                    "tw": "_DimMoire_",         "color": "#7733BB", "emoji": "🌑"},
    ],
}

SYSTEM_PROMPT = """당신은 일본 서브컬처 패션 브랜드의 SNS 게시물을 분석하는 전문가입니다.

주요 역할:
1. 게시물에서 실제 이벤트 정보를 정확히 추출합니다
2. 추출한 내용을 한국 SNS 감성에 맞는 자연스러운 문체로 요약합니다

이벤트 분류 기준:
✅ 이벤트 해당: 신상품 발매·드롭, 팝업 스토어 오픈, 선행예약·수주 시작, 할인·세일 이벤트, 기념 이벤트, 한정 컬렉션 출시
❌ 이벤트 아님: 단순 일상 포스팅, 감사 인사만 있는 글, 팔로워 소통, 단순 착샷 공유, 리포스트

설명문 작성 규칙:
- 50자 이내의 간결하고 자연스러운 한국어
- 직역 금지 — 한국 SNS 감성으로 의역
- 구체적인 이벤트 내용(날짜·종류·혜택)을 포함할 것
- 예시: "5주년 기념 10% 할인 진행 중! 🎉", "6/21 팝업 스토어 오픈 💕", "신작 드레스 드롭 예정 🌸"

응답 형식: JSON 한 줄 또는 null (다른 텍스트 없이)"""


def analyze_post(client: genai.Client, brand_name: str, text: str, today: datetime) -> dict | None:
    """Gemini로 SNS 게시물에서 이벤트를 추출. 이벤트 없으면 None 반환."""
    prompt = f"""{SYSTEM_PROMPT}

오늘: {today.strftime("%Y년 %m월 %d일")}
브랜드: {brand_name}

SNS 게시물:
---
{text[:1200]}
---

이벤트가 있으면 JSON을, 없으면 null만 출력하세요.
{{"date": "YYYY-MM-DD", "description": "한국 SNS 감성 이벤트 설명 50자 이내"}}

날짜 규칙:
- 연도 명시 없으면 {today.year}년 기준
- 날짜 파악 불가 시 null 반환"""

    try:
        resp = client.models.generate_content(
            model="gemini-1.5-flash",
            contents=prompt,
        )
        raw = resp.text.strip()

        if raw.lower() == "null" or not raw:
            return None

        # ```json ... ``` 마크다운 블록 처리
        if raw.startswith("```"):
            parts = raw.split("```")
            raw = parts[1].lstrip("json").strip() if len(parts) > 1 else raw

        data = json.loads(raw)
        if not isinstance(data, dict) or not data.get("date") or not data.get("description"):
            return None
        return data

    except Exception as e:
        print(f"    LLM 오류: {e}")
        return None


def fetch_instagram(apify: ApifyClient, handle: str) -> list[str]:
    try:
        run = apify.actor(ACTOR_IG).call(run_input={
            "directUrls": [f"https://www.instagram.com/{handle}/"],
            "resultsLimit": 5,
            "cookies": [{"name": "sessionid", "value": IG_COOKIE}] if IG_COOKIE else [],
        })
        return [
            item.get("caption") or item.get("text") or ""
            for item in apify.dataset(run.default_dataset_id).iterate_items()
        ]
    except Exception as e:
        print(f"    IG 오류 ({handle}): {e}")
        return []


def fetch_twitter(apify: ApifyClient, handle: str) -> list[str]:
    try:
        run = apify.actor(ACTOR_TW).call(run_input={
            "handles": [handle.lstrip("@")],
            "tweetsDesired": 5,
            "cookies": [{"name": "auth_token", "value": TW_COOKIE}] if TW_COOKIE else [],
        })
        return [
            item.get("text") or ""
            for item in apify.dataset(run.default_dataset_id).iterate_items()
            if not (item.get("text") or "").startswith("RT ")
        ]
    except Exception as e:
        print(f"    TW 오류 ({handle}): {e}")
        return []


def main():
    today = datetime.now()
    apify = ApifyClient(APIFY_TOKEN) if APIFY_TOKEN else None

    gemini = genai.Client(api_key=GEMINI_API_KEY) if GEMINI_API_KEY else None

    group_idx = today.day % 3
    brands = BRANDS_GROUPS.get(group_idx, [])
    print(f"그룹 {group_idx} ({len(brands)}개 브랜드) 수집 시작")

    existing = json.loads(OUT_PATH.read_text(encoding="utf-8")) if OUT_PATH.exists() else []
    processing_names = {b["name"] for b in brands}
    events = [e for e in existing if e["br"] not in processing_names]

    for brand in brands:
        print(f"\n▶ {brand['name']}")
        texts: list[str] = []

        if apify:
            if brand["ig"]:
                ig_posts = fetch_instagram(apify, brand["ig"])
                print(f"  IG {len(ig_posts)}개 수집")
                texts.extend(ig_posts)
            if brand["tw"]:
                tw_posts = fetch_twitter(apify, brand["tw"])
                print(f"  TW {len(tw_posts)}개 수집")
                texts.extend(tw_posts)

        if not texts:
            print("  수집 없음")
            continue

        for i, text in enumerate(texts):
            if not text or not text.strip():
                continue

            if gemini:
                result = analyze_post(gemini, brand["name"], text, today)
                if result:
                    print(f"  ✅ [{result['date']}] {result['description']}")
                    events.append({
                        "dt": result["date"],
                        "br": brand["name"],
                        "d":  result["description"],
                        "c":  brand["color"],
                        "e":  brand["emoji"],
                    })
                else:
                    print(f"  ⏭ 게시물 {i+1}: 이벤트 없음")
                time.sleep(0.3)
            else:
                # LLM 없을 때 폴백: 키워드 필터
                triggers = ["発売", "新作", "ドロップ", "drop", "예약", "팝업", "수주", "발매"]
                if any(t in text for t in triggers):
                    events.append({
                        "dt": (today + timedelta(days=7)).strftime("%Y-%m-%d"),
                        "br": brand["name"],
                        "d":  text[:50].strip(),
                        "c":  brand["color"],
                        "e":  brand["emoji"],
                    })

        time.sleep(10)

    # 7일 이상 지난 이벤트 제거
    cutoff = (today - timedelta(days=7)).strftime("%Y-%m-%d")
    events = [e for e in events if e.get("dt", "") >= cutoff]

    # 날짜 오름차순 정렬
    events.sort(key=lambda x: x.get("dt", "9999-12-31"))

    OUT_PATH.write_text(json.dumps(events, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n✅ 완료: {len(events)}개 이벤트 저장")


if __name__ == "__main__":
    main()
