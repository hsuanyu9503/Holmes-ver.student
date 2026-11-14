/**
 * 606 情報局 v2.8.0 Stable · 語音憑證與發言權限同步
 *
 * POST {room_id, action?: 'join'|'sync'}
 * join: 只核發『可收聽、不可發言』的五分鐘短效憑證。
 * sync: 以 Supabase 的權威房間狀態，透過 LiveKit RoomService 更新連線者
 *       canPublish (並撤銷舊權限)。任何合法房間成員可要求同步，不能指定誰能發言。
 *
 * LiveKit API Secret 必須只存在 Supabase Edge Function Secrets。
 * 注意：同步由房間狀態刷新驅動，非 PostgreSQL 事務內同步；詳見 TESTING.md 的競態限制。
 */
import { withSupabase } from "npm:@supabase/server@1";

const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
  });
const b64url = (bytes: Uint8Array): string => {
  let raw = "";
  for (const x of bytes) raw += String.fromCharCode(x);
  return btoa(raw).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};
const enc = (data: object): string => b64url(new TextEncoder().encode(JSON.stringify(data)));
async function signToken(payload: Record<string, unknown>, apiSecret: string): Promise<string> {
  const input = `${enc({ alg: "HS256", typ: "JWT" })}.${enc(payload)}`;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(apiSecret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(input)));
  return `${input}.${b64url(signature)}`;
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const roomName = (id: string, round: number) => `intel606-${id}-r${round}`;

// 以伺服器權威房間狀態計算發言權限，不接受前端傳入發言座位或暫停標記。
function micAllowed(state: Record<string, unknown>, seat: number | null, isHostOnly = false) {
  if (state.play_mode !== "remote" || state.remote_interaction_mode !== "voice") return false;
  if (state.phase === "clue")
    return !isHostOnly && !state.clue_completed && Number.isInteger(seat) &&
      seat !== null && seat > 0 && seat === Number(state.clue_current_seat);
  if (state.phase !== "chat" || state.chat_paused) return false;
  if (state.discussion_mode === "timed") {
    const deadline = Date.parse(String(state.chat_deadline_at || ""));
    if (!Number.isFinite(deadline) || deadline <= Date.now()) return false;
  }
  return true;
}

function liveConfig() {
  const url = (Deno.env.get("LIVEKIT_URL") || "").trim();
  const key = (Deno.env.get("LIVEKIT_API_KEY") || "").trim();
  const secret = (Deno.env.get("LIVEKIT_API_SECRET") || "").trim();
  if (!/^wss:\/\/[^\s/]+$/i.test(url) || !key || secret.length < 8) return null;
  return { url, key, secret, httpsUrl: url.replace(/^wss:/i, "https:") };
}

