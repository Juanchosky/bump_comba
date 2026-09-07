import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
}

const BROWSER_HEADERS = {
  "User-Agent": "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36",
  "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
  "Accept-Language": "es-419,es;q=0.9,en;q=0.8",
  "Accept-Encoding": "gzip, deflate, br",
  "Cache-Control": "no-cache",
  "Sec-Fetch-Dest": "document",
  "Sec-Fetch-Mode": "navigate",
  "Sec-Fetch-Site": "none",
  "Upgrade-Insecure-Requests": "1",
}

async function fetchPage(url: string): Promise<{ html: string; ok: boolean; blocked: boolean }> {
  try {
    const res = await fetch(url, { headers: BROWSER_HEADERS, redirect: "follow" })
    if (res.status === 404 || res.status === 410) return { html: "", ok: false, blocked: false }
    if (!res.ok) return { html: "", ok: false, blocked: false }
    const html = await res.text()
    const blocked = html.includes("Just a moment") || html.includes("_cf_chl") || html.includes("cf-browser-verification")
    return { html, ok: !blocked, blocked }
  } catch (_) {
    return { html: "", ok: false, blocked: false }
  }
}

function sleep(ms: number) { return new Promise(r => setTimeout(r, ms)) }

function stripTrailingNumber(url: string): string {
  return url.replace(/\/(\d+)\/?([?#].*)?$/, "").replace(/\/$/, "")
}

function getMetaContent(html: string, property: string): string | null {
  const m = html.match(new RegExp(`<meta[^>]*property=["']${property}["'][^>]*content=["']([^"']+)["']`, "i"))
    ?? html.match(new RegExp(`<meta[^>]*content=["']([^"']+)["'][^>]*property=["']${property}["']`, "i"))
  return m ? m[1] : null
}

function sanitizeImageUrl(rawUrl: string | null | undefined): string | null {
  if (!rawUrl) return null
  try {
    let clean = rawUrl.trim().replace(/^["']|["']$/g, '')
    clean = clean.replace(/!$/, '')
    if (clean.includes('imageView2') || clean.includes('imageMogr2')) {
      clean = clean.replace(/\?(?:imageView2|imageMogr2).*$/, '')
    }
    if (clean.includes('img.') || clean.includes('/cover/')) {
      clean += '?imageView2/1/w/220/h/330/format/webp/q/75'
    }
    return encodeURI(clean)
  } catch (_) {
    return rawUrl
  }
}

function extractReleaseYear(props: any, coverUrl: string | null, html: string): string | null {
  if (props) {
    if (props.year) return props.year.toString()
    if (props.releaseYear) return props.releaseYear.toString()
    if (props.releaseDate) {
      const m = props.releaseDate.toString().match(/\b(19\d\d|20\d\d)\b/)
      if (m) return m[1]
    }
  }

  if (coverUrl) {
    try {
      const decodedUrl = decodeURIComponent(coverUrl)
      const coverMatch = decodedUrl.match(/\/cover\/([12]\d{3})\d{4}/) ||
                         decodedUrl.match(/\/cover\/([12]\d{3})\d{2}\d{2}/) ||
                         decodedUrl.match(/\/cover\/(19\d\d|20\d\d)/)
      if (coverMatch && coverMatch[1]) {
        return coverMatch[1]
      }
    } catch (_) {}
  }

  if (html) {
    const htmlMatch = html.match(/\b(19[89]\d|20[0-3]\d)\b/)
    if (htmlMatch) return htmlMatch[1]
  }

  return null
}

function extractMetadataFromHtml(html: string): {
  title: string | null;
  coverUrl: string | null;
  seasonsList: { name: string; number: number; websiteParam?: string }[];
  episodeCount: number;
  props: any;
} {
  let title: string | null = null
  let coverUrl: string | null = null
  let seasonsList: { name: string; number: number; websiteParam?: string }[] = []
  let episodeCount = 0
  let props: any = null

  const nextMatch = html.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/)
  if (nextMatch) {
    try {
      const data = JSON.parse(nextMatch[1])
      props = data?.props?.pageProps || {}

      if (props.name && typeof props.name === 'string') {
        title = props.name.trim()
      } else if (props.title && typeof props.title === 'string') {
        title = props.title.trim()
      }

      const cover = props.coverVerticalUrl || props.coverHorizontalUrl || props.coverUrl || props.cover || ''
      if (cover) {
        if (cover.startsWith('http')) {
          coverUrl = cover
        } else {
          const imgDomain = props.imgDomain || props.vestData?.imgDomain || ''
          if (imgDomain) {
            coverUrl = `${imgDomain.replace(/\/$/, '')}/${cover.replace(/^\//, '')}`
          }
        }
      }

      if (props.seasons && Array.isArray(props.seasons)) {
        seasonsList = props.seasons.map((s: any, idx: number) => ({
          name: s.name || s.title || `Temporada ${idx + 1}`,
          number: s.seriesNo ?? s.seasonNumber ?? s.number ?? (idx + 1),
          websiteParam: s.websiteParam
        }))
      }

      if (props.episodeVo && Array.isArray(props.episodeVo)) {
        episodeCount = props.episodeVo.length
      }
    } catch (e) {
      console.warn('[extractMetadata] Error parsing __NEXT_DATA__:', e)
    }
  }

  if (!title) {
    title = getMetaContent(html, 'og:title')
  }
  if (!coverUrl) {
    coverUrl = getMetaContent(html, 'og:image')
  }

  if (!title) {
    const nameMatch = html.match(/class="[^"]*\bname\b[^"]*"[^>]*>\s*([^<]+)\s*<\/div>/i)
    if (nameMatch) title = nameMatch[1].trim()
  }

  if (!coverUrl) {
    const coverMatch = html.match(/src=["'](https?:\/\/[^"'\s]*\/cover\/[^"'\s]+)["']/i)
    if (coverMatch) coverUrl = coverMatch[1].trim()
  }

  return { title, coverUrl: sanitizeImageUrl(coverUrl), seasonsList, episodeCount, props }
}

function isEpisodePage(html: string): boolean {
  if (!html || html.length < 500) return false
  const neg = [/404/, /not found/i, /p\u00e1gina no encontrada/i, /does not exist/i]
  const pos = [/video/i, /player/i, /iframe/i, /watch/i, /episode/i, /cap[i\u00ed]tulo/i, /reproduc/i, /stream/i, /embed/i]
  for (const n of neg) if (n.test(html)) return false
  for (const p of pos) if (p.test(html)) return true
  return false
}

function detectEpisodeCount(html: string): number {
  if (!html) return 0
  const nextM = html.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/)
  if (nextM) {
    try { const n = searchForEpisodeCount(JSON.parse(nextM[1]), 0); if (n > 0) return n } catch (_) {}
  }
  const patterns = [
    /"episode_count"\s*:\s*(\d+)/,
    /"total_episodes"\s*:\s*(\d+)/,
    /"number_of_episodes"\s*:\s*(\d+)/,
    /"totalEpisodes"\s*:\s*(\d+)/,
    /(\d{1,3})\s*cap[i\u00ed]tulos/i,
    /(\d{1,3})\s*episodios/i,
    /cap[i\u00ed]tulos\s*:?\s*(\d{1,3})/i,
  ]
  for (const p of patterns) { const m = html.match(p); if (m) { const n = parseInt(m[1]); if (n > 0 && n <= 500) return n } }
  const epNums = new Set<number>()
  for (const lnk of html.matchAll(/href=["'][^"']*\detail\/[^"']+\/(\d+)["'?#]/gi)) {
    const n = parseInt(lnk[1]); if (n > 0 && n <= 500) epNums.add(n)
  }
  if (epNums.size >= 3) return Math.max(...epNums)
  return 0
}

function searchForEpisodeCount(obj: any, depth: number): number {
  if (depth > 15 || !obj || typeof obj !== "object") return 0
  if (Array.isArray(obj)) {
    if (obj.length > 0 && obj[0] && typeof obj[0] === "object" &&
      ("episode_number" in obj[0] || "episodeNumber" in obj[0] || "number" in obj[0])) return obj.length
    let best = 0; for (const i of obj) { const r = searchForEpisodeCount(i, depth + 1); if (r > best) best = r }; return best
  }
  for (const k of ["episode_count", "totalEpisodes", "total_episodes", "number_of_episodes", "episodeCount"]) {
    if (k in obj && typeof obj[k] === "number" && obj[k] > 0 && obj[k] <= 500) return obj[k]
  }
  for (const k of ["episodes", "chapter_list", "chapters", "episodeList", "items", "list"]) {
    if (k in obj && Array.isArray(obj[k]) && obj[k].length > 0) { const r = searchForEpisodeCount(obj[k], depth + 1); if (r > 0) return r }
  }
  let best = 0; for (const k of Object.keys(obj)) { const r = searchForEpisodeCount(obj[k], depth + 1); if (r > best) best = r }; return best
}

function discoverSeasonUrlMap(html: string, origin: string): Map<number, string> {
  const map = new Map<number, string>()
  const patterns = [
    /href=["']([^"']*-Season-?(\d+)[^"']*)["']/g,
    /href=["']([^"']*\/(?:temporada|season)\/(\d+)[^"']*)["']/gi,
  ]
  for (const re of patterns) {
    for (const m of html.matchAll(re)) {
      let href = m[1]; const seasonNum = parseInt(m[2])
      if (!href.startsWith("http")) href = origin + href
      href = href.split("?")[0].split("#")[0]
      if (seasonNum > 0 && seasonNum <= 30 && !map.has(seasonNum)) {
        map.set(seasonNum, href)
      }
    }
  }
  return map
}

async function probeEpisodeCount(seasonUrl: string, max = 40): Promise<number> {
  let last = 0; let fails = 0; let invalids = 0
  for (let ep = 1; ep <= max; ep++) {
    const r = await fetchPage(`${seasonUrl}/${ep}`)
    await sleep(120)
    if (!r.ok) { fails++; if (fails >= 2) break; continue }
    if (ep === 1 && !isEpisodePage(r.html)) {
      console.log(`[probe] Ep1 no es episodio valido en ${seasonUrl}`); return 0
    }
    if (!isEpisodePage(r.html)) { invalids++; if (invalids >= 2) break; continue }
    fails = 0; invalids = 0; last = ep
  }
  return last
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders })
  try {
    const body = await req.json()
    const { url, parent_id, custom_title, category } = body
    if (!url) throw new Error("Se requiere una URL")

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? ""
    )

    const cleanUrl = stripTrailingNumber(url)
    console.log(`[import] URL limpia: ${cleanUrl}`)

    const mainResult = await fetchPage(cleanUrl)
    if (mainResult.blocked) {
      return new Response(JSON.stringify({
        error: "CLOUDFLARE_BLOCKED",
        message: "Cloudflare bloqueo el acceso. Intenta desde otra red o en unos minutos.",
      }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } })
    }

    const mainHtml = mainResult.ok ? mainResult.html : ""

    const meta = extractMetadataFromHtml(mainHtml)
    
    let seriesTitle = (custom_title && typeof custom_title === 'string' && custom_title.trim())
      ? custom_title.trim()
      : (meta.title ?? "Serie Importada")

    if (!custom_title) {
      seriesTitle = seriesTitle
        .split(/[|\u2013\u2014]/)[0].trim()
        .replace(/\s*-?\s*(?:Season|Temporada)\s*\d+\s*$/i, "")
        .trim()
    }
    
    const posterUrl = meta.coverUrl

    // Extract release year and append (YYYY) to title if not present
    const year = extractReleaseYear(meta.props, posterUrl, mainHtml)
    if (year && seriesTitle && !seriesTitle.match(/\(\d{4}\)$/)) {
      seriesTitle = `${seriesTitle} (${year})`
    }

    const finalCategory = (category && typeof category === 'string' && category.trim()) ? category.trim() : "Recomendados"

    console.log(`[import] Serie con año: "${seriesTitle}", Poster: ${posterUrl ? posterUrl.substring(0, 80) : 'null'}, Categoria: ${finalCategory}`)

    let seriesId: string
    if (parent_id) {
      seriesId = parent_id
    } else {
      const { data: existing } = await supabase
        .from("custom_content").select("id").eq("title", seriesTitle).eq("type", "series").maybeSingle()
      if (existing) {
        seriesId = existing.id
        await supabase.from("custom_content").update({
          category: finalCategory,
          ...(posterUrl ? { thumbnail_url: posterUrl } : {})
        }).eq("id", seriesId)
      } else {
        const { data: created, error: e } = await supabase
          .from("custom_content")
          .insert({ title: seriesTitle, thumbnail_url: posterUrl, type: "series", category: finalCategory, is_active: true })
          .select("id").single()
        if (e) throw new Error(`Error al crear serie: ${e.message}`)
        seriesId = created.id
      }
    }
    let finalPoster = posterUrl
    if (!finalPoster) {
      const { data: sr } = await supabase.from("custom_content").select("thumbnail_url").eq("id", seriesId).single()
      finalPoster = sr?.thumbnail_url ?? null
    }

    const origin = new URL(cleanUrl).origin
    const seasonMap = new Map<number, string>()

    // A. Check explicit seasons array in __NEXT_DATA__
    if (meta.seasonsList && meta.seasonsList.length > 0) {
      for (const s of meta.seasonsList) {
        if (s.websiteParam) {
          seasonMap.set(s.number, `${origin}/es/detail/drama/${s.websiteParam}`)
        } else if (s.number === 1) {
          seasonMap.set(1, cleanUrl)
        }
      }
      if (mainResult.ok) {
        const discovered = discoverSeasonUrlMap(mainHtml, origin)
        for (const [num, su] of discovered) {
          if (!seasonMap.has(num)) seasonMap.set(num, su)
        }
      }
    } else if (mainResult.ok) {
      const discovered = discoverSeasonUrlMap(mainHtml, origin)
      if (discovered.size > 0) {
        for (const [num, su] of discovered) seasonMap.set(num, su)
      }
    }

    // B. Probing fallback only if no seasons found yet
    if (seasonMap.size === 0) {
      seasonMap.set(1, cleanUrl)
      if (!cleanUrl.match(/-Season-\d+/i)) {
        for (let s = 2; s <= 20; s++) {
          await sleep(400)
          const probeUrl = `${cleanUrl}/${s}`
          const r = await fetchPage(probeUrl)
          if (!r.ok || r.blocked) break
          // Stop probing if response is identical to main page or empty
          if (r.html === mainHtml || Math.abs(r.html.length - mainHtml.length) < 50) break
          if (detectEpisodeCount(r.html) === 0 && !isEpisodePage(r.html)) break
          
          const more = discoverSeasonUrlMap(r.html, origin)
          if (more.size > 1) {
            for (const [n, su] of more) if (!seasonMap.has(n)) seasonMap.set(n, su)
            break
          }
          seasonMap.set(s, probeUrl)
        }
      }
    }

    const sortedSeasons = [...seasonMap.entries()].sort((a, b) => a[0] - b[0])
    console.log(`[import] Temporadas a procesar: ${sortedSeasons.map(([n, u]) => `T${n}=${u.split('/').pop()}`).join(', ')}`)

    const seasonResults: { season: number; url: string; inserted: number; total: number }[] = []
    let totalInserted = 0

    for (let si = 0; si < sortedSeasons.length; si++) {
      const [seasonNum, seasonUrl] = sortedSeasons[si]
      if (si > 0) await sleep(600)

      let seasonHtml = (seasonUrl === cleanUrl && mainResult.ok) ? mainHtml : ""
      if (!seasonHtml) {
        const r = await fetchPage(seasonUrl)
        if (!r.ok || r.blocked) { console.log(`T${seasonNum}: no accesible`); continue }
        seasonHtml = r.html
      }

      let seasonPoster = finalPoster
      if (si > 0) {
        const seasonMeta = extractMetadataFromHtml(seasonHtml)
        if (seasonMeta.coverUrl) seasonPoster = seasonMeta.coverUrl
      }

      let epCount = detectEpisodeCount(seasonHtml)
      console.log(`[import] T${seasonNum} HTML count: ${epCount}, URL: ${seasonUrl}`)

      if (epCount === 0) {
        console.log(`[import] T${seasonNum}: sondeando...`)
        epCount = await probeEpisodeCount(seasonUrl, 40)
        console.log(`[import] T${seasonNum} probe count: ${epCount}`)
      }
      if (epCount === 0) { console.log(`[import] T${seasonNum}: sin episodios`); continue }

      const { data: existing } = await supabase
        .from("custom_content").select("season,episode")
        .eq("parent_id", seriesId).eq("type", "episode").eq("season", seasonNum)
      const existingSet = new Set((existing ?? []).map((e: any) => `${e.season}-${e.episode}`))

      const toInsert = []
      for (let ep = 1; ep <= epCount; ep++) {
        if (!existingSet.has(`${seasonNum}-${ep}`)) {
          toInsert.push({
            title: `Capitulo ${ep}`,
            type: "episode",
            category: finalCategory,
            parent_id: seriesId,
            season: seasonNum,
            episode: ep,
            video_url: `${seasonUrl}/${ep}`,
            thumbnail_url: seasonPoster ?? null,
            is_active: true,
          })
        }
      }

      if (toInsert.length === 0) {
        seasonResults.push({ season: seasonNum, url: seasonUrl, inserted: 0, total: epCount }); continue
      }

      let inserted = 0
      for (let i = 0; i < toInsert.length; i += 50) {
        const batch = toInsert.slice(i, i + 50)
        const { error: e } = await supabase.from("custom_content").insert(batch)
        if (!e) inserted += batch.length
        else console.error(`T${seasonNum} error: ${e.message}`)
      }
      totalInserted += inserted
      seasonResults.push({ season: seasonNum, url: seasonUrl, inserted, total: epCount })
      console.log(`[import] T${seasonNum}: ${inserted}/${epCount} insertados`)
    }

    const msg = totalInserted === 0
      ? `La serie fue registrada pero no se detectaron capitulos. Verifica que el URL sea accesible.`
      : `OK ${seasonResults.length} temporada(s), ${totalInserted} capitulos importados.`

    return new Response(JSON.stringify({
      success: true,
      series_id: seriesId,
      series_title: seriesTitle,
      series: { id: seriesId, title: seriesTitle },
      seasons_processed: seasonResults.length,
      total_episodes: totalInserted,
      season_results: seasonResults,
      message: msg,
    }), { headers: { ...corsHeaders, "Content-Type": "application/json" } })

  } catch (err) {
    const msg = (err as Error).message ?? "Error desconocido"
    console.error("[import-full-series] FATAL:", msg)
    return new Response(JSON.stringify({ error: msg }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    })
  }
})
