// Proxy de búsqueda de Open Food Facts para Vuelve (v5: país del usuario + sinónimos regionales; reintentos, tiempo máximo y buscadores de reserva).
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

// País (código ISO del usuario) -> etiqueta de país en Open Food Facts. 'xx' = sin filtrar.
const COUNTRY: Record<string, string> = {
  es: 'spain', mx: 'mexico', co: 'colombia', ar: 'argentina', cl: 'chile', pe: 'peru', ve: 'venezuela', ec: 'ecuador',
  uy: 'uruguay', py: 'paraguay', bo: 'bolivia', cr: 'costa-rica', pa: 'panama', do: 'dominican-republic', gt: 'guatemala',
  sv: 'el-salvador', hn: 'honduras', ni: 'nicaragua', pr: 'puerto-rico', us: 'united-states',
};

// Palabras que son lo mismo según el país (la primera es la de España)
const SYN_GROUPS = [
  ['patata', 'papa'], ['zumo', 'jugo'], ['platano', 'banana', 'banano', 'guineo'], ['aguacate', 'palta'], ['fresa', 'frutilla'],
  ['melocoton', 'durazno'], ['judia', 'frijol', 'poroto', 'habichuela', 'caraota'], ['guisante', 'arveja', 'chicharo'],
  ['maiz', 'choclo', 'elote'], ['cacahuete', 'mani', 'cacahuate'], ['calabacin', 'zapallito', 'zucchini'], ['calabaza', 'zapallo', 'ahuyama'],
  ['pimiento', 'morron', 'aji', 'chile'], ['refresco', 'gaseosa', 'soda'], ['cerdo', 'chancho', 'puerco'], ['gamba', 'camaron'],
  ['tomate', 'jitomate'], ['champinon', 'hongo'], ['col', 'repollo'], ['pavo', 'guajolote'], ['bizcocho', 'ponque', 'queque'],
  ['tarta', 'pastel'], ['sandia', 'patilla'], ['pina', 'anana'], ['albaricoque', 'damasco', 'chabacano'], ['yuca', 'mandioca'],
  ['boniato', 'camote', 'batata'], ['yogur', 'yogurt'], ['palomita', 'pochoclo', 'cabrita'], ['batido', 'licuado'],
];
const SYN: Record<string, string[]> = {};
for (const g of SYN_GROUPS) { const m = g.map((x) => sing(norm(x))); for (const w of m) SYN[w] = [...new Set([...(SYN[w] || []), ...m])]; }
// Una consulta alternativa con las palabras equivalentes de otra zona (null si no hay ninguna)
function altQuery(q: string): string | null {
  let changed = false;
  const out = norm(q).split(/\s+/).filter(Boolean).map((t) => {
    const g = SYN[sing(t)];
    if (!g) return t;
    const first = g[0], other = sing(t) === first ? g[1] : first;
    if (other && other !== sing(t)) { changed = true; return other; }
    return t;
  });
  return changed ? out.join(' ') : null;
}

function json(body: string, status = 200, extra: Record<string, string> = {}) {
  return new Response(body, { status, headers: { ...CORS, 'Content-Type': 'application/json', ...extra } });
}

async function getJson(url: string, ms = 9000): Promise<any> {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), ms);
  try {
    const r = await fetch(url, { headers: { 'User-Agent': UA, 'Accept': 'application/json' }, signal: ctl.signal });
    if (!r.ok) throw new Error('http ' + r.status);
    return await r.json();
  } finally { clearTimeout(timer); }
}