// LiveKit 公開的 Twirp RoomService JSON API；不將管理憑證提供給瀏覽器。
async function roomService(
  cfg: NonNullable<ReturnType<typeof liveConfig>>, method: string, payload: Record<string, unknown>, room: string
): Promise<Record<string, unknown>> {
  const now = Math.floor(Date.now() / 1000);
  const admin = await signToken({ iss: cfg.key, sub: "intel606-voice-policy", iat: now, nbf: now - 5,
    exp: now + 60, video: { roomAdmin: true, room } }, cfg.secret);
  const response = await fetch(`${cfg.httpsUrl}/twirp/livekit.RoomService/${method}`, {
    method: "POST", headers: { "Authorization": `Bearer ${admin}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload), signal: AbortSignal.timeout(8000)
  });
  const data = await response.json().catch(() => ({})) as Record<string, unknown>;
  if (!response.ok) {
    const err = new Error(`LiveKit ${method}: ${String(data.code || response.status)}`) as Error & { status?: number; code?: string };
    err.status = response.status; err.code = String(data.code || "");
    throw err;
  }
  return data;
}

async function reconcile(
  cfg: NonNullable<ReturnType<typeof liveConfig>>, roomId: string,
  readRoom: () => Promise<Record<string, unknown>>,
  readMembers: () => Promise<Map<string, number>>,
): Promise<{ updated: number; removed: number; active: boolean }> {
  // 再次查詢新鮮狀態：狀態可能在請求排隊期間已經更動。
  const state = await readRoom();
  const round = Number(state.round);
  if (!Number.isInteger(round) || round < 1) throw new Error("無效遊戲輪次");
  const liveName = roomName(roomId, round);
  const active = state.play_mode === "remote" && state.remote_interaction_mode === "voice"
    && (state.phase === "clue" || state.phase === "chat");
  let participants: Record<string, unknown>[];
  try {
    const answer = await roomService(cfg, "ListParticipants", { room: liveName }, liveName);
    participants = Array.isArray(answer.participants) ? answer.participants as Record<string, unknown>[] : [];
  } catch (error) {
    if ((error as { status?: number; code?: string }).status === 404 ||
        (error as { code?: string }).code === "not_found") return { updated: 0, removed: 0, active };
    throw error;
  }
  const members = active ? await readMembers() : new Map<string, number>();
  let updated = 0, removed = 0;
  for (const p of participants) {
    const identity = String(p.identity || "");
    const uid = identity.startsWith("intel606-u-") ? identity.slice("intel606-u-".length) : "";
    // 非當局房間成員／已離開討論階段者會被踢離並撤銷連線憑證。
    if (!active || !UUID.test(uid) || !members.has(uid)) {
      try {
        await roomService(cfg, "RemoveParticipant", { room: liveName, identity }, liveName);
        removed++;
      } catch (e) {
        if ((e as { status?: number; code?: string }).status !== 404 &&
            (e as { code?: string }).code !== "not_found") throw e;
      }
      continue;
    }
    const seat = members.get(uid) || null;
    const shouldPublish = micAllowed(state, seat, seat === null);
    const current = (p.permission && typeof p.permission === "object")
      ? p.permission as Record<string, unknown> : {};
    const sources = Array.isArray(current.canPublishSources) ? current.canPublishSources : [];
    const micOnly = sources.length === 1 && (sources[0] === 2 || sources[0] === "MICROPHONE");
    if (current.canPublish === shouldPublish && current.canSubscribe === true &&
        current.canPublishData === false && ((shouldPublish && micOnly) || (!shouldPublish && sources.length === 0))) continue;
    try {
      await roomService(cfg, "UpdateParticipant", {
        room: liveName, identity, permission: {
          canSubscribe: true, canPublish: shouldPublish,
          canPublishData: false, canPublishSources: shouldPublish ? [2] : []
        }
      }, liveName);
      updated++;
    } catch (e) {
      // 權限同步期間玩家可能剛好斷線；不因此阻擋其他人的校正。
      if ((e as { status?: number; code?: string }).status !== 404 &&
          (e as { code?: string }).code !== "not_found") throw e;
    }
  }
  // 偵測更新時的並行發言輪次變動；客戶端每次獲得房間狀態時亦重新同步。
  return { updated, removed, active };
}

export default {
  fetch: withSupabase({ auth: "user" }, async (request, ctx) => {
    if (request.method !== "POST") return json({ error: "只接受 POST" }, 405);
    let body: Record<string, unknown>;
    try { body = await request.json(); } catch { return json({ error: "請提供 JSON 內容" }, 400); }
    const roomId = typeof body?.room_id === "string" ? body.room_id.trim() : "";
    const action = body?.action === "sync" ? "sync" : body?.action === undefined || body?.action === "join" ? "join" : null;
    if (!UUID.test(roomId) || !action) return json({ error: "房間編號或操作格式不正確" }, 400);
    const userId = String(ctx.userClaims?.id ?? ctx.jwtClaims?.sub ?? "");
    if (!UUID.test(userId)) return json({ error: "登入身分不完整" }, 401);
    const readRoom = async () => {
      // RLS/SECURITY DEFINER：同房間合法主控／玩家才能讀取，沒有拿到他人私人身分。
      const { data, error } = await ctx.supabase.rpc("intel606_room_state", { p_room: roomId });
      if (error || !data) throw new Error("房間不存在或無權存取");
      return data as Record<string, unknown>;
    };
    let state: Record<string, unknown>;
    try { state = await readRoom(); } catch { return json({ error: "無法驗證房間成員身分" }, 403); }
    if (state.play_mode !== "remote" || state.remote_interaction_mode !== "voice")
      return json({ error: "只有遠距語音房間可使用語音" }, 409);
    const cfg = liveConfig();
    if (!cfg) return json({ error: "語音服務尚未由管理者設定" }, 503);

    if (action === "join") {
      if (!["clue", "chat"].includes(String(state.phase)))
        return json({ error: "目前階段尚未開放語音加入" }, 409);
      // 新進者一律 listen-only，權限需由授權服務依最新座位／暫停狀態授予。
      const seat = Number(state.my_seat);
      const name = state.is_host && !state.host_plays ? "任務主控" :
        Number.isInteger(seat) && seat >= 1 && seat <= 8 ? `${String(seat).padStart(2, "0")} 號玩家` : "情報參與者";
      const now = Math.floor(Date.now() / 1000);
      const payload = { iss: cfg.key, sub: `intel606-u-${userId}`, iat: now, nbf: now - 5,
        exp: now + 5 * 60, name,
        video: { roomJoin: true, room: roomName(roomId, Number(state.round)),
          canPublish: false, canSubscribe: true, canPublishData: false,
          roomCreate: false, roomAdmin: false, roomRecord: false } };
      return json({ serverUrl: cfg.url, token: await signToken(payload, cfg.secret), expiresIn: 300 });
    }

    try {
      // admin client 只在已通過呼叫者身分檢查後用來讀取座位對應，不寫入遊戲資料。
      const readMembers = async () => {
        const { data: members, error: e } = await ctx.supabaseAdmin.from("intel606_members")
          .select("user_id,seat_no").eq("room_id", roomId);
        if (e) throw new Error("無法讀取發言座位");
        const result = new Map<string, number>();
        for (const m of members || []) if (UUID.test(String(m.user_id)))
          result.set(String(m.user_id), Number(m.seat_no));
        // 無玩家座位的主控在自由討論可發言、線索階段只能收聽。
        const { data: owner, error: ownerError } = await ctx.supabaseAdmin.from("intel606_rooms")
          .select("host_id").eq("id", roomId).single();
        if (ownerError || !owner?.host_id) throw new Error("無法驗證房間主控");
        if (!result.has(String(owner.host_id))) result.set(String(owner.host_id), 0);
        return result;
      };
      const result = await reconcile(cfg, roomId, readRoom, readMembers);
      return json({ ok: true, ...result });
    } catch (error) {
      console.error("voice permission sync failed:", error);
      return json({ error: "語音發言權限同步失敗，請稍後重試" }, 503);
    }
  })
};
