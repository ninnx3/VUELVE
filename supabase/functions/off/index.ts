// Proxy de búsqueda de Open Food Facts para Vuelve.
// El buscador de OFF (search.openfoodfacts.org) no permite llamadas desde otras webs (CORS)
// y el buscador clásico ya no responde a usuarios anónimos, así que la web busca a través de aquí.
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const UA = 'Vuelve/1.0 (vuelve.contact@gmail.com)';
const KEEP = ['code', 'product_name', 'product_name_es', 'generic_name_es', 'brands', 'quantity', 'serving_quantity', 'serving_size', 'nutriments', 'unique_scans_n', 'popularity_key'];
const OUT = ['code', 'product_name', 'product_name_es', 'brands', 'quantity', 'serving_quantity', 'serving_size', 'nutriments'];
const CACHE = new Map<string, { t: number; body: string }>();
const TTL = 6 * 60 * 60 * 1000;
const norm = (s: unknown) => String(s ?? '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
const sing = (t: string) => t.length > 4 && t.endsWith('es') ? t.slice(0, -2) : t.length > 3 && t.endsWith('s') ? t.slice(0, -1) : t;

function json(body: string, status = 200, extra: Record<string, string> = {}) {
  return new Response(body, { status, headers: { ...CORS, 'Content-Type': 'application/json', ...extra } });
}

type Hit = Record<string, any>;
async function search(q: string, spain: boolean): Promise<Hit[]> {
  const query = spain ? `${q} countries_tags:"en:spain"` : q;
  const url = 'https://search.openfoodfacts.org/search?page_size=100&langs=es&fields=' + KEEP.join(',') + '&q=' + encodeURIComponent(query);
  const r = await fetch(url, { headers: { 'User-Agent': UA, 'Accept': 'application/json' } });
  if (!r.ok) throw new Error('off ' + r.status);
  const j = await r.json();
  return j.hits || [];
}

function rank(hits: Hit[], q: string): Hit[] {
  const toks = norm(q).split(/[^a-z0-9ñ%]+/).filter((t) => t.length > 1 && !['de', 'en', 'la', 'el', 'con', 'sin', 'y'].includes(t)).map(sing);
  const scored = hits.map((h) => {
    const brand = norm(Array.isArray(h.brands) ? h.brands.join(' ') : String(h.brands || ''));
    const b0 = norm(Array.isArray(h.brands) ? h.brands[0] : String(h.brands || '').split(',')[0]);
    let name = String(h.product_name_es || h.product_name || '').trim();
    // Fichas mal etiquetadas cuyo nombre es solo la marca: usamos el nombre genérico si lo hay
    if (!name || norm(name) === b0) name = String(h.generic_name_es || '').trim();
    if (!name || norm(name) === b0) return null;
    const n = norm(name), all = n + ' ' + brand;
    const k = h.nutriments && h.nutriments['energy-kcal_100g'];
    let s = 0, full = true;
    for (const t of toks) { if (n.includes(t)) s += 3; else if (all.includes(t)) s += 1; else { s -= 3; full = false } }
    if (k != null) s += 3;
    s += Math.min(3, Math.log10(1 + (Number(h.unique_scans_n) || 0)));
    const o: Hit = {};
    for (const key of OUT) if (h[key] !== undefined) o[key] = h[key];
    o.product_name_es = name;
    return { s, o, full };
  }).filter(Boolean) as { s: number; o: Hit; full: boolean }[];
  scored.sort((a, b) => b.s - a.s);
  const fulls = scored.filter((x) => x.full);
  return (fulls.length >= 5 ? fulls : scored).slice(0, 30).map((x) => x.o);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const u = new URL(req.url);
    let q = u.searchParams.get('q') || '';
    if (!q && req.method === 'POST') { try { q = (await req.json()).q || '' } catch { /* */ } }
    q = String(q).replace(/[\u0000-\u001f"]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80);
    if (q.length < 2) return json(JSON.stringify({ error: 'q demasiado corto', hits: [] }), 400);
    const key = norm(q);
    const c = CACHE.get(key);
    if (c && Date.now() - c.t < TTL) return json(c.body, 200, { 'X-Cache': 'hit' });
    let hits = rank(await search(q, true), q);
    if (hits.length < 5) hits = [...hits, ...rank(await search(q, false), q)].filter((h, i, a) => a.findIndex((x) => x.code === h.code) === i).slice(0, 30);
    const body = JSON.stringify({ hits });
    if (CACHE.size > 2000) CACHE.clear();
    CACHE.set(key, { t: Date.now(), body });
    return json(body, 200, { 'Cache-Control': 'public, max-age=1800' });
  } catch (e) {
    return json(JSON.stringify({ error: String(e), hits: [] }), 502);
  }
});
