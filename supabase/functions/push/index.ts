// Vuelve · notificaciones push (Web Push con VAPID)
// GET  -> devuelve la clave pública VAPID (la crea la primera vez; la privada nunca sale del servidor)
// POST -> llamado solo desde la base de datos (cabecera x-hook) para enviar avisos
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, authorization, apikey, x-client-info", "Access-Control-Allow-Methods": "GET, POST, OPTIONS" };
const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });
const TOQUES: Record<string, string> = { vamos: "¡Vamos, tú puedes!", cierra: "Cierra tu día, que ya queda poco", orgullo: "Estoy orgullosa de ti", mueve: "¿Nos movemos hoy?", agua: "Acuérdate de beber agua", juntas: "Juntas es más fácil" };
const json = (d: unknown, s = 200) => new Response(JSON.stringify(d), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

async function cfg() {
  const { data, error } = await sb.rpc("push_cfg_get");
  if (error) throw error;
  let c = (data || [])[0];
  if (!c.vapid_priv) {
    const k = webpush.generateVAPIDKeys();
    await sb.rpc("push_cfg_set", { p_pub: k.publicKey, p_priv: k.privateKey });
    const r = await sb.rpc("push_cfg_get"); c = (r.data || [])[0];
  }
  return c as { vapid_pub: string; vapid_priv: string; hook_secret: string };
}

async function enviar(c: any, userIds: string[], payload: Record<string, unknown>) {
  if (!userIds.length) return 0;
  webpush.setVapidDetails("mailto:ninnx3@gmail.com", c.vapid_pub, c.vapid_priv);
  const { data: subs, error: se } = await sb.from("push_subs").select("endpoint,p256dh,auth,user_id").in("user_id", userIds);
  console.log("enviar", JSON.stringify({ dest: userIds.length, subs: (subs || []).length, se: se && se.message }));
  let n = 0;
  await Promise.all((subs || []).map(async (s: any) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify(payload), { TTL: 60 * 60 * 12, urgency: "normal" });
      n++;
    } catch (e: any) {
      if (e && (e.statusCode === 404 || e.statusCode === 410)) await sb.from("push_subs").delete().eq("endpoint", s.endpoint);
      else console.error("push fallo", e && e.statusCode, e && e.body, String(e));
    }
  }));
  return n;
}
const nombre = async (id: string) => { const { data } = await sb.from("perfiles_publicos").select("usuario").eq("user_id", id).maybeSingle(); return data ? "@" + data.usuario : "Alguien"; };
const corta = (t: string, n = 110) => (t.length > n ? t.slice(0, n - 1) + "…" : t);
const hoy = (d = 0) => { const x = new Date(Date.now() + 60 * 60 * 1000); x.setUTCDate(x.getUTCDate() + d); return x.toISOString().slice(0, 10); };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const c = await cfg();
    if (req.method === "GET") return json({ publicKey: c.vapid_pub });
    if (req.headers.get("x-hook") !== c.hook_secret) return json({ error: "no autorizado" }, 401);
    const b = await req.json();

    if (b.tabla === "comunidad_mensajes") {
      const { data: m } = await sb.from("comunidad_mensajes").select("id,reto_id,user_id,texto,borrado").eq("id", b.id).maybeSingle();
      if (!m || m.borrado) return json({ ok: true, n: 0 });
      const [{ data: r }, { data: mm }, { data: bl }, { data: pr }] = await Promise.all([
        sb.from("comunidad_retos").select("titulo").eq("id", m.reto_id).maybeSingle(),
        sb.from("comunidad_miembros").select("user_id,silenciado").eq("reto_id", m.reto_id),
        sb.from("comunidad_bloqueos").select("user_id").eq("bloqueada", m.user_id),
        sb.from("push_prefs").select("user_id,chat_on").eq("chat_on", false)]);
      const fuera = new Set([...(bl || []).map((x: any) => x.user_id), ...(pr || []).map((x: any) => x.user_id), m.user_id]);
      console.log("mensaje", JSON.stringify({ miembros: (mm || []).length, bl: (bl || []).length, pr: (pr || []).length }));
      const dest = (mm || []).filter((x: any) => !x.silenciado && !fuera.has(x.user_id)).map((x: any) => x.user_id);
      const n = await enviar(c, dest, { title: `${await nombre(m.user_id)} · ${r?.titulo || "Tu reto"}`, body: corta(m.texto), tag: "reto-" + m.reto_id, url: "./?v=retos&reto=" + m.reto_id });
      return json({ ok: true, n });
    }
    if (b.tabla === "comunidad_invitaciones") {
      const { data: r } = await sb.from("comunidad_retos").select("titulo").eq("id", b.reto_id).maybeSingle();
      const n = await enviar(c, [b.user_id], { title: "Te han invitado a un reto", body: `${await nombre(b.por)} te invita a «${r?.titulo || "un reto"}»`, tag: "inv-" + b.reto_id, url: "./?v=retos" });
      return json({ ok: true, n });
    }
    if (b.tabla === "toques") {
      const { data: t } = await sb.from("toques").select("de_nombre,para,tipo").eq("id", b.id).maybeSingle();
      if (!t) return json({ ok: true, n: 0 });
      const n = await enviar(c, [t.para], { title: `${t.de_nombre || "Tu compañera"} te manda un toque`, body: TOQUES[t.tipo] || "¡Ánimo!", tag: "toque", url: "./?v=retos" });
      return json({ ok: true, n });
    }
    if (b.tabla === "fotos") {
      const [m1, m0] = [hoy(1), hoy(0)];
      const { data: ps } = await sb.from("push_prefs").select("user_id,foto_prox").eq("foto_on", true).in("foto_prox", [m1, m0]);
      const man = (ps || []).filter((p: any) => p.foto_prox === m1).map((p: any) => p.user_id);
      const hoyU = (ps || []).filter((p: any) => p.foto_prox === m0).map((p: any) => p.user_id);
      const n1 = await enviar(c, man, { title: "Mañana te toca tu foto de progreso", body: "Deja preparada la misma ropa de la última vez y el móvil cargado.", tag: "fotos", url: "./?v=progreso" });
      const n2 = await enviar(c, hoyU, { title: "Hoy te toca tu foto de progreso", body: "Por la mañana y en ayunas, mismo sitio y misma luz. Solo la ves tú.", tag: "fotos", url: "./?v=progreso" });
      return json({ ok: true, n: n1 + n2 });
    }
    if (b.tabla === "consejos") {
      // Mensajes de bienvenida: se envían cuando la usuaria llega a ese día (con 2 días de margen por si activó los avisos más tarde).
      const PLAN = [
        { id: "peso1", d: 0, body: "Casi todas calculamos de menos «a ojo». Te cuento cómo acertar en 1 minuto." },
        { id: "rapido3", d: 3, body: "Apuntar lo que comes en 10 segundos: tus favoritos y recientes." },
        { id: "semana1", d: 7, body: "Una semana contigo 💜 Mira todo lo que aún no has probado." },
        { id: "tend14", d: 14, body: "Tu peso de hoy dice poco. Tu tendencia lo dice todo." },
        { id: "volver21", d: 21, body: "¿Un día sin registrar? No pasa nada. Lo importante es volver." },
        { id: "mes1", d: 30, body: "Ya llevas un mes. ¿Recalculamos tu plan con tus datos de hoy?" },
      ];
      const { data: cola, error } = await sb.rpc("push_consejos_cola");
      if (error) throw error;
      let n = 0;
      for (const u of (cola || []) as any[]) {
        const t = PLAN.find((x) => u.edad >= x.d && u.edad <= x.d + 2 && !(u.enviados || []).includes(x.id));
        if (!t) continue;
        const ok = await enviar(c, [u.user_id], { title: "Vuelve", body: t.body, tag: "consejo", url: "./?v=avisos" });
        if (ok > 0) { await sb.from("push_consejos").insert({ user_id: u.user_id, aviso: t.id }); n += ok; }
      }
      return json({ ok: true, n });
    }
    if (b.tabla === "nuevas") {
      // Nueva usuaria: aviso solo a las administradoras
      const [{ data: ad }, { data: u }] = await Promise.all([
        sb.from("admins").select("user_id"),
        sb.auth.admin.getUserById(b.user_id)]);
      const { data: lista } = await sb.auth.admin.listUsers({ page: 1, perPage: 1 });
      const nom = (u?.user?.user_metadata?.nombre || u?.user?.email?.split("@")[0] || "Alguien") as string;
      const total = (lista as any)?.total;
      const cuando = new Intl.DateTimeFormat("es-ES", { timeZone: "Europe/Madrid", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }).format(new Date(u?.user?.created_at || Date.now()));
      const n = await enviar(c, (ad || []).map((x: any) => x.user_id).filter((id: string) => id !== b.user_id), { title: "Vuelve", body: `Nueva usuaria: ${corta(nom, 40)} 🎉${total ? ` Ya sois ${total}.` : ""} · ${cuando}`, tag: "nueva-" + b.user_id, url: "./?v=diario" });
      return json({ ok: true, n });
    }
    return json({ ok: true, n: 0 });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
