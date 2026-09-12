// Configuración de Supabase
const SUPABASE_URL = 'https://inukqboqdvwtmmthjwrl.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImludWtxYm9xZHZ3dG1tdGhqd3JsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3MzkyMzM3NDIsImV4cCI6MjA1NDgwOTc0Mn0.bWNkWIErT71tXchtxN9D83w-I--UIGOIzZKff3-X5V8';

const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

// ─────────────────────────────────────────────────────────────────────────────
// CONFIGURACIÓN Y SERVICIO DE TMDB (The Movie Database)
// ─────────────────────────────────────────────────────────────────────────────
const TMDB_API_KEY = '4d1a1f42684a12a2fed02f05b35b4bb8';
const TMDB_BASE_URL = 'https://api.themoviedb.org/3';

/**
 * Limpia el título eliminando marcas de calidad, audios, corchetes y ruido para consultar TMDB.
 */
function cleanTitleForTmdb(rawTitle) {
    if (!rawTitle) return '';
    let t = rawTitle;
    // Extraer o limpiar corchetes enteros: [Audio Latino], [1080p], etc.
    t = t.replace(/\[[^\]]*\]/g, ' ');
    // Limpiar etiquetas de calidad y codecs entre paréntesis o corchetes
    t = t.replace(/\((?:HDTS|CAM|TS|HDRIP|BRRIP|WEBRIP|WEB-?DL|HD|SD|4K|FHD|UHD|LAT|CAST|SUB|VOSE|DUAL|REMUX|BLURAY|DVDRIP|SCREENER|LINE|AUDIO LATINO)[^)]*\)/gi, ' ');
    // Limpiar palabras de calidad o ruido común de streaming
    t = t.replace(/\b(?:1080p|720p|480p|2160p|4k|uhd|hd|sd|web-?dl|webrip|bluray|brrip|hdrip|dvdrip|x264|x265|h264|h265|hevc|aac|ac3|dual|latino|castellano|subtitulado|vose|remux|pelicula|completa|online|gratis)\b/gi, ' ');
    // Limpiar menciones de temporadas/capítulos: "Temporada 1", "Season 2", "T3"
    t = t.replace(/\b(?:temporada|season|temp|t)\s*\d+\b/gi, ' ');
    // Remover años entre paréntesis para la consulta de texto limpia: (2023) -> ' '
    t = t.replace(/\((?:19|20)\d{2}\)/g, ' ');
    // Remover paréntesis vacíos
    t = t.replace(/\(\s*\)/g, ' ');
    // Separadores
    t = t.replace(/[|·_]/g, ' ');
    // Quitar guiones repetidos o espacios
    t = t.replace(/\s+/g, ' ').trim();
    t = t.replace(/\s*-\s*$/, '').trim();
    return t || rawTitle;
}

/**
 * Normaliza una cadena para comparaciones (sin acentos, minúsculas, alfanumérico).
 */
