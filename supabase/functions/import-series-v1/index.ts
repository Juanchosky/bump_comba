import { serve } from "https://deno.land/std@0.168.0/http/server.ts"
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { url } = await req.json()
    if (!url) throw new Error('Se requiere una URL válida')

    const supabaseClient = createClient(
      Deno.env.get('SUPABASE_URL') ?? '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? ''
    )

    console.log(`Iniciando importación desde: ${url}`)

    // 1. Fetch de la página principal
    const response = await fetch(url, {
      headers: {
        'User-Agent': 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36',
        'Accept-Language': 'es-ES,es;q=0.9,en;q=0.8',
      }
    })
    
    if (!response.ok) throw new Error(`No se pudo acceder a la página: ${response.status}`)
    
    const html = await response.text()
    
    // 2. Extracción de Metadatos de la Serie
    // Título
    const titleMatch = html.match(/<h1[^>]*>([\s\S]*?)<\/h1>/i) || html.match(/<title>([\s\S]*?)<\/title>/i)
    let title = titleMatch ? titleMatch[1].replace(/<[^>]*>/g, '').trim() : 'Serie Importada'
    // Limpiar títulos comunes
    title = title.split('|')[0].split('-')[0].trim()

    // Thumbnail (Poster)
    const thumbMatch = html.match(/<meta property="og:image" content="([^"]+)"/i) || 
                       html.match(/<img[^>]*src="([^"]+)"[^>]*class="[^"]*poster[^"]*"/i) ||
                       html.match(/<img[^>]*class="[^"]*poster[^"]*"[^>]*src="([^"]+)"/i)
    const thumbnail_url = thumbMatch ? thumbMatch[1] : null
    
    // 3. Crear o actualizar el registro de la Serie
    const { data: series, error: seriesError } = await supabaseClient
      .from('custom_content')
      .upsert({
        title,
        thumbnail_url,
        type: 'series',
        category: 'Recomendados',
        is_active: true
      }, { onConflict: 'title' })
      .select()
      .single()

    if (seriesError) throw new Error(`Error al crear serie: ${seriesError.message}`)

    // 4. Extracción de Episodios (Detector Multisitio)
    const episodes: any[] = []
    const processedUrls = new Set<string>()

    // Patrón 1: Cuevana (enlaces numéricos al final)
    const cuevanaEpRegex = /<a[^>]*href="([^"]*\/detail\/[^"]+\/(\d+))"[^>]*>/gi
    let match
    while ((match = cuevanaEpRegex.exec(html)) !== null) {
      const epUrl = match[1].startsWith('http') ? match[1] : new URL(match[1], url).href
      const epNum = parseInt(match[2])
      
      if (!processedUrls.has(epUrl)) {
        processedUrls.add(epUrl)
        episodes.push({
          parent_id: series.id,
          title: `Capítulo ${epNum}`,
          video_url: epUrl,
          thumbnail_url: series.thumbnail_url,
          type: 'episode',
          season: 1, // Por defecto temporada 1, se puede mejorar detectando el selector
          episode: epNum,
          is_active: true
        })
      }
    }

    // Patrón 2: Genérico (buscando patrones de /episode/, /ver-capitulo/, etc)
    if (episodes.length === 0) {
      const genericEpRegex = /<a[^>]*href="([^"]*(?:episodio|capitulo|episode|ver)\/[^"]+)"[^>]*>([\s\S]*?)<\/a>/gi
      while ((match = genericEpRegex.exec(html)) !== null) {
        const epUrl = match[1].startsWith('http') ? match[1] : new URL(match[1], url).href
        const epTitleRaw = match[2].replace(/<[^>]*>/g, '').trim()
        
        if (!processedUrls.has(epUrl)) {
          processedUrls.add(epUrl)
          // Intentar extraer el número de episodio del texto
          const numMatch = epTitleRaw.match(/(\d+)/)
          const epNum = numMatch ? parseInt(numMatch[1]) : (episodes.length + 1)
          
          episodes.push({
            parent_id: series.id,
            title: epTitleRaw || `Episodio ${epNum}`,
            video_url: epUrl,
            thumbnail_url: series.thumbnail_url,
            type: 'episode',
            season: 1,
            episode: epNum,
            is_active: true
          })
        }
      }
    }

    // 5. Inserción de Episodios
    if (episodes.length > 0) {
      // Ordenar por número antes de insertar
      episodes.sort((a, b) => a.episode - b.episode)
      
      const { error: epsError } = await supabaseClient
        .from('custom_content')
        .insert(episodes)
      
      if (epsError) {
        // Probable conflicto de duplicados, intentar uno a uno o simplemente loguear
        console.warn('Algunos episodios ya existen o hubo error:', epsError.message)
      }
    }

    return new Response(JSON.stringify({ 
      success: true, 
      message: `Se importó la serie "${title}" con ${episodes.length} capítulos.`,
      series, 
      episodesCount: episodes.length 
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    })

  } catch (error) {
    console.error('Error en import-series:', error.message)
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 400,
    })
  }
})
