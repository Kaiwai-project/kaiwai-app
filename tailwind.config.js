/** @type {import('tailwindcss').Config} */
module.exports = {
  // index.html 만 Tailwind CDN 을 쓴다(profile.html 은 profile.css 자체 스타일).
  // JS 템플릿 문자열 안의 클래스도 같은 파일 텍스트 스캔으로 포함된다.
  content: ["./index.html"],
  // 동적 부분조합 클래스(text-${x}-500 류)는 코드에 없음(검증 완료). 안전망으로 일부만 safelist.
  safelist: [
    "mt-6", // index.html:3540 삼항으로 선택되는 클래스(직접 등장하나 명시 보호)
  ],
  theme: { extend: {} },
  plugins: [],
};
