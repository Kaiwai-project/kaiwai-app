// ============================================================
// 페르소나 기반 하드테스트 (Bug Hunting) — 총대/참여자 엣지 케이스
//   A. 목표 금액 미달 시 '버스 출발' 차단 (관리자 패스는 유지)
//   B. 마감/꽉 찬 공구에 동시 초과 탑승 시도 차단 (원자성·동시성)
//   C. 탑승객 취소 시 총대 달성률(current) 즉각 차감 동기화
// 일회용 유저로 원격(prod) 실 JWT 검증. 종료 시 cascade 삭제.
// ============================================================
import fs from 'fs';
const SRV=(fs.readFileSync('.env.local','utf8').match(/SUPABASE_SERVICE_ROLE_KEY\s*=\s*["']?([^"'\r\n]+)/)||[])[1];
const aj=fs.readFileSync('auth.js','utf8');
const URL=(aj.match(/SUPABASE_URL\s*=\s*["']([^"']+)/)||[])[1]||'https://iwrkpwmpfhlyfvutlnuy.supabase.co';
const ANON=(aj.match(/SUPABASE_ANON_KEY\s*=\s*["']([^"']+)/)||[])[1];
let pass=0,fail=0; const log=(ok,m)=>{console.log((ok?'[OK]':'[XX]')+' '+m);ok?pass++:fail++;};
const aC=async e=>{const r=await fetch(`${URL}/auth/v1/admin/users`,{method:'POST',headers:{apikey:SRV,Authorization:`Bearer ${SRV}`,'Content-Type':'application/json'},body:JSON.stringify({email:e,password:'Test!2345',email_confirm:true})});const j=await r.json();if(!r.ok)throw new Error(JSON.stringify(j));return j.id;};
const li=async e=>{const r=await fetch(`${URL}/auth/v1/token?grant_type=password`,{method:'POST',headers:{apikey:ANON,'Content-Type':'application/json'},body:JSON.stringify({email:e,password:'Test!2345'})});const j=await r.json();if(!r.ok)throw new Error(JSON.stringify(j));return j.access_token;};
const uRpc=async(jwt,fn,b)=>{const r=await fetch(`${URL}/rest/v1/rpc/${fn}`,{method:'POST',headers:{apikey:ANON,Authorization:`Bearer ${jwt}`,'Content-Type':'application/json'},body:JSON.stringify(b||{})});const t=await r.text();let j;try{j=JSON.parse(t);}catch{j=t;}return{ok:r.ok,status:r.status,data:j};};
const uRest=async(jwt,method,path,body,prefer)=>{const h={apikey:ANON,Authorization:`Bearer ${jwt}`,'Content-Type':'application/json'};if(prefer)h.Prefer=prefer;const r=await fetch(`${URL}/rest/v1/${path}`,{method,headers:h,body:body?JSON.stringify(body):undefined});const t=await r.text();let j;try{j=JSON.parse(t);}catch{j=t;}return{ok:r.ok,status:r.status,data:j};};
const invokeVH=async(jwt,body)=>{const r=await fetch(`${URL}/functions/v1/verify-host`,{method:'POST',headers:{apikey:ANON,Authorization:`Bearer ${jwt}`,'Content-Type':'application/json'},body:JSON.stringify(body)});return r.json();};
const srvGet=async(path)=>{const r=await fetch(`${URL}/rest/v1/${path}`,{headers:{apikey:SRV,Authorization:`Bearer ${SRV}`}});return r.json();};
const srvDel=p=>fetch(`${URL}/rest/v1/${p}`,{method:'DELETE',headers:{apikey:SRV,Authorization:`Bearer ${SRV}`}});
const srvPost=async(path,body,prefer)=>{const h={apikey:SRV,Authorization:`Bearer ${SRV}`,'Content-Type':'application/json'};if(prefer)h.Prefer=prefer;const r=await fetch(`${URL}/rest/v1/${path}`,{method:'POST',headers:h,body:JSON.stringify(body)});const t=await r.text();let j;try{j=JSON.parse(t);}catch{j=t;}return{ok:r.ok,status:r.status,data:j};};
const aDel=id=>fetch(`${URL}/auth/v1/admin/users/${id}`,{method:'DELETE',headers:{apikey:SRV,Authorization:`Bearer ${SRV}`}});
const ordered=async id=>(await srvGet(`buses?id=eq.${id}&select=ordered`))[0]?.ordered;
// 프론트와 동일한 current 공식: 총대 물품가 * host_qty + Σ(라이더 yen×qty)
async function currentOf(busId){
  const b=(await srvGet(`buses?id=eq.${busId}&select=product_price,host_qty`))[0];
  const rs=await srvGet(`bus_riders?bus_id=eq.${busId}&select=yen,qty`);
  return (b.product_price||0)*(b.host_qty||1)+rs.reduce((s,r)=>s+(r.yen||0)*(r.qty||1),0);
}
const jb=(id,yen)=>({p_bus_id:id,p_nick:'R',p_product_name:'렌즈',p_qty:1,p_yen:yen,p_power:'좌 0.00 / 우 -1.00',p_method:'conv',p_amount:yen*9+1800,p_real_name:'홍길동',p_phone:'01012345678',p_address:'서울 1-2',p_payer:'홍길동',p_memo:null});
const ts=Date.now(), E=t=>`hard_${t}_${ts}@kaiwai-test.dev`;
let ids={}; const busIds=[];
const mkBus=async(jwt,owner,price,goal,minGoal)=>{const b=await uRest(jwt,'POST','buses',{owner_id:owner,captain:'H',title:'hard',goal,minimum_goal:minGoal||goal,product_name:'렌즈',product_price:price},'return=representation');if(!b.ok)throw new Error('bus '+JSON.stringify(b.data));busIds.push(b.data[0].id);return b.data[0].id;};
try{
  for(const k of ['H','A','B1','B2a','B2b','B2c','C']) ids[k]=await aC(E(k));
  const J={}; for(const k of Object.keys(ids)) J[k]=await li(E(k));
  await invokeVH(J.H,{bankName:'국민은행',accountNumber:'111-22-3333',mockName:'테스트호'});
  for(const k of ['A','B1','B2a','B2b','B2c','C']) await uRpc(J[k],'sync_local_points',{p_points:500});
  console.log('-- setup done --\n[페르소나 A] 목표 미달 출발 차단');

  // A: goal 30000, minGoal 20000, host product 11000 + rider 1000 → current 12000 (무배1만 통과, 최소2만 미달) → '최소' 차단
  const bA=await mkBus(J.H,ids.H,11000,30000,20000); await uRpc(J.A,'join_coop_bus',jb(bA,1000));
  const upA=await uRest(J.H,'PATCH',`buses?id=eq.${bA}`,{ordered:true},'return=representation');
  log(!upA.ok && String(upA.data.message||'').includes('최소') && (await ordered(bA))===false,
      `A 최소금액미달(${await currentOf(bA)}/20000) 출발 차단 → "${(upA.data.message||'').slice(0,40)}"`);

  console.log('[페르소나 B] 동시 초과 탑승 / 마감 방어');
  // B1: 같은 유저가 잔액 300 으로 동시 2회 탑승 → 정확히 1건만(원자성)
  const bB=await mkBus(J.H,ids.H,1000,999999);
  // B1 유저 잔액을 300 으로 맞춤(이미 500 → 200 차감용 더미 없음 → 새 유저 사용)
  const [c1,c2]=await Promise.all([uRpc(J.B1,'join_coop_bus',jb(bB,1000)),uRpc(J.B1,'join_coop_bus',jb(bB,1000))]);
  const succB1=[c1,c2].filter(x=>x.ok).length;
  const rowsB1=(await srvGet(`bus_riders?bus_id=eq.${bB}&user_id=eq.${ids.B1}&select=id`)).length;
  log(succB1===1 && rowsB1===1, `B1 동시 2회 탑승 → 성공 ${succB1}건(기대1), 장부 ${rowsB1}행(기대1)`);

  // B2: 마감(ordered=true) 공구에 신규 유저 3명 동시 탑승 → 전원 차단
  const bF=await mkBus(J.H,ids.H,10000,10000,10000);   // current=10000(product)>=무배1만+최소1만 → 0명이어도 출발 가능
  const upF=await uRest(J.H,'PATCH',`buses?id=eq.${bF}`,{ordered:true},'return=representation');
  const conc=await Promise.all(['B2a','B2b','B2c'].map(k=>uRpc(J[k],'join_coop_bus',jb(bF,1000))));
  const blocked=conc.filter(x=>!x.ok && String(x.data.message||'').includes('마감')).length;
  const ridersF=(await srvGet(`bus_riders?bus_id=eq.${bF}&select=id`)).length;
  log(upF.ok && blocked===3 && ridersF===0, `B2 마감 공구 동시 3명 탑승 → 차단 ${blocked}/3, 장부 ${ridersF}행(기대0)`);

  console.log('[페르소나 C] 취소 시 달성률 즉각 차감');
  // C: host product 1000 + rider 1500 = current 2500 → 취소 후 1000
  const bC=await mkBus(J.H,ids.H,1000,999999); await uRpc(J.C,'join_coop_bus',jb(bC,1500));
  const before=await currentOf(bC);
  // 탑승 취소 = 본인 bus_riders 행 DELETE (ordered=false + 미입금)
  const rid=(await srvGet(`bus_riders?bus_id=eq.${bC}&user_id=eq.${ids.C}&select=id`))[0].id;
  const delC=await uRest(J.C,'DELETE',`bus_riders?id=eq.${rid}&select=id`,null,'return=representation');
  const after=await currentOf(bC);
  log(before===2500 && delC.ok && delC.data.length===1 && after===1000,
      `C 취소 전 ${before} → 취소 후 ${after} (달성률 즉각 차감, 총대 물품 1000 잔존)`);

  console.log('[페르소나 D] 서버 권한형 expired_at 강제 (클라 시계 위조 방어)');
  // 클라가 과거(2020) expired_at 주입 → BEFORE INSERT 트리거가 now()+deadline_hours(12h) 로 덮어씀
  const dRes=await uRest(J.H,'POST','buses',{owner_id:ids.H,captain:'H',title:'dl',goal:30000,minimum_goal:10000,product_name:'렌즈',product_price:11000,deadline_hours:12,expired_at:'2020-01-01T00:00:00Z'},'return=representation');
  if(dRes.ok) busIds.push(dRes.data[0].id);
  const dHrs=dRes.ok?(new Date(dRes.data[0].expired_at)-Date.now())/3600000:-999;
  log(dRes.ok && dHrs>11 && dHrs<13, `D 위조 expired_at(2020) 무시 → 서버 강제 ${dHrs.toFixed(2)}h 후 (기대 ≈12h)`);

  console.log('[페르소나 E] 무배 하한(10,000엔) 미만 조기 출발 차단');
  // host product 5000 (current 5000 < 1만) → minGoal 1만이어도 무배 하한 가드가 먼저 차단
  const bE=await mkBus(J.H,ids.H,5000,30000,10000);
  const upE=await uRest(J.H,'PATCH',`buses?id=eq.${bE}`,{ordered:true},'return=representation');
  log(!upE.ok && String(upE.data.message||'').includes('무료 배송') && (await ordered(bE))===false,
      `E 무배미달(${await currentOf(bE)}/10000) 출발 차단 → "${(upE.data.message||'').slice(0,40)}"`);

  console.log('[페르소나 F] minimum_goal 10,000엔 CHECK 제약 (개설 거부)');
  const fRes=await uRest(J.H,'POST','buses',{owner_id:ids.H,captain:'H',title:'f',goal:30000,minimum_goal:5000,product_name:'렌즈',product_price:11000},'return=representation');
  if(fRes.ok && Array.isArray(fRes.data)) busIds.push(fRes.data[0].id);   // 혹시 통과 시 정리용
  log(!fRes.ok && (fRes.status===400 || String(fRes.data.code||'')==='23514'),
      `F 최소금액 5000(<1만) 개설 거부 → status ${fRes.status} ${fRes.data.code||''}`);

  console.log('[페르소나 G] 마감 공구 정보 수정 차단');
  // bF 는 B2 에서 ordered=true → 방장(비관리자)이 notice 수정 시도 → guard_bus_update_after_ordered 차단
  const gUp=await uRest(J.H,'PATCH',`buses?id=eq.${bF}`,{notice:'수정시도'},'return=representation');
  log(!gUp.ok && String(gUp.data.message||'').includes('마감된 공구는 수정'),
      `G 마감 공구 정보수정 차단 → "${(gUp.data.message||'').slice(0,40)}"`);

  console.log('[페르소나 R] 상호 평점 / 매너 프로필 (Step 8)');
  // 이전 페르소나에서 A·C 보증금 차감됨 → 지갑 보충
  for(const k of ['A','C']) await srvPost('user_wallets?on_conflict=user_id',{user_id:ids[k],balance:3000},'resolution=merge-duplicates');

  // 완료 공구: host product 5000 + rider(A) 6000 = 11000 (>=무배1만+최소1만) → 출발/완료 가능
  const bR = await mkBus(J.H, ids.H, 5000, 30000, 10000);
  await uRpc(J.A,'join_coop_bus', jb(bR, 6000));
  await uRest(J.H,'PATCH',`buses?id=eq.${bR}`,{ordered:true},'return=representation');   // 주문(마감)
  const fin = await uRpc(J.H,'finalize_coop',{p_bus_id:bR});                                // 배송 완료
  log(fin.ok && fin.data===true, `R0 배송 완료 처리(finalize) → ${JSON.stringify(fin.data)}`);

  const rv1 = await uRpc(J.A,'submit_coop_review',{p_bus_id:bR,p_reviewee_id:ids.H,p_rating:5,p_badges:['host_kind','host_fast_reply']});
  log(rv1.ok, `R1 탑승자→총대 평가 성공`);
  const rvDup = await uRpc(J.A,'submit_coop_review',{p_bus_id:bR,p_reviewee_id:ids.H,p_rating:3,p_badges:[]});
  log(!rvDup.ok && (rvDup.status===409 || String(rvDup.data.code||'')==='23505'), `R2 중복 평가 거부 (${rvDup.status}/${rvDup.data.code||''})`);
  const rvSelf = await uRpc(J.A,'submit_coop_review',{p_bus_id:bR,p_reviewee_id:ids.A,p_rating:5,p_badges:[]});
  log(!rvSelf.ok && /본인/.test(rvSelf.data.message||''), `R3 셀프 평가 거부`);
  const rvOut = await uRpc(J.B1,'submit_coop_review',{p_bus_id:bR,p_reviewee_id:ids.H,p_rating:5,p_badges:[]});
  log(!rvOut.ok && /참여자/.test(rvOut.data.message||''), `R4 비참여자 평가 거부`);
  const rvBad = await uRpc(J.H,'submit_coop_review',{p_bus_id:bR,p_reviewee_id:ids.A,p_rating:4,p_badges:['host_kind']});
  log(!rvBad.ok && /배지/.test(rvBad.data.message||''), `R5 역할 불일치 배지 거부`);
  const rvHR = await uRpc(J.H,'submit_coop_review',{p_bus_id:bR,p_reviewee_id:ids.A,p_rating:4,p_badges:['rider_fast_pay']});
  log(rvHR.ok, `R6 총대→탑승자 평가 성공`);

  // 미완료(finalize 전) 공구는 평가 거부
  const bR2 = await mkBus(J.H, ids.H, 5000, 30000, 10000);
  await uRpc(J.C,'join_coop_bus', jb(bR2, 6000));
  await uRest(J.H,'PATCH',`buses?id=eq.${bR2}`,{ordered:true},'return=representation');   // 주문만, finalize 안 함
  const rvEarly = await uRpc(J.C,'submit_coop_review',{p_bus_id:bR2,p_reviewee_id:ids.H,p_rating:5,p_badges:[]});
  log(!rvEarly.ok && /배송 완료/.test(rvEarly.data.message||''), `R7 미완료 공구 평가 거부`);

  // is_warned: A 에게 부정 배지 리뷰 3건 직접 적재(service_role) → 누적 3회 경고
  for(const k of ['B1','B2a','B2b'])
    await srvPost('coop_reviews', {bus_id:bR, reviewer_id:ids[k], reviewee_id:ids.A, direction:'host_to_rider', rating:2, badges:['rider_ghost']});
  const mp = await uRpc(J.H,'get_manner_profiles',{p_user_ids:[ids.A, ids.H]});
  const pa = (mp.data||[]).find(x=>x.user_id===ids.A) || {};
  const ph = (mp.data||[]).find(x=>x.user_id===ids.H) || {};
  log(mp.ok && pa.review_count===4 && pa.is_warned===true, `R8 매너집계 A: count ${pa.review_count}, is_warned ${pa.is_warned} (기대 4/true)`);
  const codes = Array.isArray(pa.top_badges) ? pa.top_badges.map(t=>t.code) : [];
  log(codes.includes('rider_fast_pay') && !codes.includes('rider_ghost'), `R9 top_badges 긍정만 노출 [${codes.join(',')}] (부정 rider_ghost 비노출)`);
  log(Number(ph.avg_rating)===5 && ph.review_count===1, `R10 매너집계 H: ⭐${ph.avg_rating} (${ph.review_count})`);

  // RLS: 비작성자는 타인 리뷰 원본 0행 / 작성자 본인은 조회 가능
  const seeOut = await uRest(J.C,'GET',`coop_reviews?reviewee_id=eq.${ids.A}&select=id`);
  log(Array.isArray(seeOut.data) && seeOut.data.length===0, `R11 비작성자 리뷰 원본 비공개 (${Array.isArray(seeOut.data)?seeOut.data.length:'?'}행)`);
  const seeOwn = await uRest(J.A,'GET',`coop_reviews?select=id`);
  log(Array.isArray(seeOwn.data) && seeOwn.data.length>=1, `R12 작성자 본인 리뷰 조회 가능 (${Array.isArray(seeOwn.data)?seeOwn.data.length:'?'}행)`);
}catch(e){console.error('THREW:',e.message);fail++;}
finally{
  for(const id of busIds){ await srvDel(`buses?id=eq.${id}`); }
  for(const k of Object.keys(ids)){ if(ids[k]) await aDel(ids[k]); }
  console.log('\n-- cleanup done --');
  console.log(`=== 페르소나 하드테스트: OK ${pass} / XX ${fail} ===`);
  process.exit(fail?1:0);
}
