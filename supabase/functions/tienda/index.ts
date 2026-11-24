// Tienda de Vuelve · función Edge única
//   POST {accion:'estado'}                         → ¿tienda abierta? ¿Stripe configurado? ¿modo test/live?
//   POST {accion:'checkout', producto_id, idioma}   → URL de pago de Stripe Checkout
//   POST {accion:'descarga', s}                     → enlaces de descarga (s = id de la sesión de Stripe)
//   POST {accion:'descarga', compra_id} + sesión    → enlaces de descarga para usuarias con cuenta
//   POST /tienda/webhook                            → avisos firmados de Stripe (checkout.session.completed)
// Secretos (Supabase → Edge Functions → Secrets): STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET
// Opcionales: TIENDA_SITE (por defecto https://vuelvehaciati.com), STRIPE_MANAGED_PAYMENTS=1
import { createClient } from "npm:@supabase/supabase-js@2";

const SITE = (Deno.env.get("TIENDA_SITE") ?? "https://vuelvehaciati.com").replace(/\/$/, "");
const SK = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
const WHS = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const MANAGED = Deno.env.get("STRIPE_MANAGED_PAYMENTS") === "1";
const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  (() => { try { return String(Object.values(JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}"))[0] || ""); } catch { return ""; } })();
const db = createClient(SB_URL, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const err = (codigo: string, status: number) => json({ error: codigo }, status);

function flat(o: Record<string, unknown>, pre = "", out: [string, string][] = []) {
  for (const [k, v] of Object.entries(o)) {
    if (v === undefined || v === null || v === "") continue;
    const key = pre ? `${pre}[${k}]` : k;
    if (typeof v === "object") flat(v as Record<string, unknown>, key, out);
    else out.push([key, String(v)]);
  }
  return out;
}
async function stripe(path: string, params?: Record<string, unknown>) {
  const r = await fetch("https://api.stripe.com/v1/" + path, {
    method: params ? "POST" : "GET",
    headers: { Authorization: "Bearer " + SK, "Content-Type": "application/x-www-form-urlencoded" },
    body: params ? new URLSearchParams(flat(params)) : undefined,
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j?.error?.message || "Error de Stripe");
  return j;
}

async function usuaria(req: Request) {
  const t = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!t || !t.includes(".")) return null; // las claves públicas no son JWT de usuaria
  const { data } = await db.auth.getUser(t);
  if (!data?.user) return null;
  const { data: a } = await db.from("admins").select("user_id").eq("user_id", data.user.id).maybeSingle();
  return { id: data.user.id, email: (data.user.email || "").toLowerCase(), admin: !!a };
}

async function registrar(s: any) {
  if (!s || s.payment_status !== "paid" || !s.metadata?.producto_id) return null;
  const email = (s.customer_details?.email || s.customer_email || "").toLowerCase();
  if (!email) return null;
  const { data: prod } = await db.from("productos").select("nombre").eq("id", s.metadata.producto_id).maybeSingle();
  await db.from("compras").upsert({
    session_id: s.id, producto_id: s.metadata.producto_id, email,
    user_id: s.metadata.user_id || null, importe_cent: s.amount_total ?? 0,
    moneda: s.currency || "eur", modo: s.livemode ? "live" : "test", producto_nombre: prod?.nombre ?? null,
  }, { onConflict: "session_id", ignoreDuplicates: true });
  const { data } = await db.from("compras").select("*").eq("session_id", s.id).maybeSingle();
  return data;
}

async function enlaces(compra: any) {
  const { data: p } = await db.from("productos").select("nombre,nombre_en,slug,archivos,tipo").eq("id", compra.producto_id).maybeSingle();
  if (!p) return { producto: null, archivos: [] };
  const archivos = [];
  for (const path of p.archivos || []) {
    const nombre = path.split("/").pop()!.replace(/^\d+-/, "");
    const { data } = await db.storage.from("tienda").createSignedUrl(path, 900, { download: nombre });
    if (data?.signedUrl) archivos.push({ nombre, url: data.signedUrl });
  }
  return { producto: { nombre: p.nombre, nombre_en: p.nombre_en, slug: p.slug, tipo: p.tipo }, archivos, email: compra.email, fecha: compra.creado, modo: compra.modo };
}

async function firmaValida(raw: string, cabecera: string) {
  if (!WHS || !cabecera) return false;
  const partes = Object.fromEntries(cabecera.split(",").map((x) => x.split("=") as [string, string]).filter((x) => x.length === 2).map(([k, v]) => [k.trim(), v]));
  const t = Number(partes.t);
  if (!t || Math.abs(Date.now() / 1000 - t) > 300) return false;
  const firmas = cabecera.split(",").filter((x) => x.trim().startsWith("v1=")).map((x) => x.trim().slice(3));
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(WHS), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(`${t}.${raw}`)));
  const hex = [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
  return firmas.some((f) => f.length === hex.length && [...f].reduce((d, c, i) => d | (c.charCodeAt(0) ^ hex.charCodeAt(i)), 0) === 0);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return err("metodo", 405);
  const url = new URL(req.url);

  // Webhook de Stripe
  if (url.pathname.endsWith("/webhook")) {
    const raw = await req.text();
    if (!(await firmaValida(raw, req.headers.get("stripe-signature") || ""))) return err("firma", 400);
    const ev = JSON.parse(raw);
    if (ev.type === "checkout.session.completed" || ev.type === "checkout.session.async_payment_succeeded") await registrar(ev.data.object);
    return json({ ok: true });
  }

  let b: any = {};
  try { b = await req.json(); } catch { return err("json", 400); }
  const modo = SK.startsWith("sk_live_") ? "live" : "test";

  try {
    if (b.accion === "estado") {
      const { data } = await db.from("tienda_config").select("abierta").eq("id", 1).maybeSingle();
      return json({ abierta: !!data?.abierta, stripe: !!SK, modo });
    }

    if (b.accion === "checkout") {
      const u = await usuaria(req);
      const { data: cfg } = await db.from("tienda_config").select("abierta").eq("id", 1).maybeSingle();
      if (!cfg?.abierta && !u?.admin) return err("cerrada", 403);
      if (!SK) return err("sin_stripe", 503);
      if (!/^[0-9a-f-]{36}$/.test(String(b.producto_id || ""))) return err("producto", 400);
      const { data: p } = await db.from("productos").select("*").eq("id", b.producto_id).maybeSingle();
      if (!p || (!p.activo && !u?.admin)) return err("producto", 404);
      const en = b.idioma === "en";
      const s = await stripe("checkout/sessions", {
        mode: "payment",
        locale: en ? "en" : "es",
        line_items: { 0: { quantity: 1, price_data: { currency: p.moneda, unit_amount: p.precio_cent,
          product_data: { name: (en && p.nombre_en) || p.nombre, images: p.portada ? { 0: p.portada } : undefined, metadata: { producto_id: p.id } } } } },
        success_url: `${SITE}/tienda/gracias/?s={CHECKOUT_SESSION_ID}&l=${en ? "en" : "es"}`,
        cancel_url: `${SITE}/tienda/?p=${p.slug}`,
        customer_email: u?.email || undefined,
        client_reference_id: u?.id || undefined,
        metadata: { producto_id: p.id, user_id: u?.id || "" },
        payment_intent_data: { metadata: { producto_id: p.id } },
        shipping_address_collection: p.tipo === "fisico" ? { allowed_countries: { 0: "ES", 1: "PT", 2: "FR", 3: "IT", 4: "DE" } } : undefined,
        managed_payments: MANAGED ? { enabled: "true" } : undefined,
      });
      return json({ url: s.url });
    }

    if (b.accion === "descarga") {
      let compra: any = null;
      if (b.s) {
        if (!/^cs_(test|live)_[A-Za-z0-9]{10,200}$/.test(String(b.s))) return err("sesion", 400);
        ({ data: compra } = await db.from("compras").select("*").eq("session_id", b.s).maybeSingle());
        if (!compra && SK) compra = await registrar(await stripe("checkout/sessions/" + b.s));
        if (!compra) return json({ pendiente: true }, 202);
      } else if (b.compra_id) {
        const u = await usuaria(req);
        if (!u) return err("sesion", 401);
        ({ data: compra } = await db.from("compras").select("*").eq("id", b.compra_id).maybeSingle());
        if (!compra || !(compra.email === u.email || compra.user_id === u.id || u.admin)) return err("compra", 404);
      } else return err("faltan_datos", 400);
      return json(await enlaces(compra));
    }

    return err("accion", 400);
  } catch (e) {
    console.error(e);
    return err("servidor", 500);
  }
});