function normalizeTextForMatch(str) {
    return (str || '')
        .normalize('NFD')
        .replace(/[\u0300-\u036f]/g, '')
        .toLowerCase()
        .replace(/[^a-z0-9]/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();
}

/**
 * Selecciona el mejor resultado de TMDB priorizando coincidencia de título y año.
 */
function pickBestTmdbMatch(results, query, yearHint, mediaType) {
    if (!results || results.length === 0) return null;
    const nQuery = normalizeTextForMatch(query);

    const valid = results.filter(r => {
        const d = mediaType === 'tv' ? r.first_air_date : r.release_date;
        return d && d.length >= 4;
    });
    const pool = valid.length > 0 ? valid : results;

    // 1. Si hay un año sugerido, buscar coincidencia exacta con ese año
    if (yearHint) {
        const withYear = pool.filter(r => {
            const d = mediaType === 'tv' ? r.first_air_date : r.release_date;
            return d && d.startsWith(yearHint);
        });
        const exactWithYear = withYear.find(r => {
            const t = normalizeTextForMatch(r.title || r.name);
            const ot = normalizeTextForMatch(r.original_title || r.original_name);
            return t === nQuery || ot === nQuery;
        });
        if (exactWithYear) return exactWithYear;
        if (withYear.length > 0) return withYear[0];
    }

    // 2. Coincidencia exacta de título
    const exact = pool.find(r => {
        const t = normalizeTextForMatch(r.title || r.name);
        const ot = normalizeTextForMatch(r.original_title || r.original_name);
        return t === nQuery || ot === nQuery;
    });
    if (exact) return exact;

    // 3. Primer resultado como fallback
    return pool[0];
}

/**
 * Consulta la API de TMDB para obtener el año oficial de estreno y metadatos complementarios.
 * @param {string} rawTitle - Título crudo
 * @param {'movie'|'tv'|'series'} mediaType - Tipo
 * @param {string|number|null} explicitYear - Año si se conoce
 * @returns {Promise<{ year: string|null, title: string|null, posterUrl: string|null, backdropUrl: string|null, overview: string|null }|null>}
 */
async function fetchTmdbInfo(rawTitle, mediaType = 'movie', explicitYear = null) {
    if (!rawTitle) return null;

    let yearHint = explicitYear ? explicitYear.toString() : null;
    if (!yearHint) {
        const ym = rawTitle.match(/[\(\[]?\b(19\d\d|20\d\d)\b[\)\]]?/);
        if (ym) yearHint = ym[1];
    }

    const cleanQuery = cleanTitleForTmdb(rawTitle);
    if (!cleanQuery) return null;

    const endpoint = (mediaType === 'series' || mediaType === 'tv') ? 'tv' : 'movie';
    const yearParam = yearHint
        ? (endpoint === 'tv' ? `&first_air_date_year=${yearHint}` : `&primary_release_year=${yearHint}`)
        : '';

    const fetchWithTimeout = async (url, ms = 4500) => {
        const controller = new AbortController();
        const id = setTimeout(() => controller.abort(), ms);
        try {
            const res = await fetch(url, { signal: controller.signal });
            clearTimeout(id);
            if (!res.ok) return null;
            return await res.json();
        } catch (_) {
            clearTimeout(id);
            return null;
        }
    };

    // 1. Intento en español con filtro de año si existe
    let data = await fetchWithTimeout(
        `${TMDB_BASE_URL}/search/${endpoint}?api_key=${TMDB_API_KEY}&query=${encodeURIComponent(cleanQuery)}${yearParam}&language=es-ES`
    );

    // 2. Si no hubo resultados y se usó filtro de año, intentar sin filtro de año
    if ((!data || !data.results || data.results.length === 0) && yearParam) {
        data = await fetchWithTimeout(
            `${TMDB_BASE_URL}/search/${endpoint}?api_key=${TMDB_API_KEY}&query=${encodeURIComponent(cleanQuery)}&language=es-ES`
        );
    }

    // 3. Si aún no hay resultados, intentar sin language (por si el nombre está en idioma original)
    if (!data || !data.results || data.results.length === 0) {
        data = await fetchWithTimeout(
            `${TMDB_BASE_URL}/search/${endpoint}?api_key=${TMDB_API_KEY}&query=${encodeURIComponent(cleanQuery)}`
        );
    }

    // 4. Si aún no hay resultados, intentar búsqueda multi
    if (!data || !data.results || data.results.length === 0) {
        data = await fetchWithTimeout(
            `${TMDB_BASE_URL}/search/multi?api_key=${TMDB_API_KEY}&query=${encodeURIComponent(cleanQuery)}&language=es-ES`
        );
    }

    const results = data?.results || [];
    const best = pickBestTmdbMatch(results, cleanQuery, yearHint, endpoint);

    if (best) {
        const rawDate = endpoint === 'tv'
            ? (best.first_air_date || best.release_date)
            : (best.release_date || best.first_air_date);
        let year = null;
        if (rawDate && typeof rawDate === 'string' && rawDate.length >= 4) {
            const yMatch = rawDate.match(/\b(19\d\d|20\d\d)\b/);
            if (yMatch) year = yMatch[1];
        }

        const resolvedTitle = best.title || best.name || best.original_title || best.original_name || null;
        const posterUrl = best.poster_path ? `https://image.tmdb.org/t/p/w500${best.poster_path}` : null;
        const backdropUrl = best.backdrop_path ? `https://image.tmdb.org/t/p/w1280${best.backdrop_path}` : null;

        return {
            year,
            title: resolvedTitle,
            posterUrl,
            backdropUrl,
            overview: best.overview || null,
            id: best.id
        };
    }

    return null;
}

/**
 * Función auxiliar para buscar en TMDB desde el modal manual de agregar/editar contenido.
 */
async function searchTmdbForManualForm() {
    const titleInput = document.getElementById('title');
    const typeInput = document.getElementById('type');
    const thumbInput = document.getElementById('thumbnail_url');
    const btn = document.getElementById('btn-search-tmdb');
    const rawTitle = titleInput ? titleInput.value.trim() : '';

    if (!rawTitle) {
        showToast('Ingresa un título para buscar en TMDB', 'error');
        return;
    }

    if (btn) {
        btn.disabled = true;
        btn.innerHTML = '<i data-lucide="loader-2" class="spinning" style="width:16px;height:16px;"></i> <span>Buscando...</span>';
        lucide.createIcons();
    }

    try {
        const mediaType = (typeInput && typeInput.value === 'series') ? 'tv' : 'movie';
        const info = await fetchTmdbInfo(rawTitle, mediaType);

        if (!info || !info.year) {
            showToast('No se encontró información o año en TMDB para este título', 'error');
        } else {
            let baseClean = cleanTitleForTmdb(rawTitle);
            const finalCleanTitle = baseClean || info.title || rawTitle;
            titleInput.value = `${finalCleanTitle} (${info.year})`;

            if (thumbInput && !thumbInput.value.trim() && info.posterUrl) {
                thumbInput.value = info.posterUrl;
            }
            showToast(`¡Encontrado en TMDB! Año: ${info.year}`, 'success');
        }
    } catch (e) {
        showToast('Error al consultar TMDB: ' + e.message, 'error');
    } finally {
        if (btn) {
            btn.disabled = false;
            btn.innerHTML = '<i data-lucide="sparkles" style="color: var(--primary); width: 16px; height: 16px;"></i> <span>Buscar TMDB</span>';
            lucide.createIcons();
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// PREVENCIÓN DE DUPLICADOS Y VERIFICACIÓN EN CATÁLOGO
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Extrae un título legible desde el slug de una URL (ej: /drama/la-reina-de-las-lagrimas -> "la reina de las lagrimas")
 */
function extractTitleFromUrl(url) {
    if (!url) return '';
    try {
        const u = new URL(url);
        const parts = u.pathname.split('/').filter(Boolean);
        const last = parts.pop() || '';
        const slug = /^\d+$/.test(last) ? (parts.pop() || last) : last;
        return slug.replace(/[-_]+/g, ' ').trim();
    } catch (_) {
        return '';
    }
}

/**
 * Comprueba si un contenido ya existe en el catálogo local (allContent).
 * Compara por URL de video limpia y por título normalizado / año.
 */
function findExistingInCatalog(title, url, type) {
    if (!allContent || allContent.length === 0) return null;

    const cleanUrl = url ? cleanVideoUrl(url) : null;
    let effectiveTitle = title;
    if (!effectiveTitle && url) {
        effectiveTitle = extractTitleFromUrl(url);
    }
    const nTargetTitle = effectiveTitle ? normalizeTextForMatch(effectiveTitle) : '';
    const targetCleanBase = effectiveTitle ? cleanTitleForTmdb(effectiveTitle) : '';
    const targetYearMatch = effectiveTitle ? effectiveTitle.match(/\((\d{4})\)$/) : null;
    const targetYear = targetYearMatch ? targetYearMatch[1] : null;

    for (const item of allContent) {
        if (type && item.type !== type) continue;

        // 1. Coincidencia por URL de video
        if (cleanUrl && item.video_url && cleanVideoUrl(item.video_url) === cleanUrl) {
            return item;
        }

        // 2. Coincidencia exacta de título normalizado completo
        if (nTargetTitle && normalizeTextForMatch(item.title) === nTargetTitle) {
            return item;
        }

        // 3. Coincidencia por título base limpio y año
        if (targetCleanBase) {
            const itemCleanBase = cleanTitleForTmdb(item.title);
            const itemYearMatch = item.title ? item.title.match(/\((\d{4})\)$/) : null;
            const itemYear = itemYearMatch ? itemYearMatch[1] : null;

            if (itemCleanBase && normalizeTextForMatch(itemCleanBase) === normalizeTextForMatch(targetCleanBase)) {
                // Si ambos tienen año y coincide, o si ninguno especificó año
                if ((targetYear && itemYear && targetYear === itemYear) || (!targetYear && !itemYear)) {
                    return item;
                }
                // Si uno no tiene año, se considera coincidencia del mismo contenido
                if (!targetYear || !itemYear) {
                    return item;
                }
            }
        }
    }
    return null;
}

/**
 * Busca contenidos en el catálogo que coincidan con una solicitud de usuario.
 * Retorna un arreglo de contenidos coincidentes ordenados por relevancia.
 */
function findMatchesInCatalog(requestTitle) {
    if (!requestTitle || !allContent || allContent.length === 0) return [];
    const reqNorm = normalizeTextForMatch(requestTitle);
    const reqClean = normalizeTextForMatch(cleanTitleForTmdb(requestTitle));
    const reqWords = reqClean.split(' ').filter(w => w.length >= 3);

    const scored = [];

    for (const item of allContent) {
        if (item.type !== 'movie' && item.type !== 'series') continue;

        const itemNorm = normalizeTextForMatch(item.title);
        const itemClean = normalizeTextForMatch(cleanTitleForTmdb(item.title));

        // 1. Coincidencia exacta de título limpio
        if (reqClean && itemClean && reqClean === itemClean) {
            scored.push({ item, score: 100 });
            continue;
        }

        // 2. Coincidencia directa de título completo
        if (reqNorm && itemNorm && (reqNorm === itemNorm || itemNorm.startsWith(reqNorm) || reqNorm.startsWith(itemNorm))) {
            scored.push({ item, score: 90 });
            continue;
        }

        // 3. Subcadena en el título limpio
        if (reqClean.length >= 4 && itemClean.includes(reqClean)) {
            scored.push({ item, score: 80 });
            continue;
        }
        if (itemClean.length >= 4 && reqClean.includes(itemClean)) {
            scored.push({ item, score: 80 });
            continue;
        }

        // 4. Coincidencia de palabras clave
        if (reqWords.length > 0) {
            const itemWords = itemClean.split(' ').filter(w => w.length >= 3);
            const overlap = reqWords.filter(w => itemWords.includes(w));
            if (overlap.length >= 2 && overlap.length >= reqWords.length * 0.7) {
                scored.push({ item, score: 70 });
            }
        }
    }

    return scored.sort((a, b) => b.score - a.score).map(s => s.item);
}

/**
 * Abre el modal interactivo para verificar si una solicitud ya está en el catálogo.
 */
function openVerifyRequestModal(requestId) {
    const req = contentRequests.find(r => r.id === requestId);
    if (!req) return;

    const modal = document.getElementById('verify-request-modal');
    const modalBody = document.getElementById('verify-request-modal-body');
    const modalFooter = document.getElementById('verify-request-modal-footer');
    if (!modal || !modalBody) return;

    const matches = findMatchesInCatalog(req.title);
    const dateStr = new Date(req.created_at).toLocaleDateString('es-ES', {
        day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit'
    });

    let matchesHtml = '';
    if (matches.length > 0) {
        matchesHtml = `
            <div>
                <div style="font-size:0.9rem;font-weight:600;color:var(--text-main);margin-bottom:0.75rem;display:flex;align-items:center;gap:0.4rem;">
                    <i data-lucide="sparkles" style="color:var(--accent-green);width:16px;height:16px;"></i>
                    <span>Coincidencia(s) encontrada(s) en tu catálogo (${matches.length})</span>
                </div>
                <div style="display:flex;flex-direction:column;gap:0.75rem;max-height:300px;overflow-y:auto;padding-right:0.3rem;">
                    ${matches.map(item => {
                        const isMovie = item.type === 'movie';
                        const epCount = !isMovie ? (episodeCountMap[item.id] || 0) : null;
                        const poster = item.thumbnail_url || 'logo.png';
                        return `
                            <div class="verify-match-card">
                                <img src="${poster}" alt="${item.title}" style="width:50px;height:75px;object-fit:cover;border-radius:0.5rem;background:#000;flex-shrink:0;" onerror="this.src='logo.png'">
                                <div style="flex:1;min-width:0;">
                                    <div style="font-weight:700;font-size:1rem;color:var(--text-main);margin-bottom:0.25rem;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;">
                                        ${item.title}
                                    </div>
                                    <div style="display:flex;gap:0.4rem;flex-wrap:wrap;font-size:0.78rem;color:var(--text-muted);align-items:center;">
                                        <span class="badge" style="padding:0.15rem 0.5rem;font-size:0.72rem;background:${isMovie ? 'rgba(56,189,248,0.15)' : 'rgba(244,114,182,0.15)'};color:${isMovie ? 'var(--primary)' : '#f472b6'};">
                                            ${isMovie ? 'Película' : 'Serie'}
                                        </span>
                                        <span>${item.category || 'General'}</span>
                                        ${epCount !== null ? `<span>• ${epCount} capítulos</span>` : ''}
                                        <span>• ${item.is_active ? '<span style="color:#34d399;">Visible</span>' : '<span style="color:#f87171;">Oculto</span>'}</span>
                                    </div>
                                </div>
                                <div style="flex-shrink:0;">
                                    ${req.status !== 'added' ? `
                                    <button class="btn btn-primary" style="padding:0.45rem 0.75rem;font-size:0.78rem;gap:0.35rem;white-space:nowrap;background:var(--accent-green);border-color:transparent;" onclick="confirmRequestAsAdded('${req.id}', '${item.title.replace(/'/g, "\\'")}')">
                                        <i data-lucide="check"></i> ¡Sí es este! Marcar agregado
                                    </button>
                                    ` : `
                                    <span class="badge badge-added" style="font-size:0.78rem;padding:0.35rem 0.65rem;">Ya agregado</span>
                                    `}
                                </div>
                            </div>
                        `;
                    }).join('')}
                </div>
            </div>
        `;
    } else {
        matchesHtml = `
            <div style="background:rgba(255,255,255,0.03);border:1px dashed var(--border-color);border-radius:0.75rem;padding:1.5rem;text-align:center;color:var(--text-muted);">
                <i data-lucide="help-circle" style="width:32px;height:32px;margin-bottom:0.5rem;opacity:0.6;color:var(--text-muted);"></i>
                <div style="font-weight:600;color:var(--text-main);font-size:0.95rem;margin-bottom:0.25rem;">No encontrado en el catálogo</div>
                <p style="font-size:0.85rem;line-height:1.5;margin:0;">No se encontró contenido con título similar a <strong>"${req.title}"</strong> en tu catálogo actual. Puedes importarlo directamente.</p>
            </div>
        `;
    }

    modalBody.innerHTML = `
        <!-- Tarjeta de Solicitud del Usuario -->
        <div style="background:rgba(56,189,248,0.05);border:1px solid rgba(56,189,248,0.2);border-radius:0.75rem;padding:1rem;">
            <div style="font-size:0.75rem;text-transform:uppercase;letter-spacing:0.05em;color:var(--primary);font-weight:700;margin-bottom:0.35rem;">
                Solicitud del Usuario
            </div>
            <div style="font-size:1.15rem;font-weight:700;color:var(--text-main);margin-bottom:0.35rem;">
                ${req.title}
            </div>
            <div style="font-size:0.85rem;color:var(--text-muted);margin-bottom:0.5rem;">
                <strong>Detalles / Notas:</strong> ${req.details ? req.details : '<span style="font-style:italic;">Ninguno</span>'}
            </div>
            <div style="display:flex;justify-content:space-between;align-items:center;font-size:0.78rem;color:var(--text-muted);border-top:1px solid rgba(255,255,255,0.05);padding-top:0.5rem;margin-top:0.5rem;">
                <span>Fecha: ${dateStr}</span>
                <span>Estado actual: <strong>${req.status === 'added' ? 'Agregado' : req.status === 'rejected' ? 'Rechazado' : 'Pendiente'}</strong></span>
            </div>
        </div>

        <!-- Coincidencias en Catálogo -->
        ${matchesHtml}
    `;

    modalFooter.innerHTML = `
        <button type="button" class="btn btn-secondary close-verify-modal">Cerrar</button>
        <button type="button" class="btn btn-primary" onclick="document.getElementById('verify-request-modal').style.display='none'; openAutoImportWithTitle('${req.title.replace(/'/g, "\\'")}', '${req.id}')">
            <i data-lucide="zap"></i> Importar este Contenido
        </button>
    `;

    modal.querySelectorAll('.close-verify-modal').forEach(b => {
        b.onclick = () => modal.style.display = 'none';
    });

    modal.style.display = 'block';
    lucide.createIcons();
}

async function confirmRequestAsAdded(requestId, itemTitle) {
    const modal = document.getElementById('verify-request-modal');
    if (modal) modal.style.display = 'none';
    await updateRequestStatus(requestId, 'added');
    showToast(`Solicitud marcada como agregada (vinculada a "${itemTitle}")`, 'success');
}

// ─────────────────────────────────────────────────────────────────────────────
// AUTH — Login / Logout usando tabla admin_users
// ─────────────────────────────────────────────────────────────────────────────

const SESSION_KEY = 'admin_session';

/** Hash SHA-256 de un string usando Web Crypto API (disponible en todos los browsers modernos) */
async function sha256(message) {
    const msgBuffer = new TextEncoder().encode(message);
    const hashBuffer = await crypto.subtle.digest('SHA-256', msgBuffer);
    const hashArray = Array.from(new Uint8Array(hashBuffer));
    return hashArray.map(b => b.toString(16).padStart(2, '0')).join('');
}

/** Guarda la sesión en sessionStorage (se borra al cerrar el tab) */
function saveSession(user) {
    sessionStorage.setItem(SESSION_KEY, JSON.stringify({ id: user.id, username: user.username, role: user.role }));
}

function getSession() {
    try { return JSON.parse(sessionStorage.getItem(SESSION_KEY)); } catch { return null; }
}

function clearSession() {
    sessionStorage.removeItem(SESSION_KEY);
}

/** Muestra el dashboard y oculta el login */
function showDashboard(user) {
    const loginScreen = document.getElementById('login-screen');
    const appContainer = document.querySelector('.app-container');

    // Actualizar sidebar con el nombre del usuario
    const avatarEl = document.getElementById('sidebar-avatar');
    const usernameEl = document.getElementById('sidebar-username');
    if (avatarEl) avatarEl.textContent = user.username.charAt(0).toUpperCase();
    if (usernameEl) usernameEl.textContent = user.username;

    loginScreen.classList.add('fade-out');
    appContainer.classList.remove('hidden');
}

/** Muestra el login y oculta el dashboard */
function showLogin() {
    const loginScreen = document.getElementById('login-screen');
    const appContainer = document.querySelector('.app-container');
    loginScreen.classList.remove('fade-out');
    appContainer.classList.add('hidden');
}

/** Intenta autenticar al usuario contra la tabla admin_users */
async function attemptLogin(username, password) {
    const hash = await sha256(password);

    const { data, error } = await supabaseClient
        .from('admin_users')
        .select('id, username, role')
        .eq('username', username)
        .eq('password_hash', hash)
        .single();

    if (error || !data) return null;

    // Actualizar last_login (no-blocking)
    supabaseClient
        .from('admin_users')
        .update({ last_login: new Date().toISOString() })
        .eq('id', data.id)
        .then(() => {});

    return data;
}

/** Configura los event listeners del formulario de login */
function setupLoginForm() {
    const form = document.getElementById('login-form');
    const loginBtn = document.getElementById('login-btn');
    const errorDiv = document.getElementById('login-error');
    const errorMsg = document.getElementById('login-error-msg');
    const toggleBtn = document.getElementById('toggle-password');
    const passwordInput = document.getElementById('login-password');
    const eyeIcon = document.getElementById('eye-icon');

    // Show/hide password toggle
    toggleBtn.addEventListener('click', () => {
        const isHidden = passwordInput.type === 'password';
        passwordInput.type = isHidden ? 'text' : 'password';
        eyeIcon.setAttribute('data-lucide', isHidden ? 'eye-off' : 'eye');
        lucide.createIcons();
    });

    form.addEventListener('submit', async (e) => {
        e.preventDefault();
        const username = document.getElementById('login-username').value.trim();
        const password = document.getElementById('login-password').value;

        if (!username || !password) return;

        // Loading state
        loginBtn.disabled = true;
        loginBtn.innerHTML = '<i data-lucide="loader-2" class="spinning"></i> Verificando...';
        lucide.createIcons();
        errorDiv.classList.add('hidden');

        try {
            const user = await attemptLogin(username, password);

            if (!user) {
                // Error de credenciales
                errorMsg.textContent = 'Usuario o contraseña incorrectos.';
                errorDiv.classList.remove('hidden');
                // Re-trigger animation
                errorDiv.style.animation = 'none';
                errorDiv.offsetHeight; // reflow
                errorDiv.style.animation = '';
                lucide.createIcons();
            } else {
                // ✅ Autenticado
                saveSession(user);
                showDashboard(user);
                // Inicializar el dashboard
                await fetchContent();
                setupEventListeners();
                lucide.createIcons();
            }
        } catch (err) {
            errorMsg.textContent = 'Error de conexión. Verifica tu red.';
            errorDiv.classList.remove('hidden');
            lucide.createIcons();
        } finally {
            loginBtn.disabled = false;
            loginBtn.innerHTML = '<i data-lucide="log-in"></i> Iniciar Sesión';
            lucide.createIcons();
        }
    });
}

/** Configura el botón de logout */
function setupLogout() {
    const logoutBtn = document.getElementById('logout-btn');
    if (logoutBtn) {
        logoutBtn.addEventListener('click', () => {
            clearSession();
            showLogin();
            // Limpiar estado del dashboard
            allContent = [];
            seriesList = [];
            episodeCountMap = {};
            currentTab = 'movies';
            activeSeriesFilter = null;
            if (document.getElementById('content-list-body')) {
                document.getElementById('content-list-body').innerHTML = '';
            }
        });
    }
}


// Estado Global
let allContent = [];
let seriesList = [];
let episodeCountMap = {}; // { [seriesId]: number } — conteo de episodios por serie
let currentTab = 'movies';
let activeSeriesFilter = null;
let viewMode = localStorage.getItem('viewMode') || 'list';


// Elementos DOM
const contentTableBody = document.getElementById('content-list-body');
const contentModal = document.getElementById('content-modal');
const contentForm = document.getElementById('content-form');
const addContentBtn = document.getElementById('add-content-btn');
const closeButtons = document.querySelectorAll('.close-modal');
const typeSelect = document.getElementById('type');
const seriesFields = document.getElementById('series-fields');
const parentIdSelect = document.getElementById('parent_id');
const searchInput = document.getElementById('global-search');
const filterCategory = document.getElementById('filter-category');
const filterSeason = document.getElementById('filter-season');
const seriesGrid = document.getElementById('series-grid');
const dataTableContainer = document.getElementById('data-table-container');
const tabButtons = document.querySelectorAll('.tab-btn');
const pageTitle = document.getElementById('page-title');
const backToSeriesBtn = document.getElementById('back-to-series');
const tableHeadRow = document.getElementById('table-head-row');
const viewListBtn = document.getElementById('view-list');
const viewGridBtn = document.getElementById('view-grid');
const manageSeasonsBtn = document.getElementById('manage-seasons-btn');
const bulkDeleteModal = document.getElementById('bulk-delete-modal');
const seasonsCheckboxList = document.getElementById('seasons-checkbox-list');
const confirmBulkDeleteBtn = document.getElementById('confirm-bulk-delete-btn');
const closeBulkDeleteBtns = document.querySelectorAll('.close-bulk-delete');
const autoImportBtn = document.getElementById('auto-import-btn');
const importModal = document.getElementById('import-modal');
const confirmImportBtn = document.getElementById('confirm-import-btn');
const importUrlInput = document.getElementById('import-url');
const toast = document.getElementById('toast');

const toastMessage = document.getElementById('toast-message');
const toastIcon = document.getElementById('toast-icon');
const closeImportModalBtns = document.querySelectorAll('.close-import-modal');



function sleep(ms) { return new Promise(resolve => setTimeout(resolve, ms)); }

// ─────────────────────────────────────────────────────────────────────────────
// BORRADO MASIVO DE TEMPORADAS
// ─────────────────────────────────────────────────────────────────────────────
function openBulkDeleteModal() {
    if (!activeSeriesFilter) return;
    
    const episodes = allContent.filter(item => item.type === 'episode' && item.parent_id === activeSeriesFilter);
    const seasons = [...new Set(episodes.map(it => it.season).filter(s => s !== null))].sort((a, b) => a - b);
    
    if (seasons.length === 0) {
        showToast('Esta serie no tiene temporadas para borrar', 'error');
        return;
    }

    seasonsCheckboxList.innerHTML = '';
    seasons.forEach(s => {
        const item = document.createElement('label');
        item.className = 'checkbox-container';
        item.style.display = 'flex';
        item.style.alignItems = 'center';
        item.style.gap = '0.5rem';
        item.style.cursor = 'pointer';
        item.innerHTML = `
            <input type="checkbox" value="${s}" class="season-checkbox">
            <span class="checkmark"></span>
            <span style="font-size:0.95rem;">Temporada ${s}</span>
        `;
        seasonsCheckboxList.appendChild(item);
    });

    bulkDeleteModal.style.display = 'block';
    lucide.createIcons();
}

async function confirmBulkDelete() {
    const checkedBoxes = document.querySelectorAll('.season-checkbox:checked');
    const selectedSeasons = Array.from(checkedBoxes).map(cb => parseInt(cb.value));

    if (selectedSeasons.length === 0) {
        showToast('Selecciona al menos una temporada', 'error');
        return;
    }

    const series = allContent.find(s => s.id === activeSeriesFilter);
    const seriesName = series ? series.title : 'esta serie';

    if (!confirm(`¿Borrar definitivamente las temporadas (${selectedSeasons.join(', ')}) de "${seriesName}"?\nSe eliminarán todos sus capítulos.`)) return;

    confirmBulkDeleteBtn.disabled = true;
    confirmBulkDeleteBtn.innerHTML = '<i data-lucide="loader-2" class="spinning"></i> Borrando...';
    lucide.createIcons();

    try {
        const { error } = await supabaseClient
            .from('custom_content')
            .delete()
            .eq('type', 'episode')
            .eq('parent_id', activeSeriesFilter)
            .in('season', selectedSeasons);

        if (error) throw error;

        showToast(`Se han borrado ${selectedSeasons.length} temporadas`, 'success');
        bulkDeleteModal.style.display = 'none';

        // Recargar episodios y actualizar UI
        const episodes = await fetchEpisodesForSeries(activeSeriesFilter);
        allContent = allContent.filter(it => !(it.type === 'episode' && it.parent_id === activeSeriesFilter));
        allContent = allContent.concat(episodes);

        // Actualizar conteo en el mapa
        episodeCountMap[activeSeriesFilter] = episodes.length;

        populateSeasonSelect(activeSeriesFilter);
        applyFilters();
    } catch (err) {
        showToast('Error: ' + err.message, 'error');
    } finally {
        confirmBulkDeleteBtn.disabled = false;
        confirmBulkDeleteBtn.innerHTML = 'Borrar Seleccionadas';
        lucide.createIcons();
    }
}



document.addEventListener('DOMContentLoaded', async () => {
    // Ocultar dashboard inicialmente
    document.querySelector('.app-container').classList.add('hidden');

    // Configurar logout y login form siempre
    setupLogout();
    setupLoginForm();
    lucide.createIcons();

    // Verificar si hay sesión activa (el usuario ya estaba logueado en este tab)
    const session = getSession();
    if (session) {
        // Sesión existente — ir directo al dashboard
        showDashboard(session);
        await fetchContent();
        setupEventListeners();
        lucide.createIcons();
    }
    // Si no hay sesión, el login-screen ya es visible por defecto
});

function populateCategoryFilter() {
    if (!filterCategory) return;
    const currentValue = filterCategory.value;

    const categoriesSet = new Set(['Recomendados']);
    allContent.forEach(item => {
        if (item.category && item.category.trim()) {
            categoriesSet.add(item.category.trim());
        }
    });

    const sortedCategories = Array.from(categoriesSet).sort((a, b) => a.localeCompare(b, 'es'));

    filterCategory.innerHTML = `<option value="all">Todas las Categorías</option>` +
        sortedCategories.map(cat => `<option value="${cat}">${cat}</option>`).join('');

    if (sortedCategories.includes(currentValue) || currentValue === 'all') {
        filterCategory.value = currentValue;
    } else {
        filterCategory.value = 'all';
    }

    let datalist = document.getElementById('category-list');
    if (!datalist) {
        datalist = document.createElement('datalist');
        datalist.id = 'category-list';
        document.body.appendChild(datalist);
        const categoryInput = document.getElementById('category');
        if (categoryInput) {
            categoryInput.setAttribute('list', 'category-list');
        }
    }
    datalist.innerHTML = sortedCategories.map(cat => `<option value="${cat}">`).join('');
}

// Carga películas y series en paralelo + conteos de episodios por serie
async function fetchContent() {
    const [movResult, serResult] = await Promise.all([
        supabaseClient.from('custom_content').select('*').eq('type', 'movie').order('created_at', { ascending: false }),
        supabaseClient.from('custom_content').select('*').eq('type', 'series').order('created_at', { ascending: false }),
    ]);

    const movies  = movResult.data || [];
    const series  = serResult.data || [];
    allContent = [...movies, ...series];
    seriesList = series;

    populateCategoryFilter();

    // Obtener conteos de episodios en paralelo (solo HEAD — cero datos transferidos)
    const countResults = await Promise.all(
        series.map(s =>
            supabaseClient
                .from('custom_content')
                .select('*', { count: 'exact', head: true })
                .eq('type', 'episode')
                .eq('parent_id', s.id)
                .then(({ count }) => ({ id: s.id, count: count || 0 }))
        )
    );
    episodeCountMap = {};
    countResults.forEach(({ id, count }) => { episodeCountMap[id] = count; });

    populateSeriesSelect();
    applyFilters();
    fetchContentRequests();
}

let contentRequests = [];

async function fetchContentRequests() {
    const { data, error } = await supabaseClient
        .from('content_requests')
        .select('*')
        .order('created_at', { ascending: false });
    
    if (error) {
        console.error('Error fetching content requests:', error);
        return;
    }

    contentRequests = data || [];
    updateRequestsBadge();
    if (currentTab === 'requests') {
        renderRequests();
    }
}

function updateRequestsBadge() {
    const badge = document.getElementById('requests-badge');
    if (!badge) return;
    const pendingCount = contentRequests.filter(r => r.status === 'pending').length;
    if (pendingCount > 0) {
        badge.textContent = pendingCount;
        badge.classList.remove('hidden');
    } else {
        badge.classList.add('hidden');
    }
}

let selectedRequestIds = new Set();

function renderRequests() {
    const requestsContainer = document.getElementById('requests-container');
    const requestsBody = document.getElementById('requests-list-body');
    const seriesGrid = document.getElementById('series-grid');
    const dataTableContainer = document.getElementById('data-table-container');

    if (seriesGrid) seriesGrid.classList.add('hidden');
    if (dataTableContainer) dataTableContainer.classList.add('hidden');
    if (requestsContainer) requestsContainer.classList.remove('hidden');

    if (!requestsBody) return;
    requestsBody.innerHTML = '';

    if (contentRequests.length === 0) {
        requestsBody.innerHTML = `
            <tr>
                <td colspan="6" style="text-align:center;padding:2.5rem;color:var(--text-muted);">
                    <div style="font-size:1.1rem;font-weight:600;margin-bottom:0.4rem;">Sin Solicitudes</div>
                    No hay solicitudes registradas por los usuarios aún.
                </td>
            </tr>
        `;
        updateSelectedRequestsCount();
        return;
    }

    contentRequests.forEach(req => {
        const tr = document.createElement('tr');
        const isChecked = selectedRequestIds.has(req.id);
        const dateStr = new Date(req.created_at).toLocaleDateString('es-ES', {
            day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit'
        });

        let statusClass = 'badge-pending';
        let statusText = 'Pendiente';
        if (req.status === 'added') { statusClass = 'badge-added'; statusText = 'Agregado'; }
        else if (req.status === 'rejected') { statusClass = 'badge-rejected'; statusText = 'Rechazado'; }

        // Coincidencias en catálogo
        const matches = findMatchesInCatalog(req.title);
        const hasMatch = matches.length > 0;
        let matchBadgeHtml = '';

        if (hasMatch) {
            const topMatch = matches[0];
            const matchCountLabel = matches.length === 1 ? '1 coincidencia' : `${matches.length} coincidencias`;
            matchBadgeHtml = `
                <div style="margin-top:0.35rem;">
                    <button type="button" class="btn-catalog-match" onclick="openVerifyRequestModal('${req.id}')" title="Click para verificar si este contenido ya está en el catálogo">
                        <i data-lucide="check-circle-2" style="width:13px;height:13px;flex-shrink:0;"></i>
                        <span>En catálogo (${matchCountLabel}: <strong>${topMatch.title}</strong>)</span>
                    </button>
                </div>
            `;
        } else {
            matchBadgeHtml = `
                <div style="margin-top:0.25rem;">
                    <span style="display:inline-flex;align-items:center;gap:0.3rem;font-size:0.75rem;color:var(--text-muted);opacity:0.85;">
                        <i data-lucide="help-circle" style="width:12px;height:12px;"></i> No detectado en catálogo
                    </span>
                </div>
            `;
        }

        tr.innerHTML = `
            <td style="text-align:center;">
                <input type="checkbox" class="request-checkbox" value="${req.id}" ${isChecked ? 'checked' : ''} onchange="onRequestCheckboxChange('${req.id}', this.checked)" style="width:16px;height:16px;cursor:pointer;">
            </td>
            <td>
                <div style="font-weight:600;font-size:1rem;color:var(--text-primary);">${req.title}</div>
                ${matchBadgeHtml}
            </td>
            <td>${req.details ? req.details : '<span style="color:var(--text-muted);font-style:italic;">Sin detalles</span>'}</td>
            <td style="font-size:0.85rem;color:var(--text-muted);">${dateStr}</td>
            <td><span class="badge ${statusClass}">${statusText}</span></td>
            <td>
                <div class="actions" style="gap:0.5rem;">
                    <button class="btn btn-secondary" style="padding:0.4rem 0.8rem;font-size:0.8rem;gap:0.3rem;background:rgba(99,102,241,0.12);color:#818cf8;border-color:rgba(99,102,241,0.25);" onclick="openVerifyRequestModal('${req.id}')" title="Verificar si coincide con contenidos existentes">
                        <i data-lucide="search-check"></i> Verificar
                    </button>
                    <button class="btn btn-secondary" style="padding:0.4rem 0.8rem;font-size:0.8rem;gap:0.3rem;" onclick="openAutoImportWithTitle('${req.title.replace(/'/g, "\\'")}', '${req.id}')">
                        <i data-lucide="zap"></i> Importar
                    </button>
                    ${req.status === 'pending' ? `
                    <button class="btn-icon" style="background:rgba(34,197,94,0.15);color:#4ade80;" title="Marcar como Agregado" onclick="updateRequestStatus('${req.id}', 'added')">
                        <i data-lucide="check"></i>
                    </button>
                    ` : ''}
                    <button class="btn-icon btn-delete" title="Eliminar solicitud" onclick="deleteRequest('${req.id}')">
                        <i data-lucide="trash-2"></i>
                    </button>
                </div>
            </td>
        `;
        requestsBody.appendChild(tr);
    });
    lucide.createIcons();
    updateSelectedRequestsCount();
}

/** Pobla el datalist del campo de categoría en el modal de importación con las categorías existentes */
function populateImportCategoryList() {
    const datalist = document.getElementById('import-category-list');
    if (!datalist) return;
    const categoriesSet = new Set(['Recomendados']);
    allContent.forEach(item => {
        if (item.category && item.category.trim()) {
            categoriesSet.add(item.category.trim());
        }
    });
    const sorted = Array.from(categoriesSet).sort((a, b) => a.localeCompare(b, 'es'));
    datalist.innerHTML = sorted.map(cat => `<option value="${cat}">`).join('');
}

function openAutoImportWithTitle(title, requestId) {
    importUrlInput.value = '';
    const catInput = document.getElementById('import-category');
    if (catInput) catInput.value = 'Recomendados';
    populateImportCategoryList();
    const bar = document.getElementById('full-import-bar');
    const status = document.getElementById('full-import-status');
    const progress = document.getElementById('full-import-progress');
    if (bar) { bar.style.width = '0%'; bar.style.background = 'var(--primary)'; }
    if (status) status.textContent = '';
    if (progress) progress.style.display = 'none';
    importModal.style.display = 'block';
    showToast(`Pega la URL para importar: "${title}"`, 'info');
}

async function updateRequestStatus(id, newStatus) {
    const { error } = await supabaseClient
        .from('content_requests')
        .update({ status: newStatus })
        .eq('id', id);

    if (error) {
        showToast('Error al actualizar estado: ' + error.message, 'error');
        return;
    }
    showToast('Estado de la solicitud actualizado', 'success');
    await fetchContentRequests();
}

async function deleteRequest(id) {
    if (!confirm('¿Deseas eliminar esta solicitud de contenido?')) return;
    const { error } = await supabaseClient
        .from('content_requests')
        .delete()
        .eq('id', id);

    if (error) {
        showToast('Error al eliminar: ' + error.message, 'error');
        return;
    }
    showToast('Solicitud eliminada', 'success');
    await fetchContentRequests();
}


// Carga episodios de una serie específica (solo cuando el usuario entra a la serie)
async function fetchEpisodesForSeries(seriesId) {
    const { data, error } = await supabaseClient
        .from('custom_content')
        .select('*')
        .eq('type', 'episode')
        .eq('parent_id', seriesId)
        .order('season', { ascending: true })
        .order('episode', { ascending: true });
    if (error) { console.error('Error episodes:', error); return []; }
    return data || [];
}


let currentVisibleItems = [];
let selectedItemIds = new Set();

function renderTableHead(viewType) {
    const estadoHeaderHtml = `
        <div style="display:flex;align-items:center;gap:0.6rem;">
            <span>Estado</span>
            <label class="switch" title="Activar / Desactivar todo lo visible">
                <input type="checkbox" id="master-status-switch" onchange="toggleAllStatus(this.checked)">
                <span class="slider"></span>
            </label>
        </div>
    `;

    const checkAllHeaderHtml = `<th style="width:40px;text-align:center;"><input type="checkbox" id="select-all-checkbox" onchange="toggleSelectAllRows(this.checked)" style="width:16px;height:16px;cursor:pointer;" title="Seleccionar todo"></th>`;

    if (viewType === 'episodes') {
        tableHeadRow.innerHTML = `${checkAllHeaderHtml}<th>Capítulo</th><th>Temporada</th><th>Episodio</th><th>${estadoHeaderHtml}</th><th>Acciones</th>`;
    } else {
        tableHeadRow.innerHTML = `${checkAllHeaderHtml}<th>Título</th><th>Categoría</th><th>${estadoHeaderHtml}</th><th>Acciones</th>`;
    }
}

function renderContent(items) {
    currentVisibleItems = items;
    viewListBtn.classList.toggle('active', viewMode === 'list');
    viewGridBtn.classList.toggle('active', viewMode === 'grid');
    if (viewMode === 'grid') { renderGridView(items); return; }
    seriesGrid.classList.add('hidden');
    dataTableContainer.classList.remove('hidden');
    contentTableBody.innerHTML = '';
    const isEpisodeView = currentTab === 'series' && activeSeriesFilter;
    renderTableHead(isEpisodeView ? 'episodes' : 'movies');

    // Actualizar estado del master switch de la cabecera
    const masterSwitch = document.getElementById('master-status-switch');
    if (masterSwitch) {
        const allActive = items.length > 0 && items.every(i => i.is_active);
        masterSwitch.checked = allActive;
    }

    items.forEach(item => {
        const tr = document.createElement('tr');
        const isChecked = selectedItemIds.has(item.id);
        tr.innerHTML = `
            <td style="text-align:center;">
                <input type="checkbox" class="row-checkbox" value="${item.id}" ${isChecked ? 'checked' : ''} onchange="onRowCheckboxChange('${item.id}', this.checked)" style="width:16px;height:16px;cursor:pointer;">
            </td>
            <td>
                <div style="display:flex;align-items:center;gap:1rem;">
                    <img src="${item.thumbnail_url || 'https://via.placeholder.com/40x60'}" style="width:40px;height:60px;object-fit:cover;border-radius:4px;background:#000;">
                    <div>
                        <div style="font-weight:600;">${item.title}</div>
                        <div style="font-size:.75rem;color:var(--text-muted);">${item.id.slice(0, 8)}...</div>
                    </div>
                </div>
            </td>
            ${isEpisodeView ? `<td data-label="Temporada">S${item.season || '-'}</td><td data-label="Episodio">E${item.episode || '-'}</td>` : `<td data-label="Categoría">${item.category}</td>`}
            <td data-label="Estado">
                <label class="switch">
                    <input type="checkbox" ${item.is_active ? 'checked' : ''} onchange="toggleStatus('${item.id}', this.checked)">
                    <span class="slider"></span>
                </label>
            </td>
            <td data-label="Acciones">
                <div class="actions">
                    <button class="btn-icon btn-edit" onclick="editItem('${item.id}')"><i data-lucide="edit-3"></i></button>
                    <button class="btn-icon btn-delete" onclick="deleteItem('${item.id}')"><i data-lucide="trash-2"></i></button>
                </div>
            </td>
        `;
        contentTableBody.appendChild(tr);
    });
    lucide.createIcons();
    updateSelectedCount();
}

function renderGridView(items) {
    seriesGrid.classList.remove('hidden');
    dataTableContainer.classList.add('hidden');
    seriesGrid.innerHTML = '';
    items.forEach(item => {
        const card = document.createElement('div');
        card.className = 'series-card';
        if (item.type === 'series') { card.onclick = () => enterSeries(item.id); } else { card.onclick = () => editItem(item.id); }
        // Usar el conteo pre-cargado (no requiere iterar allContent)
        const episodeCount = item.type === 'series' ? (episodeCountMap[item.id] ?? 0) : 0;

        card.innerHTML = `
            <div class="series-actions">
                <button class="btn-icon btn-edit" onclick="event.stopPropagation();editItem('${item.id}')"><i data-lucide="edit-3"></i></button>
                <button class="btn-icon btn-delete" onclick="event.stopPropagation();deleteItem('${item.id}')"><i data-lucide="trash-2"></i></button>
            </div>
            <img class="series-poster" src="${item.thumbnail_url || 'https://via.placeholder.com/220x330'}" alt="${item.title}">
            <div class="series-info">
                <div class="series-title">${item.title}</div>
                <div class="series-meta">
                    <span>${item.type === 'episode' ? `S${item.season} E${item.episode}` : item.category}</span>
                    ${item.type === 'series' ? `<span class="episode-count">${episodeCount} capítulos</span>` : ''}
                </div>
            </div>
        `;
        seriesGrid.appendChild(card);
    });
    lucide.createIcons();
}

function populateSeriesSelect() {
    parentIdSelect.innerHTML = '<option value="">Selecciona una serie...</option>';
    seriesList.sort((a, b) => a.title.localeCompare(b.title)).forEach(series => {
        const option = document.createElement('option');
        option.value = series.id;
        option.textContent = series.title;
        parentIdSelect.appendChild(option);
    });
}

async function enterSeries(id) {
    activeSeriesFilter = id;
    const series = allContent.find(s => s.id === id);
    pageTitle.textContent = `Capítulos de: ${series.title}`;
    backToSeriesBtn.classList.remove('hidden');
    filterCategory.classList.add('hidden');
    filterSeason.classList.remove('hidden');
    // manageSeasonsBtn siempre visible dentro de una serie
    manageSeasonsBtn.classList.remove('hidden');
    filterSeason.value = 'all';
    lucide.createIcons();



    // Cargar episodios desde la BD solo ahora que el usuario entró a la serie
    const episodes = await fetchEpisodesForSeries(id);
    // Añadir/reemplazar episodios en allContent sin borrar movies/series
    allContent = allContent.filter(it => !(it.type === 'episode' && it.parent_id === id));
    allContent = allContent.concat(episodes);

    populateSeasonSelect(id);
    applyFilters();
}


function exitSeries() {
    activeSeriesFilter = null;
    pageTitle.textContent = 'Mis Series';
    backToSeriesBtn.classList.add('hidden');
    filterCategory.classList.remove('hidden');
    filterSeason.classList.add('hidden');
    manageSeasonsBtn.classList.add('hidden');
    if (!localStorage.getItem('viewMode')) viewMode = 'grid';

    applyFilters();
}


function populateSeasonSelect(seriesId) {
    const episodes = allContent.filter(item => item.type === 'episode' && item.parent_id === seriesId);
    const seasons = [...new Set(episodes.map(it => it.season).filter(s => s !== null))].sort((a, b) => a - b);
    filterSeason.innerHTML = '<option value="all">Todas las Temporadas</option>';
    seasons.forEach(season => {
        const option = document.createElement('option');
        option.value = season;
        option.textContent = `Temporada ${season}`;
        filterSeason.appendChild(option);
    });
}

/**
 * Limpia una URL de video de fragmentos de tiempo (#t=...) y parámetros comunes (?t=, &time=, etc.)
 */
function cleanVideoUrl(url) {
    if (!url || typeof url !== 'string') return url;
    try {
        // 1. Eliminar fragmentos (#t=...)
        let cleaned = url.split('#')[0];
        
        // 2. Usar URL API para limpiar parámetros de búsqueda específicos
        const urlObj = new URL(cleaned);
        const paramsToRemove = ['t', 'time', 'start', 'at', 'position'];
        paramsToRemove.forEach(p => urlObj.searchParams.delete(p));
        
        return urlObj.toString();
    } catch (e) {
        // Fallback robusto con regex si la URL es parcial o inválida para el constructor URL
        return url.replace(/[#&?](t|time|start|at|position)=\d+[smh]?/g, '');
    }
}

async function saveContent(e) {
    e.preventDefault();
    const id = document.getElementById('item-id').value;
    const rawVideoUrl = document.getElementById('video_url').value;
    const formData = {
        title: document.getElementById('title').value,
        type: document.getElementById('type').value,
        category: document.getElementById('category').value,
        video_url: cleanVideoUrl(rawVideoUrl) || null,
        thumbnail_url: document.getElementById('thumbnail_url').value || null,
        is_active: document.getElementById('is_active').checked,
        parent_id: document.getElementById('parent_id').value || null,
        season: parseInt(document.getElementById('season').value) || null,
        episode: parseInt(document.getElementById('episode').value) || null,
    };

    let result;
    if (id) {
        // Si cambia el TITULO, los alias que TMDB resolvio para el nombre viejo
        // dejan de valer. Se ponen a NULL y `alias-tmdb.sh` los recalcula esa
        // misma madrugada (busca justo las filas con la columna en NULL).
        //
        // Importa sobre todo al reaprovechar una fila para otra pelicula: con
        // los alias antiguos dentro, la app engancharia el titulo equivocado en
        // Xtream. Un alias erroneo es peor que no tener alias, que es el
        // principio con el que esta escrito todo este sistema.
        //
        // No se tocan si el titulo no cambio: recalcular por gusto gastaria
        // peticiones a TMDB y borraria cualquier alias puesto a mano.
        const original = allContent.find(i => i.id === id);
        if (original && original.title !== formData.title) {
            formData.title_aliases = null;
        }
        result = await supabaseClient.from('custom_content').update(formData).eq('id', id);
    }
    else { result = await supabaseClient.from('custom_content').insert([formData]); }
    if (result.error) { alert('Error al guardar: ' + result.error.message); return; }

    // ── Propagación de poster a episodios sin thumbnail ──────────────────────
    // Si es una serie con thumbnail, actualiza episodios que no tienen poster propio
    const seriesId = id; // la serie editada
    if (formData.type === 'series' && formData.thumbnail_url && seriesId) {
        const { data: updated, error: propErr } = await supabaseClient
            .from('custom_content')
            .update({ thumbnail_url: formData.thumbnail_url })
            .eq('type', 'episode')
            .eq('parent_id', seriesId)
            .or('thumbnail_url.is.null,thumbnail_url.eq.');
        if (!propErr) {
            showToast(`Poster actualizado en episodios sin imagen`, 'success');
        }
    }

    closeModal();
    // Si estamos en vista de episodios, recargar solo los episodios de esa serie
    if (activeSeriesFilter) {
        const episodes = await fetchEpisodesForSeries(activeSeriesFilter);
        allContent = allContent.filter(it => !(it.type === 'episode' && it.parent_id === activeSeriesFilter));
        allContent = allContent.concat(episodes);
        populateSeasonSelect(activeSeriesFilter);
        applyFilters();
    } else {
        await fetchContent();
    }

}


async function toggleStatus(id, isActive) {
    const { error } = await supabaseClient.from('custom_content').update({ is_active: isActive }).eq('id', id);
    if (error) { alert('Error al cambiar estado: ' + error.message); fetchContent(); }
    else {
        const item = allContent.find(it => it.id === id);
        if (item) item.is_active = isActive;
        // Actualizar master switch si corresponde
        const masterSwitch = document.getElementById('master-status-switch');
        if (masterSwitch && currentVisibleItems.length > 0) {
            masterSwitch.checked = currentVisibleItems.every(i => i.is_active);
        }
    }
}

async function toggleAllStatus(isActive) {
    if (!currentVisibleItems || currentVisibleItems.length === 0) return;
    const ids = currentVisibleItems.map(i => i.id);

    const { error } = await supabaseClient
        .from('custom_content')
        .update({ is_active: isActive })
        .in('id', ids);

    if (error) {
        showToast('Error al cambiar estado masivo: ' + error.message, 'error');
        applyFilters();
        return;
    }

    // Actualización local en memoria
    allContent.forEach(item => {
        if (ids.includes(item.id)) {
            item.is_active = isActive;
        }
    });

    showToast(`Se ${isActive ? 'activaron' : 'desactivaron'} ${ids.length} elementos`, 'success');
    applyFilters();
}

function toggleSelectAllRows(isChecked) {
    if (!currentVisibleItems) return;
    currentVisibleItems.forEach(item => {
        if (isChecked) {
            selectedItemIds.add(item.id);
        } else {
            selectedItemIds.delete(item.id);
        }
    });

    const checkboxes = document.querySelectorAll('.row-checkbox');
    checkboxes.forEach(cb => cb.checked = isChecked);
    updateSelectedCount();
}

function onRowCheckboxChange(id, isChecked) {
    if (isChecked) {
        selectedItemIds.add(id);
    } else {
        selectedItemIds.delete(id);
    }
    updateSelectedCount();
}

function updateSelectedCount() {
    const deleteBtn = document.getElementById('delete-selected-btn');
    const deleteText = document.getElementById('delete-selected-text');
    const selectAllCb = document.getElementById('select-all-checkbox');

    const count = selectedItemIds.size;
    if (deleteBtn && deleteText) {
        if (count > 0) {
            deleteText.textContent = `Borrar (${count})`;
            deleteBtn.classList.remove('hidden');
        } else {
            deleteBtn.classList.add('hidden');
        }
    }

    if (selectAllCb && currentVisibleItems.length > 0) {
        const allVisibleSelected = currentVisibleItems.every(item => selectedItemIds.has(item.id));
        selectAllCb.checked = allVisibleSelected;
    }
}

function toggleSelectAllRequests(isChecked) {
    contentRequests.forEach(req => {
        if (isChecked) {
            selectedRequestIds.add(req.id);
        } else {
            selectedRequestIds.delete(req.id);
        }
    });

    const checkboxes = document.querySelectorAll('.request-checkbox');
    checkboxes.forEach(cb => cb.checked = isChecked);
    updateSelectedRequestsCount();
}

function onRequestCheckboxChange(id, isChecked) {
    if (isChecked) {
        selectedRequestIds.add(id);
    } else {
        selectedRequestIds.delete(id);
    }
    updateSelectedRequestsCount();
}

function updateSelectedRequestsCount() {
    const deleteBtn = document.getElementById('delete-selected-btn');
    const deleteText = document.getElementById('delete-selected-text');
    const selectAllCb = document.getElementById('select-all-requests-checkbox');

    const count = selectedRequestIds.size;
    if (deleteBtn && deleteText) {
        if (count > 0) {
            deleteText.textContent = `Borrar (${count})`;
            deleteBtn.classList.remove('hidden');
        } else {
            deleteBtn.classList.add('hidden');
        }
    }

    if (selectAllCb && contentRequests.length > 0) {
        const allSelected = contentRequests.every(req => selectedRequestIds.has(req.id));
        selectAllCb.checked = allSelected;
    }
}

async function deleteSelectedItems() {
    if (currentTab === 'requests') {
        if (selectedRequestIds.size === 0) return;
        const count = selectedRequestIds.size;
        if (!confirm(`¿Estás seguro de que deseas eliminar ${count} solicitudes seleccionadas?`)) return;

        const idsToDelete = Array.from(selectedRequestIds);
        const { error } = await supabaseClient
            .from('content_requests')
            .delete()
            .in('id', idsToDelete);

        if (error) {
            showToast('Error al eliminar solicitudes: ' + error.message, 'error');
            return;
        }

        selectedRequestIds.clear();
        showToast(`Se eliminaron ${count} solicitudes con éxito`, 'success');
        fetchContentRequests();
        return;
    }

    if (selectedItemIds.size === 0) return;
    const count = selectedItemIds.size;
    if (!confirm(`¿Estás seguro de que deseas eliminar ${count} elementos seleccionados?`)) return;

    const idsToDelete = Array.from(selectedItemIds);
    const { error } = await supabaseClient
        .from('custom_content')
        .delete()
        .in('id', idsToDelete);

    if (error) {
        showToast('Error al eliminar elementos: ' + error.message, 'error');
        return;
    }

    allContent = allContent.filter(item => !selectedItemIds.has(item.id));
    selectedItemIds.clear();
    showToast(`Se eliminaron ${count} elementos con éxito`, 'success');
    applyFilters();
}

async function deleteItem(id) {
    if (confirm('¿Estás seguro de que deseas eliminar este contenido?')) {
        const { error } = await supabaseClient.from('custom_content').delete().eq('id', id);
        if (error) { alert('Error al eliminar: ' + error.message); return; }
        if (activeSeriesFilter) {
            const episodes = await fetchEpisodesForSeries(activeSeriesFilter);
            allContent = allContent.filter(it => !(it.type === 'episode' && it.parent_id === activeSeriesFilter));
            allContent = allContent.concat(episodes);
            populateSeasonSelect(activeSeriesFilter);
            applyFilters();
        } else {
            await fetchContent();
        }
    }
}


function editItem(id) {
    const item = allContent.find(i => i.id === id);
    if (!item) return;
    document.getElementById('item-id').value = item.id;
    document.getElementById('title').value = item.title;
    document.getElementById('type').value = item.type;
    document.getElementById('category').value = item.category;
    document.getElementById('video_url').value = item.video_url || '';
    document.getElementById('thumbnail_url').value = item.thumbnail_url || '';
    document.getElementById('is_active').checked = item.is_active;
    document.getElementById('parent_id').value = item.parent_id || '';
    document.getElementById('season').value = item.season || '';
    document.getElementById('episode').value = item.episode || '';
    handleTypeChange();
    document.getElementById('modal-title').textContent = 'Editar Contenido';
    contentModal.style.display = 'block';
}

function setupEventListeners() {
    addContentBtn.onclick = () => {
        contentForm.reset();
        document.getElementById('item-id').value = '';
        document.getElementById('modal-title').textContent = 'Agregar Contenido';
        if (currentTab === 'series' && activeSeriesFilter) { typeSelect.value = 'episode'; parentIdSelect.value = activeSeriesFilter; }
        else if (currentTab === 'movies') { typeSelect.value = 'movie'; }
        else { typeSelect.value = 'series'; }
        handleTypeChange();
        contentModal.style.display = 'block';
    };

    closeButtons.forEach(btn => { btn.onclick = closeModal; });
    backToSeriesBtn.onclick = exitSeries;

    window.onclick = (event) => {
        if (event.target == contentModal) closeModal();
        if (event.target == importModal) importModal.style.display = 'none';
        if (event.target == bulkDeleteModal) bulkDeleteModal.style.display = 'none';
        const verifyModal = document.getElementById('verify-request-modal');
        if (verifyModal && event.target == verifyModal) verifyModal.style.display = 'none';
    };


    tabButtons.forEach(btn => {
        btn.onclick = () => {
            tabButtons.forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
            currentTab = btn.dataset.tab;
            selectedItemIds.clear();
            selectedRequestIds.clear();
            const delBtn = document.getElementById('delete-selected-btn');
            if (delBtn) delBtn.classList.add('hidden');

            const requestsContainer = document.getElementById('requests-container');

            if (currentTab === 'requests') {
                pageTitle.textContent = 'Solicitudes de Usuarios';
                filterCategory.classList.add('hidden');
                filterSeason.classList.add('hidden');
                manageSeasonsBtn.classList.add('hidden');
                renderRequests();
            } else {
                if (requestsContainer) requestsContainer.classList.add('hidden');
                filterCategory.classList.remove('hidden');
                pageTitle.textContent = currentTab === 'movies' ? 'Mis Películas' : 'Mis Series';
                if (!localStorage.getItem('viewMode')) viewMode = currentTab === 'series' ? 'grid' : 'list';
                applyFilters();
            }
        };
    });

    viewListBtn.onclick = () => { viewMode = 'list'; localStorage.setItem('viewMode', 'list'); applyFilters(); };
    viewGridBtn.onclick = () => { viewMode = 'grid'; localStorage.setItem('viewMode', 'grid'); applyFilters(); };
    typeSelect.onchange = handleTypeChange;
    contentForm.onsubmit = saveContent;
    const btnSearchTmdb = document.getElementById('btn-search-tmdb');
    if (btnSearchTmdb) btnSearchTmdb.onclick = searchTmdbForManualForm;
    searchInput.oninput = applyFilters;
    filterCategory.onchange = applyFilters;
    filterSeason.onchange = applyFilters;
    
    manageSeasonsBtn.onclick = openBulkDeleteModal;
    const deleteSelectedBtn = document.getElementById('delete-selected-btn');
    if (deleteSelectedBtn) deleteSelectedBtn.onclick = deleteSelectedItems;
    closeBulkDeleteBtns.forEach(btn => btn.onclick = () => bulkDeleteModal.style.display = 'none');
    confirmBulkDeleteBtn.onclick = confirmBulkDelete;



    const menuToggle = document.getElementById('mobile-menu-toggle');
    const sidebar = document.querySelector('.sidebar');
    const overlay = document.getElementById('sidebar-overlay');
    const navItems = document.querySelectorAll('.nav-item');
    const toggleSidebar = () => { sidebar.classList.toggle('active'); overlay.classList.toggle('active'); };
    menuToggle.onclick = toggleSidebar;
    overlay.onclick = toggleSidebar;
    navItems.forEach(item => { item.addEventListener('click', () => { if (window.innerWidth <= 1024) toggleSidebar(); }); });

    autoImportBtn.onclick = () => {
        importUrlInput.value = '';
        const catInput = document.getElementById('import-category');
        if (catInput) catInput.value = 'Recomendados';
        populateImportCategoryList();
        // Reset progress
        const bar = document.getElementById('full-import-bar');
        const status = document.getElementById('full-import-status');
        const progress = document.getElementById('full-import-progress');
        if (bar) { bar.style.width = '0%'; bar.style.background = 'var(--primary)'; }
        if (status) status.textContent = '';
        if (progress) progress.style.display = 'none';
        importModal.style.display = 'block';
    };

    closeImportModalBtns.forEach(btn => { btn.onclick = () => importModal.style.display = 'none'; });

    confirmImportBtn.onclick = async () => {
        const rawInput = importUrlInput.value.trim();
        if (!rawInput) {
            showToast('Por favor ingresa al menos una URL válida', 'error');
            return;
        }

        // ── Parsear el textarea: aislar URLs y asociar títulos personalizados ──
        // Separa cualquier URL aunque esté pegada a texto en la misma línea o con saltos de línea
        const tokens = rawInput
            .replace(/(https?:\/\/[^\s]+)/g, '\n$1\n')
            .split('\n')
            .map(t => t.trim())
            .filter(t => t.length > 0);

        const importEntries = [];
        let pendingTitle = null;

        for (let i = 0; i < tokens.length; i++) {
            const token = tokens[i];
            const isUrl = /^https?:\/\//i.test(token);

            if (isUrl) {
                const cleaned = cleanVideoUrl(token);
                // Si había un título previo pendiente (ej: título escrito antes de la URL)
                let customTitle = pendingTitle;
                pendingTitle = null;

                // Si no había título previo, revisar si el siguiente token es un título (escrito después de la URL)
                if (!customTitle && i + 1 < tokens.length && !/^https?:\/\//i.test(tokens[i + 1])) {
                    customTitle = tokens[i + 1];
                    i++; // consumir el token del título
                }

                importEntries.push({
                    url: cleaned,
                    customTitle: customTitle ? customTitle.trim() : null
                });
            } else {
                // Es texto no-URL: guardarlo como posible título para la siguiente URL
                pendingTitle = token;
            }
        }

        if (importEntries.length === 0) {
            showToast('No se encontraron URLs válidas en el texto', 'error');
            return;
        }

        // Leer la categoría seleccionada por el usuario
        const importCategoryInput = document.getElementById('import-category');
        const selectedCategory = (importCategoryInput && importCategoryInput.value.trim()) || 'Recomendados';

        const progressDiv = document.getElementById('full-import-progress');
        const statusEl = document.getElementById('full-import-status');
        const barEl = document.getElementById('full-import-bar');

        confirmImportBtn.disabled = true;
        confirmImportBtn.innerHTML = '<i data-lucide="loader-2" class="spinning"></i> Importando...';
        lucide.createIcons();
        if (progressDiv) progressDiv.style.display = 'block';
        if (barEl) barEl.style.width = '10%';
        if (statusEl) statusEl.textContent = `Procesando ${importEntries.length} enlace(s) → ${selectedCategory}...`;

        let successCount = 0;
        let skippedCount = 0;
        let failCount = 0;

        try {
            for (let i = 0; i < importEntries.length; i++) {
                const { url, customTitle } = importEntries[i];
                const pct = Math.round(((i + 1) / importEntries.length) * 100);
                if (barEl) barEl.style.width = pct + '%';
                if (statusEl) statusEl.textContent = `Procesando (${i + 1}/${importEntries.length}): ${customTitle || url.split('/').pop()}...`;

                // Detectar películas por URL — todo lo demás se importa como serie via edge function import-full-series
                const lowUrl = url.toLowerCase();
                const isPeelinkMovie = lowUrl.includes('peelink') && /\/ver-[^/]+-online\.html/.test(lowUrl);
                const isMovie = url.includes('/movie/') || url.includes('/pelicula/') || url.includes('/film/') || isPeelinkMovie;

                if (isMovie) {
                    // ── Importar como película ──
                    try {
                        // 1. Verificar si la película ya existe en el catálogo por URL
                        const existingByUrl = findExistingInCatalog(null, url, 'movie');
                        if (existingByUrl) {
                            skippedCount++;
                            const skipMsg = `Omitido (ya existe en catálogo): "${existingByUrl.title}"`;
                            if (statusEl) statusEl.textContent = `${skipMsg} (${i + 1}/${importEntries.length})`;
                            console.log(`[Import] Omitiendo película duplicada por URL: ${url} -> ${existingByUrl.title}`);
                            await sleep(250);
                            continue;
                        }

                        if (statusEl) statusEl.textContent = `Consultando TMDB y analizando película (${i + 1}/${importEntries.length}): ${customTitle || url.split('/').pop()}...`;
                        const meta = await parseMovieMetadataFromUrl(url);

                        let finalTitle = meta.title;
                        if (customTitle) {
                            finalTitle = customTitle.trim();
                            let movieYear = null;
                            const customYearMatch = finalTitle.match(/\((\d{4})\)$/);

                            if (customYearMatch) {
                                movieYear = customYearMatch[1];
                            } else {
                                // Consultar TMDB para el título personalizado
                                try {
                                    const tmdb = await fetchTmdbInfo(finalTitle, 'movie', meta.year);
                                    if (tmdb && tmdb.year) {
                                        movieYear = tmdb.year;
                                    } else if (meta.year) {
                                        movieYear = meta.year;
                                    }
                                } catch (_) {
                                    movieYear = meta.year;
                                }
                            }

                            if (movieYear && !finalTitle.match(/\(\d{4}\)$/)) {
                                finalTitle = `${finalTitle} (${movieYear})`;
                            }
                        }

                        // 2. Verificar si la película ya existe en el catálogo por título final (con año)
                        const existingByTitle = findExistingInCatalog(finalTitle, url, 'movie');
                        if (existingByTitle) {
                            skippedCount++;
                            const skipMsg = `Omitido (ya existe en catálogo): "${existingByTitle.title}"`;
                            if (statusEl) statusEl.textContent = `${skipMsg} (${i + 1}/${importEntries.length})`;
                            console.log(`[Import] Omitiendo película duplicada por título: "${finalTitle}" -> "${existingByTitle.title}"`);
                            await sleep(250);
                            continue;
                        }

                        const newItem = {
                            title: finalTitle,
                            video_url: url,
                            thumbnail_url: meta.thumbnail_url,
                            type: 'movie',
                            category: selectedCategory,
                            is_active: true
                        };

                        const { data: insertedRows, error } = await supabaseClient
                            .from('custom_content')
                            .insert([newItem])
                            .select();
                        if (error) throw error;

                        // Registrar en allContent para evitar duplicados en el mismo lote
                        if (insertedRows && insertedRows[0]) {
                            allContent.push(insertedRows[0]);
                        } else {
                            allContent.push(newItem);
                        }

                        successCount++;
                    } catch (mErr) {
                        console.error('Error al importar película:', mErr);
                        failCount++;
                    }
                } else {
                    // ── Importar como serie via edge function import-full-series ──
                    try {
                        let seriesTitleToSend = customTitle ? customTitle.trim() : null;
                        let seriesYear = null;

                        // 1. Verificar si la serie ya existe por título personalizado antes de llamar
                        if (seriesTitleToSend) {
                            const existingSeriesByTitle = findExistingInCatalog(seriesTitleToSend, null, 'series');
                            if (existingSeriesByTitle) {
                                skippedCount++;
                                const skipMsg = `Omitido (ya existe en catálogo): "${existingSeriesByTitle.title}"`;
                                if (statusEl) statusEl.textContent = `${skipMsg} (${i + 1}/${importEntries.length})`;
                                console.log(`[Import] Omitiendo serie duplicada por título: "${seriesTitleToSend}" -> "${existingSeriesByTitle.title}"`);
                                await sleep(250);
                                continue;
                            }
                        }

                        // 2. Verificar si ya existe a partir del slug de la URL
                        const existingSeriesByUrl = findExistingInCatalog(null, url, 'series');
                        if (existingSeriesByUrl) {
                            skippedCount++;
                            const skipMsg = `Omitido (ya existe en catálogo): "${existingSeriesByUrl.title}"`;
                            if (statusEl) statusEl.textContent = `${skipMsg} (${i + 1}/${importEntries.length})`;
                            console.log(`[Import] Omitiendo serie duplicada por slug/URL: ${url} -> "${existingSeriesByUrl.title}"`);
                            await sleep(250);
                            continue;
                        }

                        if (statusEl) statusEl.textContent = `Consultando TMDB y preparando serie (${i + 1}/${importEntries.length}): ${customTitle || url.split('/').pop()}...`;

                        // Si el usuario especificó un título personalizado pero no trae año, buscarlo en TMDB
                        if (seriesTitleToSend) {
                            const ym = seriesTitleToSend.match(/\((\d{4})\)$/);
                            if (ym) {
                                seriesYear = ym[1];
                            } else {
                                try {
                                    const tmdb = await fetchTmdbInfo(seriesTitleToSend, 'tv');
                                    if (tmdb && tmdb.year) {
                                        seriesYear = tmdb.year;
                                        seriesTitleToSend = `${seriesTitleToSend} (${seriesYear})`;
                                    }
                                } catch (_) {}
                            }
                        }

                        const { data, error } = await supabaseClient.functions.invoke('import-full-series', {
                            body: {
                                url,
                                custom_title: seriesTitleToSend,
                                category: selectedCategory
                            }
                        });
                        if (error) throw error;
                        if (data && data.error) throw new Error(data.error);

                        // Si la serie ya estaba y todos sus capítulos ya existían (total_episodes === 0)
                        if (data && data.total_episodes === 0 && (data.seasons_processed > 0 || data.series_id)) {
                            skippedCount++;
                            const skipMsg = `Omitido (ya existía serie con todos sus capítulos): "${data.series_title || seriesTitleToSend || 'Serie'}"`;
                            if (statusEl) statusEl.textContent = `${skipMsg} (${i + 1}/${importEntries.length})`;
                            console.log(`[Import] Serie ya completada en catálogo: ${data.series_title}`);
                            await sleep(250);
                            continue;
                        }

                        // Después de importar la serie, asegurar título con año correcto y categoría en la BD
                        const seriesId = data?.series_id || data?.series?.id;
                        if (seriesId) {
                            const updateData = {};
                            const seriesReturnedTitle = data?.series_title || (data?.series && data.series.title) || '';
                            let finalTitle = seriesTitleToSend || seriesReturnedTitle;

                            // Si el título retornado aún no tiene año (o queremos verificar con TMDB), resolver
                            if (!finalTitle.match(/\(\d{4}\)$/)) {
                                try {
                                    const tmdb = await fetchTmdbInfo(finalTitle, 'tv');
                                    if (tmdb && tmdb.year) {
                                        finalTitle = `${finalTitle} (${tmdb.year})`;
                                    }
                                } catch (_) {}
                            }

                            if (finalTitle && finalTitle !== seriesReturnedTitle) {
                                updateData.title = finalTitle;
                            }
                            if (selectedCategory && selectedCategory !== 'Recomendados') {
                                updateData.category = selectedCategory;
                            }
                            if (Object.keys(updateData).length > 0) {
                                await supabaseClient
                                    .from('custom_content')
                                    .update(updateData)
                                    .eq('id', seriesId);
                            }
                            // Asignar también la categoría elegida a todos los capítulos importados
                            if (selectedCategory && selectedCategory !== 'Recomendados') {
                                await supabaseClient
                                    .from('custom_content')
                                    .update({ category: selectedCategory })
                                    .eq('parent_id', seriesId);
                            }

                            // Registrar la serie en allContent para evitar duplicaciones en el mismo lote
                            if (!allContent.some(it => it.id === seriesId)) {
                                allContent.push({
                                    id: seriesId,
                                    title: finalTitle,
                                    type: 'series',
                                    category: selectedCategory,
                                    is_active: true
                                });
                            }
                        }

                        successCount++;
                    } catch (sErr) {
                        console.error('Error al importar serie:', sErr);
                        failCount++;
                    }
                }
            }

            if (barEl) { barEl.style.width = '100%'; barEl.style.background = 'var(--accent-green)'; }
            const msgParts = [];
            if (successCount > 0) msgParts.push(`${successCount} importado(s)`);
            if (skippedCount > 0) msgParts.push(`${skippedCount} ya existían (omitidos)`);
            if (failCount > 0) msgParts.push(`${failCount} fallidos`);
            const msg = msgParts.length > 0 ? `¡Listo! ${msgParts.join(', ')}.` : 'No se importó ningún contenido nuevo.';
            if (statusEl) statusEl.textContent = msg;
            showToast(msg, successCount > 0 ? 'success' : (skippedCount > 0 ? 'info' : 'error'));

            await sleep(1800);
            importModal.style.display = 'none';
            await fetchContent();
            if (activeSeriesFilter) {
                const eps = await fetchEpisodesForSeries(activeSeriesFilter);
                allContent = allContent.filter(it => !(it.type === 'episode' && it.parent_id === activeSeriesFilter));
                allContent = allContent.concat(eps);
                populateSeasonSelect(activeSeriesFilter);
            }
            applyFilters();
        } catch (err) {
            if (barEl) barEl.style.width = '0%';
            if (progressDiv) progressDiv.style.display = 'none';
            showToast('Error: ' + (err.message || 'Error desconocido'), 'error');
        } finally {
            confirmImportBtn.disabled = false;
            confirmImportBtn.innerHTML = '<i data-lucide="download-cloud"></i> Importar Todo';
            lucide.createIcons();
        }
    };

async function fetchPageHtml(url) {
    const fetchWithTimeout = (targetUrl, ms = 4500) => {
        return new Promise((resolve, reject) => {
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), ms);
            fetch(targetUrl, { signal: controller.signal })
                .then(res => {
                    clearTimeout(timer);
                    if (res.ok) return res.text();
                    reject(new Error('HTTP Error ' + res.status));
                })
                .then(text => {
                    if (!text || text.length < 50) return reject(new Error('Empty response'));
                    if (text.includes('"contents":') && text.trim().startsWith('{')) {
                        try {
                            const parsed = JSON.parse(text);
                            if (parsed.contents) return resolve(parsed.contents);
                        } catch (_) {}
                    }
                    resolve(text);
                })
                .catch(err => {
                    clearTimeout(timer);
                    reject(err);
                });
        });
    };

    // Detect if running locally (file://) or on Vercel (https://)
    const isLocal = window.location.protocol === 'file:';
    const VERCEL_BASE = 'https://bump-comba.vercel.app';

    // 1. Try Vercel Serverless Function Proxy - works from ANYWHERE (local file or deployed)
    try {
        const proxyBase = isLocal ? VERCEL_BASE : '';
        const vercelProxyUrl = `${proxyBase}/api/proxy?url=${encodeURIComponent(url)}`;
        console.log('[fetchPageHtml] Trying Vercel proxy:', vercelProxyUrl.substring(0, 100) + '...');
        const vercelText = await fetchWithTimeout(vercelProxyUrl, 10000);
        if (vercelText && vercelText.length > 200) {
            console.log('[fetchPageHtml] Vercel proxy SUCCESS, length:', vercelText.length);
            return vercelText;
        }
        console.log('[fetchPageHtml] Vercel proxy returned empty/short response');
    } catch (e) {
        console.warn('[fetchPageHtml] Vercel proxy FAILED:', e.message);
    }

    // 2. Try direct fetch (only works when deployed on same origin)
    if (!isLocal) {
        try {
            const directText = await fetchWithTimeout(url, 3000);
            if (directText && directText.length > 200) return directText;
        } catch (_) {}
    }

    // 3. Race public CORS proxies simultaneously as last resort backup
    const proxies = [
        `https://api.allorigins.win/raw?url=${encodeURIComponent(url)}`,
        `https://api.allorigins.win/get?url=${encodeURIComponent(url)}`
    ];

    try {
        return await Promise.any(proxies.map(p => fetchWithTimeout(p, 6000)));
    } catch (_) {
        return null;
    }
}

function sanitizeImageUrl(rawUrl) {
    if (!rawUrl) return '';
    try {
        let clean = rawUrl.trim().replace(/^["']|["']$/g, '');
        clean = clean.replace(/!$/, '');
        if (clean.includes('imageView2') || clean.includes('imageMogr2')) {
            clean = clean.replace(/\?(?:imageView2|imageMogr2).*$/, '');
        }
        if (clean.includes('img.') || clean.includes('/cover/')) {
            clean += '?imageView2/1/w/300/h/450/format/webp/q/82';
        }
        return encodeURI(clean);
    } catch (_) {
        return rawUrl;
    }
}

async function parseMovieMetadataFromUrl(url) {
    let title = '';
    let thumbnail_url = '';
    let category = 'Recomendados';

    console.log('[parseMovieMetadata] Starting extraction for:', url);
    const html = await fetchPageHtml(url);
    console.log('[parseMovieMetadata] HTML received:', html ? `${html.length} chars` : 'NULL');

    let propsData = null;

    if (html) {
        // ── 1. Next.js __NEXT_DATA__ JSON (Playspelis, Flixlat, Cuevana, 123flmsfree)
        const match = html.match(/<script id="__NEXT_DATA__" type="application\/json">(.*?)<\/script>/s);
        if (match && match[1]) {
            try {
                const data = JSON.parse(match[1]);
                const props = data.props?.pageProps || {};
                propsData = props;
                console.log('[parseMovieMetadata] __NEXT_DATA__ parsed OK, keys:', Object.keys(props).join(', '));

                // Title in Spanish
                if (props.name && typeof props.name === 'string') {
                    title = props.name.trim();
                    console.log('[parseMovieMetadata] Title from props.name:', title);
                } else if (props.title && typeof props.title === 'string') {
                    title = props.title.trim();
                    console.log('[parseMovieMetadata] Title from props.title:', title);
                }

                // Poster cover image URL
                const imgDomain = props.imgDomain || props.vestData?.imgDomain || '';
                const cover = props.coverVerticalUrl || props.coverHorizontalUrl || props.coverUrl || props.cover || '';
                console.log('[parseMovieMetadata] cover raw:', cover ? cover.substring(0, 80) + '...' : 'EMPTY');
                if (cover) {
                    if (cover.startsWith('http')) {
                        thumbnail_url = cover;
                    } else if (imgDomain) {
                        thumbnail_url = `${imgDomain.replace(/\/$/, '')}/${cover.replace(/^\//, '')}`;
                    }
                    console.log('[parseMovieMetadata] thumbnail_url set:', thumbnail_url.substring(0, 80) + '...');
                }

                // Category
                if (props.category && typeof props.category === 'string') {
                    category = props.category.trim();
                }
            } catch (e) {
                console.warn('[parseMovieMetadata] Error parsing __NEXT_DATA__:', e);
            }
        }

        // ── 2. DOM Title Extractions
        if (!title) {
            const nameMatch = html.match(/class="[^"]*\bname\b[^"]*"[^>]*>\s*([^<]+)\s*<\/div>/i);
            if (nameMatch && nameMatch[1]) {
                title = nameMatch[1].trim();
            }
        }

        if (!title) {
            const ogTitle = html.match(/<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']/i) ||
                            html.match(/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:title["']/i);
            if (ogTitle && ogTitle[1]) {
                title = ogTitle[1].trim();
            }
        }

        if (!title) {
            const imgAltMatch = html.match(/alt=["']([^"'\s][^"']{2,100})["']/i);
            if (imgAltMatch && imgAltMatch[1] && !['poster', 'cover', 'thumbnail', 'imagen'].includes(imgAltMatch[1].toLowerCase().trim())) {
                title = imgAltMatch[1].trim();
            }
        }

        // ── 3. DOM Image Extractions (Universal for ALL streaming sites)
        if (!thumbnail_url) {
            // Strategy A: src containing /cover/ path
            const coverPathMatch = html.match(/src=["'](https?:\/\/[^"'\s]*\/cover\/[^"'\s]+)["']/i);
            if (coverPathMatch && coverPathMatch[1]) {
                thumbnail_url = coverPathMatch[1].trim();
            }
        }

        if (!thumbnail_url) {
            // Strategy B: any <img ... src="..."> with class object-cover or coverImage
            const coverClassMatch = html.match(/<img[^>]+src=["'](https?:\/\/[^"'\s]+)["'][^>]*class="[^"]*(?:object-cover|coverImage)[^"]*"/i) ||
                                     html.match(/<img[^>]+class="[^"]*(?:object-cover|coverImage)[^"]*"[^>]*src=["'](https?:\/\/[^"'\s]+)["']/i);
            if (coverClassMatch && coverClassMatch[1]) {
                thumbnail_url = coverClassMatch[1].trim();
            }
        }

        if (!thumbnail_url) {
            // Strategy D: any src on img.<domain>
            const imgDomainMatch = html.match(/src=["'](https?:\/\/img\.[^"'\s]+\.(?:webp|jpg|png|jpeg)[^"'\s]*)["']/i);
            if (imgDomainMatch && imgDomainMatch[1]) {
                thumbnail_url = imgDomainMatch[1].trim();
            }
        }

        if (!thumbnail_url) {
            // Strategy E: <meta property="og:image" content="...">
            const ogImg = html.match(/<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']/i) ||
                          html.match(/<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']/i);
            if (ogImg && ogImg[1]) {
                thumbnail_url = ogImg[1].trim();
            }
        }
    }

    // ── 4. Fallback if HTML fetch fails completely: URL parsing & fallback domain image
    if (!title) {
        try {
            const urlObj = new URL(url);
            const parts = urlObj.pathname.split('/').filter(p => p.length > 0);
            const last = decodeURIComponent(parts[parts.length - 1] || '');

            if (last) {
                let t = last;
                if (t.includes('-')) {
                    const subParts = t.split('-');
                    if (subParts.length > 1 && subParts[0].length >= 10) {
                        t = subParts.slice(1).join(' ');
                    } else {
                        t = subParts.join(' ');
                    }
                }
                title = t.replace(/\b\w/g, c => c.toUpperCase());
            }
        } catch (_) {
            title = 'Película';
        }
    }

    // ── 5. Consultar TMDB para obtener el año real de estreno y poster oficial si falta
    let year = extractReleaseYear(propsData, thumbnail_url, html);
    let tmdbInfo = null;

    try {
        console.log('[parseMovieMetadata] Consultando TMDB para película:', title);
        tmdbInfo = await fetchTmdbInfo(title, 'movie', year);
        if (tmdbInfo && tmdbInfo.year) {
            year = tmdbInfo.year;
            console.log('[parseMovieMetadata] TMDB año confirmado:', year, 'Título oficial:', tmdbInfo.title);
        }
        // Si no teníamos thumbnail o era inválido, usar el poster oficial de TMDB
        if (!thumbnail_url && tmdbInfo && tmdbInfo.posterUrl) {
            thumbnail_url = tmdbInfo.posterUrl;
        }
    } catch (tmdbErr) {
        console.warn('[parseMovieMetadata] Error consultando TMDB:', tmdbErr);
    }

    if (title) {
        if (year) {
            // Reemplazar año antiguo/erróneo si ya venía uno, o agregar el año confirmado
            if (title.match(/\(\d{4}\)$/)) {
                title = title.replace(/\(\d{4}\)$/, `(${year})`);
            } else {
                title = `${title} (${year})`;
            }
        }
    }

    thumbnail_url = sanitizeImageUrl(thumbnail_url);

    console.log('[parseMovieMetadata] FINAL RESULT:', { title, thumbnail_url: thumbnail_url.substring(0, 80), category });
    return { title, thumbnail_url, category, year, tmdbInfo };
}

function extractReleaseYear(props, coverUrl, html) {
    if (props) {
        if (props.year) {
            const y = props.year.toString().match(/\b(19\d\d|20\d\d)\b/);
            if (y) return y[1];
        }
        if (props.releaseYear) {
            const y = props.releaseYear.toString().match(/\b(19\d\d|20\d\d)\b/);
            if (y) return y[1];
        }
        if (props.releaseDate) {
            const m = props.releaseDate.toString().match(/\b(19\d\d|20\d\d)\b/);
            if (m) return m[1];
        }
    }
    // NUNCA extraer año de la URL del CDN de cover (/cover/2026...) ni de regex libre en HTML,
    // ya que eso causa falsos años (ej: 2026 para películas de catálogo).
    return null;
}

    // (Botón auto-import de temporada eliminado — usar importación de serie completa)
}


function closeModal() { contentModal.style.display = 'none'; }

function handleTypeChange() {
    if (typeSelect.value === 'episode') { seriesFields.classList.remove('hidden'); }
    else { seriesFields.classList.add('hidden'); }
}

function applyFilters() {
    const query = searchInput.value.toLowerCase();
    const category = filterCategory.value;
    let filtered = [];
    if (currentTab === 'movies') {
        filtered = allContent.filter(item => item.type === 'movie');
    } else if (currentTab === 'series') {
        if (activeSeriesFilter) {
            const season = filterSeason.value;
            filtered = allContent.filter(item => item.type === 'episode' && item.parent_id === activeSeriesFilter);
            if (season !== 'all') filtered = filtered.filter(item => item.season === parseInt(season));
            filtered.sort((a, b) => (a.season - b.season) || (a.episode - b.episode));
        } else {
            filtered = allContent.filter(item => item.type === 'series');
        }
    }
    filtered = filtered.filter(item => {
        const matchesSearch = item.title.toLowerCase().includes(query);
        const matchesCategory = category === 'all' || item.category === category;
        return matchesSearch && matchesCategory;
    });
    renderContent(filtered);
}

function showToast(message, type = 'success') {
    toastMessage.textContent = message;
    toast.className = 'toast';
    if (type === 'error') toast.classList.add('error');
    toast.classList.remove('hidden');
    toastIcon.setAttribute('data-lucide', type === 'error' ? 'alert-circle' : 'check-circle');
    lucide.createIcons();
    setTimeout(() => toast.classList.add('hidden'), 5000);
}

// ─────────────────────────────────────────────────────────────────────────────
// SELECCIÓN POR ARRASTRE — click + deslizar para seleccionar múltiples filas
// ─────────────────────────────────────────────────────────────────────────────
(function setupDragSelect() {
    let isDragging = false;
    let dragSelectState = true; // true = seleccionar, false = deseleccionar
    let lastProcessedRow = null;

    // Obtener la fila <tr> más cercana desde cualquier elemento
    function getRow(el) {
        return el.closest('tr');
    }

    // Obtener el checkbox de una fila
    function getCheckbox(row) {
        return row ? row.querySelector('.row-checkbox, .request-checkbox') : null;
    }

    // Aplicar el estado de selección a un checkbox
    function applyToCheckbox(cb) {
        if (!cb || cb.checked === dragSelectState) return;
        cb.checked = dragSelectState;
        // Disparar el onchange manualmente
        const id = cb.value;
        if (cb.classList.contains('row-checkbox')) {
            onRowCheckboxChange(id, dragSelectState);
        } else if (cb.classList.contains('request-checkbox')) {
            onRequestCheckboxChange(id, dragSelectState);
        }
    }

    document.addEventListener('mousedown', (e) => {
        // Solo activar si el click es en un checkbox de fila o en la celda del checkbox
        const row = getRow(e.target);
        if (!row) return;
        const cb = getCheckbox(row);
        if (!cb) return;

        // Solo activar si el click fue en el checkbox o su celda contenedora (primera td)
        const firstTd = row.querySelector('td');
        if (!firstTd || !firstTd.contains(e.target)) return;

        isDragging = true;
        // El estado del drag depende del estado NUEVO del checkbox que se clickeó
        // Si estaba sin check → vamos a seleccionar, si estaba con check → vamos a deseleccionar
        dragSelectState = !cb.checked;
        lastProcessedRow = row;

        // Prevenir selección de texto durante el arrastre
        e.preventDefault();
        document.body.style.userSelect = 'none';
        document.body.style.webkitUserSelect = 'none';

        // Aplicar al checkbox clickeado
        applyToCheckbox(cb);
    });

    document.addEventListener('mouseover', (e) => {
        if (!isDragging) return;
        const row = getRow(e.target);
        if (!row || row === lastProcessedRow) return;
        const cb = getCheckbox(row);
        if (!cb) return;

        lastProcessedRow = row;
        applyToCheckbox(cb);
    });

    document.addEventListener('mouseup', () => {
        if (isDragging) {
            isDragging = false;
            lastProcessedRow = null;
            document.body.style.userSelect = '';
            document.body.style.webkitUserSelect = '';
        }
    });

    // Si el mouse sale de la ventana, terminar el drag
    document.addEventListener('mouseleave', () => {
        if (isDragging) {
            isDragging = false;
            lastProcessedRow = null;
            document.body.style.userSelect = '';
            document.body.style.webkitUserSelect = '';
        }
    });
})();