type Hit = Record<string, any>;
// Buscador nuevo (search-a-licious); tag = país de Open Food Facts o '' para todo el mundo
async function sal(q: string, tag: string): Promise<Hit[]> {
  const query = tag ? `${q} countries_tags:"en:${tag}"` : q;
  const j = await getJson('https://search.openfoodfacts.org/search?page_size=100&langs=es&fields=' + KEEP.join(',') + '&q=' + encodeURIComponent(query));
  return j.hits || [];
}
// Buscador clásico y API v1, como reserva
async function classic(q: string, cc: string): Promise<Hit[]> {
  const base = cc && COUNTRY[cc] ? `https://${cc}.openfoodfacts.org` : 'https://world.openfoodfacts.org';
  const j = await getJson(base + '/cgi/search.pl?action=process&json=1&page_size=60&sort_by=unique_scans_n&search_simple=1&search_terms=' + encodeURIComponent(q) + '&fields=' + KEEP.join(','), 12000);
  return j.products || [];
}
async function anyOf(label: string, fns: (() => Promise<Hit[]>)[]): Promise<Hit[]> {
  let last = '';
  for (const f of fns) {
    try { const r = await f(); if (r.length) return r; last = 'vacío'; } catch (e) { last = String(e); console.error('off ' + label + ': ' + last); }
  }
  if (last && last !== 'vacío') throw new Error(last);
  return [];
}

function rank(hits: Hit[], q: string): Hit[] {
  const toks = norm(q).split(/[^a-z0-9ñ%]+/).filter((t) => t.length > 1 && !['de', 'en', 'la', 'el', 'con', 'sin', 'y'].includes(t)).map(sing);
  const scored = hits.map((h) => {
    const brand = norm(Array.isArray(h.brands) ? h.brands.join(' ') : String(h.brands || ''));
    const b0 = norm(Array.isArray(h.brands) ? h.brands[0] : String(h.brands || '').split(',')[0]);
    let name = String(h.product_name_es || h.product_name || '').trim();
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

// Busca una consulta en el país del usuario (o en todo el mundo si cc='xx')
async function searchIn(q: string, cc: string): Promise<Hit[]> {
  const tag = COUNTRY[cc] || '';
  return rank(await anyOf(cc, [() => sal(q, tag), () => sal(q, tag), () => classic(q, cc)]), q);
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const u = new URL(req.url);
    let q = u.searchParams.get('q') || '';
    let cc = (u.searchParams.get('cc') || 'es').toLowerCase();
    if (!q && req.method === 'POST') { try { const b = await req.json(); q = b.q || ''; cc = String(b.cc || cc).toLowerCase(); } catch { /* */ } }
    if (cc !== 'xx' && !COUNTRY[cc]) cc = 'es';
    q = String(q).replace(/[\u0000-\u001f"]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, 80);
    if (q.length < 2) return json(JSON.stringify({ error: 'q demasiado corto', hits: [] }), 400);
    const key = cc + '|' + norm(q);
    const c = CACHE.get(key);
    if (c && Date.now() - c.t < TTL) return json(c.body, 200, { 'X-Cache': 'hit' });
    // 1) país del usuario (con la consulta tal cual y, si tiene palabras regionales, también con las equivalentes)
    const alt = altQuery(q);
    let firstErr = '';
    const [main, other] = await Promise.all([
      searchIn(q, cc).catch((e) => { firstErr = String(e); return [] as Hit[]; }),
      alt ? searchIn(alt, cc).catch(() => [] as Hit[]) : Promise.resolve([] as Hit[]),
    ]);
    let hits = [...main, ...other].filter((h, i, a) => a.findIndex((x) => x.code === h.code) === i).slice(0, 30);
    // 2) si hay pocos resultados, ampliamos a todo el mundo
    if (hits.length < 5 && cc !== 'xx') {
      let more: Hit[] = [];
      try { more = rank(await anyOf('world', [() => sal(q, ''), () => classic(q, '')]), q); firstErr = ''; } catch (e) { if (!firstErr) firstErr = String(e); }
      hits = [...hits, ...more].filter((h, i, a) => a.findIndex((x) => x.code === h.code) === i).slice(0, 30);
    }
    if (!hits.length && firstErr) throw new Error(firstErr);
    const body = JSON.stringify({ hits });
    if (hits.length) { if (CACHE.size > 2000) CACHE.clear(); CACHE.set(key, { t: Date.now(), body }); }
    return json(body, 200, { 'Cache-Control': hits.length ? 'public, max-age=1800' : 'no-store' });
  } catch (e) {
    console.error('off fallo total: ' + String(e));
    return json(JSON.stringify({ error: String(e), hits: [] }), 502);
  }
});
